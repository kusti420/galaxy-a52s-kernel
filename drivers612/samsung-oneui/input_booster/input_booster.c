// SPDX-License-Identifier: GPL-2.0
/*
 * Samsung SEC input booster - a52sxq Linux 6.12 module port.
 *
 * Derived from Samsung's sm7325 (Galaxy A52s, Linux 5.4) GPL sources
 *   drivers/input/input_boost/evdev_booster.c     (MODULE_AUTHOR "hongc.shim")
 *   drivers/input/input_boost/input_booster.c
 *   drivers/input/input_boost/input_booster_qc.c
 *   include/linux/input/input_booster.h
 * Copyright (C) Samsung Electronics Co., Ltd.
 *
 * What this port changes (see README.md):
 *  - Events come from an input_handler (.events, never consumes: returns count) instead of the
 *    5.4 evdev.c patch, so the GKI Image stays unchanged. The handle is opened only once
 *    userspace already opened the device (never powers a device up by itself).
 *  - The 5.4 device tree node (a52sxq_kor_single_w00_r02 "input_booster", = the A52s 5.4 boot
 *    dmesg: touch head 1324800 kHz / 200 ms, tail 300 ms) is built in; 6.12 DT has none.
 *  - All booster bookkeeping runs on ONE ordered high-priority workqueue under one mutex
 *    (5.4: unbound wq with racy RCU lists). Timing, max-aggregation and release values are the
 *    5.4 ones.
 *  - Resources: CPU = set_freq_limit(CFLM_TOUCH) of cpufreq_limit.ko (weak link), HMP =
 *    sched_set_boost() of sched-walt.ko (symbol_get). DDR (icc_get not exported, no DT device)
 *    and LPM bias (PM_QOS_BIAS_HYST does not exist on 6.12) are kept in sysfs but are no-ops.
 */
#define pr_fmt(fmt) "input_booster: " fmt

#include <linux/device.h>
#include <linux/init.h>
#include <linux/input.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#include "input_booster.h"

/* cpufreq_limit.ko (drivers612/samsung-oneui/cpufreq_limit). EXPORT_SYMBOL (not _GPL), so
 * symbol_get() refuses it on >= 6.5; a weak undefined reference resolves to NULL when the
 * module is absent instead of failing our load. */
#define CFLM_TOUCH 1
extern int set_freq_limit(unsigned int id, unsigned int freq) __weak;
/*
 * The weak address is taken ONLY in this data initialiser: an R_AARCH64_ABS64 data relocation,
 * which the module loader resolves to 0 for an unresolved weak symbol. Testing the address in
 * code makes clang emit a GOT access (R_AARCH64_ADR_GOT_PAGE, type 311), which the 6.12 arm64
 * module loader rejects ("unsupported RELA relocation: 311" = insmod fails = first-stage
 * bootloop). Read with READ_ONCE so the compiler cannot fold it back into a GOT access.
 */
static int (*p_set_freq_limit)(unsigned int id, unsigned int freq) = set_freq_limit;

/* sched-walt.ko, EXPORT_SYMBOL_GPL: looked up lazily with symbol_get(). */
extern int sched_set_boost(int type);

/* ----------------------------------------------------------------------------------------- */
/* Built-in copy of the 5.4 DT node (arch/arm64/boot/dts/samsung/a52/a52sxq/                  */
/* a52sxq_kor_single_w00_r02.dts "input_booster": max_resource_count 4, max_cluster_count 3,   */
/* cpu_cluster_policy "7,4,0", ib_release_values "-1,0,-2,0", allowed_resources "0,1,2,3").    */
/* Index == input_booster,type (the 5.4 code indexes ib_device_trees by device type).          */

#define RES(h_cpu, t_cpu, h_ddr, t_ddr, h_hmp, t_hmp, h_lpm, t_lpm) {	\
	{ CPUFREQ,  "CPU", h_cpu, t_cpu },				\
	{ DDRFREQ,  "DDR", h_ddr, t_ddr },				\
	{ HMPBOOST, "HMP", h_hmp, t_hmp },				\
	{ LPMBIAS,  "LPM", h_lpm, t_lpm } }

static struct t_ib_device_tree ib_device_trees[MAX_DEVICE_TYPE_NUM] = {
	{ "key",         KEY,         500,   0, RES(1324800,       0,    0,    0, 2, 0, 0, 0) },
	{ "touchkey",    TOUCH_KEY,     1, 500, RES(1324800,       0,    0,    0, 2, 0, 0, 0) },
	{ "touch",       TOUCH,       200, 300, RES(1324800, 1056000, 1017, 1017, 2, 2, 5, 5) },
	{ "multitouch",  MULTI_TOUCH, 200, 800, RES(2035200, 1324800,    0,    0, 2, 2, 0, 0) },
	{ "keyboard",    KEYBOARD,    130, 130, RES(1324800, 1324800,    0,    0, 2, 2, 0, 0) },
	{ "MOUSE",       MOUSE,       200, 300, RES(1324800,  489600,    0,    0, 2, 0, 0, 0) },
	{ "mouse_wheel", MOUSH_WHEEL, 200,   0, RES(1324800,       0,    0,    0, 2, 0, 0, 0) },
	{ "pen_hover",   HOVER,       200, 300, RES(1324800,  489600,    0,    0, 2, 0, 0, 0) },
	{ "pen",         SPEN,        200, 600, RES(1766400, 1056000,    0,    0, 2, 2, 5, 5) },
};

