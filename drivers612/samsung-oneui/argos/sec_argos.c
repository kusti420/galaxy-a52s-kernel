// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * argos.c
 *
 * Copyright (c) 2012 Samsung Electronics Co., Ltd
 *              http://www.samsung.com
 *
 *  This program is free software; you can redistribute  it and/or modify it
 *  under  the terms of  the GNU General  Public License as published by the
 *  Free Software Foundation;  either version 2 of the  License, or (at your
 *  option) any later version.
 *
 * ---------------------------------------------------------------------------------------------
 * 6.12 module port for the Galaxy A52s (a52sxq) OneUI port. Sources: 5.4
 * drivers/samsung/misc/sec_argos.c, include/linux/samsung/sec_argos.h and the
 * PM_QOS_NETWORK_THROUGHPUT class of kernel/power/qos.c (CONFIG_ARGOS) in
 * $ANDROID_TREE/kernel/samsung/sm7325. Differences, all forced by GKI 6.12 or a module build:
 *  - 6.12 has no pm_qos classes. The /dev/network_throughput misc device and its PM_QOS_MAX
 *    request list are re-implemented here with the 5.4 semantics: every open() adds a request
 *    (default 0), write() takes a raw s32 (count == 4) or a base-16 string (kstrtos32_from_user
 *    rules: "0x" prefix, trailing "\n", at most 22 characters), read() returns the aggregated
 *    s32, close() removes the request. A change of the aggregated value calls the argos
 *    handler (5.4: pm_qos notifier) with it.
 *  - New: when the last request is gone (argosd died), all argos locks are released
 *    (5.4 kept the last level).
 *  - The per-interface tables come from the 5.4 DT node /soc/argos
 *    (a52sxq_kor_single_w00_r0{0,1,2}.dts, identical in all three) as a built-in C table. If
 *    the running tree has a "samsung,argos" node, it is parsed instead. Device index = the
 *    unit address N of boot_device@N minus 1, which is what argosd sends
 *    (value = Mbps << 4 | N); 5.4 used the DT child order.
 *  - CPU: set_freq_limit(CFLM_ARGOS, kHz) of cpufreq_limit.ko (weak link, as input_booster).
 *  - DDR: icc_get(dev, MASTER_APPSS_PROC, SLAVE_EBI1) is not exported on GKI 6.12; the vote is
 *    made through of_icc_get() on the DT node's "interconnects" property when the node exists
 *    (platform driver, probe only takes the path). Without the node: no DDR vote.
 *  - Task / IRQ affinity and hmp boost: same code as 5.4. The lists are only filled by other
 *    kernel drivers through argos_{task,irq}_affinity_setup_label(); no driver did that on the
 *    5.4 A52s, so they stay empty (no-op), as on 5.4. Exported GPL here for a 6.12 opt-in.
 *  - Bug fixes: device index check (5.4 accepted type == ndevice), tables[-1] address taken
 *    on unlock, devices with an empty table.
 *  - Silent by default: the 5.4 pr_info lines are printed only with debug=1.
 * ---------------------------------------------------------------------------------------------
 */

#define pr_fmt(fmt)     KBUILD_MODNAME ":%s() " fmt, __func__

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/reboot.h>
#include <linux/of.h>
#include <linux/gfp.h>
#include <linux/platform_device.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/cpumask.h>
#include <linux/interrupt.h>
#include <linux/interconnect.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/sysfs.h>

#include "sec_argos.h"

static bool debug;
module_param(debug, bool, 0644);
MODULE_PARM_DESC(debug, "log level changes and frequency updates (5.4 pr_info lines)");

