// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: the 5.4 subsystem-restart (PIL) userspace face on top of 6.12
 * remoteproc, for the closed 5.4-era vendor daemons.
 *
 * Idea after donors/redwood-6.12/modules/subsys_compat; re-implemented for
 * the A52s with the 5.4 semantics of msm_subsystem_restart.c:
 *
 *  /sys/bus/msm_subsys/devices/subsysN/{name,state,crash_count,
 *      restart_level,firmware_name,system_debug}
 *      read by libmdmdetect.so (finds the modem), ssr_setup and init.qcom.rc
 *      (write restart_level), poll()ed through sysfs_notify on "state".
 *  /dev/subsys_<name>   (class "subsys", like 5.4)
 *      open  = subsystem_get(): boots the processor on the first user
 *      close = subsystem_put(): shuts it down with the last user
 *      pm-service holds /dev/subsys_modem; lib{a,c,m,s}dsprpc.so open
 *      /dev/subsys_{adsp,cdsp}.
 *
 * remoteproc keeps its own power refcount (rproc_boot/rproc_shutdown), so
 * every open is one rproc_boot() and every close one rproc_shutdown(); that
 * composes with in-kernel holders (icnss2 for the WPSS, the audio techpack's
 * adsp loader) exactly as subsystem_get/put did on 5.4.
 *
 * The devices keep the 5.4 index and sit under a device named like the 5.4
 * PIL platform device, so the sysfs paths the vendor SELinux policy labels
 * (genfs_contexts: /devices/platform/soc/4080000.qcom,mss/subsys3 ...) stay.
 *
 * Index and names are the phone's own (research/blob-uapi-evidence/
 * subsys.txt, dev_lZ.txt; minors 0..6):
 *   0 yupik_ipa_fws  1 a660_zap  2 wpss  3 modem  4 adsp  5 cdsp  6 venus
 * 0, 1 and 6 are kernel-internal firmware loads on 5.4 (IPA, GPU zap,
 * video); no userspace opens them. They are listed (name/state only, no
 * remoteproc behind them) so the subsysN numbering and what libmdmdetect
 * enumerates stay the same. Disable with stubs=0.
 */
#define pr_fmt(fmt) "subsys_compat: " fmt

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/remoteproc.h>
#include <linux/remoteproc/qcom_rproc.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/workqueue.h>
#include <trace/hooks/remoteproc.h>

/* 5.4: close of the last user shuts the processor down. 1 = leave it running
 * (what redwood does; use if a daemon restart must not bounce the modem). */
static bool keep_on_close;
module_param(keep_on_close, bool, 0644);
MODULE_PARM_DESC(keep_on_close, "do not shut a processor down when its last /dev/subsys_* user closes");

/* 5.4 default restart level is SYSTEM (crash = panic) until ssr_setup or
 * persist.vendor.ssr.restart_level writes RELATED. For bring-up the default
 * here is RELATED (remoteproc recovery on): a modem crash must not take the
 * phone down. Set to 0 for the exact 5.4 default. */
static bool default_related = true;
module_param(default_related, bool, 0444);
MODULE_PARM_DESC(default_related, "start with restart_level RELATED (remoteproc recovery enabled)");

static bool stubs = true;
module_param(stubs, bool, 0444);
MODULE_PARM_DESC(stubs, "also list the kernel-internal 5.4 subsystems (ipa_fws, a660_zap, venus)");

/* comma list of 5.4 names to boot from here once their remoteproc exists and
 * firmware loads (5.4: adsp-loader/cdsp-loader did this). Empty by default:
 * the audio techpack's loaders own it. Example: autoboot=adsp,cdsp */
static char *autoboot = "";
module_param(autoboot, charp, 0444);
MODULE_PARM_DESC(autoboot, "comma separated subsystems to boot without a user (e.g. adsp,cdsp)");

enum { ST_OFFLINING, ST_OFFLINE, ST_ONLINE };
static const char * const state_names[] = { "OFFLINING", "OFFLINE", "ONLINE" };

