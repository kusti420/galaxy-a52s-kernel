// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * f_ss_mon_gadget.c - generic USB serial function driver
 *
 * Copyright (C) 2021 by samsung Corporation
 *
 * This software is distributed under the terms of the GNU General
 * Public License ("GPL") as published by the Free Software Foundation,
 * either version 2 of that License or (at your option) any later version.
 *
 * Galaxy A52s (sm7325) Linux 6.12 module-only port, derived from the
 * Samsung S26 6.12 soc-repo drivers/usb/gadget/function/f_ss_mon_gadget.c
 * (with the A52s 5.4 OneUI copy as behavioural reference).
 *
 * Port notes (see README.md next to this file):
 *  - the kernel here is the stock GKI Image; nothing in it (or in our
 *    dwc3-msm / eusb2 phy) calls Samsung's vbus_session_notify(),
 *    usb_reset_notify() or make_suspend_current_event(), so those hooks and
 *    the state they fed (AOA abnormal-reset uevent, VBUS/RESET usblog) are
 *    dropped and NOT exported (a duplicate export would fail the insmod);
 *  - no usb_notify layer, typec manager or sec_battery on this line: the
 *    usblog strings, set_usb_enumeration_state()/set_usb_enable_state() and
 *    the BC1.2 POWER_SUPPLY_EXT_PROP_USB_CONFIGURE vbus-current work are
 *    dropped;
 *  - kept: configfs function "ss_mon" (ss_mon.mtp / ss_mon.ptp), the Samsung
 *    MTP AVD class descriptor in the config descriptor, vendor request 0xA3
 *    (PC GUID) -> /sys/class/misc/usb_mtp_gadget/guid, and the misc device
 *    /dev/usb_mtp_gadget (open/release only, exactly like 5.4 and S26);
 *  - the misc device is refcounted across instances (S26 deregistered it when
 *    the first of ss_mon.mtp/ss_mon.ptp was removed, leaving the other one
 *    without a node), and the guid attribute is created through
 *    miscdevice.groups so it exists before the uevent;
 *  - module init never fails.
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/atomic.h>
#include <linux/string.h>

#include <linux/configfs.h>
#include <linux/usb/composite.h>
#include <linux/miscdevice.h>

#define MAX_INST_NAME_LEN		40

#define DRIVER_NAME		 "usb_mtp_gadget"
#define MAX_GUID_SIZE	0x28
static const char shortname[] = DRIVER_NAME;

static char guid_info[MAX_GUID_SIZE+1];
/* samsung AVD operation: GUID for MTP */
#define SS_MON_REQ_PC_GUID	0xA3

struct usb_mtp_avd_descriptor {
	__u8	bLength;
	__u8	bDescriptorType;
	__u8	bDescriptorSubType;

	__le16	bDAU1_Type;
	__le16	bDAU1_Length;
	__u8	bDAU1_Value;
} __packed;

static struct usb_mtp_avd_descriptor mtp_avd_descriptor = {
	.bLength            =   0x08,
	.bDescriptorType    =   0x24,
	.bDescriptorSubType =   0x80,

	/* First DAU = MTU Size */
	.bDAU1_Type         =   cpu_to_le16(0x000C),
	.bDAU1_Length       =   cpu_to_le16(0x0001),
	.bDAU1_Value	= 0x01,
};

static struct usb_descriptor_header *log_fs_function[]  = {
	(struct usb_descriptor_header *) &mtp_avd_descriptor,
	NULL,
};

/* high speed support: */
static struct usb_descriptor_header *log_hs_function[]  = {
	(struct usb_descriptor_header *) &mtp_avd_descriptor,
	NULL,
};

/* super speed support: */
static struct usb_descriptor_header *log_ss_function[] = {
	(struct usb_descriptor_header *) &mtp_avd_descriptor,
	NULL,
};

struct f_ss_monitor {
	struct usb_function function;
	bool is_bind;
	struct ss_monitor_instance *func_inst;
};

static inline struct f_ss_monitor *func_to_ss_monitor(struct usb_function *f)
{
	return container_of(f, struct f_ss_monitor, function);
}

struct ss_monitor_instance {
	struct usb_function_instance func_inst;
	char *name;
	struct f_ss_monitor *ss_monitor;
	bool has_misc_ref;
};