#define argos_info(fmt, ...) \
	do { if (debug) pr_info(fmt, ##__VA_ARGS__); } while (0)

/*
 * cpufreq_limit.ko (drivers612/samsung-oneui/cpufreq_limit), EXPORT_SYMBOL: symbol_get()
 * refuses non-GPL exports on >= 6.5, so a weak reference is used (resolves to NULL when the
 * module is absent instead of failing our load). The address is taken only in this data
 * initialiser (ABS64 relocation); testing it in code would emit a GOT relocation, which the
 * 6.12 arm64 module loader rejects (insmod fails = first-stage bootloop). See input_booster.
 */
#define CFLM_ARGOS	3
#define DVFS_ARGOS_ID	CFLM_ARGOS
extern int set_freq_limit(unsigned int id, unsigned int freq) __weak;
static int (*p_set_freq_limit)(unsigned int id, unsigned int freq) = set_freq_limit;

#define ARGOS_NAME "argos"
#define TYPE_SHIFT 4
#define TYPE_MASK_BIT ((1 << TYPE_SHIFT) - 1)
#define ARGOS_MAX_DEVICES TYPE_MASK_BIT	/* argosd sends index 1..15 in the low nibble */

#define LOCK_RELEASE	0
#define FREQ_UNLOCK		-1
#define SKIP_FREQ_UPDATE	0
#define FREQ_UPDATE	1

#define CPU_UNLOCK_FREQ -1
#define DDR_UNLOCK_FREQ 0

#define BUS_W 4        /* SM8350 DDR Voting('w' for DDR is 4) */
#define MHZ_TO_KBPS(mhz, w) ((uint64_t)mhz * 1000 * w)

#define PM_QOS_DEFAULT_VALUE	(-1)
#define PM_QOS_NETWORK_THROUGHPUT_DEFAULT_VALUE	0

static DEFINE_SPINLOCK(argos_irq_lock);
static DEFINE_SPINLOCK(argos_task_lock);
static DEFINE_SPINLOCK(argos_boost_list_lock);

enum {
	THRESHOLD,
	BIG_MIN_FREQ,
	BIG_MAX_FREQ,
	LITTLE_MIN_FREQ,
	LITTLE_MAX_FREQ,
	DDR_FREQ,
	RESERVED,
	TASK_AFFINITY_EN,
	IRQ_AFFINITY_EN,
	SCHED_BOOST_EN,
	ITEM_MAX,
};

enum {
	BOOST_CPU,
	BOOST_DDR,
	BOOST_MAX
};

struct boost_table {
	unsigned int items[ITEM_MAX];
};

struct argos_task_affinity {
	struct task_struct *p;
	struct cpumask *affinity_cpu_mask;
	struct cpumask *default_cpu_mask;
	struct list_head entry;
};

struct argos_irq_affinity {
	unsigned int irq;
	struct cpumask *affinity_cpu_mask;
	struct cpumask *default_cpu_mask;
	struct list_head entry;
};

struct argos {
	const char *desc;
	const struct boost_table *tables;
	int ntables;
	int prev_level;
	struct list_head task_affinity_list;
	bool task_hotplug_disable;
	struct list_head irq_affinity_list;
	bool irq_hotplug_disable;
	bool hmpboost_enable;
	bool argos_block;
	struct blocking_notifier_head argos_notifier;
	/* protect prev_level, qos, task/irq_hotplug_disable, hmpboost_enable */
	struct mutex level_mutex;
};

struct argos_platform_data {
	struct argos *devices;
	int ndevice;
	int *boost_list[BOOST_MAX];
	int boost_max[BOOST_MAX];
	bool from_dt;
};

static struct argos_platform_data *argos_pdata;
static int boost_unlock_freq[BOOST_MAX] = {
	CPU_UNLOCK_FREQ, DDR_UNLOCK_FREQ
};

/* DDR path from the DT node (platform probe); protected by nt_lock. */
static struct icc_path *path_argos_bw;

/* ----------------------------------------------------------------------------------------- */
/* Built-in copy of the 5.4 DT node (arch/arm64/boot/dts/samsung/a52/a52sxq/                  */
/* a52sxq_kor_single_w00_r02.dts fragment@84 "argos"; r00 and r01 are identical).             */
/* Row: THRESHOLD(Mbps) BIG_MIN BIG_MAX LITTLE_MIN LITTLE_MAX (kHz, cpufreq_limit virtual      */
/* table) DDR(MHz) RESERVED TASK_AFF IRQ_AFF SCHED_BOOST. Index = N - 1 of boot_device@N.     */
/* ----------------------------------------------------------------------------------------- */
struct argos_builtin {
	const char *label;
	const char *node;
	const char *sysnode;
	int ntables;
	struct boost_table tables[2];
};

static const struct argos_builtin argos_a52sxq[] = {
	/* boot_device@1 */
	{ "WIFI TX", "wlan0", NULL, 2, {
		{ { 20, 0, 0, 576000, 0, 1017, 0, 0, 0, 0 } },
		{ { 200, 2131200, 0, 1804800, 0, 5161, 0, 1, 1, 1 } } } },
	/* boot_device@2 */
	{ "WIFI RX", "wlan0", NULL, 1, { { { 0 } } } },
	/* boot_device@3 */
	{ "SWLAN", "swlan0", NULL, 1, { { { 0 } } } },
	/* boot_device@4 */
	{ "UFS", "", "/sys/class/sec/ufs/transferred_cnt", 1, {
		{ { 800, 0, 0, 902400, 0, 0, 0, 0, 0, 0 } } } },
	/* boot_device@5 */
	{ "P2P", "p2p-wlan0-0", NULL, 1, { { { 0 } } } },
	/* boot_device@6 */
	{ "NAN", "aware_data0", NULL, 1, { { { 0 } } } },
	/* boot_device@7 */
	{ "IPC", "rmnet_mhi0", NULL, 1, { { { 0 } } } },
};

static int argos_find_index(const char *label)
{
	int i;
	int dev_num = -1;

	if (!argos_pdata) {
		pr_err("argos not initialized\n");
		return -1;
	}

	for (i = 0; i < argos_pdata->ndevice; i++)
		if (argos_pdata->devices[i].desc &&
		    strcmp(argos_pdata->devices[i].desc, label) == 0)
			dev_num = i;
	return dev_num;
}

int sec_argos_register_notifier(struct notifier_block *n, char *label)
{
	struct blocking_notifier_head *cnotifier;
	int dev_num;

	dev_num = argos_find_index(label);

	if (dev_num < 0) {
		pr_err("No match found for label: %d", dev_num);
		return -ENODEV;
	}

	cnotifier = &argos_pdata->devices[dev_num].argos_notifier;

	argos_info("%ps(dev_num:%d)\n", n->notifier_call, dev_num);

	return blocking_notifier_chain_register(cnotifier, n);
}
EXPORT_SYMBOL(sec_argos_register_notifier);

int sec_argos_unregister_notifier(struct notifier_block *n, char *label)
{
	struct blocking_notifier_head *cnotifier;
	int dev_num;

	dev_num = argos_find_index(label);

	if (dev_num < 0) {
		pr_err("No match found for label: %d", dev_num);
		return -ENODEV;
	}

	cnotifier = &argos_pdata->devices[dev_num].argos_notifier;

	argos_info("%ps(dev_num:%d)\n", n->notifier_call, dev_num);

	return blocking_notifier_chain_unregister(cnotifier, n);
}
EXPORT_SYMBOL(sec_argos_unregister_notifier);

static int argos_task_affinity_setup(struct task_struct *p, int dev_num,
				     struct cpumask *affinity_cpu_mask,
				     struct cpumask *default_cpu_mask)
{
	struct argos_task_affinity *this;
	struct list_head *head;

	if (!argos_pdata) {
		pr_err("argos not initialized\n");
		return -ENXIO;
	}

	if (dev_num < 0 || dev_num >= argos_pdata->ndevice) {
		pr_err("dev_num:%d should be dev_num:0 ~ %d in boundary\n",
		       dev_num, argos_pdata->ndevice - 1);
		return -EINVAL;
	}

	head = &argos_pdata->devices[dev_num].task_affinity_list;

	this = kzalloc(sizeof(*this), GFP_ATOMIC);
	if (!this)
		return -ENOMEM;

	this->p = p;
	this->affinity_cpu_mask = affinity_cpu_mask;
	this->default_cpu_mask = default_cpu_mask;

	spin_lock(&argos_task_lock);
	list_add(&this->entry, head);
	spin_unlock(&argos_task_lock);

	return 0;
}

int argos_task_affinity_setup_label(struct task_struct *p, const char *label,
				    struct cpumask *affinity_cpu_mask,
				    struct cpumask *default_cpu_mask)
{
	int dev_num;

	dev_num = argos_find_index(label);

	return argos_task_affinity_setup(p, dev_num, affinity_cpu_mask,
					 default_cpu_mask);
}
EXPORT_SYMBOL_GPL(argos_task_affinity_setup_label);

static int argos_irq_affinity_setup(unsigned int irq, int dev_num,
				    struct cpumask *affinity_cpu_mask,
				    struct cpumask *default_cpu_mask)
{
	struct argos_irq_affinity *this;
	struct list_head *head;

	if (!argos_pdata) {
		pr_err("argos not initialized\n");
		return -ENXIO;
	}

	if (dev_num < 0 || dev_num >= argos_pdata->ndevice) {
		pr_err("dev_num:%d should be dev_num:0 ~ %d in boundary\n",
		       dev_num, argos_pdata->ndevice - 1);
		return -EINVAL;
	}

	head = &argos_pdata->devices[dev_num].irq_affinity_list;

	this = kzalloc(sizeof(*this), GFP_ATOMIC);
	if (!this)
		return -ENOMEM;

	this->irq = irq;
	this->affinity_cpu_mask = affinity_cpu_mask;
	this->default_cpu_mask = default_cpu_mask;

	spin_lock(&argos_irq_lock);
	list_add(&this->entry, head);
	spin_unlock(&argos_irq_lock);

	return 0;
}

int argos_irq_affinity_setup_label(unsigned int irq, const char *label,
				   struct cpumask *affinity_cpu_mask,
				   struct cpumask *default_cpu_mask)
{
	int dev_num;

	dev_num = argos_find_index(label);

	return argos_irq_affinity_setup(irq, dev_num, affinity_cpu_mask,
			default_cpu_mask);
}
EXPORT_SYMBOL_GPL(argos_irq_affinity_setup_label);

static int argos_task_affinity_apply(int dev_num, bool enable)
{
	struct argos_task_affinity *this;
	struct list_head *head;
	int result = 0;
	struct cpumask *mask;
	bool *hotplug_disable;

	head = &argos_pdata->devices[dev_num].task_affinity_list;
	hotplug_disable = &argos_pdata->devices[dev_num].task_hotplug_disable;

	if (list_empty(head)) {
		pr_debug("task_affinity_list is empty\n");
		return result;
	}

	list_for_each_entry(this, head, entry) {
		if (enable) {
			if (!*hotplug_disable)
				*hotplug_disable = true;

			mask = this->affinity_cpu_mask;
		} else {
			if (*hotplug_disable)
				*hotplug_disable = false;

			mask = this->default_cpu_mask;
		}

		result = set_cpus_allowed_ptr(this->p, mask);

		argos_info("%s affinity %s to cpu_mask:0x%X\n",
			   this->p->comm,
			   (enable ? "enable" : "disable"),
			   (int)*mask->bits);
	}

	return result;
}

static int argos_irq_affinity_apply(int dev_num, bool enable)
{
	struct argos_irq_affinity *this;
	struct list_head *head;
	int result = 0;
	struct cpumask *mask;
	bool *hotplug_disable;

	head = &argos_pdata->devices[dev_num].irq_affinity_list;
	hotplug_disable = &argos_pdata->devices[dev_num].irq_hotplug_disable;

	if (list_empty(head)) {
		pr_debug("irq_affinity_list is empty\n");
		return result;
	}

	list_for_each_entry(this, head, entry) {
		if (enable) {
			if (!*hotplug_disable)
				*hotplug_disable = true;

			mask = this->affinity_cpu_mask;
		} else {
			if (*hotplug_disable)
				*hotplug_disable = false;

			mask = this->default_cpu_mask;
		}

		result = irq_set_affinity(this->irq, mask);

		argos_info("irq%d affinity %s to cpu_mask:0x%X\n",
			   this->irq, (enable ? "enable" : "disable"),
			   (int)*mask->bits);
	}

	return result;
}

static int argos_hmpboost_apply(int dev_num, bool enable)
{
	bool *hmpboost_enable;

	hmpboost_enable = &argos_pdata->devices[dev_num].hmpboost_enable;

	if (enable) {
		/* disable -> enable */
		if (!*hmpboost_enable) {
			*hmpboost_enable = true;
			argos_info("hmp boost enable [%d]\n", dev_num);
		}
	} else {
		/* enable -> disable */
		if (*hmpboost_enable) {
			*hmpboost_enable = false;
			argos_info("hmp boost disable [%d]\n", dev_num);
		}
	}

	return 0;
}

static int find_max(int dev_type, int *freq, int ndevice)
{
	int i, max = boost_unlock_freq[dev_type];

	for (i = 0; i < ndevice; i++) {
		if (freq[i] > max)
			max = freq[i];
	}

	return max;
}

static int check_update_freq(int boost_type, int dev_type, int target)
{
	int ret = SKIP_FREQ_UPDATE, new_max, prev;

	spin_lock(&argos_boost_list_lock);

	prev = argos_pdata->boost_list[boost_type][dev_type];
	argos_pdata->boost_list[boost_type][dev_type] = target;

	new_max = find_max(boost_type, argos_pdata->boost_list[boost_type],
			   argos_pdata->ndevice);

	if (new_max > argos_pdata->boost_max[boost_type] ||
	    (prev == argos_pdata->boost_max[boost_type] &&
	     new_max != argos_pdata->boost_max[boost_type])) {
		argos_pdata->boost_max[boost_type] = new_max;
		ret = FREQ_UPDATE;
	}
	spin_unlock(&argos_boost_list_lock);

	return ret;
}

static void argos_set_cpu(int freq)
{
	int (*fn)(unsigned int id, unsigned int freq) = READ_ONCE(p_set_freq_limit);

	if (fn)
		fn(DVFS_ARGOS_ID, (unsigned int)freq);
}

static void argos_set_ddr(int mhz)
{
	struct icc_path *path = READ_ONCE(path_argos_bw);

	if (path)
		icc_set_bw(path, 0, MHZ_TO_KBPS(mhz > 0 ? mhz : 0, BUS_W));
}

static void argos_freq_lock(int type, int level)
{
	unsigned int big_min_freq = 0, little_min_freq = 0;
	int target_freq, need_update;
	const struct boost_table *t = NULL;

	if (level != FREQ_UNLOCK) {
		t = &argos_pdata->devices[type].tables[level];
		big_min_freq = t->items[BIG_MIN_FREQ];
		little_min_freq = t->items[LITTLE_MIN_FREQ];
	}

	if (t)
		target_freq = (big_min_freq > little_min_freq) ?
				big_min_freq : little_min_freq;
	else
		target_freq = boost_unlock_freq[BOOST_CPU];

	need_update = check_update_freq(BOOST_CPU, type, target_freq);
	if (need_update != SKIP_FREQ_UPDATE) {
		argos_info("update cpu freq %d\n", argos_pdata->boost_max[BOOST_CPU]);
		argos_set_cpu(argos_pdata->boost_max[BOOST_CPU]);
	}

	if (t)
		target_freq = t->items[DDR_FREQ];
	else
		target_freq = boost_unlock_freq[BOOST_DDR];

	need_update = check_update_freq(BOOST_DDR, type, target_freq);
	if (need_update != SKIP_FREQ_UPDATE) {
		argos_info("update ddr freq %d\n", argos_pdata->boost_max[BOOST_DDR]);
		argos_set_ddr(argos_pdata->boost_max[BOOST_DDR]);
	}
}

/* Unlock one device (5.4 argos_block_enable(set) body). Caller holds cnode->level_mutex. */
static void argos_unlock_locked(int dev_num)
{
	struct argos *cnode = &argos_pdata->devices[dev_num];

	argos_freq_lock(dev_num, FREQ_UNLOCK);
	argos_task_affinity_apply(dev_num, 0);
	argos_irq_affinity_apply(dev_num, 0);
	argos_hmpboost_apply(dev_num, 0);
	cnode->prev_level = -1;
}

void argos_block_enable(char *req_name, bool set)
{
	int dev_num;
	struct argos *cnode;

	dev_num = argos_find_index(req_name);

	if (dev_num < 0) {
		pr_err("No match found for label: %s", req_name);
		return;
	}

	cnode = &argos_pdata->devices[dev_num];

	if (set) {
		cnode->argos_block = true;
		mutex_lock(&cnode->level_mutex);
		argos_unlock_locked(dev_num);
		mutex_unlock(&cnode->level_mutex);
	} else {
		cnode->argos_block = false;
	}
	argos_info("req_name:%s block:%d\n", req_name, cnode->argos_block);
}
EXPORT_SYMBOL_GPL(argos_block_enable);

/* New on 6.12: release every lock (last request closed, module exit). */
static void argos_release_all(void)
{
	int i;

	for (i = 0; i < argos_pdata->ndevice; i++) {
		struct argos *cnode = &argos_pdata->devices[i];

		mutex_lock(&cnode->level_mutex);
		if (cnode->prev_level != -1) {
			argos_info("release name:%s, prev level:%d\n", cnode->desc,
				   cnode->prev_level);
			argos_unlock_locked(i);
		}
		mutex_unlock(&cnode->level_mutex);
	}
}

static bool argos_stopped;	/* 5.4: pm_qos notifier removed at power off / restart */

static int argos_reboot_notifier(struct notifier_block *this,
				 unsigned long event, void *_cmd)
{
	switch (event) {
	case SYS_POWER_OFF:
	case SYS_RESTART:
		pr_debug("called\n");
		WRITE_ONCE(argos_stopped, true);
		break;
	}

	return NOTIFY_OK;
}

static struct notifier_block argos_reboot_nb = {
	.notifier_call = argos_reboot_notifier,
};

/* 5.4 argos_pm_qos_notify(), called with the aggregated value of /dev/network_throughput. */
static int argos_pm_qos_notify(unsigned long speedtype)
{
	int type, level, prev_level;
	unsigned long speed;
	bool argos_blocked;
	struct argos *cnode;

	if (READ_ONCE(argos_stopped))
		return NOTIFY_OK;

	type = (speedtype & TYPE_MASK_BIT) - 1;
	if (type < 0 || type >= argos_pdata->ndevice) {
		pr_debug("There is no type for devices type[%d], ndevice[%d]\n",
			 type, argos_pdata->ndevice);
		return NOTIFY_BAD;
	}

	speed = speedtype >> TYPE_SHIFT;
	cnode = &argos_pdata->devices[type];

	prev_level = cnode->prev_level;

	argos_blocked = cnode->argos_block;

	if (cnode->ntables < 1 || cnode->tables[0].items[THRESHOLD] == 0) {
		pr_debug("skip not used name:%s, speed:%luMbps\n",
			 cnode->desc ? cnode->desc : "", speed);
		goto out;
	}

	/* Find proper level */
	for (level = 0; level < cnode->ntables; level++) {
		const struct boost_table *t = &cnode->tables[level];

		if (speed < t->items[THRESHOLD])
			break;
	}

	/* decrease 1 level to match proper table */
	level--;
	if (!argos_blocked) {
		if (level != prev_level) {
			if (mutex_trylock(&cnode->level_mutex) == 0) {
			/*
			 * If the mutex is already locked, it means this argos
			 * is being blocked or is handling another change.
			 * We don't need to wait.
			 */
				argos_info("skip name:%s, speed:%luMbps, prev level:%d, request level:%d\n",
					   cnode->desc, speed, prev_level, level);
				goto out;
			}
			argos_info("name:%s, speed:%luMbps, prev level:%d, request level:%d\n",
				   cnode->desc, speed, prev_level, level);

			if (level == FREQ_UNLOCK) {
				if (cnode->argos_notifier.head) {
					pr_debug("Call argos notifier(%s lev:%d)\n",
						 cnode->desc, level);
					blocking_notifier_call_chain(&cnode->argos_notifier,
								     speed, NULL);
				}
				argos_freq_lock(type, FREQ_UNLOCK);
				argos_task_affinity_apply(type, 0);
				argos_irq_affinity_apply(type, 0);
				argos_hmpboost_apply(type, 0);
			} else {
				unsigned int enable_flag;

				argos_freq_lock(type, level);
				/* FIXME should control affinity and hmp boost */

				enable_flag = cnode->tables[level].items[TASK_AFFINITY_EN];
				argos_task_affinity_apply(type, enable_flag);
				enable_flag = cnode->tables[level].items[IRQ_AFFINITY_EN];
				argos_irq_affinity_apply(type, enable_flag);
				enable_flag = cnode->tables[level].items[SCHED_BOOST_EN];
				argos_hmpboost_apply(type, enable_flag);

				if (cnode->argos_notifier.head) {
					pr_debug("Call argos notifier(%s lev:%d)\n",
						 cnode->desc, level);
					blocking_notifier_call_chain(&cnode->argos_notifier,
								     speed, NULL);
				}
			}

			cnode->prev_level = level;
			mutex_unlock(&cnode->level_mutex);
		} else {
			pr_debug("same level (%d) is requested", level);
		}
	}
out:
	return NOTIFY_OK;
}

/* ----------------------------------------------------------------------------------------- */
/* /dev/network_throughput: 5.4 PM_QOS_NETWORK_THROUGHPUT (PM_QOS_MAX, default 0) misc dev.  */
/* ----------------------------------------------------------------------------------------- */
struct nt_req {
	struct list_head entry;
	s32 value;
};

static DEFINE_MUTEX(nt_lock);		/* request list, aggregate, DDR path; serializes argos */
static LIST_HEAD(nt_reqs);
static s32 nt_target = PM_QOS_NETWORK_THROUGHPUT_DEFAULT_VALUE;
static unsigned long nt_writes, nt_notifies;

static s32 nt_aggregate(void)
{
	struct nt_req *r;
	s32 v;
	bool any = false;

	v = PM_QOS_NETWORK_THROUGHPUT_DEFAULT_VALUE;
	list_for_each_entry(r, &nt_reqs, entry) {
		if (!any || r->value > v)
			v = r->value;
		any = true;
	}
	return v;
}

/* Caller holds nt_lock. */
static void nt_update_target(void)
{
	s32 cur = nt_aggregate();

	if (cur != nt_target) {
		nt_target = cur;
		nt_notifies++;
		if (cur >= 0)
			argos_pm_qos_notify((unsigned long)cur);
	}
}

static int nt_open(struct inode *inode, struct file *filp)
{
	struct nt_req *req = kzalloc(sizeof(*req), GFP_KERNEL);

	if (!req)
		return -ENOMEM;
	req->value = PM_QOS_NETWORK_THROUGHPUT_DEFAULT_VALUE;
	mutex_lock(&nt_lock);
	list_add_tail(&req->entry, &nt_reqs);
	nt_update_target();
	mutex_unlock(&nt_lock);
	filp->private_data = req;
	return 0;
}

static int nt_release(struct inode *inode, struct file *filp)
{
	struct nt_req *req = filp->private_data;
	bool last;

	mutex_lock(&nt_lock);
	list_del(&req->entry);
	nt_update_target();
	last = list_empty(&nt_reqs);
	if (last)
		argos_release_all();
	mutex_unlock(&nt_lock);
	kfree(req);
	return 0;
}

static ssize_t nt_read(struct file *filp, char __user *buf, size_t count, loff_t *f_pos)
{
	s32 value;

	mutex_lock(&nt_lock);
	value = nt_aggregate();
	mutex_unlock(&nt_lock);

	return simple_read_from_buffer(buf, count, f_pos, &value, sizeof(s32));
}

static ssize_t nt_write(struct file *filp, const char __user *buf, size_t count, loff_t *f_pos)
{
	struct nt_req *req = filp->private_data;
	s32 value;

	if (count == sizeof(s32)) {
		if (copy_from_user(&value, buf, sizeof(s32)))
			return -EFAULT;
	} else {
		/* = kstrtos32_from_user(buf, count, 16, &value) (not exported on GKI 6.12) */
		char kbuf[1 + sizeof(unsigned long long) * 8 / 3 + 1];
		size_t n = min(count, sizeof(kbuf) - 1);
		int ret;

		if (copy_from_user(kbuf, buf, n))
			return -EFAULT;
		kbuf[n] = '\0';
		ret = kstrtoint(kbuf, 16, &value);
		if (ret)
			return ret;
	}

	if (value == PM_QOS_DEFAULT_VALUE)
		value = PM_QOS_NETWORK_THROUGHPUT_DEFAULT_VALUE;

	mutex_lock(&nt_lock);
	nt_writes++;
	req->value = value;
	nt_update_target();
	mutex_unlock(&nt_lock);

	return count;
}

static const struct file_operations nt_fops = {
	.owner = THIS_MODULE,
	.open = nt_open,
	.release = nt_release,
	.read = nt_read,
	.write = nt_write,
	.llseek = noop_llseek,
};

/* Read-only status for checks: /sys/class/misc/network_throughput/argos_status */
static ssize_t argos_status_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int len = 0, i;
	struct nt_req *r;
	int nreq = 0;

	mutex_lock(&nt_lock);
	list_for_each_entry(r, &nt_reqs, entry)
		nreq++;
	len += sysfs_emit_at(buf, len, "source: %s\n", argos_pdata->from_dt ? "dt" : "builtin");
	len += sysfs_emit_at(buf, len, "target: 0x%x requests: %d writes: %lu notifies: %lu\n",
			     nt_target, nreq, nt_writes, nt_notifies);
	len += sysfs_emit_at(buf, len, "cpu: %s max %d\nddr: %s max %d\n",
			     READ_ONCE(p_set_freq_limit) ? "cpufreq_limit" : "none",
			     argos_pdata->boost_max[BOOST_CPU],
			     path_argos_bw ? "icc" : "none", argos_pdata->boost_max[BOOST_DDR]);
	for (i = 0; i < argos_pdata->ndevice; i++) {
		struct argos *c = &argos_pdata->devices[i];

		len += sysfs_emit_at(buf, len, "[%d] %s: tables %d level %d cpu %d ddr %d%s\n",
				     i + 1, c->desc ? c->desc : "-", c->ntables, c->prev_level,
				     argos_pdata->boost_list[BOOST_CPU][i],
				     argos_pdata->boost_list[BOOST_DDR][i],
				     c->argos_block ? " blocked" : "");
	}
	mutex_unlock(&nt_lock);
	return len;
}
static DEVICE_ATTR_RO(argos_status);

static struct attribute *nt_attrs[] = {
	&dev_attr_argos_status.attr,
	NULL
};
ATTRIBUTE_GROUPS(nt);

static struct miscdevice nt_miscdev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "network_throughput",
	.fops = &nt_fops,
	.groups = nt_groups,
};