struct subsys {
	const char *name;	/* 5.4 subsystem name */
	const char *compat;	/* 6.12 remoteproc node, NULL = stub */
	const char *ssr_name;	/* qcom_register_ssr_notifier() name */
	const char *node;	/* 5.4 PIL platform device name */
	int idx;		/* 5.4 subsysN and chardev minor */

	struct device *parent;
	struct rproc *rproc;
	struct device dev;
	bool dev_ok;
	struct cdev cdev;
	bool cdev_ok;
	struct mutex lock;
	int users;		/* opens we hold an rproc power ref for */
	bool auto_held;
	bool auto_want;
	int tries;
	int state;
	bool restart_system;	/* restart_level == SYSTEM */
	bool system_debug;
	char fw_name[64];	/* 5.4 style, without extension */
	struct notifier_block nb;
	void *ssr_handle;
};

static struct subsys subsystems[] = {
	{ .idx = 0, .name = "yupik_ipa_fws", .node = "soc:qcom,ipa_fws" },
	{ .idx = 1, .name = "a660_zap", .node = "soc:qcom,kgsl-hyp" },
	{ .idx = 2, .name = "wpss", .compat = "qcom,yupik-wpss-pas",
	  .ssr_name = "wpss", .node = "soc:qcom,wpss@8a00000" },
	{ .idx = 3, .name = "modem", .compat = "qcom,yupik-modem-pas",
	  .ssr_name = "mpss", .node = "4080000.qcom,mss" },
	{ .idx = 4, .name = "adsp", .compat = "qcom,yupik-adsp-pas",
	  .ssr_name = "lpass", .node = "3700000.qcom,lpass" },
	{ .idx = 5, .name = "cdsp", .compat = "qcom,yupik-cdsp-pas",
	  .ssr_name = "cdsp", .node = "a300000.qcom,turing" },
	{ .idx = 6, .name = "venus", .node = "aab0000.qcom,venus" },
};

static dev_t devt;
static struct class *subsys_class;
static struct delayed_work lookup_work;

static const struct bus_type subsys_bus = {
	.name = "msm_subsys",
};

static void subsys_set_state(struct subsys *s, int state)
{
	if (s->state == state)
		return;
	s->state = state;
	if (s->dev_ok)
		sysfs_notify(&s->dev.kobj, NULL, "state");
}

/*
 * RELATED = remoteproc recovery on, SYSTEM = off (qcom_q6v5 then panics on a
 * crash, like RESET_SOC on 5.4). Same two steps as a write to
 * /sys/class/remoteproc/remoteprocN/recovery: set the flag, then run the
 * Android vendor hook, through which qcom_q6v5_pas copies it into its own
 * shadow (subsys_recovery_disabled); without the hook a kernel client that
 * toggles recovery (qcom_rproc_update_recovery_status) would restore the
 * probe-time default "disabled".
 */
static void subsys_apply_level(struct subsys *s)
{
	if (!s->rproc)
		return;
	s->rproc->recovery_disabled = s->restart_system;
	trace_android_vh_rproc_recovery_set(s->rproc);
}

/* remoteproc of a subsystem, NULL while its driver has not probed */
static struct rproc *subsys_rproc(struct subsys *s)
{
	struct device_node *np;
	struct rproc *rproc;

	if (s->rproc || !s->compat)
		return s->rproc;
	np = of_find_compatible_node(NULL, NULL, s->compat);
	if (!np)
		return NULL;
	rproc = rproc_get_by_phandle(np->phandle);
	of_node_put(np);
	if (!rproc)
		return NULL;

	mutex_lock(&s->lock);
	if (s->rproc) {
		rproc_put(rproc);
	} else {
		s->rproc = rproc;
		subsys_apply_level(s);
		if (rproc->state == RPROC_RUNNING || rproc->state == RPROC_ATTACHED)
			subsys_set_state(s, ST_ONLINE);
		if (!s->fw_name[0] && rproc->firmware) {
			char *dot;

			strscpy(s->fw_name, kbasename(rproc->firmware),
				sizeof(s->fw_name));
			dot = strrchr(s->fw_name, '.');
			if (dot)
				*dot = '\0';
		}
	}
	mutex_unlock(&s->lock);
	return s->rproc;
}

