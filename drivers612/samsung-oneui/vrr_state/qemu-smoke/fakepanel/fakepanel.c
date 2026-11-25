// SPDX-License-Identifier: GPL-2.0
/* QEMU smoke test only: registers /sys/class/lcd/panel (lcd.ko) like ss_create_sysfs() on the phone.
 * dup=1 also adds its own "vrr_state" so the compat module must leave it alone. */
#include <linux/device.h>
#include <linux/lcd.h>
#include <linux/module.h>
static bool dup;
module_param(dup, bool, 0444);
static struct lcd_device *ld;
static ssize_t vrr_state_show(struct device *d, struct device_attribute *a, char *buf) { return sysfs_emit(buf, "fake\n"); }
static DEVICE_ATTR_RO(vrr_state);
static int __init fp_init(void)
{
	ld = lcd_device_register("panel", NULL, NULL, NULL);
	if (IS_ERR(ld))
		return PTR_ERR(ld);
	if (dup && device_create_file(&ld->dev, &dev_attr_vrr_state))
		pr_warn("fakepanel: dup attr failed\n");
	pr_info("fakepanel: /sys/class/lcd/panel registered dup=%d\n", dup);
	return 0;
}
static void __exit fp_exit(void)
{
	lcd_device_unregister(ld);
	pr_info("fakepanel: unregistered\n");
}
module_init(fp_init);
module_exit(fp_exit);
MODULE_LICENSE("GPL");
