// SPDX-License-Identifier: GPL-2.0-only
/*
 * Freecess kernel hooks for GKI android16-6.12 without an Image patch.
 *
 * Samsung patches binder.c, binder_alloc.c and signal.c (5.4 A52s and S26 6.12 alike). Here the same
 * reports hang on Android vendor hooks that sit at the same places:
 *
 *   Samsung call site                                  GKI 6.12 hook
 *   binder_transaction: freecess_sync_binder_report    android_vh_binder_trans (the line above it in S26)
 *   binder_transaction: freecess_async_binder_report   android_vh_binder_trans (earlier: before the buffer
 *                                                      is allocated; the token is read from the sender's
 *                                                      user buffer without faulting)
 *   binder_alloc_new_buf_locked: "free_buffer_full"    android_vh_binder_alloc_new_buf_locked
 *   do_send_sig_info: sig_report                       android_vh_do_send_sig_info (same line)
 *   binders_in_transcation() (static binder_procs)     android_vh_binder_preset hands out &binder_procs
 *                                                      and &binder_procs_lock at every binder open
 *
 * Vendor hooks run with preemption off: nothing here sleeps (the CFB walk runs from the netlink
 * request, in process context).
 */
#define pr_fmt(fmt) "freecess: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/cred.h>
#include <linux/pid.h>
#include <linux/uaccess.h>
#include <linux/tracepoint.h>
#include <uapi/linux/android/binder.h>
#include "binder_internal.h"
#include <trace/hooks/binder.h>
#include <trace/hooks/signal.h>
#include "freecess.h"

static struct hlist_head *fc_binder_procs;
static struct mutex *fc_binder_procs_lock;

static int binder_procs_known_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(fc_binder_procs) != NULL);
}
static const struct kernel_param_ops binder_procs_known_ops = { .get = binder_procs_known_get };
module_param_cb(binder_procs_known, &binder_procs_known_ops, NULL, 0444);

/*
 * 1) Skip first 8(P)/12(Q)/16(R+) bytes (strict mode policy, work source, header marker, length)
 * 2) Java layer uses 2 bytes char. And only the first byte has the data. (p+=2)
 * 3) Parcel::writeInterfaceToken() in frameworks/native/libs/binder/Parcel.cpp
 */
static void freecess_async_binder_report(struct binder_proc *target_proc,
					 struct binder_transaction_data *tr)
{
	char buf_user[INTERFACETOKEN_BUFF_SIZE] = {0};
	char buf[INTERFACETOKEN_BUFF_SIZE] = {0};
	int skip_bytes = 8;
	size_t n;
	int i = 0, j;

	if (freecess_fw_version == 1)
		skip_bytes = 12;
	else if (freecess_fw_version == 2)
		skip_bytes = 16;

	if (tr->data_size <= skip_bytes)
		return;

	n = min_t(binder_size_t, tr->data_size, INTERFACETOKEN_BUFF_SIZE - 2);
	/* preemption is off in a vendor hook: no page fault. The sender has just written these bytes. */
	if (copy_from_user_nofault(buf_user, (const void __user *)(uintptr_t)tr->data.ptr.buffer, n) == 0) {
		for (j = skip_bytes; i < INTERFACETOKEN_BUFF_SIZE - 1 && j < n && buf_user[j] != '\0'; j += 2)
			buf[i++] = buf_user[j];
	}
	atomic_long_inc(&freecess_stats.binder_async);
	binder_report(target_proc->tsk, tr->code, buf, tr->flags & TF_ONE_WAY);
}

static void fc_binder_trans(void *data, struct binder_proc *target_proc, struct binder_proc *proc,
			    struct binder_thread *thread, struct binder_transaction_data *tr)
{
	if (!freecess_mod_bound(MOD_BINDER))
		return;
	if (!proc || !target_proc || !tr || !target_proc->tsk)
		return;
	if (proc->pid == target_proc->pid)
		return;
	if (task_euid(target_proc->tsk).val <= 10000)
		return;
	if (!thread_group_is_frozen(target_proc->tsk))
		return;

	if (tr->flags & TF_ONE_WAY) {
		freecess_async_binder_report(target_proc, tr);
	} else {
		/* if sync binder, we don't need detecting info, so set code and interfacename as default value. */
		atomic_long_inc(&freecess_stats.binder_sync);
		binder_report(target_proc->tsk, 0, "sync_binder", 0);
	}
}

static void fc_binder_alloc_new_buf(void *data, size_t size, size_t *free_async_space, int is_async,
				    bool *should_fail)
{
	struct binder_alloc *alloc;
	struct task_struct *p;

	if (!is_async || !freecess_mod_bound(MOD_BINDER))
		return;
	alloc = container_of(free_async_space, struct binder_alloc, free_async_space);
	if (!(alloc->free_async_space < 3 * size || alloc->free_async_space < alloc->buffer_size / 4))
		return;

	rcu_read_lock();
	p = find_task_by_vpid(alloc->pid);
	if (p && (thread_group_is_frozen(p) || cgroup2_frozen(p))) {
		atomic_long_inc(&freecess_stats.binder_full);
		binder_report(p, -1, "free_buffer_full", is_async);
	}
	rcu_read_unlock();
}

