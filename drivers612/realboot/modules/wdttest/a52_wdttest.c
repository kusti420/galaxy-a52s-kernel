// SPDX-License-Identifier: GPL-2.0
/*
 * a52_wdttest: deliberate hang for the hardware (hypervisor) watchdog test. TEST PHONES ONLY, never in
 * a vendor_boot list. Loading it IS the test:
 *   insmod a52_wdttest.ko mode=1 secs=40 [cpu=N]  one CPU spins with IRQs + preemption off for secs
 *        seconds (the watchdog core's IPI ping then cannot complete -> no pet -> bark on another
 *        CPU -> bite). With secs below the bark time (11 s) nothing may happen: the "no false
 *        trip" check.
 *   insmod a52_wdttest.ko mode=2 secs=0           every online CPU spins with IRQs off (secs=0 = for
 *        ever): nothing in Linux runs any more, only the watchdog BITE (14 s) can end it.
 *   mode=3 secs=N   one CPU spins with IRQs ON, preemption off (soft lockup only; the pet thread's
 *        IPI still gets through: must NOT bite).
 * The spin uses a calibrated cpu_relax loop on the arch counter (no jiffies: IRQs are off).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/smp.h>
#include <linux/cpumask.h>
#include <linux/irqflags.h>
#include <linux/preempt.h>
#include <linux/sched/clock.h>
#include <linux/timekeeping.h>
#include <linux/nmi.h>
#include <linux/delay.h>
#include <asm/arch_timer.h>

static int mode;
module_param(mode, int, 0444);
static int secs = 30;
module_param(secs, int, 0444);
static int cpu = -1;
module_param(cpu, int, 0444);

static u64 a52_now(void) { return __arch_counter_get_cntvct(); }

static void a52_spin(u64 ticks, bool forever)
{
	u64 t0 = a52_now();

	while (forever || a52_now() - t0 < ticks)
		cpu_relax();
}

static void a52_hang_irqoff(void *arg)
{
	u64 ticks = (u64)secs * arch_timer_get_cntfrq();

	/* called with IRQs off (IPI) or we switch them off here */
	local_irq_disable();
	a52_spin(ticks, secs == 0);
	local_irq_enable();
}

static int __init a52_wdttest_init(void)
{
	u64 ticks = (u64)secs * arch_timer_get_cntfrq();
	unsigned long flags;

	switch (mode) {
	case 1:
		if (secs <= 0)
			return -EINVAL;
		if (cpu >= 0 && cpu_online(cpu) && cpu != raw_smp_processor_id()) {
			pr_emerg("a52_wdttest: mode 1: CPU%d spins %d s with IRQs off (async IPI), uptime %llu ms\n",
				 cpu, secs, ktime_get_boottime_ns() / 1000000);
			smp_call_function_single(cpu, a52_hang_irqoff, NULL, 0);
			return 0;
		}
		pr_emerg("a52_wdttest: mode 1: this CPU (%d) spins %d s with IRQs + preemption off, uptime %llu ms\n",
			 raw_smp_processor_id(), secs, ktime_get_boottime_ns() / 1000000);
		preempt_disable();
		local_irq_save(flags);
		a52_spin(ticks, false);
		local_irq_restore(flags);
		preempt_enable();
		pr_emerg("a52_wdttest: mode 1: survived %d s (no bite)\n", secs);
		return 0;
	case 2:
		pr_emerg("a52_wdttest: mode 2: ALL %u online CPUs spin with IRQs off %s, uptime %llu ms: only a watchdog bite ends this\n",
			 num_online_cpus(), secs ? "for secs" : "FOR EVER", ktime_get_boottime_ns() / 1000000);
		/* give the console (ramoops, RAM console) a moment */
		mdelay(200);
		preempt_disable();
		smp_call_function(a52_hang_irqoff, NULL, 0);
		a52_hang_irqoff(NULL);
		preempt_enable();
		pr_emerg("a52_wdttest: mode 2: survived %d s (no bite)\n", secs);
		return 0;
	case 3:
		if (secs <= 0)
			return -EINVAL;
		pr_emerg("a52_wdttest: mode 3: this CPU (%d) spins %d s with preemption off, IRQs ON, uptime %llu ms\n",
			 raw_smp_processor_id(), secs, ktime_get_boottime_ns() / 1000000);
		preempt_disable();
		a52_spin(ticks, false);
		preempt_enable();
		pr_emerg("a52_wdttest: mode 3: survived %d s\n", secs);
		return 0;
	default:
		pr_info("a52_wdttest: mode=1|2|3 secs=N [cpu=N]; nothing done\n");
		return -EINVAL;
	}
}

static void __exit a52_wdttest_exit(void) { }

module_init(a52_wdttest_init);
module_exit(a52_wdttest_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("a52sxq: deliberate CPU hang to prove the watchdog bite (test phones only)");
