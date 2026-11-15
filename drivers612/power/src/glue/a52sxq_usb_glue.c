// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq: bridge from Samsung's usb_notifier to the Qualcomm 6.12 BSP dwc3-msm.
 *
 * On 5.4 Samsung added dwc_msm_id_event()/dwc_msm_vbus_event() to dwc3-msm.c itself. The BSP
 * dwc3-msm-core.c has no such hooks but takes VBUS/ID from any extcon device listed in its
 * "extcon" DT property (EXTCON_USB = device mode, EXTCON_USB_HOST = host mode, with
 * EXTCON_PROP_USB_TYPEC_POLARITY and EXTCON_PROP_USB_SS read at role change). This module
 * registers that extcon device and implements the Samsung hooks on top of it, so dwc3-msm
 * stays unmodified.
 *
 * DT:
 *	a52sxq_usb_extcon: a52sxq-usb-extcon { compatible = "samsung,a52sxq-usb-extcon"; };
 *	&usb0 { extcon = <&eud>, <&a52sxq_usb_extcon>; };
 * The device name must not contain "eud" (dwc3-msm treats such a device as the EUD).
 *
 * Never run on hardware (2026-11-11).
 */
#include <linux/extcon-provider.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include "a52sxq_usb_glue.h"

static const unsigned int a52sxq_usb_cables[] = {
	EXTCON_USB,
	EXTCON_USB_HOST,
	EXTCON_NONE,
};

struct a52sxq_usb_glue {
	struct device *dev;
	struct extcon_dev *edev;
};

static DEFINE_MUTEX(glue_lock);
static struct a52sxq_usb_glue *glue;
/* state requested before probe, replayed at probe */
static bool pend_vbus, pend_id;
static int orientation;		/* 0 = CC1, 1 = CC2 */
static int high_speed_only;	/* dwc3_max_speed_setting(1) */

static void glue_apply(unsigned int id, bool on)
{
	union extcon_property_value val;

	if (!glue)
		return;

	if (on) {
		/* properties can only be set while the cable is attached: set state first
		 * without sync, then the properties, then notify */
		extcon_set_state(glue->edev, id, true);
		val.intval = orientation;
		extcon_set_property(glue->edev, id, EXTCON_PROP_USB_TYPEC_POLARITY, val);
		val.intval = high_speed_only ? 0 : 1;
		extcon_set_property(glue->edev, id, EXTCON_PROP_USB_SS, val);
		extcon_sync(glue->edev, id);
	} else {
		extcon_set_state_sync(glue->edev, id, false);
	}
	dev_info(glue->dev, "%s %s (cc%d, %s)\n",
		 id == EXTCON_USB ? "device" : "host", on ? "on" : "off",
		 orientation + 1, high_speed_only ? "hs only" : "ss");
}

int dwc_msm_id_event(bool enable)
{
	mutex_lock(&glue_lock);
	pend_id = enable;
	if (enable && pend_vbus) {
		pend_vbus = false;
		glue_apply(EXTCON_USB, false);
	}
	glue_apply(EXTCON_USB_HOST, enable);
	mutex_unlock(&glue_lock);
	return 0;
}
EXPORT_SYMBOL(dwc_msm_id_event);

int dwc_msm_vbus_event(bool enable)
{
	mutex_lock(&glue_lock);
	pend_vbus = enable;
	if (enable && pend_id) {
		pend_id = false;
		glue_apply(EXTCON_USB_HOST, false);
	}
	glue_apply(EXTCON_USB, enable);
	mutex_unlock(&glue_lock);
	return 0;
}
EXPORT_SYMBOL(dwc_msm_vbus_event);

/*
 * 5.4 meaning: "dwc3-msm has probed, events will not be lost". Here events are latched and
 * replayed (by us at our probe, by dwc3-msm at its probe from the extcon state), so the
 * answer is always yes once this module is loaded.
 */
