// SPDX-License-Identifier: GPL-2.0
/*
 * sb_oneui_attrs.c
 * Two /sys/class/power_supply/battery attributes the One UI 9 port's 5.4 kernel has and the 6.12 power
 * stack lacks:
 *
 *  pass_through      One UI "Pause USB Power Delivery" (BatteryService/[SS]BattUtils writes "1"/"0").
 *                    Same semantics as the port's 5.4 kernel patch k4 0008 (sb_full_soc.c there): while
 *                    set, VOTER_PASS_THROUGH holds the chgen vote at SEC_BAT_CHG_MODE_CHARGING_OFF (the
 *                    charger keeps powering the phone, the battery is not charged: the charger state the
 *                    "Protect battery" limit already uses, VOTER_FULL_CAPACITY), the status reads
 *                    NOT_CHARGING and the full-capacity logic is skipped. Cleared on cable removal (and in
 *                    slate mode); off at boot.
 *                    It does NOT use Samsung's sb_pass_through.c (sec-direct-charger) mode
 *                    SEC_BAT_CHG_MODE_PASS_THROUGH / PASS_THROUGH_MODE charger writes: the a52sxq DT has no
 *                    "pass-through" node and the sm5714 charger has no such mode.
 *
 *  sub_bat_temp_raw  5.4 sec_battery_sysfs.c: the sub-battery thermistor without LR adjustment when its
 *                    source is the ADC, else 0. a52sxq has a single cell and no battery,sub_bat_thermal_source
 *                    (source NONE), so it reads 0, as on 5.4. Read by the Samsung thermal HAL.
 *
 * The state lives here (not in struct sb_full_soc / struct sec_battery_info) so no structure reachable
 * from an exported symbol changes: the module's export CRCs (gendwarfksyms) stay those of the shipped one.
 * Nothing here is exported.
 */

#include <linux/device.h>
#include <linux/mutex.h>
#include <linux/power_supply.h>

#include "sec_battery.h"
#include "sb_oneui_attrs.h"

static DEFINE_MUTEX(pt_lock);
static bool pt_on;

bool sb_oneui_pass_through(void)
{
	return READ_ONCE(pt_on);
}

/* k4 0008 set_pass_through(), called with pt_lock held */
static void set_pass_through(struct sec_battery_info *battery, bool enable)
{
	WRITE_ONCE(pt_on, enable);
	sec_vote(battery->chgen_vote, VOTER_PASS_THROUGH, enable, SEC_BAT_CHG_MODE_CHARGING_OFF);

	if (enable) {
		if (battery->status == POWER_SUPPLY_STATUS_CHARGING)
			sec_bat_set_charging_status(battery, POWER_SUPPLY_STATUS_NOT_CHARGING);
	} else if (battery->status == POWER_SUPPLY_STATUS_NOT_CHARGING &&
		battery->health == POWER_SUPPLY_HEALTH_GOOD &&
		!(battery->misc_event & BATT_MISC_EVENT_FULL_CAPACITY)) {
		sec_bat_set_charging_status(battery, POWER_SUPPLY_STATUS_CHARGING);
	}

	pr_info("%s: pass through %s (status %d)\n", __func__,
		enable ? "on" : "off", battery->status);
	__pm_stay_awake(battery->monitor_ws);
	queue_delayed_work(battery->monitor_wqueue, &battery->monitor_work, 0);
}

/* cable removed (cw_nocharge_type) or slate mode (cw_slate_mode): a stale request never blocks the next charge */
void sb_oneui_pass_through_cable_removed(struct sec_battery_info *battery)
{
	mutex_lock(&pt_lock);
	if (pt_on) {
		WRITE_ONCE(pt_on, false);
		sec_vote(battery->chgen_vote, VOTER_PASS_THROUGH, false, 0);
		pr_info("%s: charger removed, pass through off\n", __func__);
	}
	mutex_unlock(&pt_lock);
}

/* k4 0008 hook at the top of sec_bat_check_full_capacity(): true = skip the full-capacity logic */
bool sb_oneui_pass_through_hold(struct sec_battery_info *battery)
{
	if (!READ_ONCE(pt_on))
		return false;
	if (battery->status == POWER_SUPPLY_STATUS_CHARGING)
		sec_bat_set_charging_status(battery, POWER_SUPPLY_STATUS_NOT_CHARGING);
	return true;
}

static struct sec_battery_info *dev_to_battery(struct device *dev)
{
	struct power_supply *psy = dev_get_drvdata(dev);

	return psy ? power_supply_get_drvdata(psy) : NULL;
}

static ssize_t pass_through_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", sb_oneui_pass_through());
}

static ssize_t pass_through_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_battery_info *battery = dev_to_battery(dev);
	int x = 0;

	if (!battery)
		return -ENODEV;
	if (sscanf(buf, "%10d\n", &x) != 1) {
		pr_info("%s: invalid arguments\n", __func__);
		return -EINVAL;
	}

	mutex_lock(&pt_lock);
	if (pt_on != !!x)
		set_pass_through(battery, !!x);
	mutex_unlock(&pt_lock);

	return count;
}

static ssize_t sub_bat_temp_raw_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_battery_info *battery = dev_to_battery(dev);
	int val = 0;

	if (battery && battery->pdata->sub_bat_thm_info.source == SEC_BATTERY_THERMAL_SOURCE_ADC)
		val = sec_bat_get_temperature(battery->dev, &battery->pdata->sub_bat_thm_info, 0,
			battery->pdata->charger_name, battery->pdata->fuelgauge_name,
			battery->pdata->adc_read_type);

	return scnprintf(buf, PAGE_SIZE, "%d\n", val);
}

/* 5.4: SEC_BATTERY_ATTR (0664), its store returns -EINVAL for sub_bat_temp_raw */
static ssize_t sub_bat_temp_raw_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	return -EINVAL;
}

static struct device_attribute oneui_attrs[] = {
	__ATTR(pass_through, 0664, pass_through_show, pass_through_store),
	__ATTR(sub_bat_temp_raw, 0664, sub_bat_temp_raw_show, sub_bat_temp_raw_store),
};

/* non-fatal: a failure (e.g. a name that already exists) is logged, the battery probe goes on */
void sb_oneui_attrs_init(struct sec_battery_info *battery)
{
	int i, rc;

	WRITE_ONCE(pt_on, false);
	for (i = 0; i < ARRAY_SIZE(oneui_attrs); i++) {
		rc = device_create_file(&battery->psy_bat->dev, &oneui_attrs[i]);
		pr_info("%s: %s (%d)\n", __func__, oneui_attrs[i].attr.name, rc);
	}
}
