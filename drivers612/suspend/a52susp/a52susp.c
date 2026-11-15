// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52susp: safety net for the first system-suspend tests of the 6.12 test Android on the
 * Galaxy A52s 5G (a52sxq-mainline project). Test-only; never part of a real boot.
 * The same source builds for the 6.18 test Android (bsp618/port copy, LINUX_VERSION_CODE
 * guards below: hrtimer_setup since v6.13, void alarm callbacks since v6.18).
 *
 * Why it exists (drivers612/suspend/README.md has the full audit):
 *  - hung_task detection is switched off from PM_SUSPEND_PREPARE to PM_POST_SUSPEND
 *    (kernel/hung_task.c hungtask_pm_notify), and this GKI has no CONFIG_DPM_WATCHDOG, so a
 *    driver that blocks inside a suspend/resume callback is caught by nothing: the helper's
 *    hung_task_panic does not cover suspend.  -> "deadman": two pinned timers that panic
 *    (panic=-1 reboots) when a suspend/resume transition takes longer than deadman_s.
 *  - a suspend that is never woken needs the owner's keys.  -> "backstop": an hrtimer that
 *    calls pm_system_wakeup() (works while the tick runs, i.e. in the shallow s2idle mode of
 *    the test plan, where the deepest cpuidle state is disabled), plus an ALARM_BOOTTIME alarm
 *    that alarmtimer_suspend() programs into the PMIC RTC (also works with the tick frozen).
 *  - only s2idle is wanted: Qualcomm's r70 drivers take "deepsleep" teardown paths for
 *    PM_SUSPEND_MEM.  -> .prepare refuses any other target state.
 *  - the wake source must really be armed.  -> .suspend_noirq refuses (-EBUSY) unless the IRQ
 *    given as wake_irq (the pm8xxx_rtc_alarm line of /proc/interrupts) is wake-set and armed.
 *  - Android's own autosuspend must not start a suspend in the middle of a test.  -> gate:
 *    PM_SUSPEND_PREPARE is refused unless the writer of /sys/power/state is allow_tgid.
 *  - the r70 dwc3-msm refuses system suspend while the PC link is up (dwc3_core_prepare
 *    -EBUSY "peripheral mode still active", dwc3_msm_pm_suspend -EBUSY "USB is outside LPM";
 *    its device-mode bus-suspend path is dead code: mdwc->suspend is never written).
 *    -> usbkeep=1 marks the USB controller devices as syscore devices, so the PM core skips
 *    their sleep callbacks entirely: USB stays powered and enumerated through the suspend
 *    (no detach, no re-enumeration). usbkeep=0 or rmmod restores the old flags.
 *  - optional wdt_pet: pet the Gunyah virtual watchdog at suspend_late/resume_early, exactly
 *    as the phone's 5.4 hh_virt_wdt driver does. It never arms the watchdog.
 *
 * Parameters (all in /sys/module/a52susp/parameters, writable at runtime):
 *   allow_tgid  process allowed to suspend (0 = nobody, -1 = anybody)
 *   allow_deep  0: refuse every target state except s2idle
 *   wake_irq    Linux IRQ number that must be wake-armed at suspend_noirq (0 = no check)
 *   backstop_ms hrtimer wake-up (0 = off)          alarm_s   RTC alarm wake-up (0 = off)
 *   deadman_s   panic after this long in one transition (0 = off)
 *   usbkeep     1 = skip PM of keep_devs           keep_devs comma list of platform devices
 *   wdt_pet     1 = pet the hypervisor watchdog at suspend_late/resume_early
 */
#define pr_fmt(fmt) "a52susp: " fmt

#include <linux/alarmtimer.h>
#include <linux/arm-smccc.h>
#include <linux/cpumask.h>
#include <linux/device.h>
#include <linux/hrtimer.h>
#include <linux/irq.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/rtc.h>
#include <linux/pm_wakeup.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/suspend.h>
#include <linux/sysrq.h>
#include <linux/timer.h>
#include <linux/version.h>

