// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/cpufreq/cpufreq_limit.c
 *
 * Remade according to cpufreq change
 * (refer to commit df0eea4488081e0698b0b58ccd1e8c8823e22841
 *                 18c49926c4bf4915e5194d1de3299c0537229f9f)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * a52sxq 6.12 port (2026-11-22): Samsung's 5.4 A52s driver (kernel/samsung/sm7325
 * drivers/cpufreq/cpufreq_limit.c, CONFIG_CPU_FREQ_LIMIT=y) as a loadable module, for the stock
 * OneUI vendor (Samsung thermal HAL, libbauthserver fingerprint boost, SSRM, hyper HAL) and
 * input_booster (set_freq_limit(CFLM_TOUCH, ...)). Same nodes, modes, formats and decision logic
 * as 5.4:
 *   /sys/power/{cpufreq_table 0444, cpufreq_min_limit 0644, cpufreq_max_limit 0644,
 *               over_limit 0644, limit_stat 0644}
 *   /sys/devices/system/cpu/cflm/{info 0444, silver_min_lock 0644, sched_boost_type 0644}
 * Differences, all forced by building it as a module on a GKI kernel:
 *  - power_kobj is not exported: the /sys/power kobject comes from its kernfs node (as
 *    a52sxq_volkey).
 *  - 5.4 got the frequency tables from a hook in qcom-cpufreq-hw (cflm_set_table); here they are
 *    read from policy->freq_table of cpu0 (silver) and cpu7 (prime), same filtering, same unified
 *    table.
 *  - one freq QoS request per cluster policy (cpu 0/4/7) and item instead of one per possible CPU;
 *    5.4 only ever updated the first CPU's request of each cluster to a non-default value, so the
 *    aggregated policy limits are the same.
 *  - init never fails: if a policy is not there yet, the nodes exist at once and a delayed work
 *    attaches the requests later (writes in between are kept and applied then).
 *  - store of silver_min_lock / sched_boost_type: 5.4 compared kstrtoint()'s 0 with 1 and so set
 *    the value but returned -EINVAL; here it returns the count.
 * The sched boost (CONSERVATIVE while the prime cluster has a raised min) uses WALT's
 * sched_set_boost (sched-walt.ko), as 5.4.
 */
#define pr_fmt(fmt) "cpufreq_limit: " fmt
#include <linux/module.h>
#include <linux/sysfs.h>
#include <linux/cpufreq.h>
#include <linux/err.h>
#include <linux/cpu.h>
#include <linux/kobject.h>
#include <linux/kernfs.h>
#include <linux/ktime.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pm_qos.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#include "cpufreq_limit.h"

#define MAX_BUF_SIZE	1024
#define CFLM_MIN(a, b)(((a) < (b)) ? (a) : (b))
#define CFLM_MAX(a, b)(((a) > (b)) ? (a) : (b))

/* sched boost type (kernel/sched/walt: include/linux/sched/walt.h) */
extern int sched_set_boost(int type);
#define NO_BOOST (CONSERVATIVE_BOOST * -1)
#define FULL_THROTTLE_BOOST 1
#define CONSERVATIVE_BOOST 2
#define RESTRAINED_BOOST 3

static DEFINE_MUTEX(cflm_mutex);
#define LIMIT_RELEASE	-1

/* clusters: silver 0-3, gold 4-6, prime 7 */
enum { CL_S, CL_G, CL_P, NUM_CL };
static struct freq_qos_request max_req[NUM_CL][CFLM_MAX_ITEM];
static struct freq_qos_request min_req[NUM_CL][CFLM_MAX_ITEM];
static bool cflm_ready;

/* input info: freq, time(TBD) */
struct input_info {
	int min;
	int max;
	u64 time_in_min_limit;
	u64 time_in_max_limit;
	u64 time_in_over_limit;
	ktime_t last_min_limit_time;
	ktime_t last_max_limit_time;
	ktime_t last_over_limit_time;
};
static struct input_info freq_input[CFLM_MAX_ITEM];

struct cflm_parameter {
	/* to make virtual freq table */
	unsigned int	unified_cpuftbl[50];
	unsigned int	freq_count;

	/* cpu info: silver/gold/prime */
	unsigned int	s_first;
	unsigned int	s_fmin;
	unsigned int	s_fmax;
	unsigned int	g_first;
	unsigned int	g_fmin;
	unsigned int	g_fmax;
	unsigned int	p_first;
	unsigned int	p_fmin;
	unsigned int	p_fmax;

