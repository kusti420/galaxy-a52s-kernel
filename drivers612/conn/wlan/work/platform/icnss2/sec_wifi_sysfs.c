// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung /sys/wifi interface, ported from the SM-A528B 5.4 kernel
 * (drivers/soc/qcom/icnss2/main.c, CONFIG_SEC_SS_CNSS_FEATURE_SYSFS).
 *
 * The closed vendor "macloader" reads /mnt/vendor/efs/wifi/.mac.info and
 * friends at boot and writes:
 *   /sys/wifi/mac_addr  "aa:bb:cc:dd:ee:ff"  -> provisioned MAC (cnss_utils)
 *   /sys/wifi/ant       1, 2 or 10           -> board file bdwlan.elf<N>
 *   /sys/wifi/pm        0/1                  -> power save off for RF tests
 * and reads wifiver, softap, qcwlanstate, wificable. The firmware-ready path
 * waits up to 10 s for the MAC write, exactly as on 5.4.
 */
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/sysfs.h>
#include "main.h"
#include "debug.h"
#include "cnss_utils.h"
#include "sec_wifi_sysfs.h"

enum driver_modules_status {
	DRIVER_MODULES_UNINITIALIZED,
	DRIVER_MODULES_ENABLED,
	DRIVER_MODULES_CLOSED
};

#define SEC_INFO_LEN		512
#define MACLOADER_TIMEOUT	10000
#define MAC_ADDR_SIZE		6

static enum driver_modules_status current_driver_status;
static char ver_info[SEC_INFO_LEN];
static char softap_info[SEC_INFO_LEN];
static u8 mac_from_macloader[MAC_ADDR_SIZE];
static int pm_from_macloader;
static int ant_from_macloader;
static DECLARE_COMPLETION(macloader_done);
static DEFINE_MUTEX(sec_info_lock);

/* Called by the WLAN host driver (5.4 hdd_sysfs_update_driver_status()). */
void cnss_sysfs_update_driver_status(int32_t new_status, void *version,
				     void *softap)
{
	mutex_lock(&sec_info_lock);
	if (new_status == DRIVER_MODULES_ENABLED) {
		if (version)
			strscpy(ver_info, version, sizeof(ver_info));
		if (softap)
			strscpy(softap_info, softap, sizeof(softap_info));
	}
	current_driver_status = new_status;
	mutex_unlock(&sec_info_lock);
}
EXPORT_SYMBOL(cnss_sysfs_update_driver_status);

int cnss_sysfs_get_pm_info(void)
{
	return pm_from_macloader;
}
EXPORT_SYMBOL(cnss_sysfs_get_pm_info);

int sec_wifi_ant_info(void)
{
	return ant_from_macloader;
}

void sec_wifi_wait_macloader(void)
{
	if (!wait_for_completion_timeout(&macloader_done,
					 msecs_to_jiffies(MACLOADER_TIMEOUT)))
		icnss_pr_info("macloader_done timeout\n");
}

static ssize_t mac_addr_store(struct kobject *kobj,
			      struct kobj_attribute *attr,
			      const char *buf, size_t count)
{
	u8 mac[MAC_ADDR_SIZE];

	if (sscanf(buf, "%02hhx:%02hhx:%02hhx:%02hhx:%02hhx:%02hhx",
		   &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) !=
	    MAC_ADDR_SIZE)
		return -EINVAL;

	memcpy(mac_from_macloader, mac, MAC_ADDR_SIZE);
	icnss_pr_info("Assigning MAC from Macloader %pM\n", mac_from_macloader);

	cnss_utils_set_wlan_mac_address(mac_from_macloader, MAC_ADDR_SIZE);
	complete_all(&macloader_done);

	return count;
}

static ssize_t wifiver_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	ssize_t len;

	mutex_lock(&sec_info_lock);
	len = sysfs_emit(buf, "%s", ver_info);
	mutex_unlock(&sec_info_lock);
	return len;
}

static ssize_t softap_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	ssize_t len;

	mutex_lock(&sec_info_lock);
	len = sysfs_emit(buf, "%s", softap_info);
	mutex_unlock(&sec_info_lock);
	return len;
}

static ssize_t qcwlanstate_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s",
			  current_driver_status == DRIVER_MODULES_ENABLED ?
			  "ON" : "OFF");
}

