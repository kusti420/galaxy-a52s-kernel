// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq_sec_class: the /sys/class/sec devices of the Galaxy A52s 5.4 kernel
 * (A528BXXU5FWK4, 5.4.x-qgki) that the 6.12 GKI + soc-repo stack does not create:
 *
 *   hall_ic msm_dwc3 pcie-wifi sdcard sddata sdinfo sec_abc sec_abc_hub sec_misc
 *   sec_nad sec_sysup typec_manager
 *
 * Attribute names, modes and print formats are those of the 5.4 sources
 * ($ANDROID_TREE/kernel/samsung/sm7325). Show/store bodies are reproduced from:
 *   drivers/input/misc/hall/hall_ic.c              Copyright 2017 SEC
 *   drivers/mmc/host/sdhci-msm.c (SEC_STORAGE_MMC) Copyright (c) 2013-2021 The Linux
 *                                                  Foundation; Samsung Electronics additions
 *   drivers/pci/controller/pci-msm.c (SEC_PCIE_L1SS) The Linux Foundation; Samsung additions
 *   drivers/sti/abc/abc_common.c, abc_hub_core.c   Copyright (C) 2017 Samsung Electronics
 *   drivers/samsung/misc/sec_misc.c                COPYRIGHT(C) 2006-2019 Samsung Electronics
 *   drivers/samsung/quest/sec_quest.c              COPYRIGHT(C) 2006-2017 Samsung Electronics
 *   drivers/samsung/sec_sysup.c                    Copyright (c) 2019 Samsung Electronics
 *   drivers/usb/dwc3/dwc3-msm.c, drivers/usb/typec/manager/usb_typec_manager_notifier.c
 *                                                  (device creation only)
 * All of them GPL-2.0.
 *
 * REAL (6.12 data):  hall_ic (gpio-keys SW_LID input switch state, through an input
 *                    filter; under a52sxq.userspace=samsung it also re-reports the switch
 *                    as Samsung's flip code on a second "hall" input device), sdcard/sdinfo/sddata (mmc host + card of 8804000.sdhci,
 *                    looked up at read time: sdhci-msm loads after this module),
 *                    sec_misc/msm_feature_id (QFPROM JTAG id word, only inside the
 *                    qcom,qfprom region), sec_sysup/edtbo_version (androidboot.edtbo
 *                    from /chosen/bootargs), sec_abc/features (constant in 5.4 too).
 * STUB (marked below): the Samsung mmc error log / CD counter / tuning phase, pcie-wifi
 *                    (no PCIe Wi-Fi on the A52s), sec_abc/sec_abc_hub (stored values,
 *                    never a uevent), sec_nad (no param partition reader), sec_sysup
 *                    edtbo_update (no sec_param writer). msm_dwc3 and typec_manager have
 *                    no attributes on 5.4 either.
 *
 * Module init never fails and never blocks: every device and attribute is created
 * synchronously (so the OneUI "on boot" chown/chmod lines find them), data sources are
 * resolved at read time, a device that already exists in /sys/class/sec is skipped.
 */

#include <linux/bitops.h>
#include <linux/device.h>
#include <linux/input.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/mmc/card.h>
#include <linux/mmc/host.h>
#include <linux/mmc/slot-gpio.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <linux/a52sxq_userspace.h>

#include "../../../samsung612/modules/sec_core/include/linux/sec_class.h"

enum {
	SD_HALL_IC, SD_MSM_DWC3, SD_PCIE_WIFI, SD_SDCARD, SD_SDDATA, SD_SDINFO, SD_ABC,
	SD_ABC_HUB, SD_MISC, SD_NAD, SD_SYSUP, SD_TYPEC_MANAGER, SD_MAX
};

/* ================================================================== hall_ic */
/*
 * 5.4: Samsung hall_ic driver, one hall "hall" on gpio101 (active low), SW_LID, no
 * "hall_ic,debounce-interval" in the DT (=> 50). 6.12 (build-realboot HALL=1): gpio-keys
 * /soc/hall_keys, input "hall", SW_LID, debounce-interval 15. State 1 = magnet = CLOSE on
 * both kernels (5.4: gpio ^ active_low, reported as SW_LID; gpio-keys: active-low gpiod).
 */
#define HALL_DEFAULT_DEBOUNCE	50	/* 5.4 DEFAULT_DEBOUNCE_INTERVAL */

static DEFINE_MUTEX(hall_lock);		/* hall_handle, hall_debounce */
static struct input_handle *hall_handle;
static bool hall_ready;			/* skip the state report of input_open_device() */
static int hall_debounce = HALL_DEFAULT_DEBOUNCE;
static DEFINE_SPINLOCK(hall_cnt_lock);
static int hall_count;
static int hall_uevent_state;
static struct device *sec_devs[SD_MAX];
static bool sec_dev_own[SD_MAX];

/*
 * Flip cover code per userspace (a52sxq.ko switch, SPEC/05 P1-4).
 *   aosp (and no a52sxq.ko): nothing changes, the gpio-keys "hall" reports SW_LID.
 *   samsung: a second input device "hall" reports the Samsung flip code and the SW_LID events of
 *   the gpio-keys device are filtered away from evdev. Stock 5.4 (hall_ic.c:59,
 *   a52sxq DT "event = <0x15>") reports 0x15; Samsung's own hall_ic for kernels >= 5.10 remaps
 *   0x15 -> 0x10 (hall_ic.c:54-57,644-645) and GKI 6.12 has SW_MAX 0x10, so 0x10 is the only
 *   Samsung code a 6.12 input device can carry. State 1 = magnet = cover closed, as SW_LID.
 */
