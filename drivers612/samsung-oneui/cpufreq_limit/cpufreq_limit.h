/* SPDX-License-Identifier: GPL-2.0-only */
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
 * a52sxq 6.12 module port: the request ids of the 5.4 header (include/linux/cpufreq_limit.h).
 */
#ifndef __LINUX_CPUFREQ_LIMIT_H__
#define __LINUX_CPUFREQ_LIMIT_H__

enum {
	CFLM_USERSPACE		= 0,	/* user(/sys/power/cpufreq*limit) */
	CFLM_TOUCH		= 1,	/* touch */
	CFLM_FINGER		= 2,	/* fingerprint */
	CFLM_ARGOS		= 3,	/* argos */

	CFLM_MAX_ITEM
};

int set_freq_limit(unsigned int id, unsigned int freq);

#endif /* __LINUX_CPUFREQ_LIMIT_H__ */