static inline struct ss_monitor_instance *to_fi_ss_monitor(struct usb_function_instance *fi)
{
	return container_of(fi, struct ss_monitor_instance, func_inst);
}

static inline int _lock(atomic_t *excl)
{
	if (atomic_inc_return(excl) == 1)
		return 0;

	atomic_dec(excl);
	return -1;
}

static inline void _unlock(atomic_t *excl)
{
	atomic_dec(excl);
}

struct mtpg_dev {
	int			error;
	atomic_t		open_excl;
};
/* static (not kzalloc'd as on S26): an open racing an rmdir can not UAF */
static struct mtpg_dev the_mtpg;

static int mtpg_open(struct inode *ip, struct file *fp)
{
	pr_info("[USB] %s\n", __func__);

	if (_lock(&the_mtpg.open_excl)) {
		pr_err("[USB] %s: fn mtpg device busy\n", __func__);
		return -EBUSY;
	}

	fp->private_data = &the_mtpg;

	/* clear the error latch */
	the_mtpg.error = 0;

	return 0;
}

static int mtpg_release_device(struct inode *ip, struct file *fp)
{
	pr_info("[USB] %s\n", __func__);
	_unlock(&the_mtpg.open_excl);
	return 0;
}

/* file operations for MTP device /dev/usb_mtp_gadget */
static const struct file_operations mtpg_fops = {
	.owner   = THIS_MODULE,
	.open    = mtpg_open,
	.release = mtpg_release_device,
};

/*-------------------------------------------------------------------------*/
static ssize_t guid_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	memcpy(buf, guid_info, MAX_GUID_SIZE);
	return MAX_GUID_SIZE;
}

static ssize_t guid_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t size)
{
	if (size > MAX_GUID_SIZE)
		return -EINVAL;

	snprintf(guid_info, size, "%s", buf);
	/* S26 returned snprintf()'s would-be length, which can exceed size */
	return size;
}

static DEVICE_ATTR_RW(guid);

static struct attribute *mtpg_attrs[] = {
	&dev_attr_guid.attr,
	NULL,
};
ATTRIBUTE_GROUPS(mtpg);

static struct miscdevice mtpg_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = shortname,
	.fops = &mtpg_fops,
	.groups = mtpg_groups,
};

/* /dev/usb_mtp_gadget lives while at least one ss_mon instance exists */
static DEFINE_MUTEX(mtpg_lock);
static int mtpg_users;
static bool mtpg_registered;

static bool mtpg_get(void)
{
	int rc;

	mutex_lock(&mtpg_lock);
	if (!mtpg_registered) {
		atomic_set(&the_mtpg.open_excl, 0);
		rc = misc_register(&mtpg_device);
		if (rc) {
			pr_err("[USB] %s misc_register of mtpg Failed(%d)\n", __func__, rc);
			mutex_unlock(&mtpg_lock);
			return false;
		}
		mtpg_registered = true;
	}
	mtpg_users++;
	mutex_unlock(&mtpg_lock);
	return true;
}

static void mtpg_put(void)
{
	mutex_lock(&mtpg_lock);
	if (mtpg_users > 0 && --mtpg_users == 0 && mtpg_registered) {
		misc_deregister(&mtpg_device);
		mtpg_registered = false;
	}
	mutex_unlock(&mtpg_lock);
}

/*-------------------------------------------------------------------------*/
static int ss_monitor_set_alt(struct usb_function *f,
		unsigned int intf, unsigned int alt)
{
	/* ss_mon owns no interface; kept for parity with 5.4/S26 */
	return 0;
}

static void ss_monitor_disable(struct usb_function *f)
{
	memset(guid_info, 0, sizeof(guid_info));
}

static void
mtp_complete_get_guid(struct usb_ep *ep, struct usb_request *req)
{
	int size;

	if (req->status != 0) {
		pr_info("[USB] %s: req->status %d\n", __func__, req->status);
		return;
	}

	if (req->actual >= sizeof(guid_info))
		size = sizeof(guid_info)-1;
	else
		size = req->actual;
	memset(guid_info, 0, sizeof(guid_info));
	memcpy(guid_info, req->buf, size);
}

