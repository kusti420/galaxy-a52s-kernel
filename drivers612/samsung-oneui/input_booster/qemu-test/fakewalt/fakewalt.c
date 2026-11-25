// SPDX-License-Identifier: GPL-2.0
/* QEMU-only stand-in for sched-walt.ko: exports sched_set_boost and logs every call */
#include <linux/module.h>
#include <linux/kernel.h>
int sched_set_boost(int type);
int sched_set_boost(int type)
{
	pr_info("fakewalt: sched_set_boost(%d)\n", type);
	return 0;
}
EXPORT_SYMBOL_GPL(sched_set_boost);
static int __init fw_init(void) { return 0; }
module_init(fw_init);
MODULE_LICENSE("GPL");