static const int release_val[MAX_RES_COUNT] = { -1, 0, -2, 0 };
static const int allowed_resources[] = { CPUFREQ, DDRFREQ, HMPBOOST, LPMBIAS };
#define allowed_res_count ((int)ARRAY_SIZE(allowed_resources))
static const int device_count = MAX_DEVICE_TYPE_NUM;

/* ----------------------------------------------------------------------------------------- */
/* sysfs-visible state (5.4 names) */
static unsigned int debug_flag;
static unsigned int enable_event_booster = INIT_ZERO;
static int send_ev_enable;
static unsigned int u_ib_mode;		/* ib_mode_state: not on the 5.4 A52s, see README */
static int level_value = IB_MAX;

/* ----------------------------------------------------------------------------------------- */
/* booster core state; everything below is protected by ib_lock and touched only from ib_wq
 * (plus sysfs stores of the dt values, also under ib_lock) */
static DEFINE_MUTEX(ib_lock);
static struct workqueue_struct *ib_wq;	/* ordered, WQ_HIGHPRI */
static struct list_head ib_list[MAX_DEVICE_TYPE_NUM];
static int total_ib_cnt;
static int ib_count;
static bool ib_dying;
static int evdev_mt_slot;
static int evdev_mt_event[MAX_DEVICE_TYPE_NUM];
static int current_hmp_boost;
static int (*p_sched_set_boost)(int type);

/* ----------------------------------------------------------------------------------------- */
/* resource back ends (5.4 input_booster_qc.c) */

static void set_hmp(int level)
{
	if (level == current_hmp_boost)
		return;
	if (level == 0) {
		level = -current_hmp_boost;
		current_hmp_boost = 0;
	} else {
		current_hmp_boost = level;
	}
	pr_booster("hmp_boost : %d\n", level);
	if (!p_sched_set_boost)
		p_sched_set_boost = symbol_get(sched_set_boost);
	if (p_sched_set_boost) {
		if (p_sched_set_boost(level) < 0)
			pr_err_once("sched_set_boost(%d) failed\n", level);
	}
}

static void ib_set_cpu(int value)
{
	int (*fn)(unsigned int id, unsigned int freq) = READ_ONCE(p_set_freq_limit);

	if (fn)
		fn(CFLM_TOUCH, (unsigned int)value);
	pr_booster("cpufreq value : %d\n", value);
}

static void ib_set_booster(const long *qos_values)
{
	int i, res;
	long value;

	for (i = 0; i < allowed_res_count; i++) {
		res = allowed_resources[i];
		value = qos_values[res];
		if (value <= 0)
			continue;
		switch (res) {
		case CPUFREQ:
			ib_set_cpu((int)value);
			break;
		case HMPBOOST:
			set_hmp((int)value);
			break;
		case DDRFREQ:	/* no-op on 6.12 (see README) */
		case LPMBIAS:	/* no-op on 6.12 (see README) */
		default:
			pr_booster("res %d value %ld (no-op)\n", res, value);
			break;
		}
	}
}

static void ib_release_booster(const long *rel_flags)
{
	int i, res;

	for (i = 0; i < allowed_res_count; i++) {
		res = allowed_resources[i];
		if (rel_flags[res] <= 0)
			continue;
		switch (res) {
		case CPUFREQ:
			ib_set_cpu(release_val[res]);	/* -1: release */
			break;
		case HMPBOOST:
			set_hmp(release_val[res]);	/* -2: drop CONSERVATIVE_BOOST */
			break;
		default:
			break;
		}
	}
}

/* ----------------------------------------------------------------------------------------- */
/* booster state machine (5.4 input_booster.c), called with ib_lock held */

static long get_qos_value(int res_id)
{
	struct t_ib_info *ib;
	long ret_val = 0;
	int t;

	for (t = 0; t < device_count; t++)
		list_for_each_entry(ib, &ib_list[t], list)
			if (ib->has_tv[res_id] && ib->tv[res_id] > ret_val)
				ret_val = ib->tv[res_id];
	return ret_val;
}

static bool qos_list_empty(int res_id)
{
	struct t_ib_info *ib;
	int t;

	for (t = 0; t < device_count; t++)
		list_for_each_entry(ib, &ib_list[t], list)
			if (ib->has_tv[res_id])
				return false;
	return true;
}

