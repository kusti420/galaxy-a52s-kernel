// SPDX-License-Identifier: GPL-2.0-only
/*
 * QEMU-only stand-in for the 6.12 gpio-keys hall (input "hall", EV_SW SW_LID).
 * Write 0/1 to /sys/module/fakehall/parameters/lid to report the switch.
 */
#include <linux/input.h>
#include <linux/module.h>

static struct input_dev *fh;

static int lid_set(const char *val, const struct kernel_param *kp)
{
	int ret = param_set_int(val, kp);

	if (!ret && fh) {
		input_report_switch(fh, SW_LID, !!*(int *)kp->arg);
		input_sync(fh);
	}
	return ret;
}
static const struct kernel_param_ops lid_ops = { .set = lid_set, .get = param_get_int };
static int lid;
module_param_cb(lid, &lid_ops, &lid, 0644);

static int __init fakehall_init(void)
{
	int ret;

	fh = input_allocate_device();
	if (!fh)
		return -ENOMEM;
	fh->name = "hall";
	input_set_capability(fh, EV_SW, SW_LID);
	ret = input_register_device(fh);
	if (ret) {
		input_free_device(fh);
		fh = NULL;
	}
	return ret;
}

static void __exit fakehall_exit(void)
{
	input_unregister_device(fh);
}

module_init(fakehall_init);
module_exit(fakehall_exit);
MODULE_LICENSE("GPL");
