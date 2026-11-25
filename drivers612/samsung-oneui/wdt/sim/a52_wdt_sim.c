// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52_wdt_sim: QEMU-only backend for the a52 qcom_wdt_core variant (drivers612/samsung-oneui/wdt).
 * It registers with the core exactly as gh_virt_wdt does (same ops, same dev_pm_ops) and models the
 * hypervisor watchdog: armed flag, bark time, boot-time clock since the last pet (boot time also counts
 * the time spent suspended). A checker timer and every op report "WDTSIM: BARK" when an armed watchdog
 * was not petted for longer than the bark time: on the phone that is a reset.
 * fail_disable=1 makes the disable call fail (the hypervisor refusing), fail_enable=1 the enable call.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/mod_devicetable.h>
#include <linux/ktime.h>
#include <linux/timer.h>
#include <soc/qcom/watchdog.h>

static bool armed;
static u32 bark = 0xffff, bite = 0xffff;
static u64 last_pet_ns;
static unsigned int n_pet, n_enable, n_disable, n_bark, n_settime, max_gap_ms;
static bool fail_disable, fail_enable;
module_param(n_pet, uint, 0444); module_param(n_enable, uint, 0444); module_param(n_disable, uint, 0444);
module_param(n_bark, uint, 0444); module_param(n_settime, uint, 0444); module_param(max_gap_ms, uint, 0444);
module_param(armed, bool, 0444); module_param(bark, uint, 0444); module_param(bite, uint, 0444);
module_param(fail_disable, bool, 0644); module_param(fail_enable, bool, 0644);
static struct timer_list chk;

static void sim_check(const char *where)
{
	u64 gap = div_u64(ktime_get_boottime_ns() - last_pet_ns, NSEC_PER_MSEC);

	if (!armed)
		return;
	if (gap > max_gap_ms)
		max_gap_ms = gap;
	if (gap > bark) {
		n_bark++;
		pr_err("WDTSIM: BARK (%s): armed, %llu ms since the last pet, bark %u ms\n", where, gap, bark);
		last_pet_ns = ktime_get_boottime_ns();
	}
}
static void sim_timer(struct timer_list *t) { sim_check("timer"); mod_timer(&chk, jiffies + HZ / 4); }

static int sim_bark(u32 t, struct msm_watchdog_data *d) { sim_check("set_bark"); bark = (u16)t; n_settime++; return 0; }
static int sim_bite(u32 t, struct msm_watchdog_data *d) { sim_check("set_bite"); bite = (u16)t; n_settime++; return 0; }
static int sim_pet(struct msm_watchdog_data *d)
{
	sim_check("pet"); last_pet_ns = ktime_get_boottime_ns(); n_pet++;
	return 0;
}
static int sim_enable(u32 v, struct msm_watchdog_data *d)
{
	if (d->enabled)
		return 0;
	if (fail_enable)
		return -EIO;
	if (!armed)
		last_pet_ns = ktime_get_boottime_ns();
	armed = true; n_enable++;
	pr_info("WDTSIM: enable (bark %u bite %u)\n", bark, bite);
	return 0;
}
static int sim_disable(struct msm_watchdog_data *d)
{
	if (!d->enabled)
		return 0;
	sim_check("disable");
	if (fail_disable) {
		pr_info("WDTSIM: disable refused (fail_disable)\n");
		return -EIO;
	}
	armed = false; n_disable++;
	pr_info("WDTSIM: disable\n");
	return 0;
}
static int sim_status(struct msm_watchdog_data *d) { pr_info("WDTSIM: status armed=%d\n", armed); return 0; }
static struct qcom_wdt_ops sim_ops = {
	.set_bark_time = sim_bark, .set_bite_time = sim_bite, .reset_wdt = sim_pet,
	.enable_wdt = sim_enable, .disable_wdt = sim_disable, .show_wdt_status = sim_status,
};

static int sim_probe(struct platform_device *pdev)
{
	struct msm_watchdog_data *wdog_dd = devm_kzalloc(&pdev->dev, sizeof(*wdog_dd), GFP_KERNEL);
	int ret;

	if (!wdog_dd)
		return -ENOMEM;
	wdog_dd->ops = &sim_ops;
	ret = qcom_wdt_register(pdev, wdog_dd, "gh-watchdog");
	if (!ret) {
		timer_setup(&chk, sim_timer, 0);
		mod_timer(&chk, jiffies + HZ / 4);
	}
	return ret;
}
static void sim_remove(struct platform_device *pdev) { del_timer_sync(&chk); qcom_wdt_remove(pdev); }

/* the same callbacks gh_virt_wdt.c wires up */
static const struct dev_pm_ops sim_pm = {
	.suspend_late = qcom_wdt_pet_suspend, .resume_early = qcom_wdt_pet_resume,
	.freeze_late = qcom_wdt_pet_suspend, .restore_early = qcom_wdt_pet_resume,
};
static const struct of_device_id sim_match[] = { { .compatible = "a52,wdt-sim" }, {} };
MODULE_DEVICE_TABLE(of, sim_match);
static struct platform_driver sim_drv = {
	.probe = sim_probe, .remove = sim_remove,
	.driver = { .name = "a52-wdt-sim", .pm = &sim_pm, .of_match_table = sim_match },
};
module_platform_driver(sim_drv);
MODULE_DESCRIPTION("QEMU model of the hypervisor watchdog for qcom_wdt_core tests");
MODULE_LICENSE("GPL");
