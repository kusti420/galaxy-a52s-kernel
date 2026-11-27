/* Inserted into the build's work copy of a52sxq_dsp_boot.c by build-realboot.sh WALT=1 (mk-walt-source.py),
 * right after tunables_write(). The module source itself is untouched, so builds without WALT=1 are
 * byte-identical to before. */
/*
 * WALT=1 (build-realboot.sh, drivers612/SPEC/08-walt-governor.md): the table above ends with the cpufreq
 * governor rows (policyN/scaling_governor walt + policyN/walt/ tunables). The ROM's own 5.4 post_boot script
 * writes "schedutil" (the WALT governor's name on 5.4, the upstream governor here) at sys.boot_completed,
 * which may be before or after the table: so for walt_guard_s seconds after the table every policy is
 * checked every 10 s and, if one is not on walt, the cpufreq rows are applied again. After that window the
 * governor is left alone (a user or a kernel manager may pick another one) until system_server restarts
 * (walt_guard_rearm, below). 0 = no guard.
 */
static unsigned int walt_guard_s = 300;
module_param(walt_guard_s, uint, 0444);
MODULE_PARM_DESC(walt_guard_s, "WALT=1 builds: seconds after the tunables table during which a non-walt cpufreq governor is put back (0 = off)");
static unsigned int walt_guard_reapplied;
module_param(walt_guard_reapplied, uint, 0444);
static unsigned long walt_guard_end;
/*
 * After the window: a framework restart (system_server dies, init restarts zygote) makes the ROM's post_boot run
 * again on the second sys.boot_completed and write schedutil. So the guard keeps a cheap 30 s check of
 * system_server's pid; a new pid (not the first one seen) re-opens the window for walt_guard_s seconds.
 * A governor chosen by hand later, with no framework restart, is still left alone. 0 = no re-arm.
 */
static unsigned int walt_guard_rearm = 1;
module_param(walt_guard_rearm, uint, 0644);
MODULE_PARM_DESC(walt_guard_rearm, "WALT=1 builds: re-open the guard window when system_server restarts (1, default) or not (0)");
static unsigned int walt_guard_rearmed;
module_param(walt_guard_rearmed, uint, 0444);
static pid_t walt_guard_ss_pid;
static bool walt_guard_open = true;

#include <linux/sched/signal.h>
static pid_t a52_system_server_pid(void)
{
	struct task_struct *p;
	pid_t pid = 0;

	rcu_read_lock();
	for_each_process(p)
		if (!strcmp(p->comm, "system_server")) {
			pid = task_pid_nr(p);
			break;
		}
	rcu_read_unlock();
	return pid;
}

static void walt_guard_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(walt_guard_work, walt_guard_fn);

static bool a52_is_cpufreq_row(const char *path)
{
	return strstr(path, "/cpufreq/policy") != NULL;
}

static void walt_guard_watch(void)
{
	pid_t pid = a52_system_server_pid();

	if (pid && walt_guard_ss_pid && pid != walt_guard_ss_pid) {
		walt_guard_rearmed++;
		walt_guard_open = true;
		walt_guard_end = jiffies + walt_guard_s * HZ;
		pr_info("a52sxq_dsp_boot: walt guard: system_server restarted (pid %d -> %d), window re-opened for %u s (time %u)\n",
			walt_guard_ss_pid, pid, walt_guard_s, walt_guard_rearmed);
	}
	if (pid)
		walt_guard_ss_pid = pid;
}

static void walt_guard_fn(struct work_struct *w)
{
	struct kernfs_node *root;
	unsigned int i, bad = 0, ok = 0;
	char cur[32];

	walt_guard_watch();	/* during the window too: a restart near its end still re-opens it */
	if (walt_guard_open && !time_before(jiffies, walt_guard_end)) {
		walt_guard_open = false;
		pr_info("a52sxq_dsp_boot: walt guard window ended after %u s, %u re-apply(ies)%s\n", walt_guard_s,
			walt_guard_reapplied, walt_guard_rearm ? "; watching for a system_server restart" : "");
	}
	if (!walt_guard_open) {
		/* outside the window the governor is never touched; only the restart watch runs */
		if (walt_guard_rearm)
			schedule_delayed_work(&walt_guard_work, 30 * HZ);
		return;
	}
	root = a52_sysfs_root();
	if (!root)
		return;
	for (i = 0; i < ARRAY_SIZE(a52_tunables); i++) {
		size_t l = strlen(a52_tunables[i].path);

		if (l < 17 || strcmp(a52_tunables[i].path + l - 17, "/scaling_governor") || strcmp(a52_tunables[i].val, "walt"))
			continue;
		if (a52_attr_io(root, a52_tunables[i].path, NULL, cur, sizeof(cur)) <= 0 || strcmp(strim(cur), "walt"))
			bad++;
	}
	if (bad) {
		for (i = 0; i < ARRAY_SIZE(a52_tunables); i++)
			if (a52_is_cpufreq_row(a52_tunables[i].path) &&
			    a52_attr_io(root, a52_tunables[i].path, a52_tunables[i].val, NULL, 0) >= 0)
				ok++;
		walt_guard_reapplied++;
		pr_info("a52sxq_dsp_boot: walt guard: %u policy(ies) not on walt, cpufreq rows applied again (%u ok, time %u)\n",
			bad, ok, walt_guard_reapplied);
	}
	schedule_delayed_work(&walt_guard_work, 10 * HZ);
}