static int subsys_ssr_event(struct notifier_block *nb, unsigned long event,
			    void *data)
{
	struct subsys *s = container_of(nb, struct subsys, nb);

	switch (event) {
	case QCOM_SSR_AFTER_POWERUP:
		subsys_set_state(s, ST_ONLINE);
		break;
	case QCOM_SSR_BEFORE_SHUTDOWN:
		subsys_set_state(s, ST_OFFLINING);
		break;
	case QCOM_SSR_AFTER_SHUTDOWN:
		subsys_set_state(s, ST_OFFLINE);
		break;
	}
	return NOTIFY_OK;
}

static ssize_t name_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);

	return sysfs_emit(buf, "%s\n", s->name);
}
static DEVICE_ATTR_RO(name);

static ssize_t state_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);

	subsys_rproc(s);
	return sysfs_emit(buf, "%s\n", state_names[s->state]);
}
static DEVICE_ATTR_RO(state);

static ssize_t crash_count_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);
	struct rproc *rproc = subsys_rproc(s);

	return sysfs_emit(buf, "%u\n", rproc ? rproc->crash_cnt : 0);
}
static DEVICE_ATTR_RO(crash_count);

static ssize_t restart_level_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);

	return sysfs_emit(buf, "%s\n", s->restart_system ? "SYSTEM" : "RELATED");
}

static ssize_t restart_level_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct subsys *s = container_of(dev, struct subsys, dev);
	size_t len = count;
	const char *p = memchr(buf, '\n', count);

	if (p)
		len = p - buf;
	/* same prefix matching and -EPERM as 5.4 */
	if (!strncasecmp(buf, "SYSTEM", len))
		s->restart_system = true;
	else if (!strncasecmp(buf, "RELATED", len))
		s->restart_system = false;
	else
		return -EPERM;
	subsys_rproc(s);
	mutex_lock(&s->lock);
	subsys_apply_level(s);
	mutex_unlock(&s->lock);
	return count;
}
static DEVICE_ATTR_RW(restart_level);

static ssize_t firmware_name_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);

	subsys_rproc(s);
	return sysfs_emit(buf, "%s\n", s->fw_name[0] ? s->fw_name : s->name);
}

static ssize_t firmware_name_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct subsys *s = container_of(dev, struct subsys, dev);
	struct rproc *rproc = subsys_rproc(s);
	char name[sizeof(s->fw_name)], fw[sizeof(s->fw_name) + 8];
	size_t len = count;
	const char *p = memchr(buf, '\n', count);
	int ret = 0;

	if (p)
		len = p - buf;
	if (!len || len >= sizeof(name))
		return -EINVAL;
	memcpy(name, buf, len);
	name[len] = '\0';

	/* 5.4 names have no extension; remoteproc wants the .mdt */
	if (rproc) {
		snprintf(fw, sizeof(fw), "%s.mdt", name);
		ret = rproc_set_firmware(rproc, fw);	/* -EBUSY unless offline */
	}
	if (ret)
		return ret;
	mutex_lock(&s->lock);
	strscpy(s->fw_name, name, sizeof(s->fw_name));
	mutex_unlock(&s->lock);
	return count;
}
static DEVICE_ATTR_RW(firmware_name);

static ssize_t system_debug_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct subsys *s = container_of(dev, struct subsys, dev);

	return sysfs_emit(buf, "%s\n", s->system_debug ? "set" : "reset");
}

static ssize_t system_debug_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct subsys *s = container_of(dev, struct subsys, dev);
	size_t len = count;
	const char *p = memchr(buf, '\n', count);

	if (p)
		len = p - buf;
	if (!strncasecmp(buf, "set", len))
		s->system_debug = true;
	else if (!strncasecmp(buf, "reset", len))
		s->system_debug = false;
	else
		return -EPERM;
	return count;
}
static DEVICE_ATTR_RW(system_debug);