static int allow_tgid;
module_param(allow_tgid, int, 0644);
MODULE_PARM_DESC(allow_tgid, "only this process may suspend (0 = nobody, -1 = anybody)");
static bool allow_deep;
module_param(allow_deep, bool, 0644);
static int wake_irq;
module_param(wake_irq, int, 0644);
static unsigned int backstop_ms = 30000;
module_param(backstop_ms, uint, 0644);
static unsigned int alarm_s = 45;
module_param(alarm_s, uint, 0644);
static unsigned int deadman_s = 120;
module_param(deadman_s, uint, 0644);
static bool wdt_pet;
module_param(wdt_pet, bool, 0644);
static char keep_devs[128] = "a600000.ssusb,a600000.dwc3";
module_param_string(keep_devs, keep_devs, sizeof(keep_devs), 0644);

#define MAX_KEEP 4
static struct {
	struct device *dev;
	bool old;
} kept[MAX_KEEP];
static int nkept;
static bool usbkeep;

static struct hrtimer backstop;
static struct alarm rtc_alarm;
static bool alarm_ready;
static struct timer_list deadman[2];
static atomic_t deadman_fired = ATOMIC_INIT(0);
static bool armed;		/* a suspend we allowed is in progress */
static ktime_t t_prepare;
static struct platform_device *pdev;

/* ---- usbkeep ---------------------------------------------------------------------------- */
static void usbkeep_restore(void)
{
	int i;

	for (i = 0; i < nkept; i++) {
		dev_pm_syscore_device(kept[i].dev, kept[i].old);
		pr_info("usbkeep: %s syscore=%d again\n", dev_name(kept[i].dev), kept[i].old);
		put_device(kept[i].dev);
	}
	nkept = 0;
}

static int usbkeep_apply(void)
{
	char buf[sizeof(keep_devs)], *p = buf, *name;
	struct device *dev;

	strscpy(buf, keep_devs, sizeof(buf));
	while ((name = strsep(&p, ",")) && nkept < MAX_KEEP) {
		name = strim(name);
		if (!*name)
			continue;
		dev = bus_find_device_by_name(&platform_bus_type, NULL, name);
		if (!dev) {
			pr_err("usbkeep: %s not found: nothing changed\n", name);
			usbkeep_restore();
			return -ENODEV;
		}
		kept[nkept].dev = dev;
		kept[nkept].old = dev->power.syscore;
		dev_pm_syscore_device(dev, true);
		pr_info("usbkeep: %s now skipped by system sleep (was syscore=%d)\n", name,
			kept[nkept].old);
		nkept++;
	}
	return nkept ? 0 : -EINVAL;
}

static int usbkeep_set(const char *val, const struct kernel_param *kp)
{
	unsigned int fl;
	bool on;
	int ret = kstrtobool(val, &on);

	if (ret)
		return ret;
	fl = lock_system_sleep();	/* never change the flags in the middle of a transition */
	if (on && !usbkeep)
		ret = usbkeep_apply();
	else if (!on && usbkeep)
		usbkeep_restore();
	if (!ret)
		usbkeep = on;
	unlock_system_sleep(fl);
	return ret;
}

static int usbkeep_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%d\n", usbkeep);
}

static const struct kernel_param_ops usbkeep_ops = { .set = usbkeep_set, .get = usbkeep_get };
module_param_cb(usbkeep, &usbkeep_ops, NULL, 0644);

/* ---- hypervisor watchdog pet (5.4 hh_virt_wdt: pet at suspend_late and resume_early) ------ */
#define VIRT_WDT_PET ARM_SMCCC_CALL_VAL(ARM_SMCCC_FAST_CALL, ARM_SMCCC_SMC_32, \
					 ARM_SMCCC_OWNER_VENDOR_HYP, 0x0007)
static void hyp_wdt_pet(void)
{
	struct arm_smccc_res res;

	if (wdt_pet)
		arm_smccc_1_1_smc(VIRT_WDT_PET, 0, 0, &res);
}

