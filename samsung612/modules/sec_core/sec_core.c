// SPDX-License-Identifier: GPL-2.0-only
/*
 * sec_core: the smallest Samsung platform layer the Galaxy A52s 5G (a52sxq, SM7325) needs
 * on kernel 6.12.
 *
 * 1. /sys/class/sec and sec_device_create(): every Samsung board driver (touch, battery,
 *    muic, vibrator, hall, grip, fingerprint) puts its sysfs device there and closed vendor
 *    libraries open those paths. Port of the 5.4 drivers/samsung/sec_class.c.
 *
 * 2. The restart reasons the Samsung bootloader reads after a reset. In the 5.4 kernel three
 *    files write them: drivers/samsung/debug/sec_debug.c, drivers/power/reset/
 *    qcom-reboot-reason.c (with Samsung's CONFIG_SEC_DEBUG additions) and drivers/power/
 *    reset/msm-poweroff.c. This module reproduces the end state of those three for a clean
 *    reboot or power-off. It does not handle panics, upload mode or the param partition.
 *
 * Every address and value below is taken from the 5.4 kernel source
 * (kernel/samsung/sm7325 of the ROM tree) or from the phone's device tree
 * (downstream-dt/a52sxq-r02.dts); the comments name the place. Nothing here was run on
 * hardware yet.
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/atomic.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/reboot.h>
#include <linux/sec_class.h>
#include <linux/string.h>

/* ---------------------------------------------------------------- sec class */

static struct class *sec_class;
static atomic_t sec_dev;

static int sec_class_match_device_by_name(struct device *dev, const void *data)
{
	const char *name = data;

	return sysfs_streq(name, dev_name(dev));
}

/* The caller owns a reference on the returned device (put_device()), as in 5.4. */
struct device *sec_dev_get_by_name(const char *name)
{
	return class_find_device(sec_class, NULL, name,
				 sec_class_match_device_by_name);
}
EXPORT_SYMBOL(sec_dev_get_by_name);

/*
 * 5.4 calls BUG() when the class does not exist. Here that cannot happen: a module that
 * uses this symbol can only be loaded after this module's init has succeeded.
 */
struct device *___sec_device_create(void *drvdata, const char *fmt)
{
	struct device *dev;

	/* 5.4 numbers the devices 1, 2, 3... (major 0) the same way. */
	dev = device_create(sec_class, NULL, atomic_inc_return(&sec_dev),
			    drvdata, "%s", fmt);
	if (IS_ERR(dev))
		pr_err("failed to create device %s: %ld\n", fmt, PTR_ERR(dev));

	return dev;
}
EXPORT_SYMBOL(___sec_device_create);

void sec_device_destroy(dev_t devt)
{
	if (unlikely(!devt))
		pr_err("not allowed to destroy dev 0\n");
	else
		device_destroy(sec_class, devt);
}
EXPORT_SYMBOL_GPL(sec_device_destroy);

/* ---------------------------------------------------------- restart reasons */

/*
 * (a) IMEM restart reason: one u32 in the shared "imem" page.
 * DT (a52sxq-r02.dts:2246-2267): qcom,msm-imem@146aa000, child restart_reason@65c,
 * compatible "qcom,msm-imem-restart_reason", reg <0x65c 4>, i.e. physical 0x146aa65c.
 * Qualcomm's 6.12 yupik.dtsi has the same node. 5.4 finds it by that compatible and maps
 * it with of_iomap() (sec_debug.c:773-780, msm-poweroff.c:545-549); so does this module.
 *
 * Values: enum sec_restart_reason_t, include/linux/samsung/debug/sec_debug.h:119-130, and
 * the literals in msm-poweroff.c:437-468.
 */
#define SEC_RR_NORMAL			0x00000000
#define SEC_RR_BOOTLOADER		0x77665500
#define SEC_RR_REBOOT			0x77665501
#define SEC_RR_RECOVERY			0x77665502
#define SEC_RR_RTC			0x77665503
#define SEC_RR_DMVERITY_CORRUPTED	0x77665508
#define SEC_RR_DMVERITY_ENFORCE		0x77665509
#define SEC_RR_KEYS_CLEAR		0x7766550a

/*
 * (b) PON restart reason: 7 bits in the PMK8350 SDAM, which survive the PMIC reset.
 * DT (a52sxq-r02.dts:4955-4966): pmk8350 sdam@7100, cell restart@48, reg <0x48 1>,
 * bits <1 7>; consumer node "reboot_reason", compatible "qcom,reboot-reason",
 * nvmem-cell-names "restart_reason" (a52sxq-r02.dts:1951-1956). Qualcomm's 6.12 tree has
 * the same cell (pmk8350.dtsi) and consumer node (yupik-pmic-overlay.dtsi).
 *
 * Values: enum pon_restart_reason, include/linux/samsung/debug/sec_debug.h:185-228, and the
 * table in the 5.4 qcom-reboot-reason.c ("recovery-update" 0x60).
 */
