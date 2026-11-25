// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: /sys/class/lcd/panel/vrr_state and panel_vcom_type, as the stock A528BXXU5FWK4 5.4
 * msm_drm.ko shows them.
 *
 * Reader in the OneUI 9 port: only /system/bin/bootanimation (open, read up to 92 bytes, strip
 * trailing '\n'; an empty result = keep the default display projection; otherwise it parses
 * "<w>X<h>:<mode>" and sets a {0,0,w,h} layer-stack projection). init.samsung.display.rc
 * ("on init") chowns it system:system 0440.
 *
 * Stock 5.4 vrr_state_show() (ss_dsi_panel_sysfs.c, disassembled from the vendor's msm_drm.ko):
 * the stock module is built without CONFIG_SEC_PARAM, both local buffers are zero-initialised,
 * and both branches (panel with or without a sot_hs_mode timing) end in
 * snprintf(buf, 16, "%s\n", <empty>), so the node always reads exactly "\n" (1 byte). This module
 * shows the same. No msm_drm data is needed, so it does not depend on msm_drm.ko symbols.
 * (The LineageOS 5.4 source with CONFIG_SEC_PARAM reads/WRITES the param partition from show();
 * that path is not in the stock binary and is deliberately not reproduced.)
 *
 * The S23 framework on 6.12 has no vrr_state. Its /sys/class/lcd/panel device
 * (ss_create_sysfs -> lcd_device_register("panel", NULL, ...), lcd.ko class "lcd") is
 * /sys/devices/virtual/lcd/panel. Neither lcd_class nor the vdd is exported, so the device is
 * found through sysfs's kernfs tree: root -> class -> lcd -> panel (symlink) -> target dir,
 * whose kernfs_node::priv is the device's kobject (same technique as a52sxq_volkey for
 * /sys/power). Node mode 0444 (5.4 declared S_IRUGO|S_IWUSR|S_IWGRP with a NULL store, i.e.
 * writes failed with -EIO; 6.12's device_create_file() WARNs on a write bit without a store, and
 * kernfs refuses write opens of a file without write bits, even for root).
 *
 * Second node, /sys/class/lcd/panel/panel_vcom_type (5.4 DEVICE_ATTR S_IRUGO, show only): prints
 * "%d\n" of 1 if vdd->panel_func.samsung_cmd_log_read() returns non-zero, else 0 ("Vcom register
 * check for M44 model"). No 5.4 panel sets that callback (Lineage source), and the stock msm_drm.ko
 * has no store to vdd+0x1f8 (the callback slot its show() calls) and no such function, so on the
 * A52s it always reads "0\n". No reader in the OneUI 9 port (not even an init chown); added for
 * sysfs parity (drivers612/ONEUI9-PARITY.md display.panel_attrs).
 *
 * Each node is added only if the panel does not already have one of that name.
 *
 * init never fails and never blocks: the lookup runs from a delayed work and retries
 * (retry_ms, max_tries) until the panel device exists, then gives up quietly.
 */
#define pr_fmt(fmt) "a52sxq_vrr_state: " fmt
#include <linux/device.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/sysfs.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return rcu_dereference_raw(kn->__parent); }
#else
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return kn->parent; }
#endif

static unsigned int retry_ms = 250;
module_param(retry_ms, uint, 0444);
MODULE_PARM_DESC(retry_ms, "interval between lookups of /sys/class/lcd/panel (ms)");
static unsigned int max_tries = 2400;
module_param(max_tries, uint, 0444);
MODULE_PARM_DESC(max_tries, "lookups before giving up (default 2400 x 250 ms = 10 min)");

static struct device *panel_dev;	/* with a reference, once a node is added */
static unsigned int tries;
static void vrr_state_work_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(vrr_state_work, vrr_state_work_fn);

static ssize_t vrr_state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "\n");	/* stock A528BXXU5FWK4 output, see header */
}
static DEVICE_ATTR_RO(vrr_state);

static ssize_t panel_vcom_type_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", 0);	/* no samsung_cmd_log_read on this panel, see header */
}
static DEVICE_ATTR_RO(panel_vcom_type);

static struct device_attribute *a52_attrs[] = { &dev_attr_vrr_state, &dev_attr_panel_vcom_type };
static bool a52_added[ARRAY_SIZE(a52_attrs)];