static unsigned int flip_code = 0x10;
module_param(flip_code, uint, 0444);
MODULE_PARM_DESC(flip_code, "EV_SW code of the flip cover switch under a52sxq.userspace=samsung (default 0x10; 0 = keep SW_LID)");

static DEFINE_MUTEX(hall_flip_lock);	/* hall_flip; taken before hall_lock, never inside it */
static struct input_dev *hall_flip;
static bool hall_flip_on;		/* SW_LID is being replaced by the flip code */
static bool hall_exiting;

static void hall_flip_sync(void)
{
	bool samsung = a52sxq_userspace_is_samsung();
	struct input_dev *in;
	bool have_hall;
	int state;

	mutex_lock(&hall_flip_lock);
	mutex_lock(&hall_lock);
	have_hall = hall_handle != NULL;
	state = have_hall ? test_bit(SW_LID, hall_handle->dev->sw) : 0;
	mutex_unlock(&hall_lock);

	if (samsung && have_hall && !hall_flip && !READ_ONCE(hall_exiting) &&
	    flip_code && flip_code <= SW_MAX) {
		in = input_allocate_device();
		if (in) {
			in->name = "hall";	/* 5.4 hall_ic input name */
			in->phys = "a52sxq_sec_class/flip";
			in->id.bustype = BUS_HOST;
			input_set_capability(in, EV_SW, flip_code);
			if (input_register_device(in)) {
				input_free_device(in);
			} else {
				hall_flip = in;
				pr_info("a52sxq_hall: flip switch 0x%02x registered (userspace samsung)\n",
					flip_code);
			}
		}
	}
	if (hall_flip) {
		/* leaving samsung: the flip switch reads open, SW_LID events pass again */
		input_report_switch(hall_flip, flip_code, samsung && state);
		input_sync(hall_flip);
	}
	WRITE_ONCE(hall_flip_on, samsung && hall_flip);
	mutex_unlock(&hall_flip_lock);
}

static void hall_flip_fn(struct work_struct *work)
{
	hall_flip_sync();
}
static DECLARE_WORK(hall_flip_work, hall_flip_fn);

/* late, soft binding to the switch: no depends entry, works without a52sxq.ko */
static int hall_us_event(struct notifier_block *nb, unsigned long us, void *data)
{
	schedule_work(&hall_flip_work);
	return NOTIFY_DONE;
}
static struct notifier_block hall_us_nb = { .notifier_call = hall_us_event };
static int (*hall_us_unreg)(struct notifier_block *nb);
static int hall_us_tries;
static void hall_us_bind_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(hall_us_bind_work, hall_us_bind_fn);

static void hall_us_bind_fn(struct work_struct *work)
{
	int (*reg)(struct notifier_block *nb) = symbol_get(a52sxq_userspace_register_notifier);
	int (*unreg)(struct notifier_block *nb) = symbol_get(a52sxq_userspace_unregister_notifier);

	if (reg && unreg && !reg(&hall_us_nb)) {
		hall_us_unreg = unreg;
		symbol_put(a52sxq_userspace_register_notifier);
		pr_info("a52sxq_hall: bound to the userspace switch (try %d)\n", hall_us_tries);
		hall_flip_sync();
		return;
	}
	if (reg)
		symbol_put(a52sxq_userspace_register_notifier);
	if (unreg)
		symbol_put(a52sxq_userspace_unregister_notifier);
	if (++hall_us_tries < 45 && !READ_ONCE(hall_exiting))
		schedule_delayed_work(&hall_us_bind_work, 2 * HZ);
}

static void hall_uevent_fn(struct work_struct *work)
{
	char env[20];
	char *envp[2] = { env, NULL };
	struct device *dev = sec_devs[SD_HALL_IC];

	if (!dev)
		return;
	/* 5.4 hall_ic_work(): "<name>=close|open" on the sec device */
	snprintf(env, sizeof(env), "%s=%s", "hall",
		 READ_ONCE(hall_uevent_state) ? "close" : "open");
	kobject_uevent_env(&dev->kobj, KOBJ_CHANGE, envp);
	hall_flip_sync();
}
static DECLARE_WORK(hall_uevent_work, hall_uevent_fn);

/*
 * An input filter instead of an event handler: same bookkeeping, and under samsung (once the
 * flip device exists) the SW_LID event is kept away from evdev; the flip code goes out from
 * the work instead. Returns false in every other case = the event passes as before.
 */
static bool hall_event(struct input_handle *handle, unsigned int type,
		       unsigned int code, int value)
{
	if (type != EV_SW || code != SW_LID || !READ_ONCE(hall_ready))
		return false;
	spin_lock(&hall_cnt_lock);
	hall_count++;
	spin_unlock(&hall_cnt_lock);
	WRITE_ONCE(hall_uevent_state, !!value);
	schedule_work(&hall_uevent_work);
	return READ_ONCE(hall_flip_on) && a52sxq_userspace_is_samsung();
}

