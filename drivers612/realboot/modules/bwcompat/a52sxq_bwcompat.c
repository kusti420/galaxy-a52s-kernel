// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: the 5.4 bw_hwmon devfreq nodes the ROM's Power HAL (libperfmgr, powerhint.json) writes:
 *   /sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/{min_freq,bw_hwmon/{hyst_trigger_count,hist_memory,
 *        hyst_length,sample_ms,io_percent}}
 *   /sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/{min_freq,bw_hwmon/{sample_ms,hist_memory,hyst_length,
 *        hyst_trigger_count}}
 * On 6.12 the same tunables are bwmon attributes under /sys/devices/system/cpu/bus_dcvs/, which the
 * Power HAL neither knows nor may write (label sysfs_devices_system_cpu): 1870 failed writes per
 * boot and no bus boost on interaction/launch.
 *
 * This module recreates the 5.4 paths: a platform device "soc:qcom,cpu-...-bw" under the soc
 * device, kobjects devfreq/<name>[/bw_hwmon] below it (so the real path is
 * /sys/devices/platform/soc/<name>/devfreq/<name>/..., which the ROM's genfs_contexts labels
 * vendor_sysfs_devfreq, writable by hal_power_default) and the /sys/class/devfreq/<name> link.
 * A write is forwarded to the bwmon attribute through kernfs + the attribute's own store()
 * (no VFS: a kernel-side open would be checked against the caller's SELinux domain).
 * min_freq is converted from the 5.4 unit (MB/s of the devfreq-icc OPP table: MHz * width / 1.048576,
 * width 16 for CPU-LLCC, 4 for LLCC-DDR) to bus_dcvs kHz, rounded to a MHz.
 * Not real devfreq devices: only the files above exist (no governor, cur_freq, ...).
 * Load any time after the soc platform device exists; the bwmon nodes are looked up per write.
 *
 * 2026-11-19 (b3, Power HAL retry storm: libperfmgr retries every failed node every 0.5 s for ever):
 * the other dead powerhint.json nodes, so that every write SUCCEEDS:
 *   group 2  /sys/devices/system/cpu/cpufreq/policyN/schedutil/{hispeed_freq,hispeed_load}
 *            (5.4 QGKI schedutil tunables; 6.12 runs mainline schedutil, which has neither). The two
 *            files are ADDED TO THE EXISTING schedutil directory of each policy
 *            (sysfs_add_file_to_group); the module never creates a directory of that name, so it cannot
 *            collide with the governor creating its own. A governor exit removes the directory with our
 *            files; a slow deferrable poll puts them back. Values are accepted and remembered only.
 *   group 4  /proc/sys/kernel/sched_{boost,prefer_spread,upmigrate,downmigrate,group_upmigrate,
 *            group_downmigrate} (5.4 WALT sysctls; 6.12 WALT has them under /proc/sys/walt with
 *            other value formats: per-cluster lists with ordering rules, no prefer_spread). Accepted
 *            and remembered. Only sched_boost has an exact equivalent (sched_set_boost(), same types
 *            0..2): forwarded when forward bit 4 is set (default OFF: it changes scheduling on every
 *            interaction and has not run on 6.12 yet).
 * NOT here: /sys/class/kgsl/kgsl-3d0/force_{clk,rail}_on. Those attributes exist; their store()
 * returns -EOPNOTSUPP because the GPU has a GMU (kgsl_pwrctrl.c __force_on_store): fix belongs there.
 *
 * Parameters: groups (0444, bit 1 = bw nodes, 2 = schedutil files, 4 = sysctls; default 7),
 * forward (0644, bit 1 = bw nodes -> bwmon (default), bit 4 = sched_boost -> WALT; default 1).
 * RULES of this file: a store never returns an error for a well-formed number (a failing forward is
 * logged, the value kept: an error would bring the retry storm back); nothing here divides by a
 * written value; every value is clamped before it is forwarded; module init never fails.
 */
#define pr_fmt(fmt) "a52sxq_bwcompat: " fmt
#include <linux/cpufreq.h>
#include <linux/device.h>
#include <linux/sysctl.h>
#include <linux/workqueue.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return rcu_dereference_raw(kn->__parent); }
#else
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return kn->parent; }
#endif

