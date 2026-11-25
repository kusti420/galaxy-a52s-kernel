// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq_usb_moisture: the USB-C moisture nodes One UI's USB HAL reads.
 *
 * android.hardware.usb@1.3-service.coral (K4_UN1CA 9.3.173 /vendor/bin/hw) reads
 *   /sys/class/power_supply/usb/moisture_detection_enabled   "1" = detection on
 *   /sys/class/power_supply/usb/moisture_detected            "1" = moisture in the port
 * and re-queries the port status on any uevent line starting with
 * "POWER_SUPPLY_MOISTURE_DETECTED" (or "DEVTYPE=typec_"). Neither node exists on the
 * phone's 5.4 kernel (there the HAL logs "Failed to open moisture_detection_enabled" and
 * reports contaminant detection as not supported) nor on 6.12 so far.
 *
 * The real state is the SM5714's SBU water detection (pdic_sm5714: is_water_detect, the
 * value behind /sys/class/sec/ccic/water). This module adds the two files to the "usb"
 * power supply device of sec-battery, answers moisture_detected from the PDIC driver's own
 * sysfs getter at read time, and sends KOBJ_CHANGE with POWER_SUPPLY_MOISTURE_DETECTED=0|1
 * on that device when the PDIC notifier reports PDIC_NOTIFY_ID_WATER.
 *
 * moisture_detection_enabled is a stored flag (default 1): 0 only makes moisture_detected
 * read 0 and stops the uevent. The chip's detection and the charger's hiccup protection are
 * not switched off by it (they are a safety function of the kernel side).
 *
 * The "usb" supply and the PDIC chip may register after this module: it retries once a
 * second (for 5 minutes) and never fails to load.
 */
#define pr_fmt(fmt) "a52sxq_usb_moisture: " fmt

#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/power_supply.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <linux/usb/typec/common/pdic_core.h>
#include <linux/usb/typec/common/pdic_notifier.h>
#include <linux/usb/typec/common/pdic_sysfs.h>

static struct power_supply *usb_psy;
static bool files_made, nb_registered;
static bool detection_enabled = true;
static int last_water = -1;
static int bind_tries;
static struct notifier_block water_nb;

/* 1 / 0, or < 0 when the PDIC chip driver is not there */
static int water_now(void)
{
	struct device *pdic = get_pdic_device();
	ppdic_data_t pd;
	ppdic_sysfs_property_t prop;
	char buf[32] = "";
	int v;

	if (!pdic)
		return -ENODEV;
	pd = dev_get_drvdata(pdic);
	if (!pd || !pd->pdic_sysfs_prop)
		return -ENODEV;
	prop = pd->pdic_sysfs_prop;
	if (!prop->get_property)
		return -ENODEV;
	if (prop->get_property(pd, PDIC_SYSFS_PROP_FW_WATER, buf) <= 0)
		return -EIO;
	if (kstrtoint(strim(buf), 10, &v))
		return -EIO;
	return !!v;
}

static ssize_t moisture_detected_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int v = detection_enabled ? water_now() : 0;

	return sysfs_emit(buf, "%d\n", v > 0);
}
static DEVICE_ATTR_RO(moisture_detected);

static ssize_t moisture_detection_enabled_show(struct device *dev, struct device_attribute *attr,
					       char *buf)
{
	return sysfs_emit(buf, "%d\n", detection_enabled);
}

static ssize_t moisture_detection_enabled_store(struct device *dev, struct device_attribute *attr,
						const char *buf, size_t count)
{
	bool v;

	if (kstrtobool(buf, &v))
		return -EINVAL;
	detection_enabled = v;
	return count;
}
static struct device_attribute dev_attr_moisture_detection_enabled =
	__ATTR(moisture_detection_enabled, 0664, moisture_detection_enabled_show,
	       moisture_detection_enabled_store);

static void water_uevent_fn(struct work_struct *work)
{
	char line[40];
	char *envp[2] = { line, NULL };
	int v = last_water;

	if (!usb_psy || !files_made || !detection_enabled || v < 0)
		return;
	snprintf(line, sizeof(line), "POWER_SUPPLY_MOISTURE_DETECTED=%d", v);
	pr_info("water %d -> uevent on power_supply/usb\n", v);
	kobject_uevent_env(&usb_psy->dev.kobj, KOBJ_CHANGE, envp);
}
static DECLARE_WORK(water_uevent_work, water_uevent_fn);

/* called from the PDIC notifier chain (and once with the last notification at registration) */
static int water_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	PD_NOTI_ATTACH_TYPEDEF *noti = data;

	if (!noti || noti->id != PDIC_NOTIFY_ID_WATER)
		return NOTIFY_DONE;
	if (last_water != !!noti->attach) {
		last_water = !!noti->attach;
		schedule_work(&water_uevent_work);
	}
	return NOTIFY_DONE;
}

static void bind_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(bind_work, bind_fn);

static void bind_fn(struct work_struct *work)
{
	if (!usb_psy)
		usb_psy = power_supply_get_by_name("usb");
	if (usb_psy && !files_made) {
		if (!device_create_file(&usb_psy->dev, &dev_attr_moisture_detected)) {
			if (!device_create_file(&usb_psy->dev, &dev_attr_moisture_detection_enabled))
				files_made = true;
			else
				device_remove_file(&usb_psy->dev, &dev_attr_moisture_detected);
		}
	}
	if (!nb_registered && get_pdic_device() &&
	    !pdic_notifier_register(&water_nb, water_notify, PDIC_NOTIFY_DEV_INITIAL))
		nb_registered = true;

	if (files_made && nb_registered) {
		int v = water_now();

		pr_info("bound: power_supply/usb nodes + PDIC notifier, water now %d\n", v);
		/* booted with a wet port: the interrupt came before we listened */
		if (v > 0 && last_water != 1) {
			last_water = 1;
			schedule_work(&water_uevent_work);
		}
		return;
	}
	if (++bind_tries < 300)
		schedule_delayed_work(&bind_work, HZ);
	else
		pr_warn("gave up: usb supply %d files %d notifier %d\n", !!usb_psy, files_made,
			nb_registered);
}

static int __init a52sxq_usb_moisture_init(void)
{
	schedule_delayed_work(&bind_work, 0);
	return 0;
}

static void __exit a52sxq_usb_moisture_exit(void)
{
	cancel_delayed_work_sync(&bind_work);
	if (nb_registered)
		pdic_notifier_unregister(&water_nb);
	cancel_work_sync(&water_uevent_work);
	if (files_made) {
		device_remove_file(&usb_psy->dev, &dev_attr_moisture_detection_enabled);
		device_remove_file(&usb_psy->dev, &dev_attr_moisture_detected);
	}
	if (usb_psy)
		power_supply_put(usb_psy);
}

module_init(a52sxq_usb_moisture_init);
module_exit(a52sxq_usb_moisture_exit);

MODULE_DESCRIPTION("Galaxy A52s: power_supply/usb moisture_detected nodes from the SM5714 water detection");
MODULE_AUTHOR("a52sxq-mainline");
MODULE_LICENSE("GPL");