static int hall_dt_debounce(struct input_dev *dev)
{
	struct device_node *np = dev->dev.parent ? dev->dev.parent->of_node : NULL;
	struct device_node *child;
	u32 code, type, ms;

	if (!np)
		return HALL_DEFAULT_DEBOUNCE;
	for_each_child_of_node(np, child) {
		if (of_property_read_u32(child, "linux,code", &code) || code != SW_LID)
			continue;
		if (of_property_read_u32(child, "linux,input-type", &type) || type != EV_SW)
			continue;
		if (of_property_read_u32(child, "debounce-interval", &ms))
			ms = 5;	/* gpio-keys default */
		of_node_put(child);
		return ms;
	}
	return HALL_DEFAULT_DEBOUNCE;
}

static int hall_connect(struct input_handler *handler, struct input_dev *dev,
			const struct input_device_id *id)
{
	struct input_handle *handle;
	int ret;

	mutex_lock(&hall_lock);
	/* one hall; prefer the device named "hall" (5.4 name, 6.12 HALL=1 label) */
	if (hall_handle && (!dev->name || strcmp(dev->name, "hall") ||
			    !strcmp(hall_handle->dev->name ?: "", "hall"))) {
		mutex_unlock(&hall_lock);
		return -ENODEV;
	}
	mutex_unlock(&hall_lock);

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;
	handle->dev = dev;
	handle->handler = handler;
	handle->name = "a52sxq_sec_hall";

	ret = input_register_handle(handle);
	if (ret)
		goto err_free;
	ret = input_open_device(handle);
	if (ret)
		goto err_unreg;

	mutex_lock(&hall_lock);
	if (hall_handle) {	/* replace a non-"hall" SW_LID device */
		struct input_handle *old = hall_handle;

		hall_handle = NULL;
		mutex_unlock(&hall_lock);
		input_close_device(old);
		input_unregister_handle(old);
		kfree(old);
		mutex_lock(&hall_lock);
	}
	hall_handle = handle;
	hall_debounce = hall_dt_debounce(dev);
	WRITE_ONCE(hall_ready, true);
	mutex_unlock(&hall_lock);
	schedule_work(&hall_flip_work);
	return 0;

err_unreg:
	input_unregister_handle(handle);
err_free:
	kfree(handle);
	return ret;
}

static void hall_disconnect(struct input_handle *handle)
{
	mutex_lock(&hall_lock);
	if (hall_handle == handle) {
		hall_handle = NULL;
		WRITE_ONCE(hall_ready, false);
		hall_debounce = HALL_DEFAULT_DEBOUNCE;
	}
	mutex_unlock(&hall_lock);
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
	if (!READ_ONCE(hall_exiting))
		schedule_work(&hall_flip_work);
}

static const struct input_device_id hall_ids[] = {
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_SWBIT,
		.evbit = { BIT_MASK(EV_SW) },
		.swbit = { [BIT_WORD(SW_LID)] = BIT_MASK(SW_LID) },
	},
	{ },
};

static struct input_handler hall_handler = {
	.filter		= hall_event,
	.connect	= hall_connect,
	.disconnect	= hall_disconnect,
	.name		= "a52sxq_sec_hall",
	.id_table	= hall_ids,
};
static bool hall_handler_registered;

/* 5.4 hall_detect_show(): "CLOSE\n" / "OPEN\n". No hall input: "OPEN\n" (nothing closed). */
static ssize_t hall_detect_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int state = 0;

	mutex_lock(&hall_lock);
	if (hall_handle)
		state = test_bit(SW_LID, hall_handle->dev->sw);
	mutex_unlock(&hall_lock);
	return sysfs_emit(buf, state ? "CLOSE\n" : "OPEN\n");
}
static DEVICE_ATTR_RO(hall_detect);

/* 5.4: pdata->nhalls (1 on the A52s). Here: halls found (1 with HALL=1, else 0). */
static ssize_t hall_number_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	unsigned int n;

	mutex_lock(&hall_lock);
	n = hall_handle ? 1 : 0;
	mutex_unlock(&hall_lock);
	return sysfs_emit(buf, "%u\n", n);
}
static DEVICE_ATTR_RO(hall_number);

/* 5.4: hall_ic debounce (50). Here: the gpio-keys debounce-interval of the SW_LID key. */
static ssize_t debounce_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ms;

	mutex_lock(&hall_lock);
	ms = hall_debounce;
	mutex_unlock(&hall_lock);
	return sysfs_emit(buf, "%d\n", ms);
}
static DEVICE_ATTR_RO(debounce);

/* 5.4 hall_count_show(): "\"FCNT\":\"%d\"" (no newline), counter cleared by the read */
static ssize_t hall_count_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int n;

	spin_lock_irq(&hall_cnt_lock);
	n = hall_count;
	hall_count = 0;
	spin_unlock_irq(&hall_cnt_lock);
	return sysfs_emit(buf, "\"FCNT\":\"%d\"", n);
}
static DEVICE_ATTR_RO(hall_count);

