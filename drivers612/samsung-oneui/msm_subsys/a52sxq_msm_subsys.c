// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq_msm_subsys: the 5.4 /sys/bus/msm_subsys sysfs face for the stock
 * OneUI (A528BXXU5FWK4) vendor on the Galaxy A52s 6.12 kernel line.
 *
 * Attribute names, formats, accepted input and error codes follow the
 * Qualcomm msm-5.4 drivers/soc/qcom/subsystem_restart.c
 * (Copyright (c) 2011-2020, The Linux Foundation. All rights reserved.,
 * GPL-2.0-only), the driver that registered this bus on the phone's 5.4
 * kernel. No code of it is needed here: on 6.12 the processors are
 * remoteprocs and only the sysfs view is rebuilt.
 *
 *   /sys/bus/msm_subsys/devices/subsysN/
 *     name           0444  "<5.4 name>\n"
 *     state          0444  "ONLINE\n" / "OFFLINE\n" / "OFFLINING\n", from
 *                          the matching remoteproc at read time
 *     crash_count    0444  "%d\n", remoteproc crash_cnt (0 without one)
 *     restart_level  0644  "SYSTEM\n" / "RELATED\n"; prefix match, -EPERM
 *     firmware_name  0644  "<5.4 fw name>\n"
 *     system_debug   0644  "set\n" / "reset\n"; -EPERM
 *
 * Readers on OneUI: libmdmdetect.so + sec_diag_uart_log (name, state),
 * ssr_setup from init.qcom.rc (name, writes restart_level), ssr_diag.
 *
 * Numbering and the device path are the phone's own 5.4 ones
 * (research/blob-uapi-evidence/subsys.txt: /dev/subsys_* minors 0..6 =
 * subsys index; system_fds_raw.txt: /sys/devices/platform/soc/<PIL node>/
 * subsysN; downstream-dt/a52sxq-r02.dts qcom,firmware-name):
 *   0 yupik_ipa_fws  1 a660_zap  2 wpss  3 modem  4 adsp  5 cdsp  6 venus
 * The devices sit under an empty device named like the 5.4 PIL platform
 * device, a child of the /soc platform device, so the vendor genfscon /
 * file_contexts labels (/sys/devices/platform/soc/4080000.qcom,mss/subsys3
 * /name ...) apply unchanged.
 *
 * Coexistence: drivers612/conn/subsys_compat registers the same bus with
 * the same devices plus /dev/subsys_* and remoteproc control. This module
 * is the sysfs-only fallback: it never registers the bus when one already
 * exists, and when the module named by yield_to (default subsys_compat)
 * starts loading (MODULE_STATE_COMING, before its init runs) everything here
 * is removed synchronously so that module's bus_register() succeeds. If that
 * module goes away again, the fallback comes back.
 *
 * Module init never fails and never waits: every problem is logged and the
 * module stays loaded (a first-stage insmod failure is a bootloop).
 * Remoteprocs register long after first stage; they are looked up lazily,
 * on each state / crash_count read, and the reference is dropped again.
 */
#define pr_fmt(fmt) "a52sxq_msm_subsys: " fmt

#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/remoteproc.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/workqueue.h>

static char *msub_owner = "subsys_compat";
module_param_named(yield_to, msub_owner, charp, 0444);
MODULE_PARM_DESC(yield_to, "module that owns msm_subsys when loaded (empty = never yield)");

static char *msub_soc_path = "/soc";
module_param_named(soc_path, msub_soc_path, charp, 0444);
MODULE_PARM_DESC(soc_path, "DT path of the platform device the 5.4 PIL-named parents go under (empty = no parents)");

/* 5.4 default before ssr_setup runs: RESET_SOC ("SYSTEM") */
static bool default_related;
module_param(default_related, bool, 0444);
MODULE_PARM_DESC(default_related, "start with restart_level RELATED instead of the 5.4 default SYSTEM");

struct msub {
	int idx;		/* 5.4 subsysN */
	const char *name;	/* 5.4 desc->name (= qcom,firmware-name) */
	const char *node;	/* 5.4 PIL platform device name */
	const char *compat;	/* 6.12 remoteproc node, NULL = none */

	struct device *parent;
	struct device *dev;
	bool related;		/* restart_level RELATED */
	bool system_debug;
	char fw_name[64];
};

static struct msub msubs[] = {
	{ 0, "yupik_ipa_fws", "soc:qcom,ipa_fws", NULL },
	{ 1, "a660_zap", "soc:qcom,kgsl-hyp", NULL },
	{ 2, "wpss", "soc:qcom,wpss@8a00000", "qcom,yupik-wpss-pas" },
	{ 3, "modem", "4080000.qcom,mss", "qcom,yupik-modem-pas" },
	{ 4, "adsp", "3700000.qcom,lpass", "qcom,yupik-adsp-pas" },
	{ 5, "cdsp", "a300000.qcom,turing", "qcom,yupik-cdsp-pas" },
	{ 6, "venus", "aab0000.qcom,venus", NULL },
};

static DEFINE_MUTEX(msub_lock);	/* bus/devices up or down, yield state */
static bool msub_bus_up;
static bool msub_yielded;	/* the msub_owner module is loaded */
static bool msub_nb_ok;

