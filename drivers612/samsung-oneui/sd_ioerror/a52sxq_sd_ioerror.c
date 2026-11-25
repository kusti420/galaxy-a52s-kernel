// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq_sd_ioerror: the Samsung "SD card IO error" uevent of the 5.4 kernel on 6.12.
 *
 * 5.4 (A528BXXU5FWK4): drivers/mmc/core/block.c mmc_card_error_logging() counts the card
 * status error bits of failed block requests in card->err_log[] and, for an SD card, calls
 * host->sdcard_uevent() at every 1000th GE / ECC and every 100th WP / OOR error;
 * drivers/mmc/host/sdhci-msm.c sdcard_uevent() then sends KOBJ_CHANGE on the
 * /sys/class/sec/sdcard device, whose device type adds
 *     DEVNAME=sdcard
 *     IOERROR=YES | NO | NoCard
 * (both Copyright (c) The Linux Foundation / Samsung Electronics, GPL-2.0).
 *
 * 6.12 has no such hook: mmc core + block are built into the GKI Image and sdhci-msm is the
 * upstream driver. This module gets the same information from the mmc_request_done
 * tracepoint (built-in, found with for_each_kernel_tracepoint()): the R1 card status of the
 * block commands (CMD12/13/17/18/24/25) of the SD slot's host (8804000.sdhci) and their
 * cmd/data/stop results, counts them like 5.4 and sends the same uevent on the sec/sdcard
 * device (created by a52sxq_sec_class; looked up by name when the uevent is sent).
 *
 * Difference from 5.4: 5.4 ORed status + stop + cmd response once per failed block request;
 * here every completed request is looked at on its own (a sticky bit seen in two responses
 * of one transfer counts twice). Counters restart when the card struct changes.
 *
 * Read-only views (root): /sys/module/a52sxq_sd_ioerror/parameters/
 *     sd_data   5.4 /sys/class/sec/sddata/sd_data format ("GE":"0",...,"TMO":"0")
 *     noti      uevents sent for the current card (5.4 sdcard_summary NOTI)
 *     hooked    1 = tracepoint probe registered
 * Test hook (root, touches no card): echo YES|NO|NoCard > .../parameters/test sends the
 * uevent once.
 */
#define pr_fmt(fmt) "a52sxq_sd_ioerror: " fmt

#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/mmc/card.h>
#include <linux/mmc/core.h>
#include <linux/mmc/host.h>
#include <linux/mmc/mmc.h>
#include <linux/module.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/tracepoint.h>
#include <linux/workqueue.h>

/* sec_core.ko (samsung612/modules/sec_core) */
struct device *sec_dev_get_by_name(const char *name);

#define SD_HOST_DEV	"8804000.sdhci"	/* 5.4: host->hw_name == "8804000.sdhci" */
#define SD_STATUS_MASK	(R1_ERROR | R1_CC_ERROR | R1_CARD_ECC_FAILED | R1_WP_VIOLATION | R1_OUT_OF_RANGE)

static struct {
	spinlock_t lock;
	const struct mmc_card *card;	/* identity only, never dereferenced */
	u32 ge, cc, ecc, wp, oor, noti;
	u64 crc, tmo, cnt;
} sd_err = { .lock = __SPIN_LOCK_UNLOCKED(sd_err.lock) };

static const char *sd_ioerror_val = "YES";

static void sd_ioerror_fn(struct work_struct *work)
{
	struct device *dev = sec_dev_get_by_name("sdcard");
	char ioerr[16];
	char *envp[3] = { "DEVNAME=sdcard", ioerr, NULL };
	unsigned long flags;
	int ret;

	if (!dev) {
		pr_warn("no /sys/class/sec/sdcard device (a52sxq_sec_class not loaded)\n");
		return;
	}
	snprintf(ioerr, sizeof(ioerr), "IOERROR=%s", sd_ioerror_val);
	pr_info("Send Notification about SD Card IO Error (%s)\n", ioerr);
	ret = kobject_uevent_env(&dev->kobj, KOBJ_CHANGE, envp);
	put_device(dev);
	if (ret) {
		pr_err("Failed to Send Uevent with err %d\n", ret);
		return;
	}
	spin_lock_irqsave(&sd_err.lock, flags);
	sd_err.noti++;
	spin_unlock_irqrestore(&sd_err.lock, flags);
}
static DECLARE_WORK(sd_ioerror_work, sd_ioerror_fn);