static struct attribute *hall_ic_attrs[] = {
	&dev_attr_hall_detect.attr,
	&dev_attr_hall_number.attr,
	&dev_attr_debounce.attr,
	&dev_attr_hall_count.attr,
	NULL,
};
ATTRIBUTE_GROUPS(hall_ic);

/* ========================================================= sdcard / sdinfo / sddata */
#define SD_HOST_DEV	"8804000.sdhci"	/* 5.4: host->hw_name == "8804000.sdhci" */

static int sd_match_host(struct device *dev, void *data)
{
	return dev->class && !strcmp(dev->class->name, "mmc_host");
}

static int sd_match_card(struct device *dev, void *data)
{
	return dev->bus && !strcmp(dev->bus->name, "mmc");
}

/*
 * The SD slot's mmc_host (reference held on its class device) or NULL when sdhci-msm has
 * not probed 8804000.sdhci (yet). *cardp: the card (reference held on card->dev) or NULL.
 * 5.4 read host->card unlocked; the device references here keep both structs alive.
 */
static struct mmc_host *sd_get(struct mmc_card **cardp)
{
	struct device *pdev, *hdev, *cdev;
	struct mmc_host *host;

	*cardp = NULL;
	pdev = bus_find_device_by_name(&platform_bus_type, NULL, SD_HOST_DEV);
	if (!pdev)
		return NULL;
	hdev = device_find_child(pdev, NULL, sd_match_host);
	put_device(pdev);
	if (!hdev)
		return NULL;
	host = container_of(hdev, struct mmc_host, class_dev);
	cdev = device_find_child(hdev, NULL, sd_match_card);
	if (cdev)
		*cardp = container_of(cdev, struct mmc_card, dev);
	return host;
}

static void sd_put(struct mmc_host *host, struct mmc_card *card)
{
	if (card)
		put_device(&card->dev);
	if (host)
		put_device(&host->class_dev);
}

static const char *const sd_uhs_speeds[] = {
	[UHS_SDR12_BUS_SPEED]	= "SDR12",
	[UHS_SDR25_BUS_SPEED]	= "SDR25",
	[UHS_SDR50_BUS_SPEED]	= "SDR50",
	[UHS_SDR104_BUS_SPEED]	= "SDR104",
	[UHS_DDR50_BUS_SPEED]	= "DDR50",
};

static const char *sd_uhs_name(struct mmc_card *card)
{
	if (card->sd_bus_speed < ARRAY_SIZE(sd_uhs_speeds) && sd_uhs_speeds[card->sd_bus_speed])
		return sd_uhs_speeds[card->sd_bus_speed];
	return "";
}

/* 5.4 t_flash_detect_show() */
static ssize_t status_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	const char *s = "Remove\n";

	if (host && !mmc_gpio_get_cd(host))
		s = "Notray\n";
	else if (card)
		s = "Insert\n";
	sd_put(host, card);
	return sysfs_emit(buf, "%s", s);
}
static DEVICE_ATTR_RO(status);

/* STUB: 5.4 mmc_host->card_detect_cnt (Samsung slot-gpio CD irq counter) has no 6.12 source */
static ssize_t cd_cnt_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", 0U);
}
static DEVICE_ATTR_RO(cd_cnt);

/* 5.4 sd_detect_maxmode_show() */
static ssize_t max_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	u32 caps = host ? host->caps : 0;
	const char *m;

	sd_put(host, card);
	if (caps & MMC_CAP_UHS_SDR104)
		m = "SDR104";
	else if (caps & MMC_CAP_UHS_DDR50)
		m = "DDR50";
	else if (caps & MMC_CAP_UHS_SDR50)
		m = "SDR50";
	else if (caps & MMC_CAP_UHS_SDR25)
		m = "SDR25";
	else if (caps & MMC_CAP_UHS_SDR12)
		m = "SDR12";
	else
		m = "HS";
	return sysfs_emit(buf, "%s\n", m);
}
static DEVICE_ATTR_RO(max_mode);

/* 5.4 sd_detect_curmode_show() */
static ssize_t current_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	const char *m;

	if (card)
		m = mmc_card_uhs(card) ? sd_uhs_name(card) : "HS";
	else
		m = "No Card";
	sd_put(host, card);
	return sysfs_emit(buf, "%s\n", m);
}
static DEVICE_ATTR_RO(current_mode);

/*
 * 5.4 sd_detect_curphase_show(): the saved SDR104 tuning phase, else -1.
 * STUB for SDR104: the phase lives in the soc-repo sdhci-msm private host struct -> -1.
 */
static ssize_t current_phase_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", -1);
}
static DEVICE_ATTR_RO(current_phase);