/* ---- deadman, backstops ----------------------------------------------------------------- */
static void deadman_fn(struct timer_list *t)
{
	if (atomic_xchg(&deadman_fired, 1))
		return;
	pr_emerg("DEADMAN: suspend/resume transition not finished after %u s (awake time)\n",
		 deadman_s);
	pr_emerg("DEADMAN: blocked tasks follow; the last 'calling' line of pm_print_times is the culprit\n");
	handle_sysrq('w');
	panic("a52susp: suspend/resume transition stuck");
}

static enum hrtimer_restart backstop_fn(struct hrtimer *t)
{
	pr_warn("backstop: %u ms passed, forcing a wake-up\n", backstop_ms);
	pm_system_wakeup();
	return HRTIMER_NORESTART;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
static void alarm_fn(struct alarm *a, ktime_t now)
#else
static enum alarmtimer_restart alarm_fn(struct alarm *a, ktime_t now)
#endif
{
	pr_warn("RTC alarm backstop (%u s) expired\n", alarm_s);
	pm_system_wakeup();
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
	return ALARMTIMER_NORESTART;
#endif
}

static void start_guards(void)
{
	unsigned int c0 = cpumask_first(cpu_online_mask), c1 = cpumask_last(cpu_online_mask);

	atomic_set(&deadman_fired, 0);
	if (deadman_s) {
		deadman[0].expires = jiffies + deadman_s * HZ;
		add_timer_on(&deadman[0], c0);
		if (c1 != c0) {
			deadman[1].expires = jiffies + deadman_s * HZ;
			add_timer_on(&deadman[1], c1);
		}
	}
	if (backstop_ms)
		hrtimer_start(&backstop, ms_to_ktime(backstop_ms), HRTIMER_MODE_REL);
	if (alarm_s && alarm_ready)
		alarm_start_relative(&rtc_alarm, ktime_set(alarm_s, 0));
}

static void stop_guards(void)
{
	timer_delete_sync(&deadman[0]);
	timer_delete_sync(&deadman[1]);
	hrtimer_cancel(&backstop);
	if (alarm_ready)
		alarm_cancel(&rtc_alarm);
}

/* ---- PM notifier: gate + guards --------------------------------------------------------- */
static int pm_nb_fn(struct notifier_block *nb, unsigned long action, void *data)
{
	switch (action) {
	case PM_HIBERNATION_PREPARE:
	case PM_RESTORE_PREPARE:
		pr_warn("hibernation refused\n");
		return notifier_from_errno(-EPERM);
	case PM_SUSPEND_PREPARE:
		if (allow_tgid != -1 && current->tgid != allow_tgid) {
			pr_info_ratelimited("refused suspend by %s[%d] (allow_tgid=%d)\n",
					    current->comm, current->tgid, allow_tgid);
			return notifier_from_errno(-EBUSY);
		}
		if (alarm_s && !alarmtimer_get_rtcdev()) {
			pr_err("no wake-capable RTC behind alarmtimer: suspend refused\n");
			return notifier_from_errno(-ENODEV);
		}
		armed = true;
		t_prepare = ktime_get_boottime();
		/* (no pm_wakeup_pending() here: it clears events_check_enabled as a side effect) */
		pr_info("suspend by %s[%d]: deadman %u s, backstop %u ms, rtc alarm %u s, wake_irq %d, usbkeep %d\n",
			current->comm, current->tgid, deadman_s, backstop_ms, alarm_s, wake_irq,
			usbkeep);
		start_guards();
		return NOTIFY_OK;
	case PM_POST_SUSPEND:
		if (!armed)
			return NOTIFY_OK;
		stop_guards();
		armed = false;
		pr_info("back after %lld ms (boottime), wakeup irq %u\n",
			ktime_ms_delta(ktime_get_boottime(), t_prepare), pm_wakeup_irq());
		return NOTIFY_OK;
	}
	return NOTIFY_DONE;
}

static struct notifier_block pm_nb = {
	.notifier_call = pm_nb_fn,
	.priority = INT_MAX,	/* first in the chain: a refusal stops everything else */
};

/* ---- dummy device: target-state check, wake IRQ interlock, watchdog pet ------------------ */
static int a52susp_prepare(struct device *dev)
{
	if (!allow_deep && pm_suspend_target_state != PM_SUSPEND_TO_IDLE) {
		pr_err("target state %d is not s2idle: refused (echo s2idle > /sys/power/mem_sleep)\n",
		       pm_suspend_target_state);
		return -EINVAL;
	}
	return 0;
}

static int a52susp_suspend_late(struct device *dev)
{
	hyp_wdt_pet();
	return 0;
}

static int a52susp_suspend_noirq(struct device *dev)
{
	struct irq_data *d;

	if (wake_irq <= 0)
		return 0;
	d = irq_get_irq_data(wake_irq);
	if (!d) {
		pr_err("wake_irq %d does not exist: suspend refused\n", wake_irq);
		return -ENODEV;
	}
	if (!irqd_is_wakeup_set(d) || !irqd_is_wakeup_armed(d)) {
		pr_err("wake_irq %d is not wake-armed (set %d armed %d): suspend refused\n",
		       wake_irq, irqd_is_wakeup_set(d), irqd_is_wakeup_armed(d));
		return -EBUSY;
	}
	pr_info("wake_irq %d armed, entering the last suspend phase\n", wake_irq);
	return 0;
}

static int a52susp_resume_noirq(struct device *dev)
{
	pr_info("resume_noirq\n");
	return 0;
}

static int a52susp_resume_early(struct device *dev)
{
	hyp_wdt_pet();
	return 0;
}

static const struct dev_pm_ops a52susp_pm_ops = {
	.prepare = a52susp_prepare,
	.suspend_late = a52susp_suspend_late,
	.suspend_noirq = a52susp_suspend_noirq,
	.resume_noirq = a52susp_resume_noirq,
	.resume_early = a52susp_resume_early,
};

static struct platform_driver a52susp_driver = {
	.driver = { .name = "a52susp", .pm = &a52susp_pm_ops },
};

static int __init a52susp_init(void)
{
	int ret;

	timer_setup(&deadman[0], deadman_fn, TIMER_PINNED);
	timer_setup(&deadman[1], deadman_fn, TIMER_PINNED);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
	hrtimer_setup(&backstop, backstop_fn, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
#else
	hrtimer_init(&backstop, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	backstop.function = backstop_fn;
#endif
	alarm_init(&rtc_alarm, ALARM_BOOTTIME, alarm_fn);
	alarm_ready = true;

	ret = platform_driver_register(&a52susp_driver);
	if (ret)
		return ret;
	pdev = platform_device_register_simple("a52susp", -1, NULL, 0);
	if (IS_ERR(pdev)) {
		platform_driver_unregister(&a52susp_driver);
		return PTR_ERR(pdev);
	}
	ret = register_pm_notifier(&pm_nb);
	if (ret) {
		platform_device_unregister(pdev);
		platform_driver_unregister(&a52susp_driver);
		return ret;
	}
	pr_info("loaded: every suspend refused until allow_tgid is set; rtc for alarms: %s\n",
		alarmtimer_get_rtcdev() ? dev_name(&alarmtimer_get_rtcdev()->dev) : "NONE");
	return 0;
}

static void __exit a52susp_exit(void)
{
	unsigned int fl = lock_system_sleep();

	unregister_pm_notifier(&pm_nb);
	if (armed)
		stop_guards();
	armed = false;
	if (usbkeep)
		usbkeep_restore();
	usbkeep = false;
	unlock_system_sleep(fl);
	platform_device_unregister(pdev);
	platform_driver_unregister(&a52susp_driver);
	pr_info("unloaded\n");
}

module_init(a52susp_init);
module_exit(a52susp_exit);
MODULE_DESCRIPTION("a52sxq test-only suspend safety net (gate, deadman, wake backstops, usbkeep)");
MODULE_LICENSE("GPL");