#define G_BW		0x1
#define G_SCHEDUTIL	0x2
#define G_SYSCTL	0x4
static unsigned int groups = G_BW | G_SCHEDUTIL | G_SYSCTL;
module_param(groups, uint, 0444);
MODULE_PARM_DESC(groups, "node groups to create: 1 bw_hwmon devfreq nodes, 2 schedutil hispeed files, 4 /proc/sys/kernel/sched_* (default 7)");
static unsigned int forward = G_BW;
module_param(forward, uint, 0644);
MODULE_PARM_DESC(forward, "forward writes: 1 bw nodes -> bus_dcvs bwmon (default), 4 sched_boost -> WALT sched_set_boost (default off)");

#define NATTR 6
static const char *const bw_attr_names[NATTR] = {
	"min_freq", "hyst_trigger_count", "hist_memory", "hyst_length", "sample_ms", "io_percent",
};

struct bw_file {
	struct kobj_attribute attr;
	struct bw_node *node;
	unsigned int last;		/* last value written, in the 5.4 unit */
	bool written;
};

struct bw_node {
	const char *name;		/* 5.4 device name */
	const char *target;		/* 6.12 bwmon directory, relative to /sys */
	unsigned int width;		/* bus width (bytes) of the 5.4 OPP table */
	unsigned int nattr;		/* how many of bw_attr_names (0 = min_freq) */
	struct platform_device *pdev;
	struct kobject *devfreq, *dev, *hwmon;
	bool link;
	struct bw_file f[NATTR];
};

static struct bw_node bw_nodes[] = {
	{ .name = "soc:qcom,cpu-cpu-llcc-bw", .target = "devices/system/cpu/bus_dcvs/LLCC/90b6400.qcom,bwmon-llcc", .width = 16, .nattr = 6 },
	{ .name = "soc:qcom,cpu-llcc-ddr-bw", .target = "devices/system/cpu/bus_dcvs/DDR/9091000.qcom,bwmon-ddr", .width = 4, .nattr = 5 },
};
static struct kobject *devfreq_class_kobj;

static struct kernfs_node *sysfs_root(void)
{
	struct kernfs_node *kn;

	if (!kernel_kobj || !kernel_kobj->sd)
		return NULL;
	for (kn = kernel_kobj->sd; a52_kn_parent(kn); kn = a52_kn_parent(kn))
		;
	return kn;
}

/* "a/b/c" below the sysfs root -> referenced kernfs node (symlinks followed), or NULL */
static struct kernfs_node *kn_lookup(const char *path)
{
	struct kernfs_node *kn = sysfs_root(), *next;
	char *dup, *p, *comp;

	if (!kn)
		return NULL;
	dup = kstrdup(path, GFP_KERNEL);
	if (!dup)
		return NULL;
	kernfs_get(kn);
	p = dup;
	while (kn && (comp = strsep(&p, "/"))) {
		if (!*comp)
			continue;
		next = kernfs_find_and_get(kn, comp);
		kernfs_put(kn);
		kn = next;
		if (kn && kernfs_type(kn) == KERNFS_LINK) {
			next = kn->symlink.target_kn;
			kernfs_get(next);
			kernfs_put(kn);
			kn = next;
		}
	}
	kfree(dup);
	return kn;
}

/* store() of a regular sysfs attribute, as sysfs_kf_write() calls it */
static ssize_t attr_store(const char *path, const char *val)
{
	struct kernfs_node *kn = kn_lookup(path), *parent;
	const struct sysfs_ops *ops;
	struct kobject *kobj;
	ssize_t n = -EIO;
	char *buf;

	if (!kn)
		return -ENOENT;
	parent = a52_kn_parent(kn);
	if (kernfs_type(kn) != KERNFS_FILE || !parent || !parent->priv || !kn->priv) {
		kernfs_put(kn);
		return -EINVAL;
	}
	kobj = kobject_get_unless_zero(parent->priv);
	if (!kobj) {
		kernfs_put(kn);
		return -ENODEV;
	}
	ops = kobj->ktype ? kobj->ktype->sysfs_ops : NULL;
	buf = kzalloc(PAGE_SIZE, GFP_KERNEL);
	if (!buf)
		n = -ENOMEM;
	else if (ops && ops->store)
		n = ops->store(kobj, kn->priv, buf, strscpy(buf, val, PAGE_SIZE));
	kfree(buf);
	kobject_put(kobj);
	kernfs_put(kn);
	return n;
}

static ssize_t bw_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct bw_file *f = container_of(attr, struct bw_file, attr);

	return sysfs_emit(buf, "%u\n", f->last);
}

/* what the bwmon store() of each attribute accepts (bwmon.c clamps as well; this is our own belt):
 * hyst_trigger_count / hist_memory / hyst_length 0..90, sample_ms 1..50, io_percent 1..400 */
