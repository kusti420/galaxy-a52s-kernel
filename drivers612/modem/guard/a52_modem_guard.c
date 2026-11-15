// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52_modem_guard: test-only safety net for running the A52s modem (MPSS) under the Qualcomm
 * 6.12 BSP. A modem crash must end in a subsystem restart (SSR), never in a kernel panic.
 *
 * Why it exists (run ab-s18, 2026-11-13, logs/kxfin-ab-s18-p2-191459/prev-console.txt):
 * the MPSS came up, stalled ("dog_hal_common.c:177: DOG detects stalled initialization",
 * ~66 s after each start), remoteproc recovered it once, the second recovery failed
 * (request_firmware -2) and rproc_qcom_common's vendor hook qcom_check_ssr_status() panicked
 * the kernel ("Panicking, remoteproc 4080000.remoteproc-mss failed to recover!").
 *
 * What it does, all reversible on rmmod, nothing persistent:
 *  1. nopanic=1: sets rproc_qcom_common's exported qcom_device_shutdown_in_progress. In
 *     soc-repo r70 that flag gates exactly four panics, all SSR/notification related:
 *     qcom_check_ssr_status ("failed to recover"), ssr_notif_timeout_handler,
 *     sysmon_notif_timeout_handler, pdr ind_notif_timeout_handler; with it they become WARNs.
 *     (Userspace equivalent: echo 1 > /sys/kernel/qcom_rproc/shutdown_in_progress.)
 *     It does NOT cover qcom_q6v5_pas' "auth and reset failed" panics (TZ accepted the init
 *     but refused auth_and_reset) nor qcom_q6v5's crash handler with recovery disabled.
 *  2. keep_recovery=1: the modem rproc keeps recovery ENABLED. If anything disables it
 *     (subsys_compat restart_level=SYSTEM from ssr_setup, the sysfs "recovery" file), the
 *     android_vh_rproc_recovery_set probe turns it back on: with recovery disabled qcom_q6v5's
 *     crash handler panics unconditionally ("Panicking, remoteproc %s crashed").
 *  3. coredump=0: modem coredump off (rproc dump_conf DISABLED): the default would copy the
 *     246 MiB MPSS region on every crash.
 *  4. retries=N, retry_delay=S: if a recovery leaves the modem OFFLINE while a user still holds
 *     it (pm-service's /dev/subsys_modem fd), boot it again after S seconds, at most N times.
 *     Without this the modem stays dead until reboot (rproc_shutdown refuses a non-running
 *     rproc, rproc_boot only counts a new user).
 * The modem rproc is found by compatible (default "qcom,yupik-modem-pas"); the module polls for
 * it for up to 120 s, so it may be loaded before or after qcom_q6v5_pas probes the MSS.
 */
#include <linux/atomic.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/remoteproc.h>
#include <linux/workqueue.h>
#include <trace/hooks/remoteproc.h>

extern bool qcom_device_shutdown_in_progress;	/* rproc_qcom_common (soc-repo qcom_common.c) */

static bool nopanic = true;
module_param(nopanic, bool, 0444);
MODULE_PARM_DESC(nopanic, "turn the SSR-failure/notification-timeout panics into WARNs");
static bool keep_recovery = true;
module_param(keep_recovery, bool, 0644);
MODULE_PARM_DESC(keep_recovery, "re-enable modem recovery whenever something disables it");
static bool coredump;
module_param(coredump, bool, 0444);
MODULE_PARM_DESC(coredump, "leave the modem coredump enabled (default off: 246 MiB per crash)");
static uint retries = 3;
module_param(retries, uint, 0644);
MODULE_PARM_DESC(retries, "boot attempts after a failed recovery (0 = leave it offline)");
static uint retry_delay = 20;
module_param(retry_delay, uint, 0644);
MODULE_PARM_DESC(retry_delay, "seconds before such a boot attempt");
static char *compat = "qcom,yupik-modem-pas";
module_param(compat, charp, 0444);
MODULE_PARM_DESC(compat, "compatible of the modem remoteproc node");

static struct rproc *mss;
static bool set_flag;
static uint tries;
static uint polls;
static void find_work_fn(struct work_struct *w);
static void retry_work_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(find_work, find_work_fn);
static DECLARE_DELAYED_WORK(retry_work, retry_work_fn);

static const char *st(struct rproc *r)
{
	switch (r->state) {
	case RPROC_OFFLINE: return "offline";
	case RPROC_SUSPENDED: return "suspended";
	case RPROC_RUNNING: return "running";
	case RPROC_CRASHED: return "crashed";
	case RPROC_DELETED: return "deleted";
	case RPROC_ATTACHED: return "attached";
	case RPROC_DETACHED: return "detached";
	default: return "invalid";
	}
}

static void apply(struct rproc *r)
{
	if (!coredump && r->dump_conf != RPROC_COREDUMP_DISABLED) {
		r->dump_conf = RPROC_COREDUMP_DISABLED;
		pr_info("a52_modem_guard: %s: coredump disabled\n", r->name);
	}
	if (keep_recovery && r->recovery_disabled) {
		r->recovery_disabled = false;
		pr_warn("a52_modem_guard: %s: recovery was disabled, enabled again (SSR, no panic)\n",
			r->name);
	}
}

/* runs after rproc_qcom_common's probe (same priority, registered later) */
static void on_recovery_set(void *data, struct rproc *r)
{
	if (r == READ_ONCE(mss))
		apply(r);
}

/* called by rproc_crash_handler_work after rproc_trigger_recovery(), rproc->lock released */
static void on_recovery(void *data, struct rproc *r)
{
	if (r != READ_ONCE(mss))
		return;
	pr_warn("a52_modem_guard: %s: crash #%u handled, state %s, users %d\n", r->name,
		r->crash_cnt, st(r), atomic_read(&r->power));
	if (r->state != RPROC_RUNNING && atomic_read(&r->power) > 0) {
		if (tries < retries) {
			pr_warn("a52_modem_guard: %s: recovery failed; boot attempt %u/%u in %u s\n",
				r->name, tries + 1, retries, retry_delay);
			schedule_delayed_work(&retry_work, msecs_to_jiffies(retry_delay * 1000));
		} else {
			pr_warn("a52_modem_guard: %s: recovery failed; no attempts left, modem stays %s\n",
				r->name, st(r));
		}
	}
}

static void retry_work_fn(struct work_struct *w)
{
	struct rproc *r = mss;
	int users, ret;

	if (!r || r->state != RPROC_OFFLINE)
		return;
	users = atomic_read(&r->power);
	if (users <= 0)
		return;
	tries++;
	/*
	 * Test-only accounting trick: the users still hold their references, but rproc_boot()
	 * only boots when the count goes 0 -> 1. Hand the count to rproc_boot and put the other
	 * users back afterwards, so their later close() balances as before.
	 */
	atomic_set(&r->power, 0);
	ret = rproc_boot(r);
	if (ret) {
		atomic_set(&r->power, users);
		pr_err("a52_modem_guard: %s: boot attempt %u failed: %d\n", r->name, tries, ret);
		if (tries < retries)
			schedule_delayed_work(&retry_work, msecs_to_jiffies(retry_delay * 1000));
		return;
	}
	atomic_add(users - 1, &r->power);
	pr_warn("a52_modem_guard: %s: boot attempt %u: state %s, users %d\n", r->name, tries,
		st(r), atomic_read(&r->power));
}

static void find_work_fn(struct work_struct *w)
{
	struct device_node *np = of_find_compatible_node(NULL, NULL, compat);
	struct rproc *r = NULL;

	if (np) {
		bool avail = of_device_is_available(np);

		if (avail)
			r = rproc_get_by_phandle(np->phandle);
		else
			pr_warn("a52_modem_guard: %pOF is disabled (status); nothing to guard\n", np);
		of_node_put(np);
		if (!avail)
			return;
	}
	if (!r) {
		if (++polls < 120) {
			schedule_delayed_work(&find_work, HZ);
			return;
		}
		pr_warn("a52_modem_guard: no remoteproc for %s after 120 s\n", compat);
		return;
	}
	WRITE_ONCE(mss, r);
	apply(r);
	pr_info("a52_modem_guard: guarding %s (%s, recovery %s, coredump %s, retries %u)\n",
		r->name, st(r), r->recovery_disabled ? "disabled" : "enabled",
		r->dump_conf == RPROC_COREDUMP_DISABLED ? "off" : "on", retries);
}

static int __init guard_init(void)
{
	int ret;

	ret = register_trace_android_vh_rproc_recovery_set(on_recovery_set, NULL);
	if (ret)
		return ret;
	ret = register_trace_android_vh_rproc_recovery(on_recovery, NULL);
	if (ret) {
		unregister_trace_android_vh_rproc_recovery_set(on_recovery_set, NULL);
		return ret;
	}
	if (nopanic && !qcom_device_shutdown_in_progress) {
		qcom_device_shutdown_in_progress = true;
		set_flag = true;
		pr_warn("a52_modem_guard: SSR panics off (qcom_device_shutdown_in_progress=1)\n");
	}
	schedule_delayed_work(&find_work, 0);
	return 0;
}

static void __exit guard_exit(void)
{
	cancel_delayed_work_sync(&find_work);
	cancel_delayed_work_sync(&retry_work);
	unregister_trace_android_vh_rproc_recovery(on_recovery, NULL);
	unregister_trace_android_vh_rproc_recovery_set(on_recovery_set, NULL);
	tracepoint_synchronize_unregister();
	if (set_flag)
		qcom_device_shutdown_in_progress = false;
	if (mss)
		rproc_put(mss);
}

module_init(guard_init);
module_exit(guard_exit);
MODULE_DESCRIPTION("A52s test-only modem SSR guard: no panic on modem crash, recovery kept on");
MODULE_LICENSE("GPL");