	/* exceptional case */
	unsigned int g_fmin_up;	/* fixed gold clock for performance */

	/* in virtual table little(silver)/big(gold & prime) */
	unsigned int	big_min_freq;
	unsigned int	big_max_freq;
	unsigned int	ltl_min_freq;
	unsigned int	ltl_max_freq;

	/* pre-defined value */
	unsigned int	silver_min_lock;
	unsigned int	silver_max_lock;
	unsigned int	silver_divider;

	/* current freq in virtual table */
	unsigned int	min_limit_val;
	unsigned int	max_limit_val;

	/* sched boost type */
	int		sched_boost_type;
	bool		sched_boost_cond;
	bool		sched_boost_enabled;

	/* over limit */
	unsigned int	over_limit;

	/* voltage based clock (DT limit,vol_based_clk; false on the A52s, table not ported) */
	bool		vol_based_clk;
};

static struct cflm_parameter param = {
	.freq_count		= 0,

	.s_first		= 0,
	.g_first		= 4,
	.p_first		= 7,

	.g_fmin_up		= 691200,	/* fixed gold clock for performance */

	.ltl_min_freq		= 0,		/* will be auto updated */
	.ltl_max_freq		= 0,		/* will be auto updated */
	.big_min_freq		= 0,		/* will be auto updated */
	.big_max_freq		= 0,		/* will be auto updated */

	.silver_min_lock	= 1152000,	/* real silver clock */
	.silver_max_lock	= 1804800,
	.silver_divider		= 2,

	.min_limit_val		= -1,
	.max_limit_val		= -1,

	.sched_boost_type	= CONSERVATIVE_BOOST,
	.sched_boost_cond	= false,
	.sched_boost_enabled	= false,

	.over_limit		= 0,

	.vol_based_clk		= false,
};

static unsigned int cl_cpu(int cl)
{
	return cl == CL_S ? param.s_first : cl == CL_G ? param.g_first : param.p_first;
}

static int cpu_cl(unsigned int cpu)
{
	return cpu == param.s_first ? CL_S : cpu == param.g_first ? CL_G : CL_P;
}

static void cflm_qos_update(struct freq_qos_request *req, int value)
{
	if (cflm_ready && freq_qos_request_active(req))
		freq_qos_update_request(req, value);
}

static s32 cflm_freq_qos_read_value(struct freq_constraints *qos, enum freq_qos_req_type type)
{
	return type == FREQ_QOS_MIN ? READ_ONCE(qos->min_freq.target_value)
				    : READ_ONCE(qos->max_freq.target_value);
}

/* 5.4 cflm_set_table + cflm_make_table: unified table = prime table (big_min..big_max, high to
 * low), then silver table / silver_divider (ltl_min..ltl_max, high to low) */