static const unsigned int bw_min[NATTR] = { 0, 0, 0, 0, 1, 1 };
static const unsigned int bw_max[NATTR] = { 100000 /* MB/s */, 90, 90, 90, 50, 400 };

static ssize_t bw_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t n)
{
	struct bw_file *f = container_of(attr, struct bw_file, attr);
	unsigned int i = f - f->node->f;
	char path[160], val[16];
	unsigned int v, out;
	ssize_t ret;

	if (kstrtouint(buf, 10, &v) < 0)
		return -EINVAL;
	if (i >= NATTR)
		return n;
	v = clamp(v, bw_min[i], bw_max[i]);
	f->last = v;
	f->written = true;
	if (!(forward & G_BW))
		return n;
	out = v;
	if (i == 0) {
		/* MB/s -> kHz: MHz = MBps * 1.048576 / width, rounded to a MHz (v <= 100000: no overflow) */
		u64 khz = div_u64((u64)v * 1048576ULL, f->node->width * 1000U);

		out = (unsigned int)div_u64(khz + 500, 1000) * 1000U;
	}
	snprintf(path, sizeof(path), "%s/%s", f->node->target, attr->attr.name);
	snprintf(val, sizeof(val), "%u", out);
	ret = attr_store(path, val);
	/* never an error to the writer: libperfmgr retries a failed node every 0.5 s for ever */
	if (ret < 0)
		pr_warn_ratelimited("%s <- %s: %zd (value kept, not applied)\n", path, val, ret);
	return n;
}

static void bw_remove(struct bw_node *b)
{
	if (b->link)
		sysfs_remove_link(devfreq_class_kobj, b->name);
	kobject_put(b->hwmon);		/* removes its files */
	kobject_put(b->dev);
	kobject_put(b->devfreq);
	if (b->pdev)
		platform_device_unregister(b->pdev);
	b->pdev = NULL;
	b->devfreq = b->dev = b->hwmon = NULL;
	b->link = false;
}

static int bw_add(struct bw_node *b, struct device *soc)
{
	unsigned int i;
	int ret;

	b->pdev = platform_device_alloc(b->name, PLATFORM_DEVID_NONE);
	if (!b->pdev)
		return -ENOMEM;
	b->pdev->dev.parent = soc;
	ret = platform_device_add(b->pdev);
	if (ret) {
		platform_device_put(b->pdev);
		b->pdev = NULL;
		return ret;
	}
	b->devfreq = kobject_create_and_add("devfreq", &b->pdev->dev.kobj);
	if (!b->devfreq)
		return -ENOMEM;
	b->dev = kobject_create_and_add(b->name, b->devfreq);
	if (!b->dev)
		return -ENOMEM;
	b->hwmon = kobject_create_and_add("bw_hwmon", b->dev);
	if (!b->hwmon)
		return -ENOMEM;
	for (i = 0; i < b->nattr; i++) {
		struct bw_file *f = &b->f[i];

		f->node = b;
		sysfs_attr_init(&f->attr.attr);
		f->attr.attr.name = bw_attr_names[i];
		f->attr.attr.mode = 0644;
		f->attr.show = bw_show;
		f->attr.store = bw_store;
		ret = sysfs_create_file(i ? b->hwmon : b->dev, &f->attr.attr);
		if (ret)
			return ret;
	}
	if (devfreq_class_kobj && !sysfs_create_link(devfreq_class_kobj, b->dev, b->name))
		b->link = true;
	else
		pr_warn("no /sys/class/devfreq/%s link\n", b->name);
	return 0;
}

/* ------------------------------------------------------------------ group 2: schedutil hispeed files */
#define SU_MAXPOL 4
static unsigned int su_val[SU_MAXPOL][2];	/* [policy slot][0 hispeed_freq, 1 hispeed_load] */
static int su_cpu[SU_MAXPOL] = { -1, -1, -1, -1 };	/* first related CPU of the slot's policy */

/* governor_store() does not pass the attribute, so each (slot, file) has its own functions */
#define SU_FILE(slot, idx, fname, vmax)								\
static ssize_t su_show_##slot##_##idx(struct gov_attr_set *as, char *buf)			\
{												\
	return sysfs_emit(buf, "%u\n", su_val[slot][idx]);					\
}												\
static ssize_t su_store_##slot##_##idx(struct gov_attr_set *as, const char *buf, size_t n)	\
{												\
	unsigned int v;										\
												\
	if (kstrtouint(buf, 10, &v) < 0)							\
		return -EINVAL;									\
	su_val[slot][idx] = min(v, vmax);							\
	return n;										\
}
#define SU_SLOT(slot)						\
	SU_FILE(slot, 0, hispeed_freq, 10000000U)		\
	SU_FILE(slot, 1, hispeed_load, 100U)