/* 5.4 sdcard_summary_show(); NOTI = Samsung err_log noti_cnt -> STUB 0 */
static ssize_t sdcard_summary_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	static const char *const unit[] = {"KB", "MB", "GB", "TB"};
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	const char *mode;
	unsigned int size, serial, manfid;
	int digit = 1;
	char ret_size[16];

	if (!card) {
		sd_put(host, card);
		return sysfs_emit(buf, "\"MANID\":\"NoCard\",\"SERIAL\":\"NoCard\""
				  ",\"SIZE\":\"NoCard\",\"SPEEDMODE\":\"NoCard\",\"NOTI\":\"NoCard\"\n");
	}

	serial = card->cid.serial & (0x0000FFFF);
	manfid = card->cid.manfid;
	if (card->csd.read_blkbits == 9)		/* 1 Sector = 512 Bytes */
		size = (card->csd.capacity) >> 1;
	else if (card->csd.read_blkbits == 11)		/* 1 Sector = 2048 Bytes */
		size = (card->csd.capacity) << 1;
	else						/* 1 Sector = 1024 Bytes */
		size = card->csd.capacity;

	if (size >= 380000000 && size <= 410000000) {		/* QUIRK 400GB SD Card */
		snprintf(ret_size, sizeof(ret_size), "400GB");
	} else if (size >= 190000000 && size <= 210000000) {	/* QUIRK 200GB SD Card */
		snprintf(ret_size, sizeof(ret_size), "200GB");
	} else {
		while ((size >> 1) > 0) {
			size = size >> 1;
			digit++;
		}
		snprintf(ret_size, sizeof(ret_size), "%d%s", 1 << (digit % 10),
			 unit[min(digit / 10, 3)]);
	}

	if (mmc_card_uhs(card))
		mode = sd_uhs_name(card);
	else if (mmc_card_hs(card))
		mode = "HS";
	else
		mode = "DS";
	sd_put(host, card);

	return sysfs_emit(buf, "\"MANID\":\"0x%02X\",\"SERIAL\":\"%04X\""
			  ",\"SIZE\":\"%s\",\"SPEEDMODE\":\"%s\",\"NOTI\":\"%d\"\n",
			  manfid, serial, ret_size, mode, 0);
}
static DEVICE_ATTR_RO(sdcard_summary);

static struct attribute *sdcard_attrs[] = {
	&dev_attr_status.attr,
	&dev_attr_cd_cnt.attr,
	&dev_attr_max_mode.attr,
	&dev_attr_current_mode.attr,
	&dev_attr_current_phase.attr,
	&dev_attr_sdcard_summary.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sdcard);

/* 5.4 sd_count_show(): sum of the Samsung mmc err_log counts. STUB: 0 with a card. */
static ssize_t sd_count_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	bool have = card;

	sd_put(host, card);
	if (!have)
		return sysfs_emit(buf, "no card\n");
	return sysfs_emit(buf, "%lld\n", 0LL);
}
static DEVICE_ATTR_RO(sd_count);

/* 5.4 sd_cid_show(): raw CID (REAL) */
static ssize_t data_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	ssize_t len;

	if (!card)
		len = sysfs_emit(buf, "no card\n");
	else
		len = sysfs_emit(buf, "%08x%08x%08x%08x\n", card->raw_cid[0],
				 card->raw_cid[1], card->raw_cid[2], card->raw_cid[3]);
	sd_put(host, card);
	return len;
}
static DEVICE_ATTR_RO(data);

/* 5.4 sd_health_show(): "NOCARD" / "GOOD" / "BAD". STUB: no err_log -> always GOOD. */
static ssize_t fc_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mmc_card *card;
	struct mmc_host *host = sd_get(&card);
	bool have = card;

	sd_put(host, card);
	/* There should be no spaces in 'No Card'(Vold Team). */
	return sysfs_emit(buf, have ? "GOOD\n" : "NOCARD\n");
}
static DEVICE_ATTR_RO(fc);

static struct attribute *sdinfo_attrs[] = {
	&dev_attr_sd_count.attr,
	&dev_attr_data.attr,
	&dev_attr_fc.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sdinfo);

/* 5.4 sd_data_show(); STUB: no Samsung err_log -> all counters 0 (= 5.4 with no errors) */
static ssize_t sd_data_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "\"GE\":\"0\",\"CC\":\"0\",\"ECC\":\"0\",\"WP\":\"0\","
			  "\"OOR\":\"0\",\"CRC\":\"0\",\"TMO\":\"0\"\n");
}
static DEVICE_ATTR_RO(sd_data);

static struct attribute *sddata_attrs[] = {
	&dev_attr_sd_data.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sddata);

/* ================================================================ pcie-wifi */
/*
 * STUB. 5.4 sec_show_l1ss_stat() dumps the RC0 link / L1ss registers of a PCIe Wi-Fi.
 * The A52s Wi-Fi is WCN6750 on icnss2 (no PCIe EP, no RC0 link), so 5.4 took the
 * "link is not enabled" branch; writes went to sec_pcie_l1ss_{enable,disable}() and were
 * accepted (the return value is always count). OneUI writer: hyper (config_chipset.json
 * BoostPath).
 */
static ssize_t pcie_l1ss_ctrl_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "RC%d link is not enabled.\n", 0);
}

static ssize_t pcie_l1ss_ctrl_store(struct device *dev, struct device_attribute *attr,
				    const char *buf, size_t count)
{
	unsigned int enable;

	if (kstrtouint(buf, 0, &enable))
		return count;	/* 5.4: "Fail get enable", still count */
	return count;
}
static DEVICE_ATTR(pcie_l1ss_ctrl, 0664, pcie_l1ss_ctrl_show, pcie_l1ss_ctrl_store);	/* 5.4: 0664 */

static struct attribute *pcie_wifi_attrs[] = {
	&dev_attr_pcie_l1ss_ctrl.attr,
	NULL,
};
ATTRIBUTE_GROUPS(pcie_wifi);