#define PON_RR_RECOVERY			0x01
#define PON_RR_BOOTLOADER		0x02
#define PON_RR_RTC			0x03
#define PON_RR_DMVERITY_CORRUPTED	0x04
#define PON_RR_DMVERITY_ENFORCE		0x05
#define PON_RR_KEYS_CLEAR		0x06
#define PON_RR_NORMALBOOT		0x14
#define PON_RR_DOWNLOAD			0x15
#define PON_RR_NVBACKUP			0x16
#define PON_RR_NVRESTORE		0x17
#define PON_RR_NVERASE			0x18
#define PON_RR_NVRECOVERY		0x19
#define PON_RR_RECOVERY_UPDATE		0x60

static u32 __iomem *imem_restart_reason;
static struct nvmem_cell *pon_cell;

/*
 * On load, mark the IMEM cell "normal" (0). 5.4 does the opposite at boot: it arms upload
 * mode with 0x776655ee (sec_debug.c, sec_debug_init) and sets 0 again on every clean
 * reboot (sec_debug_normal_reboot_handler). This port has no upload-mode support, so the
 * cell should not keep whatever an earlier kernel or the bootloader left in it. Off with
 * clear_on_load=0.
 */
static bool clear_on_load = true;
module_param(clear_on_load, bool, 0444);

struct sec_reboot_cmd {
	const char *cmd;
	bool prefix;	/* 5.4 compares these with strncmp() */
	u8 pon;
	u32 imem;
};

/*
 * End state of the three 5.4 writers per reboot command.
 *  - PON: qcom-reboot-reason.c table (exact match), then the "magic" table in
 *    sec_debug_update_restart_reason() (prefix match; sec_debug.c:337-512).
 *  - IMEM: msm_restart_prepare() runs last and decides: "bootloader" and "recovery" by
 *    prefix, "rtc", "dm-verity ..." and "keys clear" exactly, anything else 0x77665501
 *    (msm-poweroff.c:437-468).
 * Order matters: exact entries first, then prefixes.
 */
static const struct sec_reboot_cmd sec_reboot_cmds[] = {
	{ "recovery-update",		false, PON_RR_RECOVERY_UPDATE,	   SEC_RR_RECOVERY },
	{ "rtc",			false, PON_RR_RTC,		   SEC_RR_RTC },
	{ "dm-verity device corrupted",	false, PON_RR_DMVERITY_CORRUPTED,  SEC_RR_DMVERITY_CORRUPTED },
	{ "dm-verity enforcing",	false, PON_RR_DMVERITY_ENFORCE,	   SEC_RR_DMVERITY_ENFORCE },
	{ "keys clear",			false, PON_RR_KEYS_CLEAR,	   SEC_RR_KEYS_CLEAR },
	{ "recovery",			true,  PON_RR_RECOVERY,		   SEC_RR_RECOVERY },
	{ "bootloader",			true,  PON_RR_BOOTLOADER,	   SEC_RR_BOOTLOADER },
	{ "download",			true,  PON_RR_DOWNLOAD,		   SEC_RR_REBOOT },
	{ "nvbackup",			true,  PON_RR_NVBACKUP,		   SEC_RR_REBOOT },
	{ "nvrestore",			true,  PON_RR_NVRESTORE,	   SEC_RR_REBOOT },
	{ "nverase",			true,  PON_RR_NVERASE,		   SEC_RR_REBOOT },
	{ "nvrecovery",			true,  PON_RR_NVRECOVERY,	   SEC_RR_REBOOT },
};

static void sec_reboot_write(u8 pon, u32 imem)
{
	int ret;

	if (imem_restart_reason)
		__raw_writel(imem, imem_restart_reason);

	if (pon_cell) {
		/* 5.4 writes one byte too; the nvmem core shifts it into bits 1..7. */
		ret = nvmem_cell_write(pon_cell, &pon, sizeof(pon));
		if (ret < 0)
			pr_err("PON restart reason 0x%02x not written: %d\n", pon, ret);
	}

	pr_emerg("restart reason: pon 0x%02x, imem 0x%08x\n", pon, imem);
}

