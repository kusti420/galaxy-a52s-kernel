// SPDX-License-Identifier: GPL-2.0-only
/*
 * ufs_sec_sysfs: the Samsung UFS sysfs nodes of the Galaxy A52s 5.4 kernel
 * (A528BXXU5FWK4, 5.4.233-qgki) for the 6.12 GKI + Qualcomm soc-repo ufs-qcom stack,
 * as an add-on module that does not touch the UFS driver itself.
 *
 * Reproduced from the Samsung 5.4 sources (drivers/scsi/ufs/ufs-qcom.c, ufs-sysfs.c):
 *   Copyright (c) 2013-2020, Linux Foundation. All rights reserved.
 *   Copyright (C) 2018 Western Digital Corporation
 *   Samsung Electronics Co., Ltd. "sec special features" (unique number, LT, LC,
 *   man_id, transferred_cnt, SEC WB, SEC_UFS error-count nodes).
 * Structure follows the Samsung S26 6.12 ufs-sec-feature.c / ufs-sec-sysfs.c, whose
 * unique-number format is identical to 5.4.
 *
 * Nodes (names, modes and print formats exactly as 5.4; see README.md):
 *   /sys/class/sec/ufs/{un 0440, lt 0444, lc 0664, man_id 0444, transferred_cnt 0444,
 *                       sec_wb_enable 0664}
 *   /sys/class/scsi_host/host0/{SEC_UFS_op_cnt, SEC_UFS_uic_cmd_cnt, SEC_UFS_uic_err_cnt,
 *                       SEC_UFS_fatal_cnt, SEC_UFS_utp_cnt, SEC_UFS_query_cnt,
 *                       SEC_UFS_err_sum, sense_err_count, sense_err_logging} 0444
 *   /sys/class/scsi_host/host0/unique_number 0440 ONLY with legacy_shost_un=1 (5.4 on the
 *                       A52s did NOT have this node; default off).
 *
 * Module init never fails and never blocks: it creates the /sys/class/sec/ufs device and
 * schedules a delayed work that waits for the UFS host (platform device 1d84000.ufshc) to
 * be operational, then reads the device / string / health descriptors once, exactly as
 * 5.4's ufs_set_sec_features() did, and adds the scsi_host nodes.
 */

#define pr_fmt(fmt) "ufs_sec_sysfs: " fmt

#include <linux/atomic.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/semaphore.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_host.h>
#include <ufs/ufs.h>
#include <ufs/ufshcd.h>

#include "../../../samsung612/modules/sec_core/include/linux/sec_class.h"

/* Exported by the GKI core (EXPORT_SYMBOL_GPL), declared only in ufshcd-priv.h. */
int ufshcd_query_descriptor_retry(struct ufs_hba *hba, enum query_opcode opcode,
				  enum desc_idn idn, u8 index, u8 selector,
				  u8 *desc_buf, int *buf_len);

#define UFS_SEC_HOST_DEV	"1d84000.ufshc"

/* 5.4 ufs-qcom.h */
#define UFS_UN_20_DIGITS	20
#define UFS_UN_MAX_DIGITS	21	/* current max digit + 1 */
#define SERIAL_NUM_SIZE		7

#define UFS_SEC_RETRY_MS	250
#define UFS_SEC_RETRY_MAX	240	/* 60 s */

static bool legacy_shost_un;
module_param(legacy_shost_un, bool, 0444);
MODULE_PARM_DESC(legacy_shost_un,
	"also create /sys/class/scsi_host/host0/unique_number (absent on the A52s 5.4 kernel)");

/* 5.4 struct ufs_vendor_dev_info */
static struct {
	char unique_number[UFS_UN_MAX_DIGITS];
	u8 lifetime;
	unsigned int lc_info;
	u16 wmanufacturerid;
	struct ufs_hba *hba;
} ufs_vdi;