/* ================================================================== sec_abc */
/*
 * STUB telemetry. 5.4 ABC (Abnormal Behavior Catcher) sends KOBJ_CHANGE uevents
 * (MODULE=, WARN=/INFO=, TIMESTAMP=, HOST=, EXT_LOG=) on /devices/virtual/sec/sec_abc
 * that SamsungDeviceHealthManagerService listens for; this stub never sends one and
 * exports no sec_abc_send_event(). The enable-mode bits are tracked exactly as 5.4.
 */
#define ERROR_REPORT_MODE_BIT	(1 << 0)
#define ALL_REPORT_MODE_BIT	(1 << 1)
#define PRE_EVENT_ENABLE_BIT	(1 << 7)
#define ABC_CMD_MAX		8
#define ABC_CMD_STR_MAX		16

static DEFINE_MUTEX(abc_lock);
static int abc_enable_mode = PRE_EVENT_ENABLE_BIT;	/* 5.4 probe: |= PRE_EVENT_ENABLE_BIT */

static const struct { int bit; const char *str; } abc_cmds[] = {
	{ ERROR_REPORT_MODE_BIT, "ERROR_REPORT=1" }, { ERROR_REPORT_MODE_BIT, "ERROR_REPORT=0" },
	{ ALL_REPORT_MODE_BIT, "ALL_REPORT=1" },     { ALL_REPORT_MODE_BIT, "ALL_REPORT=0" },
	{ PRE_EVENT_ENABLE_BIT, "PRE_EVENT=1" },     { PRE_EVENT_ENABLE_BIT, "PRE_EVENT=0" },
};

/* 5.4 enabled_store(): "1" / "0" (ACT) or "ERROR_REPORT=1,PRE_EVENT=0,..." (LABO) */
static ssize_t enabled_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	char temp[ABC_CMD_STR_MAX * 3], *p, *c, *cmd[ABC_CMD_MAX];
	int idx = 0, i, j, mode;
	bool chk;

	mutex_lock(&abc_lock);
	if (!strncmp(buf, "1", 1)) {
		abc_enable_mode |= ERROR_REPORT_MODE_BIT;
	} else if (!strncmp(buf, "0", 1)) {
		abc_enable_mode &= ~ERROR_REPORT_MODE_BIT;
	} else {
		mode = abc_enable_mode;
		strscpy(temp, buf, sizeof(temp));
		p = temp;
		while ((c = strsep(&p, ",")) != NULL && idx < ABC_CMD_MAX)
			cmd[idx++] = c;
		for (i = 0; i < idx; i++) {
			chk = false;
			for (j = 0; j < ARRAY_SIZE(abc_cmds); j++) {
				if (strncmp(cmd[i], abc_cmds[j].str, strlen(abc_cmds[j].str)))
					continue;
				if (strstr(abc_cmds[j].str, "=1"))
					mode |= abc_cmds[j].bit;
				else
					mode &= ~abc_cmds[j].bit;
				chk = true;
			}
			if (!chk)	/* 5.4: invalid string -> unchanged, still count */
				goto out;
		}
		abc_enable_mode = mode;
	}
out:
	mutex_unlock(&abc_lock);
	return count;
}

static ssize_t enabled_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int on;

	mutex_lock(&abc_lock);
	on = abc_enable_mode & (ERROR_REPORT_MODE_BIT | ALL_REPORT_MODE_BIT);
	mutex_unlock(&abc_lock);
	return sysfs_emit(buf, on ? "1\n" : "0\n");
}
static DEVICE_ATTR_RW(enabled);

/* STUB: 5.4 sec_abc_read_spec() header line only (no spec list: no ABC event sources) */
static ssize_t spec_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "spec type1\n");
}

static ssize_t spec_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	return count;
}
static DEVICE_ATTR_RW(spec);

/* 5.4 features_show()/features_store(): constant / ignored (REAL) */
static ssize_t features_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "spec_control\nhost\n");
}

static ssize_t features_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	return count;
}
static DEVICE_ATTR_RW(features);

static struct attribute *sec_abc_attrs[] = {
	&dev_attr_enabled.attr,
	&dev_attr_spec.attr,
	&dev_attr_features.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sec_abc);

/* ============================================================== sec_abc_hub */
/*
 * STUB telemetry (stored values). 5.4 abc_hub bootc compares bootc_time (written by
 * bootchecker) + bootc_offset (vold/fs_mgr "fsck,<secs>") against a boot-time limit and
 * raises an ABC event; nothing is evaluated here.
 */
#define BOOTC_OFFSET_STR_MAX	100

static int abc_hub_enabled;		/* ABC_HUB_DISABLED */
static int bootc_offset;		/* module "fsck" (BOOTC_OFFSET_DATA_CNT 1) */
static int bootc_time = -1;

static ssize_t enable_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	mutex_lock(&abc_lock);
	if (!strncmp(buf, "1", 1))
		abc_hub_enabled = 1;
	else if (!strncmp(buf, "0", 1))
		abc_hub_enabled = 0;
	mutex_unlock(&abc_lock);
	return count;
}

static ssize_t enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(abc_hub_enabled));
}
static DEVICE_ATTR_RW(enable);

