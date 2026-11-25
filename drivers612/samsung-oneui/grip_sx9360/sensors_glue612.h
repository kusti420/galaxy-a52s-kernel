/* SPDX-License-Identifier: GPL-2.0 */
/*
 * a52sxq 6.12: the 5.4 sensors_core API (sensors_register / sensors_create_symlink ...) for sx9360,
 * on top of the classes that adsp_factory_dlkm.ko already owns.
 *
 * On 6.12 /sys/class/sensors and /sys/class/sensor_event are created by adsp_factory_dlkm.ko
 * (drivers612/sensors-factory/sensors_core.c), which exports none of the sensors_core functions.
 * A second class_create("sensors") would fail with -EEXIST (or, loaded first, break adsp_factory).
 * So the existing class objects are looked up through sysfs (kernfs), public structures only:
 *   /sys/class/sensors/sensor_dev       (created by sensors_core init, always there) -> its
 *        struct device -> dev->class = the "sensors" class; grip_sensor is device_create()d in it.
 *   /sys/class/sensor_event/symlink     -> the symlink_dev whose kobject holds the
 *        input-device links (5.4 sensors_create_symlink() target).
 * Both are reference-counted (get_device) while this module uses them. If either is missing
 * (adsp_factory_dlkm not loaded yet) probe returns -EPROBE_DEFER: nothing is created.
 */
#ifndef SX9360_SENSORS_GLUE612_H
#define SX9360_SENSORS_GLUE612_H

#include <linux/device.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>

static struct device *glue_sensor_dev;	/* /sys/class/sensors/sensor_dev */
static struct device *glue_symlink_dev;	/* /sys/class/sensor_event/symlink */

static struct device *glue_find_class_dev(const char *cls, const char *name)
{
	struct kernfs_node *root, *kc, *kcls, *kl, *target;
	struct device *dev = NULL;

	if (!kernel_kobj || !kernel_kobj->sd || !kernel_kobj->sd->parent)
		return NULL;
	root = kernel_kobj->sd->parent;		/* /sys */
	kc = kernfs_find_and_get(root, "class");
	if (!kc)
		return NULL;
	kcls = kernfs_find_and_get(kc, cls);
	kernfs_put(kc);
	if (!kcls)
		return NULL;
	kl = kernfs_find_and_get(kcls, name);
	kernfs_put(kcls);
	if (!kl)
		return NULL;
	if (kernfs_type(kl) == KERNFS_LINK) {
		target = kl->symlink.target_kn;	/* pinned by the link node we hold */
		if (target && kernfs_type(target) == KERNFS_DIR && target->priv) {
			struct device *d = kobj_to_dev((struct kobject *)target->priv);

			if (d->class && d->class->name && !strcmp(d->class->name, cls))
				dev = get_device(d);
		}
	}
	kernfs_put(kl);
	return dev;
}

static int glue_sensors_get(void)
{
	if (!glue_sensor_dev)
		glue_sensor_dev = glue_find_class_dev("sensors", "sensor_dev");
	if (!glue_symlink_dev)
		glue_symlink_dev = glue_find_class_dev("sensor_event", "symlink");
	return (glue_sensor_dev && glue_symlink_dev) ? 0 : -EPROBE_DEFER;
}

static void glue_sensors_put(void)
{
	if (glue_symlink_dev)
		put_device(glue_symlink_dev);
	if (glue_sensor_dev)
		put_device(glue_sensor_dev);
	glue_symlink_dev = glue_sensor_dev = NULL;
}

/* 5.4 sensors_core.c semantics, minus its leaks (sensors_unregister now also removes the device) */
static int sensors_create_symlink(struct kobject *target, const char *name)
{
	if (!glue_symlink_dev)
		return -ENODEV;
	return sysfs_create_link(&glue_symlink_dev->kobj, target, name);
}

static void sensors_remove_symlink(struct kobject *target, const char *name)
{
	if (glue_symlink_dev)
		sysfs_remove_link(&glue_symlink_dev->kobj, name);
}

static int sensors_register(struct device **dev, void *drvdata,
			    struct device_attribute *attributes[], char *name)
{
	struct device *d;
	int i;

	if (!glue_sensor_dev)
		return -ENODEV;
	d = device_create(glue_sensor_dev->class, NULL, 0, drvdata, "%s", name);
	if (IS_ERR(d)) {
		pr_err("[SENSORS CORE] device_create failed![%ld]\n", PTR_ERR(d));
		return PTR_ERR(d);
	}
	for (i = 0; attributes[i] != NULL; i++)
		if (device_create_file(d, attributes[i]) < 0)
			pr_err("[SENSOR CORE] fail device_create_file(dev, attributes[%d])\n", i);
	*dev = d;
	return 0;
}

static void sensors_unregister(struct device *dev, struct device_attribute *attributes[])
{
	int i;

	if (IS_ERR_OR_NULL(dev))
		return;
	for (i = 0; attributes[i] != NULL; i++)
		device_remove_file(dev, attributes[i]);
	device_unregister(dev);
}

#endif
