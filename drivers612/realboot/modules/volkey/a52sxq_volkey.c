// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: /sys/power/volkey_wakeup, as Samsung's 5.4 kernel (kernel/power/main.c CONFIG_SEC_PM ->
 * qpnp-power-on.c sec_set_resin_wk_int()): 0 (default) = the volume-down key (PMIC RESIN) does not
 * wake the phone from suspend, 1 = it does. The ROM's init.samsung.rc chowns the file to
 * radio:system 0660 and IchthysOS Abyss writes 1 (keys-only mode).
 *
 * 5.4 toggled enable_irq_wake() on the RESIN state IRQ. On 6.12 the key is a pm8941-pwrkey
 * platform device ("qcom,pmk8350-resin") that calls enable_irq_wake() in its suspend callback
 * when device_may_wakeup(): so the same switch is the device's wakeup enable. The driver's
 * default is "may wake"; this module sets the 5.4 default (off) when it finds the device.
 *
 * power_kobj is not exported by the GKI: the /sys/power kobject is taken from its kernfs node
 * (kernfs_node::priv of a sysfs directory is its kobject), reached from /sys/kernel.
 * Load after pm8941-pwrkey.ko. Param: resin_compat (default "qcom,pmk8350-resin").
 */
#define pr_fmt(fmt) "a52sxq_volkey: " fmt
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/pm_wakeup.h>
#include <linux/sysfs.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return rcu_dereference_raw(kn->__parent); }
#else
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return kn->parent; }
#endif

static char *resin_compat = "qcom,pmk8350-resin";
module_param(resin_compat, charp, 0444);
MODULE_PARM_DESC(resin_compat, "compatible of the volume-down (RESIN) key device");

static DEFINE_MUTEX(volkey_lock);
static int volkey_wakeup;		/* 5.4 default: 0 */
static bool volkey_applied;
static struct kobject *power_kobj_p;
static int tries;
static void volkey_retry(struct work_struct *w);
static DECLARE_DELAYED_WORK(volkey_work, volkey_retry);

/* the bound RESIN key device, with a reference, or NULL */
static struct device *resin_dev(void)
{
	struct device_node *np = of_find_compatible_node(NULL, NULL, resin_compat);
	struct platform_device *pdev;

	if (!np)
		return NULL;
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev)
		return NULL;
	if (!pdev->dev.driver || !device_can_wakeup(&pdev->dev)) {
		put_device(&pdev->dev);
		return NULL;
	}
	return &pdev->dev;
}

/* caller holds volkey_lock */
static int volkey_apply(void)
{
	struct device *dev = resin_dev();
	int ret;

	if (!dev)
		return -ENODEV;
	ret = device_set_wakeup_enable(dev, volkey_wakeup);
	pr_info("%s: volkey_wakeup = %d (%d)\n", dev_name(dev), volkey_wakeup, ret);
	put_device(dev);
	volkey_applied = !ret;
	return ret;
}

static void volkey_retry(struct work_struct *w)
{
	mutex_lock(&volkey_lock);
	if (!volkey_applied && volkey_apply() == -ENODEV && ++tries < 30)
		schedule_delayed_work(&volkey_work, HZ);
	else if (!volkey_applied)
		pr_warn("no bound %s device: volume-down wake state left as the driver set it\n", resin_compat);
	mutex_unlock(&volkey_lock);
}

static ssize_t volkey_wakeup_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", volkey_wakeup);
}

static ssize_t volkey_wakeup_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t n)
{
	int val;

	if (kstrtoint(buf, 10, &val) < 0)
		return -EINVAL;
	mutex_lock(&volkey_lock);
	if (volkey_wakeup != !!val || !volkey_applied) {
		volkey_wakeup = !!val;
		volkey_apply();
	}
	mutex_unlock(&volkey_lock);
	return n;
}
static struct kobj_attribute volkey_wakeup_attr = __ATTR(volkey_wakeup, 0644, volkey_wakeup_show, volkey_wakeup_store);

static int __init a52_volkey_init(void)
{
	struct kernfs_node *root, *kn;
	int ret;

	if (!kernel_kobj || !kernel_kobj->sd)
		return -ENODEV;
	for (root = kernel_kobj->sd; a52_kn_parent(root); root = a52_kn_parent(root))
		;
	kn = kernfs_find_and_get(root, "power");
	if (!kn)
		return -ENOENT;
	if (kernfs_type(kn) != KERNFS_DIR || !kn->priv) {
		kernfs_put(kn);
		return -EINVAL;
	}
	power_kobj_p = kobject_get(kn->priv);
	kernfs_put(kn);
	ret = sysfs_create_file(power_kobj_p, &volkey_wakeup_attr.attr);
	if (ret) {
		kobject_put(power_kobj_p);
		return ret;
	}
	schedule_delayed_work(&volkey_work, 0);
	return 0;
}

static void __exit a52_volkey_exit(void)
{
	cancel_delayed_work_sync(&volkey_work);
	sysfs_remove_file(power_kobj_p, &volkey_wakeup_attr.attr);
	kobject_put(power_kobj_p);
}
module_init(a52_volkey_init);
module_exit(a52_volkey_exit);
MODULE_DESCRIPTION("a52sxq: /sys/power/volkey_wakeup (Samsung 5.4 compat)");
MODULE_LICENSE("GPL");