static void fc_do_send_sig_info(void *data, int sig, struct task_struct *killer, struct task_struct *p)
{
	/*
	 * System will send SIGIO to the app that locked the file when other apps access the file.
	 * Report SIGIO to prevent other apps from getting stuck
	 */
	if (sig == SIGKILL || sig == SIGTERM || sig == SIGABRT || sig == SIGQUIT || sig == SIGIO) {
		if (!freecess_mod_bound(MOD_SIG))
			return;
		/* Report pid if signal is fatal */
		sig_report(p, sig != SIGIO);
	}
}

static void fc_binder_preset(void *data, struct hlist_head *hhead, struct mutex *lock,
			     struct binder_proc *proc)
{
	if (unlikely(!READ_ONCE(fc_binder_procs))) {
		fc_binder_procs_lock = lock;
		smp_wmb();
		WRITE_ONCE(fc_binder_procs, hhead);
	}
}

/* MOD_CFB: does a (just frozen) uid still owe somebody a binder answer? */
static void binder_in_transaction(struct binder_proc *proc, int uid)
{
	struct rb_node *n = NULL;
	struct binder_thread *thread = NULL;
	struct binder_transaction *t = NULL;
	struct binder_work *w = NULL;
	const char *found = NULL;

	spin_lock(&proc->inner_lock);
	/* check binder threads todo and transaction_stack list */
	for (n = rb_first(&proc->threads); n != NULL && !found; n = rb_next(n)) {
		thread = rb_entry(n, struct binder_thread, rb_node);
		list_for_each_entry(w, &thread->todo, entry) {
			if (w->type == BINDER_WORK_TRANSACTION) {
				t = container_of(w, struct binder_transaction, work);
				if (!(t->flags & TF_ONE_WAY)) {
					found = "thread";
					break;
				}
			} else if (w->type != BINDER_WORK_TRANSACTION_COMPLETE && w->type != BINDER_WORK_NODE) {
				found = "thread";
				break;
			}
		}
		if (found)
			break;

		/* processing one binder call */
		t = thread->transaction_stack;
		if (t && t->to_thread == thread)
			found = "transaction_stack";
	}

	/* check binder proc todo list */
	if (!found) {
		list_for_each_entry(w, &proc->todo, entry) {
			if (w->type == BINDER_WORK_TRANSACTION) {
				t = container_of(w, struct binder_transaction, work);
				if (!(t->flags & TF_ONE_WAY)) {
					found = "proc";
					break;
				}
			} else if (w->type != BINDER_WORK_TRANSACTION_COMPLETE && w->type != BINDER_WORK_NODE) {
				found = "proc";
				break;
			}
		}
	}
	spin_unlock(&proc->inner_lock);

	if (found) {
		atomic_long_inc(&freecess_stats.cfb_hit);
		cfb_report(uid, found);
	}
}

void binders_in_transcation(int uid)
{
	struct hlist_head *procs = READ_ONCE(fc_binder_procs);
	struct binder_proc *itr;

	atomic_long_inc(&freecess_stats.cfb_req);
	if (!procs) {
		/* no binder open since the module loaded: cannot happen when loaded from the first stage */
		pr_warn_once("MOD_CFB: binder_procs not seen yet, request for uid %d not checked\n", uid);
		return;
	}
	smp_rmb();
	mutex_lock(fc_binder_procs_lock);
	hlist_for_each_entry(itr, procs, proc_node) {
		if (itr->tsk && task_euid(itr->tsk).val == uid)
			binder_in_transaction(itr, uid);
	}
	mutex_unlock(fc_binder_procs_lock);
}

int freecess_hooks_init(void)
{
	int ret;

	ret = register_trace_android_vh_binder_preset(fc_binder_preset, NULL);
	if (ret)
		goto e0;
	ret = register_trace_android_vh_binder_trans(fc_binder_trans, NULL);
	if (ret)
		goto e1;
	ret = register_trace_android_vh_binder_alloc_new_buf_locked(fc_binder_alloc_new_buf, NULL);
	if (ret)
		goto e2;
	ret = register_trace_android_vh_do_send_sig_info(fc_do_send_sig_info, NULL);
	if (ret)
		goto e3;
	return 0;
e3:
	unregister_trace_android_vh_binder_alloc_new_buf_locked(fc_binder_alloc_new_buf, NULL);
e2:
	unregister_trace_android_vh_binder_trans(fc_binder_trans, NULL);
e1:
	unregister_trace_android_vh_binder_preset(fc_binder_preset, NULL);
e0:
	tracepoint_synchronize_unregister();
	pr_err("vendor hook registration failed: %d\n", ret);
	return ret;
}

void freecess_hooks_exit(void)
{
	unregister_trace_android_vh_do_send_sig_info(fc_do_send_sig_info, NULL);
	unregister_trace_android_vh_binder_alloc_new_buf_locked(fc_binder_alloc_new_buf, NULL);
	unregister_trace_android_vh_binder_trans(fc_binder_trans, NULL);
	unregister_trace_android_vh_binder_preset(fc_binder_preset, NULL);
	tracepoint_synchronize_unregister();
}
