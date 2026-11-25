/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung SEC input booster - a52sxq Linux 6.12 module port.
 *
 * Derived from Samsung's sm7325 (Galaxy A52s, Linux 5.4) sources:
 *   include/linux/input/input_booster.h
 *   drivers/input/input_boost/{evdev_booster.c,input_booster.c,input_booster_qc.c}
 * (MODULE_AUTHOR "hongc.shim", Samsung Electronics, GPL).
 *
 * Only the CONFIG_SEC_INPUT_BOOSTER_QC + non-MODE flavour that the A52s 5.4 kernel was built
 * with (lineage-a52sxq_defconfig: SEC_INPUT_BOOSTER=y, _QC=y, _MODE/_HANDLER not set) is kept.
 */
#ifndef _A52S_INPUT_BOOSTER_H_
#define _A52S_INPUT_BOOSTER_H_

#include <linux/input.h>
#include <linux/list.h>
#include <linux/workqueue.h>

#define ITAG	" [Input Booster] "

/* debug_level (sysfs) gates every per-event message, as 5.4 pr_booster() did. */
#define pr_booster(fmt, ...) do {				\
	if (debug_flag)						\
		printk(KERN_INFO ITAG fmt, ##__VA_ARGS__);	\
} while (0)

#define MAX_MULTI_TOUCH_EVENTS	10
#define MAX_IB_COUNT		100
#define MAX_EVENTS		(MAX_MULTI_TOUCH_EVENTS * 10)
#define INIT_ZERO		0

#define TYPE_BITS 8
#define CODE_BITS 12

enum ib_flag_on_off {
	FLAG_OFF = 0,
	FLAG_ON
};

enum booster_head_or_tail {
	IB_HEAD = 0,
	IB_TAIL,
	IB_MAX
};

enum booster_mode_on_off {
	BOOSTER_OFF = 0,
	BOOSTER_ON,
};

enum {
	NONE_TYPE_DEVICE = -1,
	KEY = 0,
	TOUCH_KEY,
	TOUCH,
	MULTI_TOUCH,
	KEYBOARD,
	MOUSE,
	MOUSH_WHEEL,
	HOVER,
	SPEN,
	MAX_DEVICE_TYPE_NUM
};

/* CONFIG_SEC_INPUT_BOOSTER_QC resource ids */
enum booster_res_type {
	CPUFREQ = 0,
	DDRFREQ,
	HMPBOOST,
	LPMBIAS,
	MAX_RES_COUNT
};

struct t_ib_res_info {
	int res_id;
	const char *label;
	int head_value;
	int tail_value;
};

struct t_ib_device_tree {
	const char *label;
	int type;
	int head_time;
	int tail_time;
	struct t_ib_res_info res[MAX_RES_COUNT];
};

/*
 * One boost instance (5.4 struct t_ib_info). The per-resource "target value" (5.4 struct
 * t_ib_target, kept on qos_list[res]) is folded into the instance: has_tv[res] == entry
 * present on qos_list[res], tv[res] == its value.
 */
struct t_ib_info {
	int key_id;
	int uniq_id;
	int press_flag;
	int rel_flag;
	int isHeadFinished;

	struct t_ib_device_tree *ib_dt;
	struct list_head list;

	bool has_tv[MAX_RES_COUNT];
	long tv[MAX_RES_COUNT];

	struct work_struct ib_state_work[IB_MAX];
	struct delayed_work ib_timeout_work[IB_MAX];
};

#endif /* _A52S_INPUT_BOOSTER_H_ */