/* ----------------------------------------------------------------------------------------- */
/* Tables: DT node "samsung,argos" if present (5.4 argos_parse_dt), else the built-in copy.  */
/* ----------------------------------------------------------------------------------------- */
static void argos_init_cnode(struct argos *cnode)
{
	INIT_LIST_HEAD(&cnode->task_affinity_list);
	INIT_LIST_HEAD(&cnode->irq_affinity_list);
	cnode->task_hotplug_disable = false;
	cnode->irq_hotplug_disable = false;
	cnode->hmpboost_enable = false;
	cnode->argos_block = false;
	cnode->prev_level = -1;
	mutex_init(&cnode->level_mutex);
	BLOCKING_INIT_NOTIFIER_HEAD(&cnode->argos_notifier);
}

static int argos_child_index(struct device_node *cnp)
{
	const char *at = strrchr(cnp->full_name, '@');
	unsigned int n;

	if (!at || kstrtouint(at + 1, 10, &n) || n < 1 || n > ARGOS_MAX_DEVICES)
		return -EINVAL;
	return n - 1;
}

static void argos_free_devices(struct argos_platform_data *pdata)
{
	int i;

	if (!pdata->devices)
		return;
	if (pdata->from_dt)
		for (i = 0; i < pdata->ndevice; i++)
			kfree(pdata->devices[i].tables);
	kfree(pdata->devices);
	pdata->devices = NULL;
}