SU_SLOT(0) SU_SLOT(1) SU_SLOT(2) SU_SLOT(3)
#define SU_ATTR(slot, idx, fname) \
	{ .attr = { .name = #fname, .mode = 0644 }, .show = su_show_##slot##_##idx, .store = su_store_##slot##_##idx }
static struct governor_attr su_attr[SU_MAXPOL][2] = {
	{ SU_ATTR(0, 0, hispeed_freq), SU_ATTR(0, 1, hispeed_load) },
	{ SU_ATTR(1, 0, hispeed_freq), SU_ATTR(1, 1, hispeed_load) },
	{ SU_ATTR(2, 0, hispeed_freq), SU_ATTR(2, 1, hispeed_load) },
	{ SU_ATTR(3, 0, hispeed_freq), SU_ATTR(3, 1, hispeed_load) },
};
static const char su_dir[] = "schedutil";
static struct delayed_work su_work;
static unsigned int su_polls;
static bool su_stop;

/* 1 = the file in <policy>/schedutil is ours, 0 = no such file, -1 = no directory or somebody else's file */
static int su_file_state(struct cpufreq_policy *policy, struct governor_attr *ga)
{
	struct kernfs_node *dir, *kn;
	int st;

	if (!policy->kobj.sd)
		return -1;
	dir = kernfs_find_and_get(policy->kobj.sd, su_dir);
	if (!dir)
		return -1;
	if (kernfs_type(dir) != KERNFS_DIR) {
		kernfs_put(dir);
		return -1;
	}
	kn = kernfs_find_and_get(dir, ga->attr.name);
	st = !kn ? 0 : (kn->priv == &ga->attr ? 1 : -1);
	if (kn)
		kernfs_put(kn);
	kernfs_put(dir);
	return st;
}

static void su_sync(bool remove)
{
	unsigned int cpu, slot, i;

	for_each_possible_cpu(cpu) {
		struct cpufreq_policy *policy = cpufreq_cpu_get(cpu);
		unsigned int first;

		if (!policy)
			continue;
		first = cpumask_first(policy->related_cpus);
		if (first != cpu)
			goto put;
		for (slot = 0; slot < SU_MAXPOL; slot++)
			if (su_cpu[slot] == first || su_cpu[slot] < 0)
				break;
		if (slot == SU_MAXPOL)
			goto put;
		su_cpu[slot] = first;
		for (i = 0; i < 2; i++) {
			struct governor_attr *ga = &su_attr[slot][i];
			int st = su_file_state(policy, ga);

			if (remove) {
				if (st == 1)
					sysfs_remove_file_from_group(&policy->kobj, &ga->attr, su_dir);
			} else if (st == 0) {
				/* -ENOENT (directory just went away) and -EEXIST are both fine */
				if (!sysfs_add_file_to_group(&policy->kobj, &ga->attr, su_dir))
					pr_info("policy%u/%s/%s added\n", first, su_dir, ga->attr.name);
			}
		}
put:
		cpufreq_cpu_put(policy);
	}
}

static void su_work_fn(struct work_struct *w)
{
	if (su_stop)
		return;
	su_sync(false);
	/* the governor recreates its directory on a governor change or a policy going offline/online:
	 * look every 2 s during the first 2 minutes (boot), every 30 s after (deferrable: no wakeup) */
	su_polls++;
	queue_delayed_work(system_power_efficient_wq, &su_work, su_polls < 60 ? 2 * HZ : 30 * HZ);
}

/* ------------------------------------------------------------------ group 4: /proc/sys/kernel/sched_* */
enum { SC_BOOST, SC_SPREAD, SC_UP, SC_DOWN, SC_GUP, SC_GDOWN, SC_N };
static int sc_val[SC_N];
static const int sc_max[SC_N] = { 5, 4, 1000, 1000, 1000, 1000 };
static struct ctl_table_header *sc_hdr;

static void sc_forward_boost(int type)
{
	int (*fn)(int) = (int (*)(int))__symbol_get("sched_set_boost");
	int ret;

	if (!fn) {
		pr_warn_ratelimited("sched_boost %d: no sched_set_boost (sched-walt not loaded)\n", type);
		return;
	}
	ret = fn(type);		/* WALT validates the type itself (-EINVAL) */
	if (ret)
		pr_warn_ratelimited("sched_set_boost(%d) = %d\n", type, ret);
	symbol_put_addr(fn);
}

static int sc_handler(const struct ctl_table *table, int write, void *buffer, size_t *lenp, loff_t *ppos)
{
	unsigned int idx = (int *)table->data - sc_val;
	int val = idx < SC_N ? sc_val[idx] : 0, ret;
	struct ctl_table tmp = { .data = &val, .maxlen = sizeof(int), .mode = table->mode };

	if (idx >= SC_N)
		return -EINVAL;
	ret = proc_dointvec(&tmp, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;
	val = clamp(val, 0, sc_max[idx]);
	sc_val[idx] = val;
	if (idx == SC_BOOST && (forward & G_SYSCTL) && val <= 2)
		sc_forward_boost(val);
	return 0;
}

#define SC_ENT(n, i) { .procname = n, .data = &sc_val[i], .maxlen = sizeof(int), .mode = 0644, .proc_handler = sc_handler }
static struct ctl_table sc_table[] = {
	SC_ENT("sched_boost", SC_BOOST),
	SC_ENT("sched_prefer_spread", SC_SPREAD),
	SC_ENT("sched_upmigrate", SC_UP),
	SC_ENT("sched_downmigrate", SC_DOWN),
	SC_ENT("sched_group_upmigrate", SC_GUP),
	SC_ENT("sched_group_downmigrate", SC_GDOWN),
};

/* ------------------------------------------------------------------ init: nothing here may fail the load */
static void bw_init(void)
{
	struct device *soc = bus_find_device_by_name(&platform_bus_type, NULL, "soc");
	struct kernfs_node *kn;
	unsigned int i;
	int ret = 0;

	if (!soc) {
		pr_warn("no soc platform device: no bw_hwmon nodes\n");
		return;
	}
	kn = kn_lookup("class/devfreq");
	if (kn && kernfs_type(kn) == KERNFS_DIR && kn->priv)
		devfreq_class_kobj = kobject_get(kn->priv);
	if (kn)
		kernfs_put(kn);
	for (i = 0; i < ARRAY_SIZE(bw_nodes) && !ret; i++)
		ret = bw_add(&bw_nodes[i], soc);
	put_device(soc);
	if (ret) {
		for (i = 0; i < ARRAY_SIZE(bw_nodes); i++)
			bw_remove(&bw_nodes[i]);
		kobject_put(devfreq_class_kobj);
		devfreq_class_kobj = NULL;
		pr_warn("bw_hwmon nodes not created: %d\n", ret);
		return;
	}
	pr_info("5.4 bw_hwmon nodes for the Power HAL: %zu devices -> bus_dcvs bwmon\n", ARRAY_SIZE(bw_nodes));
}

static int __init a52_bwcompat_init(void)
{
	if (groups & G_BW)
		bw_init();
	if (groups & G_SYSCTL) {
		/* fails (NULL) when a name already exists under /proc/sys/kernel: then the real one is there */
		sc_hdr = register_sysctl("kernel", sc_table);
		pr_info("/proc/sys/kernel/sched_{boost,prefer_spread,upmigrate,downmigrate,group_*}: %s\n",
			sc_hdr ? "registered (accept + remember)" : "NOT registered");
	}
	if (groups & G_SCHEDUTIL) {
		unsigned int a, b;

		for (a = 0; a < SU_MAXPOL; a++)
			for (b = 0; b < 2; b++)
				sysfs_attr_init(&su_attr[a][b].attr);
		INIT_DEFERRABLE_WORK(&su_work, su_work_fn);
		queue_delayed_work(system_power_efficient_wq, &su_work, HZ);
	}
	return 0;
}

static void __exit a52_bwcompat_exit(void)
{
	unsigned int i;

	if (groups & G_SCHEDUTIL) {
		su_stop = true;
		cancel_delayed_work_sync(&su_work);
		su_sync(true);
	}
	if (sc_hdr)
		unregister_sysctl_table(sc_hdr);
	for (i = 0; i < ARRAY_SIZE(bw_nodes); i++)
		bw_remove(&bw_nodes[i]);
	kobject_put(devfreq_class_kobj);
}
module_init(a52_bwcompat_init);
module_exit(a52_bwcompat_exit);
MODULE_DESCRIPTION("a52sxq: 5.4 sysfs/sysctl nodes of the ROM's Power HAL (bw_hwmon devfreq -> bus_dcvs bwmon, schedutil hispeed, WALT sysctls)");
MODULE_LICENSE("GPL");