static bool is_validate_uniqid(int uniq_id)
{
	struct t_ib_info *ib;
	int t;

	for (t = 0; t < device_count; t++)
		list_for_each_entry(ib, &ib_list[t], list)
			if (ib->uniq_id == uniq_id)
				return false;
	return true;
}

static struct t_ib_info *find_release_ib(int dev_type, int key_id)
{
	struct t_ib_info *ib;

	list_for_each_entry(ib, &ib_list[dev_type], list)
		if (ib->key_id == key_id && ib->rel_flag == FLAG_OFF)
			return ib;
	return NULL;
}

static void remove_ib_instance(struct t_ib_info *ib)
{
	pr_booster("Del Ib Instance's Id : %d\n", ib->uniq_id);
	list_del(&ib->list);
	ib_count--;
	kfree(ib);	/* freeing the running work item's container is allowed */
}

/* drop all target values of @ib, release resources nobody holds any more, re-apply the rest */
static void ib_drop_targets(struct t_ib_info *ib)
{
	long qos_values[MAX_RES_COUNT] = { 0 };
	long rel_flags[MAX_RES_COUNT] = { 0 };
	int i, res;

	for (i = 0; i < allowed_res_count; i++) {
		res = allowed_resources[i];
		if (!ib->has_tv[res])
			continue;
		ib->has_tv[res] = false;
		if (!qos_list_empty(res))
			qos_values[res] = get_qos_value(res);
		else
			rel_flags[res] = 1;
	}
	ib_release_booster(rel_flags);
	ib_set_booster(qos_values);
}

static void press_state_func(struct work_struct *work)
{
	struct t_ib_info *ib = container_of(work, struct t_ib_info, ib_state_work[IB_HEAD]);
	long qos_values[MAX_RES_COUNT] = { 0 };
	struct t_ib_res_info *res;
	int i;

	mutex_lock(&ib_lock);
	if (ib_dying)
		goto out;
	pr_booster("Press State Func :::: Unique_Id(%d)\n", ib->uniq_id);
	for (i = 0; i < allowed_res_count; i++) {
		res = &ib->ib_dt->res[allowed_resources[i]];
		if (res->head_value == 0 || !ib->has_tv[res->res_id])
			continue;
		ib->tv[res->res_id] = res->head_value;
		qos_values[res->res_id] = get_qos_value(res->res_id);
	}
	ib_set_booster(qos_values);
	queue_delayed_work(ib_wq, &ib->ib_timeout_work[IB_HEAD],
			   msecs_to_jiffies(ib->ib_dt->head_time));
out:
	mutex_unlock(&ib_lock);
}

static void press_timeout_func(struct work_struct *work)
{
	struct t_ib_info *ib = container_of(to_delayed_work(work), struct t_ib_info,
					    ib_timeout_work[IB_HEAD]);

	mutex_lock(&ib_lock);
	if (ib_dying)
		goto out;
	pr_booster("Press Timeout Func :::: Unique_Id(%d) Tail_Time(%d)\n",
		   ib->uniq_id, ib->ib_dt->tail_time);
	if (ib->ib_dt->tail_time != 0) {
		queue_work(ib_wq, &ib->ib_state_work[IB_TAIL]);
	} else {
		/* NO TAIL scenario: drop the instance */
		ib_drop_targets(ib);
		remove_ib_instance(ib);
	}
out:
	mutex_unlock(&ib_lock);
}

static void release_state_func(struct work_struct *work)
{
	struct t_ib_info *ib = container_of(work, struct t_ib_info, ib_state_work[IB_TAIL]);
	long qos_values[MAX_RES_COUNT] = { 0 };
	struct t_ib_res_info *res;
	int i;

	mutex_lock(&ib_lock);
	if (ib_dying)
		goto out;
	ib->isHeadFinished = 1;
	pr_booster("Release State Func :::: Unique_Id(%d) Rel_Flag(%d)\n",
		   ib->uniq_id, ib->rel_flag);
	for (i = 0; i < allowed_res_count; i++) {
		res = &ib->ib_dt->res[allowed_resources[i]];
		if (res->tail_value == 0 || !ib->has_tv[res->res_id])
			continue;
		ib->tv[res->res_id] = res->tail_value;
		qos_values[res->res_id] = get_qos_value(res->res_id);
	}
	ib_set_booster(qos_values);

	/* released already: tail timer now; else a 60 s safety timer (5.4) */
	if (ib->rel_flag == FLAG_ON) {
		if (!delayed_work_pending(&ib->ib_timeout_work[IB_TAIL]))
			queue_delayed_work(ib_wq, &ib->ib_timeout_work[IB_TAIL],
					   msecs_to_jiffies(ib->ib_dt->tail_time));
	} else {
		queue_delayed_work(ib_wq, &ib->ib_timeout_work[IB_TAIL],
				   msecs_to_jiffies(60000));
	}
out:
	mutex_unlock(&ib_lock);
}