static bool cflm_make_table(struct cpufreq_frequency_table *ftbl_L, struct cpufreq_frequency_table *ftbl_b)
{
	int i, count = 0, freq_count = 0;
	unsigned int max_freq_b = 0, min_freq_b = UINT_MAX;
	unsigned int max_freq_l = 0, min_freq_l = UINT_MAX;
	unsigned int freq;

	if (!ftbl_L || !ftbl_b)
		return false;

	/* update little config */
	for (i = 0; ftbl_L[i].frequency != CPUFREQ_TABLE_END; i++)
		count = i;
	for (i = count; i >= 0; i--) {
		if (ftbl_L[i].frequency == CPUFREQ_ENTRY_INVALID)
			continue;
		if (ftbl_L[i].frequency < min_freq_l)
			min_freq_l = ftbl_L[i].frequency;
		if (ftbl_L[i].frequency > max_freq_l)
			max_freq_l = ftbl_L[i].frequency;
	}
	if (!param.ltl_min_freq)
		param.ltl_min_freq = min_freq_l / param.silver_divider;
	if (!param.ltl_max_freq)
		param.ltl_max_freq = max_freq_l / param.silver_divider;

	/* update big config */
	count = 0;
	for (i = 0; ftbl_b[i].frequency != CPUFREQ_TABLE_END; i++)
		count = i;
	for (i = count; i >= 0; i--) {
		if (ftbl_b[i].frequency == CPUFREQ_ENTRY_INVALID)
			continue;
		if ((ftbl_b[i].frequency < min_freq_b) && (ftbl_b[i].frequency > param.ltl_max_freq))
			min_freq_b = ftbl_b[i].frequency;
		if (ftbl_b[i].frequency > max_freq_b)
			max_freq_b = ftbl_b[i].frequency;
	}
	if (!param.big_min_freq)
		param.big_min_freq = min_freq_b;
	if (!param.big_max_freq)
		param.big_max_freq = max_freq_b;

	pr_info("%s: updated: little(%u-%u), big(%u-%u)\n", __func__,
			param.ltl_min_freq, param.ltl_max_freq, param.big_min_freq, param.big_max_freq);

	/* big cluster table */
	count = 0;
	for (i = 0; ftbl_b[i].frequency != CPUFREQ_TABLE_END; i++)
		count = i;
	for (i = count; i >= 0 && freq_count < ARRAY_SIZE(param.unified_cpuftbl); i--) {
		freq = ftbl_b[i].frequency;
		if (freq == CPUFREQ_ENTRY_INVALID)
			continue;
		if (freq < param.big_min_freq || freq > param.big_max_freq)
			continue;
		param.unified_cpuftbl[freq_count++] = freq;
	}

	/* LITTLE cluster table */
	count = 0;
	for (i = 0; ftbl_L[i].frequency != CPUFREQ_TABLE_END; i++)
		count = i;
	for (i = count; i >= 0 && freq_count < ARRAY_SIZE(param.unified_cpuftbl); i--) {
		if (ftbl_L[i].frequency == CPUFREQ_ENTRY_INVALID)
			continue;
		freq = ftbl_L[i].frequency / param.silver_divider;
		if (freq < param.ltl_min_freq || freq > param.ltl_max_freq)
			continue;
		param.unified_cpuftbl[freq_count++] = freq;
	}

	if (!freq_count) {
		pr_err("%s: cannot make unified table\n", __func__);
		return false;
	}
	param.freq_count = freq_count;
	return true;
}

static ssize_t cflm_get_table(char *buf)
{
	ssize_t len = 0;
	int i = 0;

	if (!param.freq_count)
		return len;

	for (i = 0; i < param.freq_count; i++)
		len += scnprintf(buf + len, MAX_BUF_SIZE - len, "%u ", param.unified_cpuftbl[i]);

	len--;
	len += scnprintf(buf + len, MAX_BUF_SIZE - len, "\n");

	return len;
}

static void cflm_update_boost(void)
{
	/* sched boost */
	if (param.sched_boost_cond) {
		if (!param.sched_boost_enabled) {
			pr_debug("%s: sched boost on\n", __func__);
			sched_set_boost(param.sched_boost_type);
			param.sched_boost_enabled = true;
		}
	} else {
		if (param.sched_boost_enabled) {
			pr_debug("%s: sched boost off\n", __func__);
			sched_set_boost(NO_BOOST);
			param.sched_boost_enabled = false;
		}
	}
}

static void cflm_update_current_freq(void)
{
	struct cpufreq_policy *policy;
	int s_min = 0, s_max = 0;
	int g_min = 0, g_max = 0;
	int p_min = 0, p_max = 0;

	policy = cpufreq_cpu_get(param.s_first);
	if (policy) {
		s_min = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MIN);
		s_max = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MAX);
		cpufreq_cpu_put(policy);
	}

	policy = cpufreq_cpu_get(param.g_first);
	if (policy) {
		g_min = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MIN);
		g_max = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MAX);
		cpufreq_cpu_put(policy);
	}

	policy = cpufreq_cpu_get(param.p_first);
	if (policy) {
		p_min = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MIN);
		p_max = cflm_freq_qos_read_value(&policy->constraints, FREQ_QOS_MAX);
		cpufreq_cpu_put(policy);
	}

	/* 5.4 printed this at pr_info on every decision (several per touch): debug here */
	pr_debug("%s: current freq: s(%d ~ %d), g(%d ~ %d), p(%d ~ %d)\n",
			__func__, s_min, s_max, g_min, g_max, p_min, p_max);

	/* sched boost condition */
	if ((param.sched_boost_type) && (p_min > param.p_fmin))
		param.sched_boost_cond = true;
	else
		param.sched_boost_cond = false;
}

static bool cflm_max_lock_need_restore(void)
{
	if ((int)param.over_limit <= 0)
		return false;

	if (freq_input[CFLM_USERSPACE].min > 0) {
		if (freq_input[CFLM_USERSPACE].min > (int)param.ltl_max_freq)
			return false;
	}

	if (freq_input[CFLM_TOUCH].min > 0) {
		if (freq_input[CFLM_TOUCH].min > (int)param.ltl_max_freq)
			return false;
	}

	return true;
}