/*
 * Only reached for requests ss_monitor_req_match() claims (vendor 0xA3) via
 * the stock composite_setup() "unknown request" path. On S26 Samsung's
 * dwc3-msm kretprobe on configfs_composite_setup() additionally fed every
 * other ep0 request in here for logging / AOA accounting; that is gone.
 */
static int ss_monitor_setup(struct usb_function *f,
				const struct usb_ctrlrequest *ctrl)
{
	struct usb_composite_dev *cdev;
	struct usb_request	*req;
	int	value = -EOPNOTSUPP;
	u16	w_length = le16_to_cpu(ctrl->wLength);

	if (f->config == NULL || f->config->cdev == NULL)
		return value;
	cdev = f->config->cdev;
	req = cdev->req;

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_VENDOR ||
	    (ctrl->bRequestType & USB_DIR_IN) ||
	    ctrl->bRequest != SS_MON_REQ_PC_GUID)
		return value;

	pr_info("[USB] %s: (mtp) RECEIVE PC GUID\n", __func__);
	if (w_length > MAX_GUID_SIZE) {
		pr_info("[USB] %s: Invalid GUID size %u\n", __func__, w_length);
		return value;
	}

	value = w_length;
	req->complete = mtp_complete_get_guid;
	req->zero = 0;
	req->length = value;
	value = usb_ep_queue(cdev->gadget->ep0, req, GFP_ATOMIC);
	if (value < 0)
		pr_err("[USB] %s: (mtp) Error usb_ep_queue %d\n", __func__, value);

	return value;
}

static bool ss_monitor_req_match(struct usb_function *f,
		const struct usb_ctrlrequest *ctrl, bool config)
{
	if ((ctrl->bRequestType & USB_TYPE_MASK) == USB_TYPE_VENDOR)
		if (ctrl->bRequest == SS_MON_REQ_PC_GUID)
			return true;

	return false;
}

static int
ss_monitor_bind(struct usb_configuration *c, struct usb_function *f)
{
	struct f_ss_monitor		*ss_monitor = func_to_ss_monitor(f);
	struct ss_monitor_instance *opts;
	int	rc;

	opts = container_of(f->fi, struct ss_monitor_instance, func_inst);

	/* copies are made per speed; ssp reuses the ss set */
	rc = usb_assign_descriptors(f, log_fs_function, log_hs_function,
				    log_ss_function, log_ss_function);
	if (rc) {
		pr_err("[USB] %s: ss_mon.%s bind fail %d\n", __func__, opts->name, rc);
		return rc;
	}

	f->setup = ss_monitor_setup;
	ss_monitor->is_bind = 1;
	pr_info("[USB] %s: ss_mon.%s bind\n", __func__, opts->name);
	return 0;
}

static void
ss_monitor_unbind(struct usb_configuration *c, struct usb_function *f)
{
	struct f_ss_monitor *ss_monitor = func_to_ss_monitor(f);
	struct ss_monitor_instance *opts;

	opts = container_of(f->fi, struct ss_monitor_instance, func_inst);
	f->setup = NULL;
	ss_monitor->is_bind = 0;
	usb_free_all_descriptors(f);

	pr_info("[USB] %s: ss_mon.%s unbind\n", __func__, opts->name);
}

static struct ss_monitor_instance *to_ss_monitor_instance(struct config_item *item)
{
	return container_of(to_config_group(item), struct ss_monitor_instance,
		func_inst.group);
}

static void ss_monitor_attr_release(struct config_item *item)
{
	struct ss_monitor_instance *fi_ss_monitor = to_ss_monitor_instance(item);

	usb_put_function_instance(&fi_ss_monitor->func_inst);
}

static struct configfs_item_operations ss_monitor_item_ops = {
	.release        = ss_monitor_attr_release,
};

static const struct config_item_type ss_monitor_func_type = {
	.ct_item_ops    = &ss_monitor_item_ops,
	.ct_owner       = THIS_MODULE,
};