static ssize_t pm_store(struct kobject *kobj, struct kobj_attribute *attr,
			const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 10, &val))
		return -EINVAL;
	/* 5.4 semantics: the file holds "power save enabled", we keep "off" */
	pm_from_macloader = !val;
	icnss_pr_info("pm_from_macloader %d\n", pm_from_macloader);
	return count;
}

static ssize_t ant_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 10, &val))
		return -EINVAL;
	ant_from_macloader = val;
	icnss_pr_info("ant_from_macloader %d\n", ant_from_macloader);
	return count;
}

/*
 * RF test cable detection. The A52s device tree has no "samsung,rome_cable"
 * node, so this reads as empty there, as on 5.4.
 */
static ssize_t wificable_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	struct device_node *np;
	struct gpio_desc *c1, *c2;
	ssize_t len = 0;

	np = of_find_compatible_node(NULL, NULL, "samsung,rome_cable");
	if (!np)
		return 0;

	c1 = fwnode_gpiod_get_index(of_fwnode_handle(np), "wlan_cable_wifi_1",
				    0, GPIOD_IN, "wlan_cable_wifi_1");
	c2 = fwnode_gpiod_get_index(of_fwnode_handle(np), "wlan_cable_wifi_2",
				    0, GPIOD_IN, "wlan_cable_wifi_2");
	if (!IS_ERR(c1) && !IS_ERR(c2)) {
		msleep(100);
		len = sysfs_emit(buf, "%c%c\n",
				 gpiod_get_raw_value_cansleep(c1) > 0 ? 'D' : 'E',
				 gpiod_get_raw_value_cansleep(c2) > 0 ? 'D' : 'E');
	} else {
		icnss_pr_err("can't get the wlan_cable_wifi GPIOs\n");
	}
	if (!IS_ERR(c1))
		gpiod_put(c1);
	if (!IS_ERR(c2))
		gpiod_put(c2);
	of_node_put(np);
	return len;
}

static ssize_t memdump_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	return count;
}

/* modes as on 5.4 (init chowns them: wifi_sec.rc) */
static struct kobj_attribute sec_mac_addr_attr = __ATTR(mac_addr, 0220, NULL, mac_addr_store);
static struct kobj_attribute sec_wifiver_attr = __ATTR(wifiver, 0440, wifiver_show, NULL);
static struct kobj_attribute sec_softap_attr = __ATTR(softap, 0440, softap_show, NULL);
static struct kobj_attribute sec_qcwlanstate_attr = __ATTR(qcwlanstate, 0440, qcwlanstate_show, NULL);
static struct kobj_attribute sec_pm_attr = __ATTR(pm, 0220, NULL, pm_store);
static struct kobj_attribute sec_ant_attr = __ATTR(ant, 0220, NULL, ant_store);
static struct kobj_attribute sec_wificable_attr = __ATTR(wificable, 0440, wificable_show, NULL);
static struct kobj_attribute sec_memdump_attr = __ATTR(memdump, 0220, NULL, memdump_store);

static struct attribute *sec_sysfs_attrs[] = {
	&sec_mac_addr_attr.attr,
	&sec_wifiver_attr.attr,
	&sec_softap_attr.attr,
	&sec_qcwlanstate_attr.attr,
	&sec_pm_attr.attr,
	&sec_ant_attr.attr,
	&sec_wificable_attr.attr,
	&sec_memdump_attr.attr,
	NULL
};

static const struct attribute_group sec_sysfs_attr_group = {
	.attrs = sec_sysfs_attrs,
};

int sec_create_wifi_sysfs(struct icnss_priv *priv)
{
	int ret;

	priv->wifi_kobj = kobject_create_and_add("wifi", NULL);
	if (!priv->wifi_kobj) {
		icnss_pr_err("Failed to create the wifi kernel object\n");
		return -ENOMEM;
	}

	ret = sysfs_create_group(priv->wifi_kobj, &sec_sysfs_attr_group);
	if (ret) {
		icnss_pr_err("could not create the wifi group %d\n", ret);
		kobject_put(priv->wifi_kobj);
		priv->wifi_kobj = NULL;
	}
	return ret;
}

void sec_remove_wifi_sysfs(struct icnss_priv *priv)
{
	complete_all(&macloader_done);
	if (priv->wifi_kobj) {
		sysfs_remove_group(priv->wifi_kobj, &sec_sysfs_attr_group);
		kobject_put(priv->wifi_kobj);
		priv->wifi_kobj = NULL;
	}
}
