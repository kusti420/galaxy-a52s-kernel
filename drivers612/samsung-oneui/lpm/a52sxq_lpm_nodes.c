// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq 6.12: the Samsung reset-reason / lpm nodes that 5.4 really has on this phone.
 *
 * /proc/extra  5.4 drivers/samsung/debug/sec_hw_param.c:1460 (CONFIG_SEC_DEBUG): mode S_IWUGO
 *              (0222) with a seq_file read; prints the extended reset info (" RR:.. PANIC:..")
 *              ONLY when the debug partition holds a valid crash reset reason, otherwise the
 *              read returns 0 bytes ("updated nothing"). 6.12 has no sec_debug partition code,
 *              so the read is always empty = the 5.4 answer after a clean boot. Reader:
 *              /system/bin/resetreason (eRR.p), lpm.
 * /sys/module/a52sxq_lpm_nodes/parameters/lpm
 *              1 when the bootloader started power-off charging (a52_lpm_bootargs.h); for
 *              tests and logs. The kernel side that acts on it is sec-battery/sm5714_fuelgauge
 *              (patch 0001 in this directory).
 *
 * NOT created, on purpose (see README.md): /proc/pwrsrc and /sys/class/sec/pm/pwr_on_off_src
 * (no 5.4 A52s kernel has them: show_pwrsrc is commented out and never registered; the
 * PMK8350 PON is GEN3 = no PON/POFF reason registers, qpnp-power-on.c:2411), /dev/power_on_alarm
 * and rtc0/alarm_boot (CONFIG_RTC_AUTO_PWRON is not set in the 5.4 config).
 */
#define pr_fmt(fmt) "a52sxq_lpm_nodes: " fmt
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include "a52_lpm_bootargs.h"

static unsigned int lpm;
module_param(lpm, uint, 0444);
MODULE_PARM_DESC(lpm, "1 = booted for power-off charging (from /chosen/bootargs, read-only)");

static int extra_show(struct seq_file *m, void *v)
{
	return 0;	/* 5.4: nothing unless the last reset was a crash with stored ex_info */
}

static struct proc_dir_entry *extra;

static int __init a52sxq_lpm_nodes_init(void)
{
	lpm = a52_bootargs_lpm();
	extra = proc_create_single("extra", 0222, NULL, extra_show);
	if (!extra)
		pr_warn("/proc/extra exists already or failed\n");
	pr_info("lpm=%u, /proc/extra %s\n", lpm, extra ? "created" : "not created");
	return 0;
}

static void __exit a52sxq_lpm_nodes_exit(void)
{
	if (extra)
		proc_remove(extra);
}
module_init(a52sxq_lpm_nodes_init);
module_exit(a52sxq_lpm_nodes_exit);
MODULE_DESCRIPTION("a52sxq: /proc/extra (5.4 sec_hw_param) and lpm boot detection");
MODULE_LICENSE("GPL");