/* 5.4 bootc_offset_store(): "<module>,<offset>", only module "fsck", offset >= 0 */
static ssize_t bootc_offset_store(struct device *dev, struct device_attribute *attr,
				  const char *buf, size_t count)
{
	char module[BOOTC_OFFSET_STR_MAX] = { 0, };
	const char *cur;
	int offset = 0;

	if (count >= BOOTC_OFFSET_STR_MAX || strnlen(buf, count) >= BOOTC_OFFSET_STR_MAX)
		return count;
	cur = strnchr(buf, count, ',');
	if (!cur)
		return count;
	memcpy(module, buf, cur - buf);
	if (kstrtoint(cur + 1, 0, &offset))
		return count;
	if (offset >= 0 && !strcmp(module, "fsck")) {
		mutex_lock(&abc_lock);
		bootc_offset = offset;
		mutex_unlock(&abc_lock);
	}
	return count;
}

static ssize_t bootc_offset_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s,%d\n", "fsck", READ_ONCE(bootc_offset));
}
static DEVICE_ATTR_RW(bootc_offset);

static ssize_t bootc_time_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	int t;

	if (kstrtoint(buf, 0, &t))
		t = -1;	/* 5.4: "failed to get bootc_time" -> -1 */
	WRITE_ONCE(bootc_time, t);
	return count;
}

static ssize_t bootc_time_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(bootc_time));
}
static DEVICE_ATTR_RW(bootc_time);

static struct attribute *sec_abc_hub_attrs[] = {
	&dev_attr_enable.attr,
	&dev_attr_bootc_offset.attr,
	&dev_attr_bootc_time.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sec_abc_hub);

/* ================================================================= sec_misc */
/*
 * 5.4 msm_feature_id_show(): bits 20..27 of the QFPROM JTAG id word at "qfprom_jtag,reg"
 * of the "samsung,sec_misc" node (A52s: 0x784180; 5.4 code default 0x784130). Read once,
 * at the first read, and only when the word lies inside the reg of a "qcom,qfprom" node
 * (the region the 6.12 qfprom nvmem driver maps; 0x784180 is also its tsens_chipinfo cell).
 */
#define QFPROM_JTAG_A52S	0x784180

union qfprom_jtag_reg {
	u32 raw;
	struct {
		u32 jtag_id:20;
		u32 feature_id:8;
		u32 reserved_0:4;
	};
};

static DEFINE_MUTEX(misc_lock);
static union qfprom_jtag_reg qfprom_jtag;

static bool qfprom_covers(phys_addr_t pa)
{
	struct device_node *np;
	struct resource res;
	bool ok = false;

	for_each_compatible_node(np, NULL, "qcom,qfprom") {
		if (!of_device_is_available(np) || of_address_to_resource(np, 0, &res))
			continue;
		if (pa >= res.start && pa + sizeof(u32) - 1 <= res.end) {
			ok = true;
			of_node_put(np);
			break;
		}
	}
	return ok;
}

static ssize_t msm_feature_id_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct device_node *np;
	u32 pa = QFPROM_JTAG_A52S, dt;
	void __iomem *va;
	union qfprom_jtag_reg r;

	mutex_lock(&misc_lock);
	if (!qfprom_jtag.raw) {
		np = of_find_node_by_name(NULL, "samsung,sec_misc");
		if (np) {
			if (!of_property_read_u32(np, "qfprom_jtag,reg", &dt))
				pa = dt;
			of_node_put(np);
		}
		va = qfprom_covers(pa) ? ioremap(pa, sizeof(u32)) : NULL;
		if (!va) {
			mutex_unlock(&misc_lock);
			return sysfs_emit(buf, "could not map FEATURE_ID address\n");
		}
		qfprom_jtag.raw = readl_relaxed(va);
		iounmap(va);
	}
	r = qfprom_jtag;
	mutex_unlock(&misc_lock);

	if (!r.raw)
		return sysfs_emit(buf, "Feature ID is not supported!!\n");
	return sysfs_emit(buf, "%02u\n", r.feature_id);
}
static DEVICE_ATTR_RO(msm_feature_id);

static struct attribute *sec_misc_attrs[] = {
	&dev_attr_msm_feature_id.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sec_misc);

/* ================================================================== sec_nad */
/* STUB: 5.4 reads param_quest_data.quest_fv_flashed from the param partition; 0 = none */
static ssize_t quest_fv_flashed_show(struct device *dev, struct device_attribute *attr,
				     char *buf)
{
	return sysfs_emit(buf, "%d\n", 0);
}
static DEVICE_ATTR_RO(quest_fv_flashed);

static struct attribute *sec_nad_attrs[] = {
	&dev_attr_quest_fv_flashed.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sec_nad);

/* ================================================================ sec_sysup */
static unsigned long edtbo_ver;		/* 5.4: early_param("androidboot.edtbo") */