static DEFINE_MUTEX(ufs_sec_lock);	/* health descriptor refresh */
static struct device *sec_ufs_cmd_dev;
static bool sec_ufs_group_ok;
static struct device *ufs_pdev;		/* reference on 1d84000.ufshc */
static bool shost_group_ok, shost_un_ok;
static struct delayed_work ufs_sec_work;
static int ufs_sec_tries;

/* 5.4 SEC WB state, only the parts behind sec_wb_enable (see README: no-op on 6.12) */
static DEFINE_SPINLOCK(wb_lock);
static atomic_t wb_off_cnt = ATOMIC_INIT(0);
static bool wb_off;

/* ------------------------------------------------------------------ queries */

/* Caller holds a runtime-PM reference and hba->host_sem. 5.4 ufs_get_health_desc(). */
static void ufs_sec_get_health_desc(struct ufs_hba *hba)
{
	int buff_len = QUERY_DESC_MAX_SIZE;
	u8 *desc_buf;
	int err;

	desc_buf = kzalloc(buff_len, GFP_KERNEL);
	if (!desc_buf)
		return;

	err = ufshcd_query_descriptor_retry(hba, UPIU_QUERY_OPCODE_READ_DESC,
			QUERY_DESC_IDN_HEALTH, 0, 0, desc_buf, &buff_len);
	if (err) {
		dev_err(hba->dev, "%s: Failed reading health descriptor. err %d",
				__func__, err);
		goto out;
	}

	/* getting Life Time at Device Health DESC */
	ufs_vdi.lifetime = desc_buf[HEALTH_DESC_PARAM_LIFE_TIME_EST_A];
out:
	kfree(desc_buf);
}

/*
 * 5.4 ufs_set_sec_unique_number() (ufs-qcom.c:4366-4410), byte for byte:
 * manid = low byte of wManufacturerID, the two raw bytes of wManufactureDate, then the
 * first 7 raw bytes of the serial-number string descriptor ("spec is unicode but sec
 * uses hex data"), each as %02X: 20 upper-case hex digits.
 */
static void ufs_sec_set_unique_number(struct ufs_hba *hba, u8 *desc_buf)
{
	u8 manid;
	u8 serial_num_index;
	u8 snum_buf[UFS_UN_MAX_DIGITS];
	int buff_len = QUERY_DESC_MAX_SIZE;
	u8 *str_desc_buf;
	int err;

	str_desc_buf = kzalloc(buff_len, GFP_KERNEL);
	if (!str_desc_buf)
		return;

	serial_num_index = desc_buf[DEVICE_DESC_PARAM_SN];

	/* spec is unicode but sec uses hex data */
	err = ufshcd_query_descriptor_retry(hba, UPIU_QUERY_OPCODE_READ_DESC,
			QUERY_DESC_IDN_STRING, serial_num_index, 0,
			str_desc_buf, &buff_len);
	if (err) {
		dev_err(hba->dev, "%s: Failed reading string descriptor. err %d",
				__func__, err);
		goto out;
	}

	/* setup unique_number */
	manid = desc_buf[DEVICE_DESC_PARAM_MANF_ID + 1];
	memset(snum_buf, 0, sizeof(snum_buf));
	memcpy(snum_buf, str_desc_buf + QUERY_DESC_HDR_SIZE, SERIAL_NUM_SIZE);
	memset(ufs_vdi.unique_number, 0, sizeof(ufs_vdi.unique_number));

	snprintf(ufs_vdi.unique_number, UFS_UN_MAX_DIGITS,
			"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
			manid,
			desc_buf[DEVICE_DESC_PARAM_MANF_DATE],
			desc_buf[DEVICE_DESC_PARAM_MANF_DATE + 1],
			snum_buf[0], snum_buf[1], snum_buf[2], snum_buf[3],
			snum_buf[4], snum_buf[5], snum_buf[6]);

	/* Null terminate the unique number string */
	ufs_vdi.unique_number[UFS_UN_20_DIGITS] = '\0';

	dev_dbg(hba->dev, "%s: ufs un : %s\n", __func__, ufs_vdi.unique_number);
out:
	kfree(str_desc_buf);
}