static struct attribute *subsys_attrs[] = {
	&dev_attr_name.attr,
	&dev_attr_state.attr,
	&dev_attr_crash_count.attr,
	&dev_attr_restart_level.attr,
	&dev_attr_firmware_name.attr,
	&dev_attr_system_debug.attr,
	NULL,
};
ATTRIBUTE_GROUPS(subsys);

static int subsys_open(struct inode *inode, struct file *file)
{
	struct subsys *s = container_of(inode->i_cdev, struct subsys, cdev);
	struct rproc *rproc;
	int ret;

	file->private_data = s;
	if (!s->compat)		/* stub: nothing to boot from here */
		return 0;
	rproc = subsys_rproc(s);
	if (!rproc)
		return -ENODEV;	/* 5.4: subsystem_get() fails the same way */

	/* one power reference per open, as subsystem_get() */
	ret = rproc_boot(rproc);
	if (ret) {
		pr_err("booting %s failed: %d\n", s->name, ret);
		return ret;
	}
	mutex_lock(&s->lock);
	s->users++;
	subsys_set_state(s, ST_ONLINE);
	mutex_unlock(&s->lock);
	return 0;
}

static int subsys_release(struct inode *inode, struct file *file)
{
	struct subsys *s = file->private_data;
	bool put;

	if (!s->compat || !s->rproc)
		return 0;
	mutex_lock(&s->lock);
	/*
	 * keep_on_close: hold on to the first reference for good, drop the
	 * others, so the refcount stays balanced and the processor stays up.
	 */
	put = !(keep_on_close && s->users == 1);
	if (put)
		s->users--;
	mutex_unlock(&s->lock);
	if (put)
		rproc_shutdown(s->rproc);	/* stops it with the last ref */
	return 0;
}

static const struct file_operations subsys_fops = {
	.owner = THIS_MODULE,
	.open = subsys_open,
	.release = subsys_release,
	.llseek = noop_llseek,
};

static void subsys_dev_release(struct device *dev)
{
}

/*
 * The remoteproc drivers probe after us or defer; look the processors up
 * until all are found (that also applies the restart level, which decides
 * whether a firmware crash panics the phone), and boot the autoboot ones.
 */
static void subsys_lookup_work(struct work_struct *work)
{
	bool again = false;
	int i;

	for (i = 0; i < ARRAY_SIZE(subsystems); i++) {
		struct subsys *s = &subsystems[i];
		struct rproc *rproc;

		if (!s->compat)
			continue;
		rproc = subsys_rproc(s);
		if (!rproc) {
			again |= ++s->tries <= 120;
			continue;
		}
		if (!s->auto_want || s->auto_held)
			continue;
		if (rproc_boot(rproc)) {	/* firmware not there yet */
			again |= ++s->tries <= 120;
			continue;
		}
		s->auto_held = true;
		mutex_lock(&s->lock);
		subsys_set_state(s, ST_ONLINE);
		mutex_unlock(&s->lock);
		pr_info("%s booted\n", s->name);
	}
	if (again)
		schedule_delayed_work(&lookup_work, 5 * HZ);
}

static void parent_release(struct device *dev)
{
	kfree(dev);
}

/* an empty device named like the 5.4 PIL platform device, under /soc */
static struct device *make_parent(struct device *soc, const char *name)
{
	struct device *dev = kzalloc(sizeof(*dev), GFP_KERNEL);

	if (!dev)
		return NULL;
	device_initialize(dev);
	dev->parent = soc;
	dev->release = parent_release;
	if (dev_set_name(dev, "%s", name) || device_add(dev)) {
		put_device(dev);
		return NULL;
	}
	return dev;
}

static bool in_list(const char *list, const char *name)
{
	size_t n = strlen(name);
	const char *p = list;

	while (p && *p) {
		if (!strncmp(p, name, n) && (p[n] == ',' || p[n] == '\0'))
			return true;
		p = strchr(p, ',');
		if (p)
			p++;
	}
	return false;
}

