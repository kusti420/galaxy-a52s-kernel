// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: /sys/kernel/mm/vmscan/{mem_boost_mode,am_app_launch} for the 6.12 GKI, as Samsung's
 * 5.4 kernel (SM-A528B, mm/vmscan.c 2394-2552, attribute group "vmscan" on mm_kobj).
 *
 * The show/store code, the mode range, the "%d\n" format and the 5 s timeout are taken from
 * Samsung's additions to mm/vmscan.c in the SM-A528B 5.4 kernel source
 * (Copyright (C) Samsung Electronics, GPL-2.0, same licence as that file).
 *
 *   mem_boost_mode  0644  "%d\n"  0 NO_BOOST, 1 BOOST_MID, 2 BOOST_HIGH, 3 BOOST_KILL;
 *                   anything else (or not a decimal int) -> -EINVAL. A read more than
 *                   MEM_BOOST_MAX_TIME (5 s) after the last write resets the mode to 0 first
 *                   (5.4 mem_boost_mode_show()). Written by lmkd and the camera HAL.
 *   am_app_launch   0644  "%d\n"  0 or 1, else -EINVAL. Written by the hyper HAL (BoostPath).
 *
 * STORE-ONLY on 6.12: no reclaim behaviour changes. On 5.4 a mode >= BOOST_HIGH (inside the 5 s
 * window) made kswapd's get_scan_count() reclaim file pages only (unless file cache was below
 * 200-500 MB), skipped the anon active-list rebalance at the end of shrink_lruvec(), skipped
 * drain_all_pages() in __alloc_pages_direct_reclaim() and woke the ION rbin pre-reclaim.
 * am_app_launch only fed an in-kernel notifier chain (no 6.12 consumers). All of these are
 * static code inside mm/; the 6.12 GKI runs MGLRU (CONFIG_LRU_GEN_ENABLED=y), where
 * get_scan_count() is not used for kswapd at all, and the only module-reachable knobs are
 * android_vh_* GKI vendor hooks (tune_swappiness, drain_all_pages_bypass, ...), which this module
 * deliberately does not register (GKI hooks are out of scope; the stored value is what a future
 * hook module would read). Writers get the 5.4 accept/reject behaviour and read-back, nothing more.
 *
 * mm_kobj is not exported by the GKI: the /sys/kernel/mm kobject is taken from its kernfs node
 * (kernfs_node::priv of a sysfs kobject directory is its kobject), like a52sxq_volkey does for
 * /sys/power. Init never fails: on any problem it logs once and loads without the nodes.
 */
#define pr_fmt(fmt) "a52sxq_mm_boost: " fmt
#include <linux/jiffies.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/kstrtox.h>
#include <linux/module.h>
#include <linux/sysfs.h>

/* mem_boost throttles only kswapd's behavior (5.4) */
enum mem_boost {
	NO_BOOST,
	BOOST_MID = 1,
	BOOST_HIGH = 2,
	BOOST_KILL = 3,
};
static int mem_boost_mode = NO_BOOST;
static unsigned long last_mode_change;
static bool am_app_launch;

#define MEM_BOOST_MAX_TIME (5 * HZ) /* 5 sec */

static void mem_boost_expire(void)
{
	if (time_after(jiffies, READ_ONCE(last_mode_change) + MEM_BOOST_MAX_TIME))
		WRITE_ONCE(mem_boost_mode, NO_BOOST);
}

static ssize_t mem_boost_mode_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	mem_boost_expire();
	return sysfs_emit(buf, "%d\n", READ_ONCE(mem_boost_mode));
}

static ssize_t mem_boost_mode_store(struct kobject *kobj, struct kobj_attribute *attr,
				    const char *buf, size_t count)
{
	int mode;
	int err;

	err = kstrtoint(buf, 10, &mode);
	if (err || mode > BOOST_KILL || mode < NO_BOOST)
		return -EINVAL;

	WRITE_ONCE(last_mode_change, jiffies);
	WRITE_ONCE(mem_boost_mode, mode);
	/* 5.4: mode >= BOOST_HIGH woke the ION rbin pre-reclaim; no rbin heap on 6.12 */
	return count;
}

static ssize_t am_app_launch_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(am_app_launch) ? 1 : 0);
}