enum { ST_OFFLINING, ST_OFFLINE, ST_ONLINE };
static const char * const msub_states[] = {
	[ST_OFFLINING] = "OFFLINING",
	[ST_OFFLINE] = "OFFLINE",
	[ST_ONLINE] = "ONLINE",
};

static const char * const msub_levels[] = { "SYSTEM", "RELATED" };

static struct msub *to_msub(struct device *dev)
{
	return dev_get_drvdata(dev);
}

/* remoteproc behind a subsystem with a reference, or NULL; rproc_put() it */
static struct rproc *msub_rproc_get(struct msub *s)
{
	struct device_node *np;
	struct rproc *rproc;

	if (!s->compat)
		return NULL;
	np = of_find_compatible_node(NULL, NULL, s->compat);
	if (!np)
		return NULL;
	rproc = rproc_get_by_phandle(np->phandle);
	of_node_put(np);
	return rproc;
}

static ssize_t name_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	return sysfs_emit(buf, "%s\n", to_msub(dev)->name);
}
static DEVICE_ATTR_RO(name);

static ssize_t state_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct rproc *rproc = msub_rproc_get(to_msub(dev));
	int st = ST_OFFLINE;

	if (rproc) {
		switch (READ_ONCE(rproc->state)) {
		case RPROC_RUNNING:
		case RPROC_ATTACHED:
		case RPROC_SUSPENDED:
			st = ST_ONLINE;
			break;
		case RPROC_CRASHED:
			st = ST_OFFLINING;	/* 5.4: shut down for SSR */
			break;
		default:
			break;
		}
		rproc_put(rproc);
	}
	return sysfs_emit(buf, "%s\n", msub_states[st]);
}
static DEVICE_ATTR_RO(state);

static ssize_t crash_count_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct rproc *rproc = msub_rproc_get(to_msub(dev));
	int n = 0;

	if (rproc) {
		n = READ_ONCE(rproc->crash_cnt);
		rproc_put(rproc);
	}
	return sysfs_emit(buf, "%d\n", n);
}
static DEVICE_ATTR_RO(crash_count);

static size_t msub_len(const char *buf, size_t count)
{
	const char *p = memchr(buf, '\n', count);

	return p ? p - buf : count;
}

static ssize_t restart_level_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", msub_levels[READ_ONCE(to_msub(dev)->related)]);
}

/* 5.4: strncasecmp() against each level over the input length, else -EPERM */
static ssize_t restart_level_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	size_t len = msub_len(buf, count);
	int i;

	for (i = 0; i < ARRAY_SIZE(msub_levels); i++) {
		if (!strncasecmp(buf, msub_levels[i], len)) {
			WRITE_ONCE(to_msub(dev)->related, i == 1);
			return count;
		}
	}
	return -EPERM;
}
static DEVICE_ATTR_RW(restart_level);

static ssize_t firmware_name_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct msub *s = to_msub(dev);
	ssize_t ret;

	mutex_lock(&msub_lock);
	ret = sysfs_emit(buf, "%s\n", s->fw_name);
	mutex_unlock(&msub_lock);
	return ret;
}

/* 5.4 stores the name for the next boot of the subsystem; recorded only */
static ssize_t firmware_name_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct msub *s = to_msub(dev);
	size_t len = msub_len(buf, count);

	if (!len || len >= sizeof(s->fw_name))
		return -EINVAL;
	mutex_lock(&msub_lock);
	memcpy(s->fw_name, buf, len);
	s->fw_name[len] = '\0';
	mutex_unlock(&msub_lock);
	return count;
}
static DEVICE_ATTR_RW(firmware_name);

static ssize_t system_debug_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", READ_ONCE(to_msub(dev)->system_debug) ? "set" : "reset");
}

static ssize_t system_debug_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	size_t len = msub_len(buf, count);

	if (!strncasecmp(buf, "set", len))
		WRITE_ONCE(to_msub(dev)->system_debug, true);
	else if (!strncasecmp(buf, "reset", len))
		WRITE_ONCE(to_msub(dev)->system_debug, false);
	else
		return -EPERM;
	return count;
}
static DEVICE_ATTR_RW(system_debug);

static struct attribute *msub_attrs[] = {
	&dev_attr_name.attr,
	&dev_attr_state.attr,
	&dev_attr_crash_count.attr,
	&dev_attr_restart_level.attr,
	&dev_attr_firmware_name.attr,
	&dev_attr_system_debug.attr,
	NULL,
};
ATTRIBUTE_GROUPS(msub);

static const struct bus_type msub_bus = {
	.name = "msm_subsys",
	.dev_groups = msub_groups,
};

static void msub_dev_release(struct device *dev)
{
	kfree(dev);
}

/* true when some module already registered a bus called msm_subsys */
static bool msub_bus_exists(void)
{
	struct kset *pk = bus_get_kset(&platform_bus_type);
	struct kobject *k;

	if (!pk || !pk->kobj.kset)
		return false;
	k = kset_find_obj(pk->kobj.kset, msub_bus.name);
	if (!k)
		return false;
	kobject_put(k);
	return true;
}