static void release_timeout_func(struct work_struct *work)
{
	struct t_ib_info *ib = container_of(to_delayed_work(work), struct t_ib_info,
					    ib_timeout_work[IB_TAIL]);

	mutex_lock(&ib_lock);
	if (ib_dying)
		goto out;
	pr_booster("Release Timeout Func :::: Unique_Id(%d)\n", ib->uniq_id);
	ib_drop_targets(ib);
	remove_ib_instance(ib);
out:
	mutex_unlock(&ib_lock);
}

static struct t_ib_info *create_ib_instance(int dev_type, int key_id, int uniq_id)
{
	struct t_ib_info *ib = kzalloc(sizeof(*ib), GFP_KERNEL);

	if (!ib)
		return NULL;
	ib->key_id = key_id;
	ib->uniq_id = uniq_id;
	ib->press_flag = FLAG_OFF;
	ib->rel_flag = FLAG_OFF;
	ib->isHeadFinished = 0;
	ib->ib_dt = &ib_device_trees[dev_type];
	INIT_WORK(&ib->ib_state_work[IB_HEAD], press_state_func);
	INIT_DELAYED_WORK(&ib->ib_timeout_work[IB_HEAD], press_timeout_func);
	INIT_WORK(&ib->ib_state_work[IB_TAIL], release_state_func);
	INIT_DELAYED_WORK(&ib->ib_timeout_work[IB_TAIL], release_timeout_func);
	list_add_tail(&ib->list, &ib_list[dev_type]);
	ib_count++;
	return ib;
}

/* 5.4 trigger_input_booster(), called from the event worker with ib_lock held */
static void trigger_input_booster(int dev_type, int key_id, int event_type)
{
	struct t_ib_info *ib;
	int uniq_id, i, res;

	if (event_type == BOOSTER_ON) {
		if (find_release_ib(dev_type, key_id)) {
			pr_booster("IB Trigger :: ib already exist. Key(%d)\n", key_id);
			return;
		}
		if (ib_count >= MAX_IB_COUNT)	/* 5.4 would spin forever looking for an id */
			return;
		do {
			uniq_id = total_ib_cnt++;
			if (total_ib_cnt == MAX_IB_COUNT)
				total_ib_cnt = 0;
		} while (!is_validate_uniqid(uniq_id));

		ib = create_ib_instance(dev_type, key_id, uniq_id);
		if (!ib)
			return;
		pr_booster("IB Trigger Press :: IB Uniq Id(%d)\n", uniq_id);
		ib->press_flag = FLAG_ON;
		for (i = 0; i < allowed_res_count; i++) {
			res = allowed_resources[i];
			if (ib->ib_dt->res[res].head_value != 0) {
				ib->has_tv[res] = true;
				ib->tv[res] = 0;
			}
		}
		queue_work(ib_wq, &ib->ib_state_work[IB_HEAD]);
		return;
	}

	ib = find_release_ib(dev_type, key_id);
	if (!ib) {
		pr_booster("IB is null on release\n");
		return;
	}
	pr_booster("IB Trigger Release :: Uniq ID(%d)\n", ib->uniq_id);
	ib->rel_flag = FLAG_ON;
	if (ib->ib_dt->tail_time == 0)
		return;
	/* head finished already: (re)start the tail timer */
	if (ib->isHeadFinished)
		mod_delayed_work(ib_wq, &ib->ib_timeout_work[IB_TAIL],
				 msecs_to_jiffies(ib->ib_dt->tail_time));
}

/* ----------------------------------------------------------------------------------------- */
/* event decoding (5.4 evdev_booster.c, unchanged logic) */

static unsigned int create_uniq_id(int type, int code, int slot)
{
	return (type << (TYPE_BITS + CODE_BITS)) | (code << CODE_BITS) | slot;
}

static int chk_next_data(const struct input_value *vals, int next_idx, int input_type)
{
	int next_type = vals[next_idx].type;
	int next_code = vals[next_idx].code;

	switch (input_type) {
	case BTN_TOUCH:
		return next_type == EV_ABS && next_code == ABS_PRESSURE;
	case EV_KEY:
		return 1;
	default:
		return 0;
	}
}

static int chk_boost_on_off(const struct input_value *vals, int idx, int dev_type)
{
	int ret_val = -1;

	if (dev_type < 0)
		return ret_val;

	/* SPEN / HOVER: the multi event count must be empty before starting */
	if (dev_type == SPEN || dev_type == HOVER) {
		if (!evdev_mt_event[dev_type] && vals[idx].value)
			ret_val = 1;
		else if (evdev_mt_event[dev_type] && !vals[idx].value)
			ret_val = 0;
	} else if (dev_type == TOUCH || dev_type == MULTI_TOUCH) {
		ret_val = vals[idx].value >= 0 ? 1 : 0;
	} else if (vals[idx].value > 0) {
		ret_val = 1;
	} else {
		ret_val = 0;
	}
	return ret_val;
}

