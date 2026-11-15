// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq_dsp_boot: start the ADSP and the CDSP of the Galaxy A52s once their firmware can be
 * read, for the REAL boot of LineageOS on the Qualcomm 6.12 kernel (drivers612/realboot).
 *
 * Why this exists: the test helper (drivers612/androidboot/kexec-rd/helper2.sh, stage suffix
 * "@adsp") wrote "start" to /sys/class/remoteproc/<adsp>/state every 3 s until Android had
 * mounted /vendor/firmware_mnt (apnhlos), then the CDSP, then loaded the audio modules. On a
 * real boot there is no helper, and:
 *  - the yupik ADSP has no auto_boot in qcom_q6v5_pas; the 5.4 ROM boots it through
 *    /sys/kernel/boot_adsp/boot (init.qcom.rc, early-boot), which only exists once
 *    adsp_loader_dlkm is loaded, and that module is part of the audio set that must load
 *    AFTER the ADSP runs (the codecs only enumerate then, 2026-11-13);
 *  - the CDSP has auto_boot, but it fires at probe time in the first stage, when the firmware
 *    partition is not mounted yet, so it stays offline;
 *  - init may not write /sys/class/remoteproc/... under enforcing SELinux.
 * So this module does what the helper did, in the kernel: retry rproc_boot() on the ADSP every
 * <interval_ms> (rproc_boot fails with -ENOENT until /vendor/firmware_mnt is mounted), then
 * boot the CDSP, then create /sys/kernel/a52sxq_dsp/adsp_running (and cdsp_running) so that
 * the vendor init rc (realboot/vendor-addon/etc/init/a52sxq-k612.rc) can `wait` for it and
 * modprobe the audio set. init may stat any sysfs file (sysfs_type getattr), so no policy
 * change is needed for that.
 *
 * DT (added by realboot/build-realboot.sh):
 *   a52sxq-dsp-boot { compatible = "a52sxq,dsp-boot";
 *                     qcom,adsp-rproc = <&adsp_pas>; qcom,cdsp-rproc = <&cdsp_pas>; };
 * Parameters: cdsp=0 leaves the CDSP alone; tries=, interval_ms=, settle_ms=.
 * Only the phone's own firmware (firmware_class.path) is ever used: this module names no file.
 */
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/remoteproc.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

static bool cdsp = true;
module_param(cdsp, bool, 0444);
MODULE_PARM_DESC(cdsp, "also boot the CDSP after the ADSP (default 1)");
static unsigned int tries = 120;
module_param(tries, uint, 0444);
MODULE_PARM_DESC(tries, "boot attempts per DSP before giving up (default 120)");
static unsigned int interval_ms = 2000;
module_param(interval_ms, uint, 0444);
static unsigned int settle_ms = 2000;
module_param(settle_ms, uint, 0444);

/*
 * WALT boot boost. sched-walt's walt_boost_init() starts with FULL_THROTTLE_BOOST (sched_boost 1)
 * and Qualcomm's 6.x post_boot clears it via /proc/sys/walt/sched_boost; this ROM's post_boot is
 * the 5.4 one (writes /proc/sys/kernel/sched_boost, absent on 6.x) and its vendor_init may not
 * write /proc/sys/walt (labelled plain proc), so the boost stayed on forever: CPUs pinned at max
 * frequency with the screen off (alpha1 tester report, 2026-11-15). Drop exactly the boot's
 * FULL_THROTTLE reference (sched_set_boost(-1)) after boot; other boost requests stay.
 * 0 = leave it alone.
 */
static unsigned int walt_boost_release_s = 45;
module_param(walt_boost_release_s, uint, 0444);
MODULE_PARM_DESC(walt_boost_release_s, "seconds after probe to drop WALT's boot FULL_THROTTLE boost (0 = keep)");

/*
 * L3 idle floor (2026-11-15, drivers612/busdcvs/L3-MEMLAT.md): the silver CPU domain's L3 vote port
 * EPSS 0x18591090 sits at index 7 (1190.4 MHz) from boot and nothing on 6.x writes it (5.4's RIMPS
 * memlat owned it), so the L3 never ran below 1.19 GHz. Measured on phone 1: writing 0 drops the idle
 * L3 to 250-555 MHz, restoring 7 brings 1.19 GHz back. The AP's own L3 votes go to the shared port
 * (0x18590090) and are unaffected. 0 = leave it alone.
 */
static bool l3_vote_release = true;
module_param(l3_vote_release, bool, 0444);
MODULE_PARM_DESC(l3_vote_release, "clear the stale silver-domain L3 vote (EPSS 0x18591090) after boot (default 1)");
#define A52_EPSS_SILVER_L3_VOTE 0x18591090

static void l3_vote_release_do(void)
{
	void __iomem *r = ioremap(A52_EPSS_SILVER_L3_VOTE, 4);
	u32 old;

	if (!r)
		return;
	old = readl_relaxed(r);
	writel_relaxed(0, r);
	iounmap(r);
	pr_info("a52sxq_dsp_boot: silver-domain L3 vote 0x%x -> 0 (L3 idle floor released)\n", old);
}

static void walt_boost_release_fn(struct work_struct *w)
{
	if (l3_vote_release)
		l3_vote_release_do();
	int (*set_boost)(int) = (int (*)(int))__symbol_get("sched_set_boost");
	int ret;

	if (!set_boost) {
		pr_info("a52sxq_dsp_boot: sched_set_boost not available, WALT boot boost left as is\n");
		return;
	}
	ret = set_boost(-1);
	symbol_put_addr(set_boost);
	pr_info("a52sxq_dsp_boot: WALT boot boost released (sched_set_boost(-1) = %d)\n", ret);
}
static DECLARE_DELAYED_WORK(walt_boost_work, walt_boost_release_fn);
MODULE_PARM_DESC(settle_ms, "wait after the ADSP runs before announcing it (helper2.sh: 2 s)");