/* mmc_request_done tracepoint: any context, no sleeping */
static void sd_req_done(void *data, struct mmc_host *host, struct mmc_request *mrq)
{
	struct mmc_command *cmd = mrq ? mrq->cmd : NULL;
	const struct mmc_card *card = host ? host->card : NULL;
	int err[3], i;
	bool noti = false;
	unsigned long flags;
	u32 val = 0;

	if (!cmd || !card || card->type != MMC_TYPE_SD)
		return;
	switch (cmd->opcode) {
	case MMC_STOP_TRANSMISSION:
	case MMC_SEND_STATUS:
	case MMC_READ_SINGLE_BLOCK:
	case MMC_READ_MULTIPLE_BLOCK:
	case MMC_WRITE_BLOCK:
	case MMC_WRITE_MULTIPLE_BLOCK:
		break;
	default:
		return;
	}
	err[0] = cmd->error;
	err[1] = mrq->data ? mrq->data->error : 0;
	err[2] = mrq->stop ? mrq->stop->error : 0;
	if (!err[0])
		val |= cmd->resp[0];
	if (mrq->stop && !err[2])
		val |= mrq->stop->resp[0];
	val &= SD_STATUS_MASK;
	if (!val && !err[0] && !err[1] && !err[2])
		return;
	if (!host->parent || strcmp(dev_name(host->parent), SD_HOST_DEV))
		return;

	spin_lock_irqsave(&sd_err.lock, flags);
	if (sd_err.card != card) {
		sd_err.ge = sd_err.cc = sd_err.ecc = sd_err.wp = sd_err.oor = sd_err.noti = 0;
		sd_err.crc = sd_err.tmo = sd_err.cnt = 0;
		sd_err.card = card;
	}
	if ((val & R1_ERROR) && !(++sd_err.ge % 1000))
		noti = true;
	if (val & R1_CC_ERROR)
		sd_err.cc++;
	if ((val & R1_CARD_ECC_FAILED) && !(++sd_err.ecc % 1000))
		noti = true;
	if ((val & R1_WP_VIOLATION) && !(++sd_err.wp % 100))
		noti = true;
	if ((val & R1_OUT_OF_RANGE) && !(++sd_err.oor % 100))
		noti = true;
	for (i = 0; i < 3; i++) {
		if (!err[i])
			continue;
		sd_err.cnt++;
		if (err[i] == -EILSEQ)
			sd_err.crc++;
		else if (err[i] == -ETIMEDOUT)
			sd_err.tmo++;
	}
	spin_unlock_irqrestore(&sd_err.lock, flags);

	if (noti) {
		sd_ioerror_val = "YES";
		schedule_work(&sd_ioerror_work);
	}
}

static struct tracepoint *sd_tp;
static bool sd_hooked;

static void sd_tp_find(struct tracepoint *tp, void *priv)
{
	if (!strcmp(tp->name, "mmc_request_done"))
		sd_tp = tp;
}

static int sd_test_set(const char *val, const struct kernel_param *kp)
{
	if (sysfs_streq(val, "YES"))
		sd_ioerror_val = "YES";
	else if (sysfs_streq(val, "NO"))
		sd_ioerror_val = "NO";
	else if (sysfs_streq(val, "NoCard"))
		sd_ioerror_val = "NoCard";
	else
		return -EINVAL;
	schedule_work(&sd_ioerror_work);
	return 0;
}
static const struct kernel_param_ops sd_test_ops = { .set = sd_test_set };
module_param_cb(test, &sd_test_ops, NULL, 0200);

static int sd_data_get(char *buf, const struct kernel_param *kp)
{
	unsigned long flags;
	int n;

	spin_lock_irqsave(&sd_err.lock, flags);
	n = sysfs_emit(buf, "\"GE\":\"%d\",\"CC\":\"%d\",\"ECC\":\"%d\",\"WP\":\"%d\","
		       "\"OOR\":\"%d\",\"CRC\":\"%lld\",\"TMO\":\"%lld\"\n",
		       sd_err.ge, sd_err.cc, sd_err.ecc, sd_err.wp, sd_err.oor,
		       (long long)sd_err.crc, (long long)sd_err.tmo);
	spin_unlock_irqrestore(&sd_err.lock, flags);
	return n;
}
static const struct kernel_param_ops sd_data_ops = { .get = sd_data_get };
module_param_cb(sd_data, &sd_data_ops, NULL, 0400);

static int sd_noti_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%u\n", READ_ONCE(sd_err.noti));
}
static const struct kernel_param_ops sd_noti_ops = { .get = sd_noti_get };
module_param_cb(noti, &sd_noti_ops, NULL, 0400);

module_param_named(hooked, sd_hooked, bool, 0444);

static int __init a52sxq_sd_ioerror_init(void)
{
	for_each_kernel_tracepoint(sd_tp_find, NULL);
	if (!sd_tp) {
		pr_warn("mmc_request_done tracepoint not found: test hook only\n");
		return 0;
	}
	if (tracepoint_probe_register(sd_tp, sd_req_done, NULL)) {
		pr_warn("cannot register the mmc_request_done probe: test hook only\n");
		sd_tp = NULL;
		return 0;
	}
	sd_hooked = true;
	return 0;
}

static void __exit a52sxq_sd_ioerror_exit(void)
{
	if (sd_tp) {
		tracepoint_probe_unregister(sd_tp, sd_req_done, NULL);
		tracepoint_synchronize_unregister();
	}
	cancel_work_sync(&sd_ioerror_work);
}

module_init(a52sxq_sd_ioerror_init);
module_exit(a52sxq_sd_ioerror_exit);

MODULE_DESCRIPTION("Galaxy A52s: Samsung 5.4 SD card IOERROR uevent on 6.12 (mmc_request_done tracepoint)");
MODULE_AUTHOR("Samsung Electronics (5.4 mmc error log); a52sxq-mainline port");
MODULE_LICENSE("GPL");