static int get_device_type(int *device_type, unsigned int *keyId, int *cur_idx,
			   const struct input_value *vals, int evt_cnt)
{
	int i, ret_val = -1, dev_type = NONE_TYPE_DEVICE;
	int uniq_slot = 0, next_idx = 0, target_idx = 0;

	*device_type = dev_type;

	for (i = *cur_idx; i < evt_cnt; i++) {
		if (vals[i].type == EV_SYN || vals[i].code == SYN_REPORT)
			break;

		if (vals[i].type == EV_KEY) {
			target_idx = i;
			switch (vals[i].code) {
			case BTN_TOUCH:
				next_idx = i + 1;
				if (!chk_next_data(vals, next_idx, BTN_TOUCH))
					break;
				dev_type = SPEN;
				break;
			case BTN_TOOL_PEN:
				dev_type = HOVER;
				break;
			case KEY_BACK:
			case KEY_HOMEPAGE:
				dev_type = TOUCH_KEY;
				break;
			case KEY_VOLUMEUP:
			case KEY_VOLUMEDOWN:
			case KEY_POWER:
				dev_type = KEY;
				break;
			default:
				break;
			}
		} else if (vals[i].type == EV_ABS) {
			target_idx = i;
			if (vals[i].code == ABS_MT_TRACKING_ID) {
				if (vals[i].value >= 0) {
					evdev_mt_slot++;
				} else {
					evdev_mt_slot--;
					if (evdev_mt_slot < 0) {
						evdev_mt_slot = 0;
						goto found;
					}
				}
				if (vals[i].value >= 0) {
					if (evdev_mt_slot == 1) {
						dev_type = TOUCH;
						uniq_slot = 1;
					} else if (evdev_mt_slot == 2) {
						dev_type = MULTI_TOUCH;
						uniq_slot = 2;
					}
				} else {
					if (evdev_mt_slot == 0) {
						dev_type = TOUCH;
						uniq_slot = 1;
					} else if (evdev_mt_slot == 1) {
						dev_type = MULTI_TOUCH;
						uniq_slot = 2;
					}
				}
				pr_booster("Touch Booster Trigger(%d), T(%d) C(%d) V(%d), Idx(%d), Cnt(%d)\n",
					   evdev_mt_slot, vals[i].type, vals[i].code,
					   vals[i].value, i, evt_cnt);
			}
		} else if (vals[i].type == EV_MSC && vals[i].code == MSC_SCAN) {
			next_idx = i++;
			if (!chk_next_data(vals, next_idx, EV_KEY))
				break;
			next_idx = i++;
			target_idx = next_idx;
			switch (vals[next_idx].code) {
			case BTN_LEFT:
			case BTN_RIGHT:
			case BTN_MIDDLE:
				dev_type = MOUSE;
				uniq_slot = vals[next_idx].code;
				break;
			default:
				dev_type = KEYBOARD;
				uniq_slot = vals[next_idx].code;
				break;
			}
		}
found:
		if (dev_type != NONE_TYPE_DEVICE) {
			*keyId = create_uniq_id(vals[i].type, vals[i].code, uniq_slot);
			ret_val = chk_boost_on_off(vals, target_idx, dev_type);
			pr_booster("Dev type Find(%d), KeyID(%u), enable(%d), Target(%d)\n",
				   dev_type, *keyId, ret_val, target_idx);
			break;
		}
	}

	*cur_idx = i + 1;
	*device_type = dev_type;
	return ret_val;
}

/* 5.4 input_booster(): one packet, ib_lock held */
static void input_booster(const struct input_value *vals, int evt_cnt)
{
	int dev_type, cur_idx = 0, enable;
	unsigned int keyId;

	while (cur_idx < evt_cnt) {
		keyId = 0;
		enable = get_device_type(&dev_type, &keyId, &cur_idx, vals, evt_cnt);
		if (enable < 0 || keyId == 0)
			continue;
		if (dev_type <= NONE_TYPE_DEVICE || dev_type >= MAX_DEVICE_TYPE_NUM)
			continue;
		if (enable == BOOSTER_ON)
			evdev_mt_event[dev_type]++;
		else
			evdev_mt_event[dev_type]--;
		pr_booster("Device_Type(%d), KeyId(%u), enable(%d)\n", dev_type, keyId, enable);
		trigger_input_booster(dev_type, keyId, enable);
	}
}

/* ----------------------------------------------------------------------------------------- */
/* event path: input handler -> packet ring -> ib_wq */

#define IB_RING_SIZE	64		/* packets */
#define IB_PKT_PAD	3		/* the 5.4 decoder may look up to 2 entries past the end */

struct ib_pkt {
	unsigned int cnt;
	struct input_value vals[MAX_EVENTS + IB_PKT_PAD];
};

static struct ib_pkt *ib_ring;
static unsigned int ib_ring_head, ib_ring_tail;	/* head: next write, tail: next read */
static DEFINE_SPINLOCK(ib_ring_lock);
static unsigned long ib_ring_drops;
static struct ib_pkt ib_scratch;		/* only used by the (single, ordered) worker */