static bool cflm_high_pri_min_lock_required(void)
{
	if ((int)param.over_limit <= 0)
		return false;

	if (freq_input[CFLM_USERSPACE].min > 0) {
		if (freq_input[CFLM_USERSPACE].min > (int)param.ltl_max_freq)
			return true;
	}

	if (freq_input[CFLM_TOUCH].min > 0) {
		if (freq_input[CFLM_TOUCH].min > (int)param.ltl_max_freq)
			return true;
	}

	return false;
}

static void cflm_set_max3(int type, int s_max, int g_max, int p_max)
{
	cflm_qos_update(&max_req[CL_S][type], s_max);
	cflm_qos_update(&max_req[CL_G][type], g_max);
	cflm_qos_update(&max_req[CL_P][type], p_max);
}

/* max in the virtual table -> real per-cluster max (5.4: duplicated for new_max and new_user_max) */
static void cflm_virt_max(int virt, int *s_max, int *g_max, int *p_max)
{
	if (virt < param.big_min_freq) {
		*s_max = CFLM_MIN(param.silver_max_lock, virt * param.silver_divider);

		/* if silver clock is limited as fmax, set promised clock for gold cluster */
		if (virt == param.s_fmax / param.silver_divider)
			*g_max = param.g_fmin_up;
		else
			*g_max = param.g_fmin;

		*p_max = param.p_fmin;
	} else {
		*p_max = CFLM_MIN(virt, param.p_fmax);
		*g_max = CFLM_MIN(virt, param.g_fmax);
	}
}

static void cflm_freq_decision(int type, int new_min, int new_max)
{
	int cl = 0;
	int s_min = param.s_fmin;
	int s_max = param.s_fmax;
	int g_min = param.g_fmin;
	int g_max = param.g_fmax;
	int p_min = param.p_fmin;
	int p_max = param.p_fmax;

	bool need_update_user_max = false;
	int new_user_max = FREQ_QOS_MAX_DEFAULT_VALUE;

	pr_debug("%s: input: type(%d), min(%d), max(%d)\n", __func__, type, new_min, new_max);

	/* update input freq */
	if (new_min != 0) {
		freq_input[type].min = new_min;
		if ((new_min == LIMIT_RELEASE || new_min == param.ltl_min_freq) &&
			freq_input[type].last_min_limit_time != 0) {
			freq_input[type].time_in_min_limit += ktime_to_ms(ktime_get() -
				freq_input[type].last_min_limit_time);
			freq_input[type].last_min_limit_time = 0;
		}
		if (new_min != LIMIT_RELEASE && new_min != param.ltl_min_freq &&
			freq_input[type].last_min_limit_time == 0) {
			freq_input[type].last_min_limit_time = ktime_get();
		}
	}

	if (new_max != 0) {
		freq_input[type].max = new_max;
		if ((new_max == LIMIT_RELEASE || new_max == param.big_max_freq) &&
			freq_input[type].last_max_limit_time != 0) {
			freq_input[type].time_in_max_limit += ktime_to_ms(ktime_get() -
				freq_input[type].last_max_limit_time);
			freq_input[type].last_max_limit_time = 0;
		}
		if (new_max != LIMIT_RELEASE && new_max != param.big_max_freq &&
			freq_input[type].last_max_limit_time == 0) {
			freq_input[type].last_max_limit_time = ktime_get();
		}
	}

	if (!cflm_ready)
		return;	/* recorded; applied by cflm_attach() */

	if (new_min > 0) {
		if (new_min < param.ltl_min_freq) {
			pr_debug("%s: too low freq(%d), set to %d\n", __func__, new_min, param.ltl_min_freq);
			new_min = param.ltl_min_freq;
		}

		if ((type == CFLM_USERSPACE || type == CFLM_TOUCH) &&
			cflm_high_pri_min_lock_required()) {
			if (freq_input[CFLM_USERSPACE].max > 0) {
				need_update_user_max = true;
				new_user_max = CFLM_MAX((int)param.over_limit, freq_input[CFLM_USERSPACE].max);
			}
		}

		/* boost @gold/prime */
		if (new_min > param.ltl_max_freq) {
			s_min = param.silver_min_lock;
			g_min = CFLM_MIN(new_min, param.g_fmax);
			p_min = CFLM_MIN(new_min, param.p_fmax);
		} else {
			s_min = new_min * param.silver_divider;
			g_min = param.g_fmin;
			p_min = param.p_fmin;
		}

		cflm_qos_update(&min_req[CL_S][type], s_min);
		cflm_qos_update(&min_req[CL_G][type], g_min);
		cflm_qos_update(&min_req[CL_P][type], p_min);
	} else if (new_min == LIMIT_RELEASE) {
		for (cl = 0; cl < NUM_CL; cl++)
			cflm_qos_update(&min_req[cl][type], FREQ_QOS_MIN_DEFAULT_VALUE);

		if ((type == CFLM_USERSPACE || type == CFLM_TOUCH) &&
			cflm_max_lock_need_restore()) {
			if (freq_input[CFLM_USERSPACE].max > 0) {
				need_update_user_max = true;
				new_user_max = freq_input[CFLM_USERSPACE].max;
			}
		}
	}

	if (new_max > 0) {
		if (new_max > param.big_max_freq) {
			pr_debug("%s: too high freq(%d), set to %d\n", __func__, new_max, param.big_max_freq);
			new_max = param.big_max_freq;
		}

		if ((type == CFLM_USERSPACE) && cflm_high_pri_min_lock_required()) {
			need_update_user_max = true;
			new_user_max = CFLM_MAX((int)param.over_limit, freq_input[CFLM_USERSPACE].max);
		}

		cflm_virt_max(new_max, &s_max, &g_max, &p_max);
		cflm_set_max3(type, s_max, g_max, p_max);
	} else if (new_max == LIMIT_RELEASE) {
		for (cl = 0; cl < NUM_CL; cl++)
			cflm_qos_update(&max_req[cl][type], FREQ_QOS_MAX_DEFAULT_VALUE);
	}

	if ((freq_input[type].min <= (int)param.ltl_max_freq || new_user_max != (int)param.over_limit) &&
		freq_input[type].last_over_limit_time != 0) {
		freq_input[type].time_in_over_limit += ktime_to_ms(ktime_get() -
			freq_input[type].last_over_limit_time);
		freq_input[type].last_over_limit_time = 0;
	}
	if (freq_input[type].min > (int)param.ltl_max_freq && new_user_max == (int)param.over_limit &&
		freq_input[type].last_over_limit_time == 0) {
		freq_input[type].last_over_limit_time = ktime_get();
	}

	if (need_update_user_max) {
		if (new_user_max > param.big_max_freq)
			new_user_max = param.big_max_freq;

		cflm_virt_max(new_user_max, &s_max, &g_max, &p_max);
		pr_debug("%s: freq_update_request : new userspace max %d %d %d\n", __func__, s_max, g_max, p_max);
		cflm_set_max3(CFLM_USERSPACE, s_max, g_max, p_max);
	}

	cflm_update_current_freq();

	cflm_update_boost();
}