int is_dwc3_msm_probe_done(void)
{
	return 1;
}
EXPORT_SYMBOL(is_dwc3_msm_probe_done);

/* 0 = SuperSpeed allowed, 1 = restrict to high speed (takes effect at the next attach) */
void dwc3_max_speed_setting(int speed)
{
	mutex_lock(&glue_lock);
	high_speed_only = !!speed;
	mutex_unlock(&glue_lock);
	pr_info("%s: high_speed_only=%d\n", __func__, high_speed_only);
}
EXPORT_SYMBOL(dwc3_max_speed_setting);

/*
 * 5.4/S26 return dwc->gadget->speed. The gadget is private to dwc3-msm here, so report
 * USB_SPEED_UNKNOWN (0). usb_notify only uses it for the "usb speed" hardware-parameter
 * statistics.
 */
int gadget_speed(void)
{
	return 0;
}
EXPORT_SYMBOL(gadget_speed);

void a52sxq_usb_glue_set_orientation(int flipped)
{
	mutex_lock(&glue_lock);
	orientation = !!flipped;
	mutex_unlock(&glue_lock);
}
EXPORT_SYMBOL(a52sxq_usb_glue_set_orientation);

static ssize_t state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "vbus=%d id=%d cc=%d hs_only=%d\n",
			  pend_vbus, pend_id, orientation + 1, high_speed_only);
}
static DEVICE_ATTR_RO(state);

static int a52sxq_usb_glue_probe(struct platform_device *pdev)
{
	struct a52sxq_usb_glue *g;
	int ret;

	g = devm_kzalloc(&pdev->dev, sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;
	g->dev = &pdev->dev;

	g->edev = devm_extcon_dev_allocate(&pdev->dev, a52sxq_usb_cables);
	if (IS_ERR(g->edev))
		return PTR_ERR(g->edev);
	ret = devm_extcon_dev_register(&pdev->dev, g->edev);
	if (ret)
		return ret;

	extcon_set_property_capability(g->edev, EXTCON_USB, EXTCON_PROP_USB_TYPEC_POLARITY);
	extcon_set_property_capability(g->edev, EXTCON_USB, EXTCON_PROP_USB_SS);
	extcon_set_property_capability(g->edev, EXTCON_USB_HOST, EXTCON_PROP_USB_TYPEC_POLARITY);
	extcon_set_property_capability(g->edev, EXTCON_USB_HOST, EXTCON_PROP_USB_SS);

	ret = device_create_file(&pdev->dev, &dev_attr_state);
	if (ret)
		return ret;

	mutex_lock(&glue_lock);
	glue = g;
	if (pend_id)
		glue_apply(EXTCON_USB_HOST, true);
	else if (pend_vbus)
		glue_apply(EXTCON_USB, true);
	mutex_unlock(&glue_lock);

	dev_info(&pdev->dev, "a52sxq usb glue: extcon registered\n");
	return 0;
}

static void a52sxq_usb_glue_remove(struct platform_device *pdev)
{
	device_remove_file(&pdev->dev, &dev_attr_state);
	mutex_lock(&glue_lock);
	glue = NULL;
	mutex_unlock(&glue_lock);
}

static const struct of_device_id a52sxq_usb_glue_of_match[] = {
	{ .compatible = "samsung,a52sxq-usb-extcon" },
	{ }
};
MODULE_DEVICE_TABLE(of, a52sxq_usb_glue_of_match);

static struct platform_driver a52sxq_usb_glue_driver = {
	.probe = a52sxq_usb_glue_probe,
	.remove = a52sxq_usb_glue_remove,
	.driver = {
		.name = "a52sxq-usb-glue",
		.of_match_table = a52sxq_usb_glue_of_match,
	},
};
module_platform_driver(a52sxq_usb_glue_driver);

MODULE_DESCRIPTION("a52sxq: Samsung usb_notifier to dwc3-msm extcon bridge");
MODULE_LICENSE("GPL");