static void ib_evt_workfn(struct work_struct *work)
{
	unsigned long flags;
	bool have;

	for (;;) {
		spin_lock_irqsave(&ib_ring_lock, flags);
		have = ib_ring_tail != ib_ring_head;
		if (have) {
			struct ib_pkt *p = &ib_ring[ib_ring_tail % IB_RING_SIZE];

			ib_scratch.cnt = p->cnt;
			memcpy(ib_scratch.vals, p->vals, sizeof(p->vals[0]) * p->cnt);
			ib_ring_tail++;
		}
		spin_unlock_irqrestore(&ib_ring_lock, flags);
		if (!have)
			break;
		memset(&ib_scratch.vals[ib_scratch.cnt], 0, sizeof(ib_scratch.vals[0]) * IB_PKT_PAD);

		mutex_lock(&ib_lock);
		if (!ib_dying)
			input_booster(ib_scratch.vals, ib_scratch.cnt);
		mutex_unlock(&ib_lock);
	}
}
static DECLARE_WORK(ib_evt_work, ib_evt_workfn);

/* only packets that can produce a device type (5.4 get_device_type) are queued */
static bool ib_pkt_relevant(const struct input_value *vals, unsigned int count)
{
	unsigned int i;

	for (i = 0; i < count; i++) {
		if (vals[i].type == EV_KEY)
			return true;
		if (vals[i].type == EV_ABS && vals[i].code == ABS_MT_TRACKING_ID)
			return true;
		if (vals[i].type == EV_MSC && vals[i].code == MSC_SCAN)
			return true;
	}
	return false;
}

/* called by the input core with dev->event_lock held, irqs off: copy + queue, never consume */
static unsigned int sec_input_boost_events(struct input_handle *handle,
					   struct input_value *vals, unsigned int count)
{
	unsigned long flags;

	if (!ib_ring || count == 0 || !ib_pkt_relevant(vals, count))
		return count;
	if (count > MAX_EVENTS) {	/* 5.4: "Exceed max event number" */
		ib_ring_drops++;
		return count;
	}

	spin_lock_irqsave(&ib_ring_lock, flags);
	if (ib_ring_head - ib_ring_tail >= IB_RING_SIZE) {
		ib_ring_drops++;
	} else {
		struct ib_pkt *p = &ib_ring[ib_ring_head % IB_RING_SIZE];

		p->cnt = count;
		memcpy(p->vals, vals, sizeof(vals[0]) * count);
		ib_ring_head++;
	}
	spin_unlock_irqrestore(&ib_ring_lock, flags);
	queue_work(ib_wq, &ib_evt_work);
	return count;
}

/*
 * Connection: the handle is registered at connect() but opened only once some other user
 * (Android's EventHub) has the device open, and closed again when we are the last user, so
 * this handler never calls a driver's open()/close() on its own (the stm touch driver's
 * open() is a no-op before its probe finished, an early open would leave it disabled).
 * Polled with a deferrable timer (no idle wake-ups).
 */
struct ib_handle {
	struct input_handle handle;
	struct delayed_work poll;
	bool opened;
	unsigned int tries;
};

static void ib_handle_poll(struct work_struct *work)
{
	struct ib_handle *ih = container_of(to_delayed_work(work), struct ib_handle, poll);
	struct input_dev *dev = ih->handle.dev;
	unsigned int users = READ_ONCE(dev->users);
	unsigned long delay;

	if (!ih->opened && users > 0) {
		if (!input_open_device(&ih->handle))
			ih->opened = true;
	} else if (ih->opened && users <= 1) {
		input_close_device(&ih->handle);
		ih->opened = false;
	}

	if (ih->opened)
		delay = 5 * HZ;
	else
		delay = ih->tries++ < 120 ? HZ : 5 * HZ;
	queue_delayed_work(system_unbound_wq, &ih->poll, delay);
}

static int sec_input_boost_connect(struct input_handler *handler, struct input_dev *dev,
				   const struct input_device_id *id)
{
	struct ib_handle *ih;
	int error;

	ih = kzalloc(sizeof(*ih), GFP_KERNEL);
	if (!ih)
		return -ENOMEM;
	ih->handle.dev = dev;
	ih->handle.handler = handler;
	ih->handle.name = "sec_input_booster";
	ih->handle.private = ih;

	error = input_register_handle(&ih->handle);
	if (error) {
		kfree(ih);
		return error;
	}
	INIT_DEFERRABLE_WORK(&ih->poll, ib_handle_poll);
	queue_delayed_work(system_unbound_wq, &ih->poll, HZ);
	return 0;
}

static void sec_input_boost_disconnect(struct input_handle *handle)
{
	struct ib_handle *ih = handle->private;

	cancel_delayed_work_sync(&ih->poll);
	if (ih->opened)
		input_close_device(handle);
	input_unregister_handle(handle);
	kfree(ih);
}