static ssize_t cpufreq_table_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return cflm_get_table(buf);
}

static ssize_t cpufreq_max_limit_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, MAX_BUF_SIZE, "%d\n", param.max_limit_val);
}

static ssize_t cpufreq_max_limit_store(struct kobject *kobj, struct kobj_attribute *attr,
					const char *buf, size_t n)
{
	int freq;
	int ret;

	ret = kstrtoint(buf, 10, &freq);
	if (ret < 0) {
		pr_err("%s: cflm: Invalid cpufreq format\n", __func__);
		return -EINVAL;
	}

	mutex_lock(&cflm_mutex);
	param.max_limit_val = freq;
	cflm_freq_decision(CFLM_USERSPACE, 0, freq);
	mutex_unlock(&cflm_mutex);
	return n;
}

static ssize_t cpufreq_min_limit_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, MAX_BUF_SIZE, "%d\n", param.min_limit_val);
}

static ssize_t cpufreq_min_limit_store(struct kobject *kobj, struct kobj_attribute *attr,
					const char *buf, size_t n)
{
	int freq;
	int ret;

	ret = kstrtoint(buf, 10, &freq);
	if (ret < 0) {
		pr_err("%s: cflm: Invalid cpufreq format\n", __func__);
		return -EINVAL;
	}

	mutex_lock(&cflm_mutex);
	cflm_freq_decision(CFLM_USERSPACE, freq, 0);
	param.min_limit_val = freq;
	mutex_unlock(&cflm_mutex);
	return n;
}

static ssize_t over_limit_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, MAX_BUF_SIZE, "%d\n", param.over_limit);
}