static int argos_parse_dt(struct argos_platform_data *pdata, struct device_node *np)
{
	struct device_node *cnp;
	int ndevice = 0, idx, i, j, num_level, retval;

	for_each_child_of_node(np, cnp) {
		idx = argos_child_index(cnp);
		if (idx < 0)
			continue;
		if (idx + 1 > ndevice)
			ndevice = idx + 1;
	}
	if (!ndevice)
		return -ENODEV;

	pdata->devices = kcalloc(ndevice, sizeof(*pdata->devices), GFP_KERNEL);
	if (!pdata->devices)
		return -ENOMEM;
	pdata->ndevice = ndevice;
	pdata->from_dt = true;
	for (i = 0; i < ndevice; i++)
		argos_init_cnode(&pdata->devices[i]);

	for_each_child_of_node(np, cnp) {
		struct argos *cnode;
		struct boost_table *tables;

		idx = argos_child_index(cnp);
		if (idx < 0)
			continue;
		cnode = &pdata->devices[idx];
		cnode->desc = of_get_property(cnp, "net_boost,label", NULL);
		if (of_property_read_u32(cnp, "net_boost,table_size", &num_level) ||
		    num_level < 1 || num_level > 16) {
			pr_err("%pOF: bad net_boost,table_size\n", cnp);
			retval = -EINVAL;
			goto err_out;
		}

		tables = kcalloc(num_level, sizeof(*tables), GFP_KERNEL);
		if (!tables) {
			retval = -ENOMEM;
			goto err_out;
		}
		cnode->tables = tables;
		cnode->ntables = num_level;

		for (i = 0; i < num_level; i++) {
			for (j = 0; j < ITEM_MAX; j++) {
				retval = of_property_read_u32_index(cnp, "net_boost,table",
								    i * ITEM_MAX + j,
								    &tables[i].items[j]);
				if (retval) {
					pr_err("%pOF: Failed to get property\n", cnp);
					retval = -EINVAL;
					goto err_out;
				}
			}
		}
	}
	return 0;

err_out:
	of_node_put(cnp);
	argos_free_devices(pdata);
	pdata->ndevice = 0;
	pdata->from_dt = false;
	return retval;
}