/* Samsung's own CONFIG_SEC_INPUT_BOOSTER_HANDLER id table (5.4 evdev_booster.c) */
static const struct input_device_id sec_input_boost_ids[] = {
	{	/* multi-touch touchscreen */
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_ABSBIT,
		.evbit = { BIT_MASK(EV_ABS) },
		.absbit = { [BIT_WORD(ABS_MT_POSITION_X)] =
			BIT_MASK(ABS_MT_POSITION_X) | BIT_MASK(ABS_MT_POSITION_Y) },
	},
	{	/* touchpad */
		.flags = INPUT_DEVICE_ID_MATCH_KEYBIT | INPUT_DEVICE_ID_MATCH_ABSBIT,
		.keybit = { [BIT_WORD(BTN_TOUCH)] = BIT_MASK(BTN_TOUCH) },
		.absbit = { [BIT_WORD(ABS_X)] = BIT_MASK(ABS_X) | BIT_MASK(ABS_Y) },
	},
	{	/* keypad */
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT,
		.evbit = { BIT_MASK(EV_KEY) },
	},
	{ },
};

static struct input_handler ib_input_handler = {
	.events		= sec_input_boost_events,
	.connect	= sec_input_boost_connect,
	.disconnect	= sec_input_boost_disconnect,
	.name		= "sec_input_booster",
	.id_table	= sec_input_boost_ids,
};

/* ----------------------------------------------------------------------------------------- */
/* sysfs: /sys/class/input_booster/{enable_event,debug_level,sendevent,ib_mode_state} and
 * /sys/devices/virtual/input_booster/<label>/{head,tail,level}, all 0644 (5.4 S_IRUGO|S_IWUSR) */

#define IB_CLASS_ATTR(_name, _var, _type, _fmt)						\
static ssize_t _name##_show(const struct class *c, const struct class_attribute *a,	\
			    char *buf)							\
{											\
	return sysfs_emit(buf, _fmt, _var);						\
}											\
static ssize_t _name##_store(const struct class *c, const struct class_attribute *a,	\
			     const char *buf, size_t count)				\
{											\
	_type v[1] = { _var };								\
											\
	if (sscanf(buf, _fmt, v) == 1)	/* 5.4: sscanf, always "succeeds" */		\
		_var = v[0];								\
	return count;									\
}											\
static CLASS_ATTR_RW(_name)

IB_CLASS_ATTR(enable_event, enable_event_booster, unsigned int, "%u\n");
IB_CLASS_ATTR(debug_level, debug_flag, unsigned int, "%u\n");
IB_CLASS_ATTR(sendevent, send_ev_enable, int, "%d\n");
IB_CLASS_ATTR(ib_mode_state, u_ib_mode, unsigned int, "%u\n");

static struct attribute *ib_class_attrs[] = {
	&class_attr_enable_event.attr,
	&class_attr_debug_level.attr,
	&class_attr_sendevent.attr,
	&class_attr_ib_mode_state.attr,
	NULL,
};
ATTRIBUTE_GROUPS(ib_class);

static struct class ib_class = {
	.name		= "input_booster",
	.class_groups	= ib_class_groups,
};

static ssize_t ib_head_tail_show(struct device *dev, char *buf, bool tail)
{
	struct t_ib_device_tree *ib_dt = dev_get_drvdata(dev);
	int i, len;

	if (!ib_dt)
		return 0;
	mutex_lock(&ib_lock);
	len = sysfs_emit(buf, "%d", tail ? ib_dt->tail_time : ib_dt->head_time);
	for (i = 0; i < allowed_res_count; i++) {
		struct t_ib_res_info *r = &ib_dt->res[allowed_resources[i]];

		len += sysfs_emit_at(buf, len, " %d", tail ? r->tail_value : r->head_value);
	}
	len += sysfs_emit_at(buf, len, "\n");
	mutex_unlock(&ib_lock);
	return len;
}

/* "time v0 v1 v2 v3": exactly time + one value per allowed resource, else ignored (5.4) */
static ssize_t ib_head_tail_store(struct device *dev, const char *buf, size_t count, bool tail)
{
	struct t_ib_device_tree *ib_dt = dev_get_drvdata(dev);
	int values[MAX_RES_COUNT + 1] = { 0 };
	int time = 0, offset = 0, i, extra;

	if (!ib_dt)
		return count;
	if (sscanf(buf, "%d%n", &time, &offset) != 1)
		goto bad;
	buf += offset;
	for (i = 0; i < allowed_res_count; i++) {
		if (sscanf(buf, "%d%n", &values[allowed_resources[i]], &offset) != 1)
			goto bad;
		buf += offset;
	}
	if (sscanf(buf, "%d", &extra) == 1)
		goto bad;

	mutex_lock(&ib_lock);
	if (tail)
		ib_dt->tail_time = time;
	else
		ib_dt->head_time = time;
	for (i = 0; i < allowed_res_count; i++) {
		struct t_ib_res_info *r = &ib_dt->res[allowed_resources[i]];

		if (tail)
			r->tail_value = values[allowed_resources[i]];
		else
			r->head_value = values[allowed_resources[i]];
	}
	mutex_unlock(&ib_lock);
	return count;
bad:
	pr_booster("### Keep this format : [time cpu_freq ddr_freq hmp_boost lpm_bias] (Ex: 200 1171200 1017 2 5) ###\n");
	return count;
}