static struct device *msub_add(struct device *parent, const char *name,
			       const struct bus_type *bus, void *data)
{
	struct device *dev = kzalloc(sizeof(*dev), GFP_KERNEL);

	if (!dev)
		return NULL;
	device_initialize(dev);
	dev->parent = parent;
	dev->bus = bus;
	dev->release = msub_dev_release;
	dev_set_drvdata(dev, data);
	if (dev_set_name(dev, "%s", name) || device_add(dev)) {
		put_device(dev);
		return NULL;
	}
	return dev;
}

static void msub_down_locked(void)
{
	int i;

	if (!msub_bus_up)
		return;
	for (i = ARRAY_SIZE(msubs) - 1; i >= 0; i--) {
		struct msub *s = &msubs[i];

		if (s->dev)
			device_unregister(s->dev);
		if (s->parent)
			device_unregister(s->parent);
		s->dev = NULL;
		s->parent = NULL;
	}
	bus_unregister(&msub_bus);
	msub_bus_up = false;
}

static void msub_up_locked(void)
{
	struct platform_device *soc = NULL;
	struct device_node *np;
	char nm[16];
	int i, n = 0, ret;

	if (msub_bus_up || msub_yielded)
		return;
	if (msub_bus_exists()) {
		pr_info("msm_subsys bus already registered elsewhere, staying idle\n");
		return;
	}
	ret = bus_register(&msub_bus);
	if (ret) {
		pr_err("bus_register: %d\n", ret);
		return;
	}
	msub_bus_up = true;

	np = msub_soc_path[0] ? of_find_node_by_path(msub_soc_path) : NULL;
	if (np) {
		soc = of_find_device_by_node(np);
		of_node_put(np);
	}
	if (msub_soc_path[0] && !soc)
		pr_warn("no platform device at %s: subsysN without the 5.4 parent\n", msub_soc_path);

	for (i = 0; i < ARRAY_SIZE(msubs); i++) {
		struct msub *s = &msubs[i];
		struct device *other;

		if (soc) {
			other = device_find_child_by_name(&soc->dev, s->node);
			if (other) {
				put_device(other);
				pr_warn("%s/%s exists, subsys%d without parent\n",
					dev_name(&soc->dev), s->node, s->idx);
			} else {
				s->parent = msub_add(&soc->dev, s->node, NULL, NULL);
			}
		}
		snprintf(nm, sizeof(nm), "subsys%d", s->idx);
		s->dev = msub_add(s->parent, nm, &msub_bus, s);
		if (!s->dev) {
			pr_err("%s (%s) not created\n", nm, s->name);
			continue;
		}
		n++;
	}
	if (soc)
		put_device(&soc->dev);
	pr_info("%d subsystems on msm_subsys%s\n", n, soc ? "" : " (no 5.4 parents)");
}

static void msub_retry_fn(struct work_struct *work)
{
	mutex_lock(&msub_lock);
	msub_up_locked();
	mutex_unlock(&msub_lock);
}
static DECLARE_WORK(msub_retry, msub_retry_fn);

static int msub_module_event(struct notifier_block *nb, unsigned long action,
			     void *data)
{
	struct module *mod = data;

	if (!msub_owner[0] || strcmp(mod->name, msub_owner))
		return NOTIFY_DONE;
	switch (action) {
	case MODULE_STATE_COMING:	/* before its init: free the names */
		cancel_work_sync(&msub_retry);
		mutex_lock(&msub_lock);
		msub_yielded = true;
		if (msub_bus_up)
			pr_info("%s loading: handing msm_subsys over\n", mod->name);
		msub_down_locked();
		mutex_unlock(&msub_lock);
		break;
	case MODULE_STATE_GOING:	/* unloaded or its init failed */
		mutex_lock(&msub_lock);
		msub_yielded = false;
		mutex_unlock(&msub_lock);
		schedule_work(&msub_retry);
		break;
	}
	return NOTIFY_OK;
}

static struct notifier_block msub_module_nb = {
	.notifier_call = msub_module_event,
};

static int __init msub_init(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(msubs); i++) {
		msubs[i].related = default_related;
		strscpy(msubs[i].fw_name, msubs[i].name, sizeof(msubs[i].fw_name));
	}
	if (register_module_notifier(&msub_module_nb))
		pr_warn("no module notifier: will not yield to %s\n", msub_owner);
	else
		msub_nb_ok = true;
	mutex_lock(&msub_lock);
	msub_up_locked();
	mutex_unlock(&msub_lock);
	return 0;
}

static void __exit msub_exit(void)
{
	if (msub_nb_ok)
		unregister_module_notifier(&msub_module_nb);
	cancel_work_sync(&msub_retry);
	mutex_lock(&msub_lock);
	msub_down_locked();
	mutex_unlock(&msub_lock);
}

module_init(msub_init);
module_exit(msub_exit);
MODULE_DESCRIPTION("a52sxq: 5.4 /sys/bus/msm_subsys view of the 6.12 remoteprocs (fallback for subsys_compat)");
MODULE_LICENSE("GPL");