static int argos_builtin_tables(struct argos_platform_data *pdata)
{
	int i, n = ARRAY_SIZE(argos_a52sxq);

	pdata->devices = kcalloc(n, sizeof(*pdata->devices), GFP_KERNEL);
	if (!pdata->devices)
		return -ENOMEM;
	pdata->ndevice = n;
	pdata->from_dt = false;
	for (i = 0; i < n; i++) {
		struct argos *cnode = &pdata->devices[i];

		argos_init_cnode(cnode);
		cnode->desc = argos_a52sxq[i].label;
		cnode->tables = argos_a52sxq[i].tables;
		cnode->ntables = argos_a52sxq[i].ntables;
	}
	return 0;
}

/* ----------------------------------------------------------------------------------------- */
/* Optional platform driver on the DT node: only takes the DDR interconnect path.            */
/* ----------------------------------------------------------------------------------------- */
static int argos_probe(struct platform_device *pdev)
{
	struct icc_path *path;

	path = of_icc_get(&pdev->dev, NULL);
	if (IS_ERR(path)) {
		if (PTR_ERR(path) == -EPROBE_DEFER)
			return -EPROBE_DEFER;
		dev_dbg(&pdev->dev, "no DDR path (%ld)\n", PTR_ERR(path));
		path = NULL;
	}

	mutex_lock(&nt_lock);
	WRITE_ONCE(path_argos_bw, path);
	if (path && argos_pdata->boost_max[BOOST_DDR] > 0)
		argos_set_ddr(argos_pdata->boost_max[BOOST_DDR]);
	mutex_unlock(&nt_lock);

	dev_dbg(&pdev->dev, "probed, DDR path %s\n", path ? "ok" : "none");
	return 0;
}

