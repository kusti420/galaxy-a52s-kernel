// SPDX-License-Identifier: GPL-2.0
/* test consumer of the soft binding in <linux/a52sxq_userspace.h> (QEMU smoke test only) */
#include <linux/module.h>
#include <linux/a52sxq_userspace.h>

static int is_samsung_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%d\n", a52sxq_userspace_is_samsung());
}
static const struct kernel_param_ops ops = { .get = is_samsung_get };
module_param_cb(is_samsung, &ops, NULL, 0444);

static int __init t_init(void) { pr_info("a52us_test: at load is_samsung=%d\n", a52sxq_userspace_is_samsung()); return 0; }
static void __exit t_exit(void) { }
module_init(t_init);
module_exit(t_exit);
MODULE_LICENSE("GPL");
