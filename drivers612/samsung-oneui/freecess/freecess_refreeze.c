// SPDX-License-Identifier: GPL-2.0-only
/*
 * Re-freeze cgroup v1 frozen tasks after system resume (SPEC/07-art-suspendall-timeouts.md).
 *
 * Since the 6.1 freezer rewrite a task that sleeps in a TASK_FREEZABLE wait (futex, epoll, nanosleep,
 * binder) is frozen in place: __state = TASK_FROZEN, saved_state = the sleep state. Only a task that was
 * running goes through the fake signal into __refrigerator(). On every system resume thaw_processes()
 * calls __thaw_task() for every task. A refrigerator task wakes, sees cgroup_freezing() and freezes again.
 * An in-place frozen task just gets its sleep state back: it is not frozen any more, and the v1 freezer
 * calls freeze_task() only at attach and at a freezer.state write. So after the first suspend/resume a
 * Freecess-frozen app (/dev/freezer/frozen) is half thawed: the threads that slept in the kernel run
 * again at their next wake-up, the threads that were in user code stay in the refrigerator. ART's
 * HeapTaskDaemon wakes, calls SuspendAll, waits 48 s for frozen threads and aborts the app.
 * The 5.4 kernel froze every task in the refrigerator, where the PM thaw is harmless.
 *
 * freeze_task() is not exported. After the PM thaw this walks all user threads and queues a task work
 * (TWA_SIGNAL: wakes an interruptible sleeper, kicks a running task) on each that is freezing() and not
 * frozen. The work sets TIF_SIGPENDING on the task itself, so get_signal() goes on to try_to_freeze(),
 * which is the kernel's own decision at that moment (no race with a thaw by the framework: a thawed task
 * sees freezing() false and only restarts its syscall, as after the freezer's own fake signal).
 */
#include <linux/atomic.h>
#include <linux/freezer.h>
#include <linux/module.h>
#include <linux/rcupdate.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/slab.h>
#include <linux/suspend.h>
#include <linux/task_work.h>

#include "freecess.h"

static bool refreeze = true;
module_param(refreeze, bool, 0644);
MODULE_PARM_DESC(refreeze, "after system resume freeze again the cgroup v1 frozen tasks the PM thaw let go (0: only count them)");

static atomic_long_t refreeze_runs, refreeze_escaped, refreeze_queued, refreeze_last;

static void refreeze_work(struct callback_head *head)
{
	kfree(head);
	if (freezing(current))
		set_thread_flag(TIF_SIGPENDING);	/* get_signal(): try_to_freeze(), then no signal */
	module_put(THIS_MODULE);
}

static long refreeze_walk(bool act)
{
	struct task_struct *g, *p;
	long escaped = 0, queued = 0;

	rcu_read_lock();
	for_each_process_thread(g, p) {
		struct callback_head *work;

		if (p->flags & (PF_KTHREAD | PF_EXITING))
			continue;
		if (!freezing(p) || (READ_ONCE(p->__state) & TASK_FROZEN))
			continue;
		escaped++;
		if (!act)
			continue;
		work = kmalloc(sizeof(*work), GFP_ATOMIC);
		if (!work)
			continue;
		if (!try_module_get(THIS_MODULE)) {
			kfree(work);
			continue;
		}
		init_task_work(work, refreeze_work);
		if (task_work_add(p, work, TWA_SIGNAL)) {
			kfree(work);
			module_put(THIS_MODULE);
			continue;
		}
		queued++;
	}
	rcu_read_unlock();
	atomic_long_inc(&refreeze_runs);
	atomic_long_add(escaped, &refreeze_escaped);
	atomic_long_add(queued, &refreeze_queued);
	atomic_long_set(&refreeze_last, escaped);
	return escaped;
}

static int refreeze_pm_notify(struct notifier_block *nb, unsigned long event, void *unused)
{
	switch (event) {
	case PM_POST_SUSPEND:
	case PM_POST_HIBERNATION:
	case PM_POST_RESTORE:
		/* pm_freezing is off again here: freezing() is the cgroup v1 state alone */
		refreeze_walk(refreeze);
		break;
	}
	return NOTIFY_DONE;
}

static struct notifier_block refreeze_nb = { .notifier_call = refreeze_pm_notify };

/* echo 1 > parameters/refreeze_now: one walk by hand (test); reads back the count of the last walk */
static int refreeze_now_set(const char *val, const struct kernel_param *kp)
{
	refreeze_walk(refreeze);
	return 0;
}

static int refreeze_now_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%ld\n", atomic_long_read(&refreeze_last));
}

static const struct kernel_param_ops refreeze_now_ops = { .set = refreeze_now_set, .get = refreeze_now_get };
module_param_cb(refreeze_now, &refreeze_now_ops, NULL, 0644);

#define RF_STAT(name, var) \
	static int rf_get_##name(char *buf, const struct kernel_param *kp) \
	{ return sysfs_emit(buf, "%ld\n", atomic_long_read(&var)); } \
	static const struct kernel_param_ops rf_ops_##name = { .get = rf_get_##name }; \
	module_param_cb(stat_##name, &rf_ops_##name, NULL, 0444)
RF_STAT(refreeze_runs, refreeze_runs);		/* walks (system resumes) */
RF_STAT(refreeze_escaped, refreeze_escaped);	/* tasks found freezing() but not frozen, total */
RF_STAT(refreeze_queued, refreeze_queued);	/* of those: sent back to the freezer */

int freecess_refreeze_init(void)
{
	return register_pm_notifier(&refreeze_nb);
}

void freecess_refreeze_exit(void)
{
	unregister_pm_notifier(&refreeze_nb);
}