static void argos_remove(struct platform_device *pdev)
{
	struct icc_path *path;

	mutex_lock(&nt_lock);
	path = path_argos_bw;
	WRITE_ONCE(path_argos_bw, NULL);
	mutex_unlock(&nt_lock);
	if (path) {
		icc_set_bw(path, 0, 0);
		icc_put(path);
	}
}

static const struct of_device_id argos_dt_ids[] = {
	{ .compatible = "samsung,argos"},
	{ }
};
MODULE_DEVICE_TABLE(of, argos_dt_ids);

static struct platform_driver argos_driver = {
	.driver = {
		.name = ARGOS_NAME,
		.of_match_table	= argos_dt_ids,
	},
	.probe = argos_probe,
	.remove = argos_remove,
};

static bool argos_pdrv_registered, argos_misc_registered, argos_reboot_registered;

static void argos_teardown(void)
{
	int i;

	if (argos_misc_registered)
		misc_deregister(&nt_miscdev);
	argos_misc_registered = false;
	if (argos_pdrv_registered)
		platform_driver_unregister(&argos_driver);
	argos_pdrv_registered = false;
	if (argos_reboot_registered)
		unregister_reboot_notifier(&argos_reboot_nb);
	argos_reboot_registered = false;

	if (!argos_pdata)
		return;
	if (argos_pdata->devices)
		argos_release_all();
	for (i = 0; i < argos_pdata->ndevice; i++) {
		struct argos *c = &argos_pdata->devices[i];
		struct argos_task_affinity *t, *tn;
		struct argos_irq_affinity *q, *qn;

		list_for_each_entry_safe(t, tn, &c->task_affinity_list, entry)
			kfree(t);
		list_for_each_entry_safe(q, qn, &c->irq_affinity_list, entry)
			kfree(q);
	}
	for (i = 0; i < BOOST_MAX; i++)
		kfree(argos_pdata->boost_list[i]);
	argos_free_devices(argos_pdata);
	kfree(argos_pdata);
	argos_pdata = NULL;
}

