/* Inserted into the build's work copy of a52sxq_dsp_boot.c by build-realboot.sh WALT=1 (mk-walt-source.py),
 * right after tunables_write(). The module source itself is untouched, so builds without WALT=1 are
 * byte-identical to before. */
/*
 * WALT=1 (build-realboot.sh, drivers612/SPEC/08-walt-governor.md): the table above ends with the cpufreq
 * governor rows (policyN/scaling_governor walt + policyN/walt/ tunables). The ROM's own 5.4 post_boot script
 * writes "schedutil" (the WALT governor's name on 5.4, the upstream governor here) at sys.boot_completed,
 * which may be before or after the table: so for walt_guard_s seconds after the table every policy is
 * checked every 10 s and, if one is not on walt, the cpufreq rows are applied again. After that window the
 * governor is left alone (a user or a kernel manager may pick another one). 0 = no guard.
 */
static unsigned int walt_guard_s = 300;
module_param(walt_guard_s, uint, 0444);
MODULE_PARM_DESC(walt_guard_s, "WALT=1 builds: seconds after the tunables table during which a non-walt cpufreq governor is put back (0 = off)");
static unsigned int walt_guard_reapplied;
module_param(walt_guard_reapplied, uint, 0444);
static unsigned long walt_guard_end;

static void walt_guard_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(walt_guard_work, walt_guard_fn);

static bool a52_is_cpufreq_row(const char *path)
{
	return strstr(path, "/cpufreq/policy") != NULL;
}

static void walt_guard_fn(struct work_struct *w)
{
	struct kernfs_node *root = a52_sysfs_root();
	unsigned int i, bad = 0, ok = 0;
	char cur[32];

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
	if (time_before(jiffies, walt_guard_end))
		schedule_delayed_work(&walt_guard_work, 10 * HZ);
	else
		pr_info("a52sxq_dsp_boot: walt guard ended after %u s, %u re-apply(ies)\n", walt_guard_s, walt_guard_reapplied);
}