static int ss_monitor_set_inst_name(struct usb_function_instance *fi, const char *name)
{
	struct ss_monitor_instance *fi_ss_monitor;
	char *ptr;
	int name_len;

	name_len = strlen(name) + 1;
	if (name_len > MAX_INST_NAME_LEN)
		return -ENAMETOOLONG;

	ptr = kstrndup(name, name_len, GFP_KERNEL);
	if (!ptr)
		return -ENOMEM;

	fi_ss_monitor = to_fi_ss_monitor(fi);
	fi_ss_monitor->name = ptr;

	return 0;
}

static void ss_monitor_free_inst(struct usb_function_instance *fi)
{
	struct ss_monitor_instance *fi_ss_monitor;

	fi_ss_monitor = to_fi_ss_monitor(fi);
	if (fi_ss_monitor->has_misc_ref)
		mtpg_put();
	kfree(fi_ss_monitor->name);
	kfree(fi_ss_monitor);
}

static struct usb_function_instance *ss_mon_alloc_inst(void)
{
	struct ss_monitor_instance *fi_ss_monitor;

	fi_ss_monitor = kzalloc(sizeof(*fi_ss_monitor), GFP_KERNEL);
	if (!fi_ss_monitor) {
		pr_err("[USB] %s: ss_mon_alloc_inst fail\n", __func__);
		return ERR_PTR(-ENOMEM);
	}

	/* as on S26: a misc_register failure does not fail the mkdir */
	fi_ss_monitor->has_misc_ref = mtpg_get();

	fi_ss_monitor->func_inst.set_inst_name = ss_monitor_set_inst_name;
	fi_ss_monitor->func_inst.free_func_inst = ss_monitor_free_inst;

	config_group_init_type_name(&fi_ss_monitor->func_inst.group,
					"", &ss_monitor_func_type);

	return  &fi_ss_monitor->func_inst;
}

static void ss_monitor_free(struct usb_function *f)
{
	struct f_ss_monitor	*ss_monitor = func_to_ss_monitor(f);

	if (ss_monitor->func_inst && ss_monitor->func_inst->ss_monitor == ss_monitor)
		ss_monitor->func_inst->ss_monitor = NULL;
	kfree(ss_monitor);
}

static struct usb_function *ss_mon_alloc(struct usb_function_instance *fi)
{
	struct ss_monitor_instance *fi_ss_monitor = to_fi_ss_monitor(fi);
	struct f_ss_monitor *ss_monitor;

	/* allocate and initialize one new instance */
	ss_monitor = kzalloc(sizeof(*ss_monitor), GFP_KERNEL);
	if (!ss_monitor)
		return ERR_PTR(-ENOMEM);

	ss_monitor->function.name = "ss_mon";
	ss_monitor->function.bind = ss_monitor_bind;
	ss_monitor->function.unbind = ss_monitor_unbind;
	ss_monitor->function.set_alt = ss_monitor_set_alt;
	ss_monitor->function.disable = ss_monitor_disable;
	ss_monitor->function.free_func = ss_monitor_free;
	ss_monitor->function.req_match = ss_monitor_req_match;
	fi_ss_monitor->ss_monitor = ss_monitor;
	ss_monitor->func_inst = fi_ss_monitor;

	return &ss_monitor->function;
}

/*
 * Open-coded DECLARE_USB_FUNCTION_INIT(ss_mon, ...): the stock macro returns
 * usb_function_register()'s error from module init; a first-stage insmod
 * failure must never happen, so log and carry on instead.
 */
static struct usb_function_driver ss_monusb_func = {
	.name = "ss_mon",
	.mod  = THIS_MODULE,
	.alloc_inst = ss_mon_alloc_inst,
	.alloc_func = ss_mon_alloc,
};

static bool ss_mon_registered;

static int __init ss_mon_mod_init(void)
{
	int rc = usb_function_register(&ss_monusb_func);

	if (rc)
		pr_err("[USB] ss_mon: usb_function_register failed %d\n", rc);
	else
		ss_mon_registered = true;
	return 0;
}
module_init(ss_mon_mod_init);

static void __exit ss_mon_mod_exit(void)
{
	if (ss_mon_registered)
		usb_function_unregister(&ss_monusb_func);
}
module_exit(ss_mon_mod_exit);

MODULE_AUTHOR("Samsung USB Team");
MODULE_DESCRIPTION("usb device monitor gadget");
MODULE_LICENSE("GPL");