enum { ST_ADSP, ST_SETTLE, ST_CDSP, ST_DONE };

struct dspboot {
	struct device *dev;
	struct delayed_work work;
	struct kobject *kobj;
	phandle ph_adsp, ph_cdsp;
	struct rproc *adsp, *cdsp;
	unsigned int n;
	int step;
	bool adsp_up, cdsp_up, adsp_file, cdsp_file;
};

static ssize_t state_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "1\n");
}
static struct kobj_attribute adsp_running_attr = __ATTR(adsp_running, 0444, state_show, NULL);
static struct kobj_attribute cdsp_running_attr = __ATTR(cdsp_running, 0444, state_show, NULL);

static bool running(struct rproc *r)
{
	return r && (r->state == RPROC_RUNNING || r->state == RPROC_ATTACHED);
}

/* one boot attempt; true when the processor runs afterwards */
static bool try_boot(struct dspboot *d, struct rproc **rp, phandle ph, const char *what)
{
	int ret;

	if (!*rp) {
		*rp = rproc_get_by_phandle(ph);
		if (!*rp)
			return false;	/* qcom_q6v5_pas has not probed this one yet */
	}
	if (running(*rp))
		return true;
	ret = rproc_boot(*rp);
	if (!ret) {
		dev_info(d->dev, "%s: booted after %u attempt(s)\n", what, d->n + 1);
		return true;
	}
	if (d->n == 0 || ret != -ENOENT)
		dev_info(d->dev, "%s: rproc_boot = %d (retrying every %u ms)\n", what, ret, interval_ms);
	return false;
}

static void dspboot_work(struct work_struct *w)
{
	struct dspboot *d = container_of(to_delayed_work(w), struct dspboot, work);

	switch (d->step) {
	case ST_ADSP:
		if (try_boot(d, &d->adsp, d->ph_adsp, "adsp")) {
			d->adsp_up = true; d->step = ST_SETTLE; d->n = 0;
			schedule_delayed_work(&d->work, msecs_to_jiffies(settle_ms));
			return;
		}
		break;
	case ST_SETTLE:
		if (!sysfs_create_file(d->kobj, &adsp_running_attr.attr))
			d->adsp_file = true;
		dev_info(d->dev, "adsp running: /sys/kernel/a52sxq_dsp/adsp_running\n");
		d->step = (cdsp && d->ph_cdsp) ? ST_CDSP : ST_DONE;
		if (d->step == ST_DONE)
			return;
		fallthrough;
	case ST_CDSP:
		if (try_boot(d, &d->cdsp, d->ph_cdsp, "cdsp")) {
			d->cdsp_up = true; d->step = ST_DONE;
			if (!sysfs_create_file(d->kobj, &cdsp_running_attr.attr))
				d->cdsp_file = true;
			return;
		}
		break;
	default:
		return;
	}
	if (++d->n >= tries) {
		dev_err(d->dev, "giving up on the %s after %u attempts\n",
			d->step == ST_ADSP ? "adsp" : "cdsp", d->n);
		d->step = ST_DONE;
		return;
	}
	schedule_delayed_work(&d->work, msecs_to_jiffies(interval_ms));
}

static int dspboot_probe(struct platform_device *pdev)
{
	struct device_node *np = pdev->dev.of_node;
	struct dspboot *d;
	u32 ph;

	d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;
	d->dev = &pdev->dev;
	if (of_property_read_u32(np, "qcom,adsp-rproc", &ph))
		return dev_err_probe(&pdev->dev, -EINVAL, "no qcom,adsp-rproc\n");
	d->ph_adsp = ph;
	if (!of_property_read_u32(np, "qcom,cdsp-rproc", &ph))
		d->ph_cdsp = ph;
	d->kobj = kobject_create_and_add("a52sxq_dsp", kernel_kobj);
	if (!d->kobj)
		return -ENOMEM;
	INIT_DELAYED_WORK(&d->work, dspboot_work);
	platform_set_drvdata(pdev, d);
	schedule_delayed_work(&d->work, 0);
	if (walt_boost_release_s)
		schedule_delayed_work(&walt_boost_work, msecs_to_jiffies(walt_boost_release_s * 1000));
	return 0;
}

static void dspboot_remove(struct platform_device *pdev)
{
	struct dspboot *d = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&d->work);
	cancel_delayed_work_sync(&walt_boost_work);
	if (d->adsp_file)
		sysfs_remove_file(d->kobj, &adsp_running_attr.attr);
	if (d->cdsp_file)
		sysfs_remove_file(d->kobj, &cdsp_running_attr.attr);
	kobject_put(d->kobj);
	/* the DSPs stay up: shutting them down under the audio stack would crash it */
	if (d->adsp)
		rproc_put(d->adsp);
	if (d->cdsp)
		rproc_put(d->cdsp);
}

static const struct of_device_id dspboot_match[] = {
	{ .compatible = "a52sxq,dsp-boot" },
	{ }
};
MODULE_DEVICE_TABLE(of, dspboot_match);

static struct platform_driver dspboot_driver = {
	.probe = dspboot_probe,
	.remove = dspboot_remove,
	.driver = { .name = "a52sxq-dsp-boot", .of_match_table = dspboot_match },
};
module_platform_driver(dspboot_driver);
MODULE_DESCRIPTION("a52sxq: boot ADSP and CDSP once their firmware is mounted (real-boot helper)");
MODULE_LICENSE("GPL");