static int sec_reboot_notify(struct notifier_block *nb, unsigned long action,
			     void *data)
{
	const char *cmd = data;
	size_t i;

	if (action != SYS_RESTART) {
		/*
		 * Power-off and halt: 5.4 only puts IMEM back to "normal"
		 * (sec_debug_normal_reboot_handler); the PON byte is left alone
		 * (qcom-reboot-reason.c skips sec_debug for SYS_POWER_OFF).
		 */
		if (imem_restart_reason)
			__raw_writel(SEC_RR_NORMAL, imem_restart_reason);
		return NOTIFY_DONE;
	}

	/* No command, or "adb...": normal boot (sec_debug.c:465, "goto __done"). */
	if (!cmd || !cmd[0] || !strncmp(cmd, "adb", 3)) {
		sec_reboot_write(PON_RR_NORMALBOOT, SEC_RR_NORMAL);
		return NOTIFY_DONE;
	}

	for (i = 0; i < ARRAY_SIZE(sec_reboot_cmds); i++) {
		const struct sec_reboot_cmd *c = &sec_reboot_cmds[i];

		if (c->prefix ? strncmp(cmd, c->cmd, strlen(c->cmd)) : strcmp(cmd, c->cmd))
			continue;
		sec_reboot_write(c->pon, c->imem);
		return NOTIFY_DONE;
	}

	/*
	 * Any other command ("shell", "userrequested", ...): IMEM 0x77665501 as in
	 * msm-poweroff.c:468. For the PON byte 5.4 writes "normal boot" (0x14) only for the
	 * commands its table names and leaves the byte untouched for the rest. This module
	 * writes 0x14 for all of them, so that a stale value can never pick the boot target.
	 * That is the one deliberate difference from 5.4.
	 */
	sec_reboot_write(PON_RR_NORMALBOOT, SEC_RR_REBOOT);
	return NOTIFY_DONE;
}

/*
 * Qualcomm's qcom-reboot-reason.c (6.12 soc-repo, compatible "qcom,reboot-reason") registers
 * with priority 255 and writes the same PON values for the commands it knows. This notifier
 * runs right after it and has the last word. If the device tree also has an upstream
 * "nvmem-reboot-mode" node on the same cell (priority 0, runs later), give it the same
 * values or remove it.
 */
static struct notifier_block sec_reboot_nb = {
	.notifier_call = sec_reboot_notify,
	.priority = 254,
};

static void sec_reboot_release(void)
{
	if (pon_cell)
		nvmem_cell_put(pon_cell);
	if (imem_restart_reason)
		iounmap(imem_restart_reason);
	pon_cell = NULL;
	imem_restart_reason = NULL;
}

/*
 * Returns -EPROBE_DEFER when the SDAM nvmem provider is not there yet (nvmem-qcom-spmi-sdam
 * is a module in the 6.12 lahaina config); load this module after it.
 * A missing node is not an error: the class is still useful on a tree without the nodes.
 */
static int sec_reboot_init(void)
{
	struct device_node *np;

	np = of_find_compatible_node(NULL, NULL, "qcom,msm-imem-restart_reason");
	if (np) {
		imem_restart_reason = of_iomap(np, 0);
		of_node_put(np);
	}
	if (!imem_restart_reason)
		pr_warn("no qcom,msm-imem-restart_reason node: IMEM reason not written\n");

	np = of_find_compatible_node(NULL, NULL, "qcom,reboot-reason");
	if (np) {
		pon_cell = of_nvmem_cell_get(np, "restart_reason");
		of_node_put(np);
		if (IS_ERR(pon_cell)) {
			int ret = PTR_ERR(pon_cell);

			pon_cell = NULL;
			if (ret == -EPROBE_DEFER) {
				sec_reboot_release();
				return ret;
			}
			pr_warn("nvmem cell restart_reason: %d\n", ret);
		}
	}
	if (!pon_cell)
		pr_warn("no restart_reason nvmem cell: PON reason not written\n");

	if (!imem_restart_reason && !pon_cell)
		return 0;

	if (clear_on_load && imem_restart_reason)
		__raw_writel(SEC_RR_NORMAL, imem_restart_reason);

	return register_reboot_notifier(&sec_reboot_nb);
}

/* ------------------------------------------------------------------ module */

static int __init sec_core_init(void)
{
	int ret;

	sec_class = class_create("sec");
	if (IS_ERR(sec_class)) {
		pr_err("failed to create class sec: %ld\n", PTR_ERR(sec_class));
		return PTR_ERR(sec_class);
	}

	ret = sec_reboot_init();
	if (ret) {
		class_destroy(sec_class);
		return ret;
	}

	pr_info("class sec ready; imem reason %s, pon reason %s\n",
		imem_restart_reason ? "mapped" : "absent",
		pon_cell ? "present" : "absent");
	return 0;
}

static void __exit sec_core_exit(void)
{
	if (imem_restart_reason || pon_cell)
		unregister_reboot_notifier(&sec_reboot_nb);
	sec_reboot_release();
	class_destroy(sec_class);
}

/* 5.4 creates the class at arch_initcall; as a module, load it before any Samsung driver. */
module_init(sec_core_init);
module_exit(sec_core_exit);

MODULE_DESCRIPTION("Samsung sec class and bootloader restart reasons for a52sxq");
MODULE_LICENSE("GPL");