static ssize_t am_app_launch_store(struct kobject *kobj, struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	int mode;
	int err;

	err = kstrtoint(buf, 10, &mode);
	if (err || (mode != 0 && mode != 1))
		return -EINVAL;
	/* 5.4 also called an in-kernel notifier chain on 0<->1 changes; nothing listens on 6.12 */
	WRITE_ONCE(am_app_launch, mode ? true : false);
	return count;
}

#define VMSCAN_ATTR(_name) \
	static struct kobj_attribute _name##_attr = \
		__ATTR(_name, 0644, _name##_show, _name##_store)
VMSCAN_ATTR(mem_boost_mode);
VMSCAN_ATTR(am_app_launch);

static struct attribute *vmscan_attrs[] = {
	&mem_boost_mode_attr.attr,
	&am_app_launch_attr.attr,
	NULL,
};

static const struct attribute_group vmscan_attr_group = {
	.attrs = vmscan_attrs,
	.name = "vmscan",
};

static struct kobject *mm_kobj_p;
static bool own_mm_kobj;	/* /sys/kernel/mm was missing and we created it */
static bool group_created;	/* we created /sys/kernel/mm/vmscan */
static unsigned long files_added;	/* bitmask into vmscan_attrs, when vmscan/ already existed */

static struct kobject *find_mm_kobj(void)
{
	struct kernfs_node *kn;
	struct kobject *k = NULL;

	if (!kernel_kobj || !kernel_kobj->sd)
		return NULL;
	kn = kernfs_find_and_get(kernel_kobj->sd, "mm");
	if (!kn)
		return NULL;
	if (kernfs_type(kn) == KERNFS_DIR && kn->priv)
		k = kobject_get(kn->priv);
	kernfs_put(kn);
	return k;
}

static bool has_child_kn(struct kernfs_node *dir, const char *name)
{
	struct kernfs_node *kn = kernfs_find_and_get(dir, name);

	if (kn)
		kernfs_put(kn);
	return kn != NULL;
}

static int __init a52_mm_boost_init(void)
{
	struct kernfs_node *dir;
	int i, ret;

	mm_kobj_p = find_mm_kobj();
	if (!mm_kobj_p && kernel_kobj) {
		mm_kobj_p = kobject_create_and_add("mm", kernel_kobj);
		own_mm_kobj = mm_kobj_p != NULL;
	}
	if (!mm_kobj_p) {
		pr_warn("no /sys/kernel/mm kobject: nodes not created\n");
		return 0;
	}

	dir = kernfs_find_and_get(mm_kobj_p->sd, "vmscan");
	if (!dir) {
		ret = sysfs_create_group(mm_kobj_p, &vmscan_attr_group);
		group_created = !ret;
		if (ret)
			pr_warn("vmscan group: %d\n", ret);
		return 0;
	}
	kernfs_put(dir);
	/* someone else owns /sys/kernel/mm/vmscan: add the missing files into it */
	for (i = 0; vmscan_attrs[i]; i++) {
		struct kernfs_node *d = kernfs_find_and_get(mm_kobj_p->sd, "vmscan");
		bool exists = false;

		if (d) {
			exists = has_child_kn(d, vmscan_attrs[i]->name);
			kernfs_put(d);
		}
		if (!exists && !sysfs_add_file_to_group(mm_kobj_p, vmscan_attrs[i], "vmscan"))
			files_added |= BIT(i);
	}
	return 0;
}

static void __exit a52_mm_boost_exit(void)
{
	int i;

	if (!mm_kobj_p)
		return;
	if (group_created)
		sysfs_remove_group(mm_kobj_p, &vmscan_attr_group);
	for (i = 0; vmscan_attrs[i]; i++)
		if (files_added & BIT(i))
			sysfs_remove_file_from_group(mm_kobj_p, vmscan_attrs[i], "vmscan");
	kobject_put(mm_kobj_p);	/* also frees /sys/kernel/mm if we created it */
}
module_init(a52_mm_boost_init);
module_exit(a52_mm_boost_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("a52sxq: /sys/kernel/mm/vmscan/mem_boost_mode + am_app_launch (Samsung 5.4 compat, store-only)");