static void sysup_parse_bootargs(void)
{
	const char *args = NULL, *p;
	char num[24];
	size_t n;

	if (!of_chosen || of_property_read_string(of_chosen, "bootargs", &args) || !args)
		return;
	for (p = strstr(args, "androidboot.edtbo="); p; p = strstr(p + 1, "androidboot.edtbo=")) {
		if (p != args && p[-1] != ' ')
			continue;
		p += strlen("androidboot.edtbo=");
		n = strcspn(p, " ");
		n = min(n, sizeof(num) - 1);
		memcpy(num, p, n);
		num[n] = '\0';
		/* 5.4 simple_strtoul(): leading digits, garbage -> 0 */
		edtbo_ver = 0;
		for (n = 0; num[n] >= '0' && num[n] <= '9'; n++)
			edtbo_ver = edtbo_ver * 10 + (num[n] - '0');
		return;
	}
}

/*
 * STUB. 5.4 sec_edtbo_update_store(): "1" -> fiemap of /spu/edtbo/edtbo.img into the
 * sec_param partition for the bootloader. No sec_param writer on 6.12: "1" is refused
 * with -EOPNOTSUPP (anything else -EINVAL as 5.4).
 */
static ssize_t edtbo_update_store(struct device *dev, struct device_attribute *attr,
				  const char *buf, size_t size)
{
	int update;

	if (sscanf(buf, "%d", &update) != 1 || update != 1)
		return -EINVAL;
	return -EOPNOTSUPP;
}

static ssize_t edtbo_version_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%lu\n", edtbo_ver);
}

static struct device_attribute dev_attr_edtbo_update = __ATTR(edtbo_update, 0220, NULL,
							      edtbo_update_store);
static struct device_attribute dev_attr_edtbo_version = __ATTR(edtbo_version, 0440,
							       edtbo_version_show, NULL);

static struct attribute *sec_sysup_attrs[] = {
	&dev_attr_edtbo_update.attr,
	&dev_attr_edtbo_version.attr,
	NULL,
};
ATTRIBUTE_GROUPS(sec_sysup);

/* ================================================================== devices */
static const struct {
	const char *name;
	const struct attribute_group **groups;
} sec_tab[SD_MAX] = {
	[SD_HALL_IC]		= { "hall_ic", hall_ic_groups },
	[SD_MSM_DWC3]		= { "msm_dwc3", NULL },		/* 5.4: no attributes */
	[SD_PCIE_WIFI]		= { "pcie-wifi", pcie_wifi_groups },
	[SD_SDCARD]		= { "sdcard", sdcard_groups },
	[SD_SDDATA]		= { "sddata", sddata_groups },
	[SD_SDINFO]		= { "sdinfo", sdinfo_groups },
	[SD_ABC]		= { "sec_abc", sec_abc_groups },
	[SD_ABC_HUB]		= { "sec_abc_hub", sec_abc_hub_groups },
	[SD_MISC]		= { "sec_misc", sec_misc_groups },
	[SD_NAD]		= { "sec_nad", sec_nad_groups },
	[SD_SYSUP]		= { "sec_sysup", sec_sysup_groups },
	[SD_TYPEC_MANAGER]	= { "typec_manager", NULL },	/* 5.4 non-factory: none */
};

static void sec_class_remove(void)
{
	int i;

	for (i = SD_MAX - 1; i >= 0; i--) {
		if (!sec_devs[i] || !sec_dev_own[i])
			continue;
		if (sec_tab[i].groups)
			sysfs_remove_groups(&sec_devs[i]->kobj, sec_tab[i].groups);
		sec_device_destroy(sec_devs[i]->devt);
		sec_devs[i] = NULL;
	}
}

static int __init a52sxq_sec_class_init(void)
{
	struct device *d;
	int i;

	sysup_parse_bootargs();

	for (i = 0; i < SD_MAX; i++) {
		d = sec_dev_get_by_name(sec_tab[i].name);
		if (d) {		/* created by another driver: leave it alone */
			put_device(d);
			continue;
		}
		d = sec_device_create(NULL, sec_tab[i].name);
		if (IS_ERR_OR_NULL(d))
			continue;
		if (sec_tab[i].groups && sysfs_create_groups(&d->kobj, sec_tab[i].groups)) {
			sec_device_destroy(d->devt);
			continue;
		}
		sec_devs[i] = d;
		sec_dev_own[i] = true;
	}

	if (sec_devs[SD_HALL_IC] && !input_register_handler(&hall_handler)) {
		hall_handler_registered = true;
		schedule_delayed_work(&hall_us_bind_work, 0);
	}
	return 0;
}

static void __exit a52sxq_sec_class_exit(void)
{
	WRITE_ONCE(hall_exiting, true);
	cancel_delayed_work_sync(&hall_us_bind_work);
	if (hall_us_unreg) {
		hall_us_unreg(&hall_us_nb);
		symbol_put(a52sxq_userspace_unregister_notifier);
	}
	if (hall_handler_registered)
		input_unregister_handler(&hall_handler);
	cancel_work_sync(&hall_uevent_work);
	cancel_work_sync(&hall_flip_work);
	if (hall_flip)
		input_unregister_device(hall_flip);
	sec_class_remove();
}

module_init(a52sxq_sec_class_init);
module_exit(a52sxq_sec_class_exit);

MODULE_DESCRIPTION("Galaxy A52s 5.4 /sys/class/sec devices (hall_ic, sd*, sec_abc*, ...) on 6.12");
MODULE_AUTHOR("Samsung Electronics (5.4 drivers); a52sxq-mainline port");
MODULE_LICENSE("GPL");