static ssize_t over_limit_store(struct kobject *kobj, struct kobj_attribute *attr,
					const char *buf, size_t n)
{
	int freq;
	int ret;

	ret = kstrtoint(buf, 10, &freq);
	if (ret < 0) {
		pr_err("%s: cflm: Invalid cpufreq format\n", __func__);
		return -EINVAL;
	}

	mutex_lock(&cflm_mutex);
	if (param.over_limit != freq) {
		param.over_limit = freq;
		if ((int)param.max_limit_val > 0)
			cflm_freq_decision(CFLM_USERSPACE, 0, param.max_limit_val);
	}
	mutex_unlock(&cflm_mutex);
	return n;
}

static ssize_t limit_stat_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int i, j = 0;

	mutex_lock(&cflm_mutex);
	for (i = 0; i < CFLM_MAX_ITEM; i++) {
		if (freq_input[i].last_min_limit_time != 0) {
			freq_input[i].time_in_min_limit += ktime_to_ms(ktime_get() -
				freq_input[i].last_min_limit_time);
			freq_input[i].last_min_limit_time = ktime_get();
		}

		if (freq_input[i].last_max_limit_time != 0) {
			freq_input[i].time_in_max_limit += ktime_to_ms(ktime_get() -
				freq_input[i].last_max_limit_time);
			freq_input[i].last_max_limit_time = ktime_get();
		}

		if (freq_input[i].last_over_limit_time != 0) {
			freq_input[i].time_in_over_limit += ktime_to_ms(ktime_get() -
				freq_input[i].last_over_limit_time);
			freq_input[i].last_over_limit_time = ktime_get();
		}
	}

	for (j = 0; j < CFLM_MAX_ITEM; j++) {
		len += scnprintf(buf + len, MAX_BUF_SIZE - len, "%llu %llu %llu\n",
				freq_input[j].time_in_min_limit, freq_input[j].time_in_max_limit,
				freq_input[j].time_in_over_limit);
	}

	mutex_unlock(&cflm_mutex);
	return len;
}

/* sysfs in /sys/power */
static struct kobj_attribute cpufreq_table = __ATTR(cpufreq_table, 0444, cpufreq_table_show, NULL);
static struct kobj_attribute cpufreq_min_limit =
	__ATTR(cpufreq_min_limit, 0644, cpufreq_min_limit_show, cpufreq_min_limit_store);
static struct kobj_attribute cpufreq_max_limit =
	__ATTR(cpufreq_max_limit, 0644, cpufreq_max_limit_show, cpufreq_max_limit_store);
static struct kobj_attribute over_limit = __ATTR(over_limit, 0644, over_limit_show, over_limit_store);
/* 5.4: mode 0644 without a store */
static struct kobj_attribute limit_stat = {
	.attr	= { .name = "limit_stat", .mode = 0644 },
	.show	= limit_stat_show,
};

static struct attribute *cflm_power_attrs[] = {
	&cpufreq_table.attr,
	&cpufreq_min_limit.attr,
	&cpufreq_max_limit.attr,
	&over_limit.attr,
	&limit_stat.attr,
	NULL,
};

int set_freq_limit(unsigned int id, unsigned int freq)
{
	if (id >= CFLM_MAX_ITEM)
		return -EINVAL;

	mutex_lock(&cflm_mutex);
	pr_debug("%s: cflm: id(%d) freq(%d)\n", __func__, (int)id, freq);
	cflm_freq_decision(id, freq, 0);
	mutex_unlock(&cflm_mutex);

	return 0;
}
EXPORT_SYMBOL(set_freq_limit);