/* 5.4 ufs_set_sec_features() minus WB; returns 0 when the descriptors were read. */
static int ufs_sec_read_features(struct ufs_hba *hba)
{
	int buff_len = QUERY_DESC_MAX_SIZE;
	u8 *desc_buf;
	int err;

	desc_buf = kzalloc(buff_len, GFP_KERNEL);
	if (!desc_buf)
		return -ENOMEM;

	down(&hba->host_sem);
	if (hba->shutting_down) {
		err = -EBUSY;
		goto out_sem;
	}
	ufshcd_rpm_get_sync(hba);

	err = ufshcd_query_descriptor_retry(hba, UPIU_QUERY_OPCODE_READ_DESC,
			QUERY_DESC_IDN_DEVICE, 0, 0, desc_buf, &buff_len);
	if (err) {
		dev_err(hba->dev, "%s: Failed reading device descriptor. err %d",
				__func__, err);
	} else {
		ufs_vdi.wmanufacturerid = desc_buf[DEVICE_DESC_PARAM_MANF_ID] << 8 |
					  desc_buf[DEVICE_DESC_PARAM_MANF_ID + 1];
		ufs_sec_set_unique_number(hba, desc_buf);
		mutex_lock(&ufs_sec_lock);
		ufs_sec_get_health_desc(hba);
		mutex_unlock(&ufs_sec_lock);
	}

	ufshcd_rpm_put_sync(hba);
out_sem:
	up(&hba->host_sem);
	kfree(desc_buf);
	return err;
}

/* ------------------------------------------------------------ /sys/class/sec/ufs */

static ssize_t ufs_unique_number_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%s\n", ufs_vdi.unique_number);
}
static DEVICE_ATTR(un, 0440, ufs_unique_number_show, NULL);

static ssize_t ufs_lt_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct ufs_hba *hba = READ_ONCE(ufs_vdi.hba);

	if (!hba) {
		dev_err(dev, "skipping ufs lt read\n");
		ufs_vdi.lifetime = 0;
	} else if (hba->ufshcd_state == UFSHCD_STATE_OPERATIONAL &&
		   hba->ufs_device_wlun) {
		down(&hba->host_sem);
		if (!hba->shutting_down) {
			ufshcd_rpm_get_sync(hba);
			mutex_lock(&ufs_sec_lock);
			ufs_sec_get_health_desc(hba);
			mutex_unlock(&ufs_sec_lock);
			ufshcd_rpm_put_sync(hba);
		}
		up(&hba->host_sem);
	} else {
		/* return previous LT value if not operational */
		dev_info(hba->dev, "ufshcd_state : %d, old LT: %01x\n",
				hba->ufshcd_state, ufs_vdi.lifetime);
	}
	return snprintf(buf, PAGE_SIZE, "%01x\n", ufs_vdi.lifetime);
}
static DEVICE_ATTR(lt, 0444, ufs_lt_show, NULL);

static ssize_t ufs_lc_info_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%u\n", ufs_vdi.lc_info);
}

static ssize_t ufs_lc_info_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	unsigned int value;

	if (kstrtou32(buf, 0, &value))
		return -EINVAL;

	ufs_vdi.lc_info = value;

	return count;
}
static DEVICE_ATTR(lc, 0664, ufs_lc_info_show, ufs_lc_info_store);

static ssize_t man_id_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct ufs_hba *hba = READ_ONCE(ufs_vdi.hba);

	/* 5.4 prints hba->dev_info.wmanufacturerid (same bytes as the device descriptor) */
	return sprintf(buf, "%04x\n",
		       hba ? hba->dev_info.wmanufacturerid : ufs_vdi.wmanufacturerid);
}
static DEVICE_ATTR_RO(man_id);

/* 5.4 counts bytes in ufs-qcom's completion path; 6.12 ufs-qcom has no such counter. */
static ssize_t transferred_cnt_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%llu\n", 0ULL);
}
static DEVICE_ATTR_RO(transferred_cnt);