static void subsys_remove_one(struct subsys *s)
{
	if (s->ssr_handle && !IS_ERR(s->ssr_handle))
		qcom_unregister_ssr_notifier(s->ssr_handle, &s->nb);
	if (s->cdev_ok) {
		device_destroy(subsys_class, MKDEV(MAJOR(devt), s->idx));
		cdev_del(&s->cdev);
	}
	if (s->rproc) {
		if (s->auto_held)
			rproc_shutdown(s->rproc);
		/* a reference kept by keep_on_close */
		while (s->users-- > 0)
			rproc_shutdown(s->rproc);
		rproc_put(s->rproc);
	}
	if (s->dev_ok)
		device_unregister(&s->dev);
	if (s->parent)
		device_unregister(s->parent);
}

static int __init subsys_compat_init(void)
{
	struct device_node *np = of_find_node_by_path("/soc");
	struct platform_device *soc = np ? of_find_device_by_node(np) : NULL;
	int i, ret;

	of_node_put(np);

	ret = bus_register(&subsys_bus);
	if (ret)
		goto err_soc;
	ret = alloc_chrdev_region(&devt, 0, ARRAY_SIZE(subsystems), "subsys");
	if (ret)
		goto err_bus;
	subsys_class = class_create("subsys");
	if (IS_ERR(subsys_class)) {
		ret = PTR_ERR(subsys_class);
		goto err_chrdev;
	}

	for (i = 0; i < ARRAY_SIZE(subsystems); i++) {
		struct subsys *s = &subsystems[i];

		mutex_init(&s->lock);
		if (!s->compat && !stubs)
			continue;
		s->state = ST_OFFLINE;
		s->restart_system = !default_related;
		s->auto_want = s->compat && in_list(autoboot, s->name);
		if (!s->compat)
			strscpy(s->fw_name, s->name, sizeof(s->fw_name));

		if (soc)
			s->parent = make_parent(&soc->dev, s->node);
		s->dev.parent = s->parent;
		s->dev.bus = &subsys_bus;
		s->dev.groups = subsys_groups;
		s->dev.release = subsys_dev_release;
		dev_set_name(&s->dev, "subsys%d", s->idx);
		ret = device_register(&s->dev);
		if (ret) {
			pr_err("subsys%d (%s): %d\n", s->idx, s->name, ret);
			put_device(&s->dev);
			continue;
		}
		s->dev_ok = true;

		cdev_init(&s->cdev, &subsys_fops);
		s->cdev.owner = THIS_MODULE;
		if (!cdev_add(&s->cdev, MKDEV(MAJOR(devt), s->idx), 1)) {
			s->cdev_ok = true;
			device_create(subsys_class, &s->dev,
				      MKDEV(MAJOR(devt), s->idx), NULL,
				      "subsys_%s", s->name);
		}

		if (s->ssr_name) {
			s->nb.notifier_call = subsys_ssr_event;
			s->ssr_handle = qcom_register_ssr_notifier(s->ssr_name,
								   &s->nb);
			if (IS_ERR(s->ssr_handle))
				pr_warn("%s: no ssr notifier: %ld\n", s->name,
					PTR_ERR(s->ssr_handle));
		}
	}

	if (soc)
		put_device(&soc->dev);
	INIT_DELAYED_WORK(&lookup_work, subsys_lookup_work);
	schedule_delayed_work(&lookup_work, 0);
	return 0;

err_chrdev:
	unregister_chrdev_region(devt, ARRAY_SIZE(subsystems));
err_bus:
	bus_unregister(&subsys_bus);
err_soc:
	if (soc)
		put_device(&soc->dev);
	return ret;
}

static void __exit subsys_compat_exit(void)
{
	int i;

	cancel_delayed_work_sync(&lookup_work);
	for (i = 0; i < ARRAY_SIZE(subsystems); i++)
		subsys_remove_one(&subsystems[i]);
	class_destroy(subsys_class);
	unregister_chrdev_region(devt, ARRAY_SIZE(subsystems));
	bus_unregister(&subsys_bus);
}

module_init(subsys_compat_init);
module_exit(subsys_compat_exit);
MODULE_DESCRIPTION("a52sxq: 5.4 subsystem-restart userspace interface on top of remoteproc");
MODULE_LICENSE("GPL");