#define cflm_attr_rw(_name)		\
static struct kobj_attribute _name##_attr =	\
__ATTR(_name, 0644, show_##_name, store_##_name)

#define show_one(file_name)			\
static ssize_t show_##file_name			\
(struct kobject *kobj, struct kobj_attribute *attr, char *buf)	\
{								\
	return scnprintf(buf, PAGE_SIZE, "%u\n", param.file_name);	\
}

#define store_one(file_name)					\
static ssize_t store_##file_name				\
(struct kobject *kobj, struct kobj_attribute *attr,		\
const char *buf, size_t count)					\
{								\
	int ret, v;						\
								\
	ret = kstrtoint(buf, 0, &v);				\
	if (ret)						\
		return -EINVAL;					\
	mutex_lock(&cflm_mutex);				\
	param.file_name = v;					\
	mutex_unlock(&cflm_mutex);				\
	return count;						\
}

show_one(silver_min_lock);
show_one(sched_boost_type);
store_one(silver_min_lock);
store_one(sched_boost_type);
cflm_attr_rw(silver_min_lock);
cflm_attr_rw(sched_boost_type);

static ssize_t show_cflm_info(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int i = 0;

	mutex_lock(&cflm_mutex);

	len += scnprintf(buf, MAX_BUF_SIZE,
			"real: silver(%d ~ %d), gold(%d ~ %d), prime(%d ~ %d)\n",
			param.s_fmin, param.s_fmax,
			param.g_fmin, param.g_fmax,
			param.p_fmin, param.p_fmax);

	len += scnprintf(buf + len, MAX_BUF_SIZE - len,
			"virt: little(%d ~ %d), big(%d ~ %d)\n",
			param.ltl_min_freq, param.ltl_max_freq,
			param.big_min_freq, param.big_max_freq);

	len += scnprintf(buf + len, MAX_BUF_SIZE - len,
			"param: silver boost(%d), div(%d), sched boost(%d)\n",
			param.silver_min_lock, param.silver_divider,
					param.sched_boost_type);

	len += scnprintf(buf + len, MAX_BUF_SIZE - len,
			"param: vbaedc(%d)\n", param.vol_based_clk);

	for (i = 0; i < CFLM_MAX_ITEM; i++) {
		len += scnprintf(buf + len, MAX_BUF_SIZE - len,
				"requested: [%d] min(%d), max(%d)\n",
				i, freq_input[i].min, freq_input[i].max);
	}

	mutex_unlock(&cflm_mutex);

	return len;
}

static struct kobj_attribute cflm_info = __ATTR(info, 0444, show_cflm_info, NULL);

static struct attribute *cflm_attributes[] = {
	&cflm_info.attr,
	&silver_min_lock_attr.attr,
	&sched_boost_type_attr.attr,
	NULL,
};

static struct attribute_group cflm_attr_group = {
	.attrs = cflm_attributes,
};

static struct kobject *power_kobj_p;
static struct kobject *cflm_kobj;
static bool power_files;
static int attach_tries;
static void cflm_attach_work(struct work_struct *w);
static DECLARE_DELAYED_WORK(cflm_work, cflm_attach_work);

static void cflm_remove_qos(void)
{
	int cl, j;

	for (cl = 0; cl < NUM_CL; cl++)
		for (j = 0; j < CFLM_MAX_ITEM; j++) {
			if (freq_qos_request_active(&min_req[cl][j]))
				freq_qos_remove_request(&min_req[cl][j]);
			if (freq_qos_request_active(&max_req[cl][j]))
				freq_qos_remove_request(&max_req[cl][j]);
		}
}

/* all three cluster policies present: add the requests, build the table; caller holds cflm_mutex */
static int cflm_attach(void)
{
	struct cpufreq_policy *pol[NUM_CL] = { };
	int cl, j, ret = 0;

	for (cl = 0; cl < NUM_CL; cl++) {
		pol[cl] = cpufreq_cpu_get(cl_cpu(cl));
		if (!pol[cl] || !pol[cl]->freq_table) {
			ret = -EAGAIN;
			goto out;
		}
	}

	if (!cflm_make_table(pol[CL_S]->freq_table, pol[CL_P]->freq_table)) {
		ret = -EINVAL;
		goto out;
	}

	for (cl = 0; cl < NUM_CL; cl++) {
		struct cpufreq_policy *p = pol[cl];

		for (j = 0; j < CFLM_MAX_ITEM; j++) {
			ret = freq_qos_add_request(&p->constraints, &min_req[cl][j],
						   FREQ_QOS_MIN, p->cpuinfo.min_freq);
			if (ret < 0)
				goto fail;
			ret = freq_qos_add_request(&p->constraints, &max_req[cl][j],
						   FREQ_QOS_MAX, p->cpuinfo.max_freq);
			if (ret < 0)
				goto fail;
		}
		/* 5.4 took policy->min/max at late_initcall time, before any limit: = cpuinfo */
		switch (cpu_cl(cl_cpu(cl))) {
		case CL_S: param.s_fmin = p->cpuinfo.min_freq; param.s_fmax = p->cpuinfo.max_freq; break;
		case CL_G: param.g_fmin = p->cpuinfo.min_freq; param.g_fmax = p->cpuinfo.max_freq; break;
		default:   param.p_fmin = p->cpuinfo.min_freq; param.p_fmax = p->cpuinfo.max_freq; break;
		}
	}
	ret = 0;
	cflm_ready = true;
	pr_info("ready: silver %u-%u gold %u-%u prime %u-%u, table %u entries\n",
		param.s_fmin, param.s_fmax, param.g_fmin, param.g_fmax, param.p_fmin, param.p_fmax,
		param.freq_count);

	/* replay what was written before the policies were there */
	for (j = 0; j < CFLM_MAX_ITEM; j++) {
		if (freq_input[j].min > 0)
			cflm_freq_decision(j, freq_input[j].min, 0);
		if (freq_input[j].max > 0)
			cflm_freq_decision(j, 0, freq_input[j].max);
	}
	goto out;
fail:
	pr_err("freq_qos_add_request failed (%d)\n", ret);
	cflm_remove_qos();
out:
	for (cl = 0; cl < NUM_CL; cl++)
		if (pol[cl])
			cpufreq_cpu_put(pol[cl]);
	return ret;
}

static void cflm_attach_work(struct work_struct *w)
{
	int ret;

	mutex_lock(&cflm_mutex);
	ret = cflm_ready ? 0 : cflm_attach();
	mutex_unlock(&cflm_mutex);
	if (ret == -EAGAIN && ++attach_tries < 240)
		schedule_delayed_work(&cflm_work, msecs_to_jiffies(500));
	else if (ret)
		pr_err("not attached to the cpufreq policies (%d, %d tries): limits are recorded only\n",
		       ret, attach_tries);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return rcu_dereference_raw(kn->__parent); }
#else
static inline struct kernfs_node *a52_kn_parent(struct kernfs_node *kn) { return kn->parent; }
#endif

/* /sys/power: power_kobj is not exported by the GKI (see a52sxq_volkey) */
static struct kobject *cflm_power_kobj(void)
{
	struct kernfs_node *root, *kn;
	struct kobject *k = NULL;

	if (!kernel_kobj || !kernel_kobj->sd)
		return NULL;
	for (root = kernel_kobj->sd; a52_kn_parent(root); root = a52_kn_parent(root))
		;
	kn = kernfs_find_and_get(root, "power");
	if (!kn)
		return NULL;
	if (kernfs_type(kn) == KERNFS_DIR && kn->priv)
		k = kobject_get(kn->priv);
	kernfs_put(kn);
	return k;
}

static int __init cflm_init(void)
{
	struct device *dev_root;
	int ret;

	/* never fail the load (a first-stage insmod error is fatal): log and carry on */
	power_kobj_p = cflm_power_kobj();
	if (power_kobj_p) {
		ret = sysfs_create_files(power_kobj_p, (const struct attribute * const *)cflm_power_attrs);
		if (ret)
			pr_err("Unable to create /sys/power nodes (%d)\n", ret);
		else
			power_files = true;
	} else {
		pr_err("no /sys/power kobject\n");
	}

	dev_root = bus_get_dev_root(&cpu_subsys);
	if (dev_root) {
		cflm_kobj = kobject_create_and_add("cflm", &dev_root->kobj);
		put_device(dev_root);
	}
	if (cflm_kobj && sysfs_create_group(cflm_kobj, &cflm_attr_group))
		pr_err("Unable to create cflm group\n");

	mutex_lock(&cflm_mutex);
	ret = cflm_attach();
	mutex_unlock(&cflm_mutex);
	if (ret == -EAGAIN)
		schedule_delayed_work(&cflm_work, msecs_to_jiffies(500));
	else if (ret)
		pr_err("attach failed (%d): limits are recorded only\n", ret);
	return 0;
}

static void __exit cflm_exit(void)
{
	cancel_delayed_work_sync(&cflm_work);
	if (power_files)
		sysfs_remove_files(power_kobj_p, (const struct attribute * const *)cflm_power_attrs);
	if (power_kobj_p)
		kobject_put(power_kobj_p);
	if (cflm_kobj) {
		sysfs_remove_group(cflm_kobj, &cflm_attr_group);
		kobject_put(cflm_kobj);
	}
	mutex_lock(&cflm_mutex);
	if (param.sched_boost_enabled) {
		sched_set_boost(NO_BOOST);
		param.sched_boost_enabled = false;
	}
	cflm_ready = false;
	cflm_remove_qos();
	mutex_unlock(&cflm_mutex);
}

MODULE_AUTHOR("Sangyoung Son <hello.son@samsung.com");
MODULE_DESCRIPTION("'cpufreq_limit' - A driver to limit cpu frequency (a52sxq 6.12 module port)");
MODULE_LICENSE("GPL");

module_init(cflm_init);
module_exit(cflm_exit);