/*
 * 5.4 ufs_sec_wb_enable_{store,show} (CONFIG_SEC_UFS_WB_FEATURE): an off-request
 * refcount (the camera HAL writes it). Kept with the same parsing, refcount and output;
 * on 6.12 it does not switch WriteBooster (the GKI core owns WB policy).
 */
static ssize_t ufs_sec_wb_enable_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	unsigned long flags;
	u32 value;

	if (kstrtou32(buf, 0, &value))
		return -EINVAL;

	spin_lock_irqsave(&wb_lock, flags);
	value = !!value;

	if (!value) {
		if (atomic_inc_return(&wb_off_cnt) == 1) {
			wb_off = true;
			pr_debug("disable SEC WB\n");
		}
	} else {
		if (atomic_dec_and_test(&wb_off_cnt)) {
			wb_off = false;
			pr_debug("enable SEC WB.\n");
		}
	}
	spin_unlock_irqrestore(&wb_lock, flags);

	return count;
}

static ssize_t ufs_sec_wb_enable_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%s\n", wb_off ? "off" : "Enabled");
}
static DEVICE_ATTR(sec_wb_enable, 0664, ufs_sec_wb_enable_show, ufs_sec_wb_enable_store);

static struct attribute *sec_ufs_info_attributes[] = {
	&dev_attr_un.attr,
	&dev_attr_lt.attr,
	&dev_attr_lc.attr,
	&dev_attr_man_id.attr,
	&dev_attr_transferred_cnt.attr,
	&dev_attr_sec_wb_enable.attr,
	NULL
};

static const struct attribute_group sec_ufs_info_attribute_group = {
	.attrs	= sec_ufs_info_attributes,
};

/* ------------------------------------------------ /sys/class/scsi_host/host0 */

/*
 * 5.4 ufs-sysfs.c:1231-1322 (SEC_UFS_DATA_ATTR, mode 0444). The 5.4 counters are fed by
 * Samsung hooks inside ufshcd.c error handling, which the 6.12 GKI core does not have:
 * the nodes exist with the 5.4 format and report 0.
 */