/* kernfs node of /sys/class/lcd/panel's target directory, with a kernfs reference, or NULL */
static struct kernfs_node *panel_kn(void)
{
	struct kernfs_node *root, *a, *b, *t = NULL;

	if (!kernel_kobj || !kernel_kobj->sd)
		return NULL;
	for (root = kernel_kobj->sd; a52_kn_parent(root); root = a52_kn_parent(root))
		;
	a = kernfs_find_and_get(root, "class");
	if (!a)
		return NULL;
	b = kernfs_find_and_get(a, "lcd");
	kernfs_put(a);
	if (!b)
		return NULL;		/* lcd.ko not loaded yet */
	a = kernfs_find_and_get(b, "panel");
	kernfs_put(b);
	if (!a)
		return NULL;		/* panel not registered yet */
	if (kernfs_type(a) == KERNFS_LINK && a->symlink.target_kn) {
		t = a->symlink.target_kn;	/* the link holds a reference on its target */
		kernfs_get(t);
	} else if (kernfs_type(a) == KERNFS_DIR) {
		t = a;
		kernfs_get(t);
	}
	kernfs_put(a);
	if (t && (kernfs_type(t) != KERNFS_DIR || !t->priv)) {
		kernfs_put(t);
		t = NULL;
	}
	return t;
}

/* 1 = done (attached or nothing to do), 0 = try again */
static int vrr_state_attach(void)
{
	struct kernfs_node *kn = panel_kn(), *dup;
	struct device *dev;
	int i, ret, n = 0;

	if (!kn)
		return 0;
	dev = get_device(kobj_to_dev(kn->priv));
	if (!dev->class || strcmp(dev->class->name, "lcd") || strcmp(dev_name(dev), "panel")) {
		pr_warn("/sys/class/lcd/panel is not the lcd class panel device, not adding\n");
		put_device(dev);
		kernfs_put(kn);
		return 1;
	}
	for (i = 0; i < ARRAY_SIZE(a52_attrs); i++) {
		const char *name = a52_attrs[i]->attr.name;

		dup = kernfs_find_and_get(kn, name);
		if (dup) {
			kernfs_put(dup);
			pr_info("panel already has %s, not adding\n", name);
			continue;
		}
		ret = device_create_file(dev, a52_attrs[i]);
		if (ret) {
			pr_warn("device_create_file(%s): %d\n", name, ret);
			continue;
		}
		a52_added[i] = true;
		n++;
		pr_info("added /sys/class/lcd/panel/%s (after %u lookups)\n", name, tries);
	}
	kernfs_put(kn);
	if (n)
		panel_dev = dev;
	else
		put_device(dev);
	return 1;
}

static void vrr_state_work_fn(struct work_struct *w)
{
	tries++;
	if (vrr_state_attach())
		return;
	if (tries == 1)
		pr_info("no /sys/class/lcd/panel yet, retrying every %u ms\n", retry_ms);
	if (tries >= max_tries) {
		pr_info("no /sys/class/lcd/panel after %u lookups, giving up\n", tries);
		return;
	}
	schedule_delayed_work(&vrr_state_work, msecs_to_jiffies(retry_ms ? retry_ms : 1));
}

static int __init a52_vrr_state_init(void)
{
	schedule_delayed_work(&vrr_state_work, 0);
	return 0;
}

static void __exit a52_vrr_state_exit(void)
{
	cancel_delayed_work_sync(&vrr_state_work);
	if (panel_dev) {
		/* if the panel was unregistered meanwhile, its sysfs dir (and our file) is gone already */
		int i;

		for (i = 0; i < ARRAY_SIZE(a52_attrs); i++)
			if (a52_added[i] && panel_dev->kobj.state_in_sysfs && panel_dev->kobj.sd)
				device_remove_file(panel_dev, a52_attrs[i]);
		put_device(panel_dev);
		panel_dev = NULL;
	}
}
module_init(a52_vrr_state_init);
module_exit(a52_vrr_state_exit);
MODULE_DESCRIPTION("a52sxq: /sys/class/lcd/panel/{vrr_state,panel_vcom_type} (Samsung 5.4 / OneUI compat)");
MODULE_LICENSE("GPL");
