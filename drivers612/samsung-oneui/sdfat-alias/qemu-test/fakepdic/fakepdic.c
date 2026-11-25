// SPDX-License-Identifier: GPL-2.0-only
/*
 * QEMU-only stand-in for sec-battery's "usb" power supply and the SM5714 PDIC chip driver:
 * registers power_supply "usb", registers a chip with pdic_core whose water property is the
 * module parameter "water"; writing the parameter sends PDIC_NOTIFY_ID_WATER like
 * sm5714_process_cc_water_det().
 */
#include <linux/module.h>
#include <linux/power_supply.h>
#include <linux/usb/typec/common/pdic_core.h>
#include <linux/usb/typec/common/pdic_notifier.h>
#include <linux/usb/typec/common/pdic_sysfs.h>

static int water;
static struct power_supply *psy;

static int fp_get(struct _pdic_data_t *d, enum pdic_sysfs_property p, char *buf)
{
	if (p == PDIC_SYSFS_PROP_FW_WATER)
		return sprintf(buf, "%d\n", water);
	return -ENODATA;
}
static enum pdic_sysfs_property fp_props[] = { PDIC_SYSFS_PROP_FW_WATER };
static pdic_sysfs_property_t fp_prop = {
	.properties = fp_props, .num_properties = 1, .get_property = fp_get,
};
static pdic_data_t fp_data = { .name = "fakepdic", .pdic_sysfs_prop = &fp_prop };

static int water_set(const char *val, const struct kernel_param *kp)
{
	PD_NOTI_ATTACH_TYPEDEF n = { };
	int ret = param_set_int(val, kp);

	if (ret)
		return ret;
	n.src = PDIC_NOTIFY_DEV_CCIC;
	n.dest = PDIC_NOTIFY_DEV_BATT;
	n.id = PDIC_NOTIFY_ID_WATER;
	n.attach = water;
	pdic_notifier_notify((PD_NOTI_TYPEDEF *)&n, NULL, 0);
	return 0;
}
static const struct kernel_param_ops water_ops = { .set = water_set, .get = param_get_int };
module_param_cb(water, &water_ops, &water, 0644);

static enum power_supply_property fp_psy_props[] = { POWER_SUPPLY_PROP_ONLINE };
static int fp_psy_get(struct power_supply *p, enum power_supply_property prop,
		      union power_supply_propval *val)
{
	val->intval = 0;
	return 0;
}
static const struct power_supply_desc fp_desc = {
	.name = "usb", .type = POWER_SUPPLY_TYPE_USB, .properties = fp_psy_props,
	.num_properties = 1, .get_property = fp_psy_get,
};

static int __init fakepdic_init(void)
{
	struct power_supply_config cfg = { };
	int ret;

	if (!get_pdic_device())
		return -ENODEV;
	ret = pdic_core_register_chip(&fp_data);
	if (ret)
		return ret;
	psy = power_supply_register(NULL, &fp_desc, &cfg);
	if (IS_ERR(psy)) {
		pdic_core_unregister_chip();
		return PTR_ERR(psy);
	}
	return 0;
}

static void __exit fakepdic_exit(void)
{
	power_supply_unregister(psy);
	pdic_core_unregister_chip();
}
module_init(fakepdic_init);
module_exit(fakepdic_exit);
MODULE_LICENSE("GPL");