#define SEC_UFS_DATA_ATTR(name, fmt, args...)					\
static ssize_t SEC_UFS_##name##_show(struct device *dev,			\
		struct device_attribute *attr, char *buf)			\
{										\
	return sprintf(buf, fmt, args);						\
}										\
static DEVICE_ATTR(name, 0444, SEC_UFS_##name##_show, NULL)

#define Z	0u
#define ZL	0ul

SEC_UFS_DATA_ATTR(SEC_UFS_op_cnt, "\"HWRESET\":\"%u\",\"LINKFAIL\":\"%u\",\"H8ENTERFAIL\":\"%u\""
		",\"H8EXITFAIL\":\"%u\"\n", Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_uic_cmd_cnt, "\"TESTMODE\":\"%u\",\"DME_GET\":\"%u\",\"DME_SET\":\"%u\""
		",\"DME_PGET\":\"%u\",\"DME_PSET\":\"%u\",\"PWRON\":\"%u\",\"PWROFF\":\"%u\""
		",\"DME_EN\":\"%u\",\"DME_RST\":\"%u\",\"EPRST\":\"%u\",\"LINKSTARTUP\":\"%u\""
		",\"H8ENTER\":\"%u\",\"H8EXIT\":\"%u\"\n",
		Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_uic_err_cnt, "\"PAERR\":\"%u\",\"DLPAINITERROR\":\"%u\",\"DLNAC\":\"%u\""
		",\"DLTCREPLAY\":\"%u\",\"NLERR\":\"%u\",\"TLERR\":\"%u\",\"DMEERR\":\"%u\"\n",
		Z, Z, Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_fatal_cnt, "\"DFE\":\"%u\",\"CFE\":\"%u\",\"SBFE\":\"%u\""
		",\"CEFE\":\"%u\",\"LLE\":\"%u\"\n", Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_utp_cnt, "\"UTMRQTASK\":\"%u\",\"UTMRATASK\":\"%u\",\"UTRR\":\"%u\""
		",\"UTRW\":\"%u\",\"UTRSYNCCACHE\":\"%u\",\"UTRUNMAP\":\"%u\",\"UTRETC\":\"%u\"\n",
		Z, Z, Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_query_cnt, "\"NOPERR\":\"%u\",\"R_DESC\":\"%u\",\"W_DESC\":\"%u\""
		",\"R_ATTR\":\"%u\",\"W_ATTR\":\"%u\",\"R_FLAG\":\"%u\",\"S_FLAG\":\"%u\""
		",\"C_FLAG\":\"%u\",\"T_FLAG\":\"%u\"\n", Z, Z, Z, Z, Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(SEC_UFS_err_sum, "\"OPERR\":\"%u\",\"UICCMD\":\"%u\",\"UICERR\":\"%u\""
		",\"FATALERR\":\"%u\",\"UTPERR\":\"%u\",\"QUERYERR\":\"%u\"\n",
		Z, Z, Z, Z, Z, Z);

SEC_UFS_DATA_ATTR(sense_err_count, "\"MEDIUM\":\"%u\",\"HWERR\":\"%u\"\n", Z, Z);

SEC_UFS_DATA_ATTR(sense_err_logging, "\"LBA0\":\"%lx\",\"LBA1\":\"%lx\",\"LBA2\":\"%lx\""
		",\"LBA3\":\"%lx\",\"LBA4\":\"%lx\",\"LBA5\":\"%lx\""
		",\"LBA6\":\"%lx\",\"LBA7\":\"%lx\",\"LBA8\":\"%lx\",\"LBA9\":\"%lx\""
		",\"REGIONMAP\":\"%016llx\"\n",
		ZL, ZL, ZL, ZL, ZL, ZL, ZL, ZL, ZL, ZL, 0ULL);

static struct attribute *sec_ufs_error_attributes[] = {
	&dev_attr_SEC_UFS_op_cnt.attr,
	&dev_attr_SEC_UFS_uic_cmd_cnt.attr,
	&dev_attr_SEC_UFS_uic_err_cnt.attr,
	&dev_attr_SEC_UFS_fatal_cnt.attr,
	&dev_attr_SEC_UFS_utp_cnt.attr,
	&dev_attr_SEC_UFS_query_cnt.attr,
	&dev_attr_SEC_UFS_err_sum.attr,
	&dev_attr_sense_err_count.attr,
	&dev_attr_sense_err_logging.attr,
	NULL
};

static const struct attribute_group sec_ufs_error_attribute_group = {
	.attrs	= sec_ufs_error_attributes,
};

/* Legacy (pre-R) Samsung location of the same string; off by default, see README. */
static DEVICE_ATTR(unique_number, 0440, ufs_unique_number_show, NULL);

/* ------------------------------------------------------------------- setup */

static struct ufs_hba *ufs_sec_find_hba(void)
{
	struct ufs_hba *hba;

	if (!ufs_pdev) {
		ufs_pdev = bus_find_device_by_name(&platform_bus_type, NULL,
						   UFS_SEC_HOST_DEV);
		if (!ufs_pdev)
			return NULL;
	}

	if (!READ_ONCE(ufs_pdev->driver))
		return NULL;
	hba = dev_get_drvdata(ufs_pdev);
	if (!hba || hba->dev != ufs_pdev || !hba->host)
		return NULL;
	/* probe finished: device W-LUN added and the host operational */
	if (!READ_ONCE(hba->ufs_device_wlun) ||
	    READ_ONCE(hba->ufshcd_state) != UFSHCD_STATE_OPERATIONAL)
		return NULL;
	if (!device_is_registered(&hba->host->shost_dev))
		return NULL;
	return hba;
}

static void ufs_sec_work_fn(struct work_struct *work)
{
	struct ufs_hba *hba = ufs_sec_find_hba();
	struct device *shost_dev;
	int err;

	if (!hba) {
		if (++ufs_sec_tries < UFS_SEC_RETRY_MAX) {
			schedule_delayed_work(&ufs_sec_work,
					      msecs_to_jiffies(UFS_SEC_RETRY_MS));
			return;
		}
		pr_err("UFS host %s not operational after %d s; un/lt stay empty/0\n",
		       UFS_SEC_HOST_DEV, UFS_SEC_RETRY_MAX * UFS_SEC_RETRY_MS / 1000);
		return;
	}

	if (sec_ufs_cmd_dev && !IS_ERR(sec_ufs_cmd_dev))
		dev_set_drvdata(sec_ufs_cmd_dev, hba);	/* as 5.4: sec_device_create(hba, "ufs") */

	err = ufs_sec_read_features(hba);
	WRITE_ONCE(ufs_vdi.hba, hba);
	if (err)
		dev_err(hba->dev, "ufs_sec_sysfs: descriptor read failed (%d), un empty\n", err);
	else
		dev_info(hba->dev, "ufs_sec_sysfs: un ready (%zu digits), man_id %04x, LT %01x\n",
			 strlen(ufs_vdi.unique_number), hba->dev_info.wmanufacturerid,
			 ufs_vdi.lifetime);

	shost_dev = &hba->host->shost_dev;
	err = sysfs_create_group(&shost_dev->kobj, &sec_ufs_error_attribute_group);
	if (err)
		dev_err(hba->dev, "cannot create sec error sysfs group err: %d\n", err);
	else
		shost_group_ok = true;

	if (legacy_shost_un) {
		err = device_create_file(shost_dev, &dev_attr_unique_number);
		if (err)
			dev_err(hba->dev, "cannot create host unique_number: %d\n", err);
		else
			shost_un_ok = true;
	}
}

static int __init ufs_sec_sysfs_init(void)
{
	int ret;

	INIT_DELAYED_WORK(&ufs_sec_work, ufs_sec_work_fn);

	sec_ufs_cmd_dev = sec_device_create(NULL, "ufs");
	if (IS_ERR(sec_ufs_cmd_dev)) {
		pr_err("Fail to create sysfs dev\n");
	} else {
		ret = sysfs_create_group(&sec_ufs_cmd_dev->kobj,
				&sec_ufs_info_attribute_group);
		if (ret)
			pr_err("%s: Failed to create sec_ufs_info sysfs group (err = %d)\n",
			       __func__, ret);
		else
			sec_ufs_group_ok = true;
	}

	schedule_delayed_work(&ufs_sec_work, 0);
	return 0;	/* never fail: this module is in the first stage */
}

static void __exit ufs_sec_sysfs_exit(void)
{
	struct ufs_hba *hba;

	cancel_delayed_work_sync(&ufs_sec_work);

	hba = ufs_vdi.hba;
	if (hba) {
		if (shost_un_ok)
			device_remove_file(&hba->host->shost_dev, &dev_attr_unique_number);
		if (shost_group_ok)
			sysfs_remove_group(&hba->host->shost_dev.kobj,
					   &sec_ufs_error_attribute_group);
	}
	WRITE_ONCE(ufs_vdi.hba, NULL);

	if (!IS_ERR_OR_NULL(sec_ufs_cmd_dev)) {
		if (sec_ufs_group_ok)
			sysfs_remove_group(&sec_ufs_cmd_dev->kobj,
					   &sec_ufs_info_attribute_group);
		sec_device_destroy(sec_ufs_cmd_dev->devt);
	}
	if (ufs_pdev)
		put_device(ufs_pdev);
}

module_init(ufs_sec_sysfs_init);
module_exit(ufs_sec_sysfs_exit);

MODULE_DESCRIPTION("Samsung 5.4 UFS sysfs nodes (/sys/class/sec/ufs, scsi_host SEC_UFS_*) for 6.12");
MODULE_LICENSE("GPL");