/*
 * Never fails (first-stage insmod failure = bootloop): on any error the module stays loaded
 * without /dev/network_throughput and says why once.
 */
static int __init argos_init(void)
{
	struct argos_platform_data *pdata;
	struct device_node *np;
	int i, j, ret;

	pdata = kzalloc(sizeof(*pdata), GFP_KERNEL);
	if (!pdata)
		goto fail;
	argos_pdata = pdata;

	np = of_find_compatible_node(NULL, NULL, "samsung,argos");
	if (np) {
		ret = argos_parse_dt(pdata, np);
		of_node_put(np);
		if (ret)
			pr_warn("DT node unusable (%d), using the built-in A52s table\n", ret);
	}
	if (!pdata->devices && argos_builtin_tables(pdata))
		goto fail;

	for (i = 0; i < BOOST_MAX; i++) {
		pdata->boost_list[i] = kcalloc(pdata->ndevice, sizeof(int), GFP_KERNEL);
		if (!pdata->boost_list[i])
			goto fail;
		for (j = 0; j < pdata->ndevice; j++)
			pdata->boost_list[i][j] = boost_unlock_freq[i];
		pdata->boost_max[i] = boost_unlock_freq[i];
	}

	if (!register_reboot_notifier(&argos_reboot_nb))
		argos_reboot_registered = true;

	ret = misc_register(&nt_miscdev);
	if (ret) {
		pr_err("network_throughput misc device failed (%d)\n", ret);
		goto fail;
	}
	argos_misc_registered = true;

	ret = platform_driver_register(&argos_driver);
	if (ret)
		pr_warn("platform driver not registered (%d): no DDR vote\n", ret);
	else
		argos_pdrv_registered = true;

	pr_debug("ready: %d devices (%s), cpufreq_limit %s\n", pdata->ndevice,
		 pdata->from_dt ? "dt" : "builtin", READ_ONCE(p_set_freq_limit) ? "yes" : "no");
	return 0;

fail:
	pr_err("init failed, argos disabled\n");
	argos_teardown();
	return 0;
}

static void __exit argos_exit(void)
{
	argos_teardown();
}
module_init(argos_init);
module_exit(argos_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SAMSUNG Electronics");
MODULE_DESCRIPTION("ARGOS DEVICE (6.12 module port: /dev/network_throughput + argos)");
