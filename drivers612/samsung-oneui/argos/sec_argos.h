/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * sec_argos.h
 *
 * Copyright (c) 2012 Samsung Electronics Co., Ltd
 *              http://www.samsung.com
 *
 * 5.4: include/linux/samsung/sec_argos.h (the two notifier calls). The affinity/block calls
 * existed in 5.4 sec_argos.c without a header or export; they are exported (GPL) here so that
 * a 6.12 driver can opt in.
 */
#ifndef _SEC_ARGOS_H
#define _SEC_ARGOS_H

#include <linux/cpumask.h>
#include <linux/notifier.h>
#include <linux/sched.h>

extern int sec_argos_register_notifier(struct notifier_block *n, char *label);
extern int sec_argos_unregister_notifier(struct notifier_block *n, char *label);

extern int argos_task_affinity_setup_label(struct task_struct *p, const char *label,
					   struct cpumask *affinity_cpu_mask,
					   struct cpumask *default_cpu_mask);
extern int argos_irq_affinity_setup_label(unsigned int irq, const char *label,
					  struct cpumask *affinity_cpu_mask,
					  struct cpumask *default_cpu_mask);
extern void argos_block_enable(char *req_name, bool set);

#endif