static ssize_t head_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return ib_head_tail_show(dev, buf, false);
}

static ssize_t head_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	return ib_head_tail_store(dev, buf, count, false);
}

static ssize_t tail_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return ib_head_tail_show(dev, buf, true);
}

static ssize_t tail_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	return ib_head_tail_store(dev, buf, count, true);
}

/* level: one global value for every device node, 0..2, stored only (as 5.4) */
static ssize_t level_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", level_value);
}

static ssize_t level_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	int level = -1;

	if (sscanf(buf, "%d", &level) == 1 && level >= 0 && level <= 2)
		level_value = level;
	return count;
}

static DEVICE_ATTR_RW(head);
static DEVICE_ATTR_RW(tail);
static DEVICE_ATTR_RW(level);

static struct attribute *dvfs_attrs[] = {
	&dev_attr_head.attr,
	&dev_attr_tail.attr,
	&dev_attr_level.attr,
	NULL,
};
ATTRIBUTE_GROUPS(dvfs);

static struct device *ib_sysfs_dev[MAX_DEVICE_TYPE_NUM];
static bool ib_class_ok, ib_handler_ok;

/* ----------------------------------------------------------------------------------------- */

static int __init input_booster_init(void)
{
	int i;

	for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++)
		INIT_LIST_HEAD(&ib_list[i]);

	/* never fail, never block: every step is optional */
	ib_wq = alloc_ordered_workqueue("ib_unbound_highwq", WQ_HIGHPRI);
	if (ib_wq)
		ib_ring = kvcalloc(IB_RING_SIZE, sizeof(*ib_ring), GFP_KERNEL);
	if (!ib_ring)
		pr_err("no memory/workqueue: sysfs only, no boosting\n");

	if (class_register(&ib_class)) {
		pr_err("class_register failed\n");
	} else {
		ib_class_ok = true;
		for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++) {
			struct device *d = device_create_with_groups(&ib_class, NULL, MKDEV(0, 0),
					&ib_device_trees[i], dvfs_groups, "%s",
					ib_device_trees[i].label);

			if (IS_ERR(d))
				pr_err("cannot create %s\n", ib_device_trees[i].label);
			else
				ib_sysfs_dev[i] = d;
		}
	}

	if (ib_ring) {
		if (input_register_handler(&ib_input_handler))
			pr_err("input_register_handler failed\n");
		else
			ib_handler_ok = true;
	}
	return 0;
}

static void __exit input_booster_exit(void)
{
	long rel[MAX_RES_COUNT] = { [CPUFREQ] = 1, [HMPBOOST] = 1 };
	struct t_ib_info *ib, *tmp;
	int i;

	if (ib_handler_ok)
		input_unregister_handler(&ib_input_handler);

	mutex_lock(&ib_lock);
	ib_dying = true;
	for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++)
		list_for_each_entry(ib, &ib_list[i], list) {
			cancel_delayed_work(&ib->ib_timeout_work[IB_HEAD]);
			cancel_delayed_work(&ib->ib_timeout_work[IB_TAIL]);
		}
	mutex_unlock(&ib_lock);

	if (ib_wq) {
		/* a timer that fired during the cancel above queued its work: let it no-op */
		for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++)
			list_for_each_entry(ib, &ib_list[i], list) {
				cancel_delayed_work_sync(&ib->ib_timeout_work[IB_HEAD]);
				cancel_delayed_work_sync(&ib->ib_timeout_work[IB_TAIL]);
			}
		drain_workqueue(ib_wq);
		destroy_workqueue(ib_wq);
	}

	mutex_lock(&ib_lock);
	for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++)
		list_for_each_entry_safe(ib, tmp, &ib_list[i], list)
			remove_ib_instance(ib);
	if (current_hmp_boost <= 0)
		rel[HMPBOOST] = 0;
	ib_release_booster(rel);
	mutex_unlock(&ib_lock);
	if (p_sched_set_boost)
		symbol_put(sched_set_boost);

	if (ib_class_ok) {
		for (i = 0; i < MAX_DEVICE_TYPE_NUM; i++)
			if (ib_sysfs_dev[i])
				device_unregister(ib_sysfs_dev[i]);
		class_unregister(&ib_class);
	}
	kvfree(ib_ring);
}

module_init(input_booster_init);
module_exit(input_booster_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("hongc.shim (Samsung); a52sxq 6.12 port");
MODULE_DESCRIPTION("SEC input booster (5.4 A52s port: input handler, built-in boost tables)");
