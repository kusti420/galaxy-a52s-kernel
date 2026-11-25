#!/system/bin/sh
# a52sxq (SM7325 yupik) on 6.12: WALT cpufreq governor + the phone's 5.4 post_boot tunables.
# drivers612/SPEC/08-walt-governor.md has the mapping table. Standalone, POSIX sh, root:
#   a52sxq-walt.sh apply    governor walt on policy0/4/7, policyN/walt/* tunables, /proc/sys/walt values
#   a52sxq-walt.sh revert   governor schedutil on policy0/4/7 and the WALT sysctls back to the 6.12 defaults
#   a52sxq-walt.sh status   governor + every value this script manages (also the ones it cannot set)
# Every write is guarded by [ -e ]; a missing file or a refused write is logged to the kernel log
# (tag a52sxq-walt) and to stderr, and counted. Exit status: 0 = every write took, 1 = some failed.
# 5.4 source of the values: /vendor/bin/init.kernel.post_boot-yupik.sh (logs/walt/ copy), where the
# WALT governor is called "schedutil" and the sysctls live in /proc/sys/kernel.
# Env: LOAD_BOOST=0 skips the gold/prime `boost -6` (6.12 stand-in for 5.4's per-CPU sched_load_boost).

CPUFREQ=/sys/devices/system/cpu/cpufreq
WALT=/proc/sys/walt
FAIL=0

log() {
	echo "a52sxq-walt: $*" >&2
	[ -w /dev/kmsg ] && echo "a52sxq-walt: $*" > /dev/kmsg 2>/dev/null
}

# w <file> <value...>: write, then read back (first line) and compare where the file is readable
w() {
	f=$1; shift; v="$*"
	if [ ! -e "$f" ]; then log "MISSING $f (wanted '$v')"; FAIL=$((FAIL + 1)); return 1; fi
	if ! echo "$v" > "$f" 2>/dev/null; then log "WRITE FAILED $f <- '$v'"; FAIL=$((FAIL + 1)); return 1; fi
	return 0
}

# sysctl arrays read back tab-separated: normalise blanks for the status print
rdv() { if [ -e "$1" ]; then tr -s '\t\n ' '   ' < "$1" 2>/dev/null | sed 's/ *$//'; else echo "(missing)"; fi; }

POLICIES="policy0 policy4 policy7"
# files under policyN/walt managed here
GOV_FILES="up_rate_limit_us down_rate_limit_us hispeed_freq hispeed_load hispeed_cond_freq rtg_boost_freq pl boost adaptive_level_1 adaptive_low_freq adaptive_high_freq"
SYSCTLS="sched_upmigrate sched_downmigrate sched_group_upmigrate sched_group_downmigrate sched_walt_rotate_big_tasks sched_coloc_busy_hysteresis_enable_cpus sched_busy_hysteresis_enable_cpus sched_busy_hyst_ns sched_min_task_util_for_boost sched_min_task_util_for_colocation sched_task_unfilter_period sched_conservative_pl sched_boost input_boost/input_boost_ms input_boost/input_boost_freq"

gov_all() {
	for p in $POLICIES; do w $CPUFREQ/$p/scaling_governor "$1"; done
}

apply() {
	gov_all walt
	# the tunables directory appears with the governor
	for p in $POLICIES; do [ -d $CPUFREQ/$p/walt ] || { log "no $CPUFREQ/$p/walt after the governor switch (governor is $(rdv $CPUFREQ/$p/scaling_governor))"; FAIL=$((FAIL + 1)); }; done

	# silver (5.4 lines 191-196, 227)
	G=$CPUFREQ/policy0/walt
	w $G/down_rate_limit_us 0
	w $G/up_rate_limit_us 0
	w $G/hispeed_freq 1152000
	w $G/pl 0
	w $G/rtg_boost_freq 691200		# colocation V3: silver floor for the top-app group
	w $CPUFREQ/policy0/scaling_min_freq 691200

	# gold (5.4 lines 203-213)
	G=$CPUFREQ/policy4/walt
	w $G/down_rate_limit_us 0
	w $G/up_rate_limit_us 0
	w $G/hispeed_freq 1228800
	w $G/hispeed_load 85
	w $G/rtg_boost_freq 0
	w $G/pl 0
	w $CPUFREQ/policy4/scaling_min_freq 691200

	# gold+ (5.4 lines 216-224)
	G=$CPUFREQ/policy7/walt
	w $G/down_rate_limit_us 0
	w $G/up_rate_limit_us 0
	w $G/hispeed_freq 1324800
	w $G/hispeed_load 85
	w $G/rtg_boost_freq 0
	w $G/pl 0
	w $CPUFREQ/policy7/scaling_min_freq 806400

	# 5.4: sched_load_boost -6 on cpu4..7 (6 % less load in the frequency request). 6.12 has no
	# per-CPU file; the per-policy `boost` (percent, -100..1000) scales the policy's util the same way.
	if [ "${LOAD_BOOST:-1}" = 1 ]; then
		w $CPUFREQ/policy4/walt/boost -6
		w $CPUFREQ/policy7/walt/boost -6
	fi

	# b.L thresholds (5.4 lines 174-182). Order matters on 6.12: the handler refuses up < down, and
	# group down must stay below group up. 6.12 defaults: up "95 95", down "85 85", group 100 / 95.
	w $WALT/sched_downmigrate 65 85
	w $WALT/sched_upmigrate 71 95
	w $WALT/sched_group_downmigrate 85
	w $WALT/sched_group_upmigrate 100
	w $WALT/sched_walt_rotate_big_tasks 1
	w $WALT/sched_coloc_busy_hysteresis_enable_cpus 0
	w $WALT/sched_busy_hysteresis_enable_cpus 240	# decimal CPU mask: cpu4-7
	# colocation V3 (5.4 lines 228-230) + conservative pl (233)
	w $WALT/sched_min_task_util_for_boost 51
	w $WALT/sched_min_task_util_for_colocation 35
	w $WALT/sched_task_unfilter_period 20000000
	w $WALT/sched_conservative_pl 1
	# input boost off, as 5.4 ("0:0", 0 ms)
	w $WALT/input_boost/input_boost_freq 0 0 0 0 0 0 0 0
	w $WALT/input_boost/input_boost_ms 0
	log "apply done, $FAIL failed write(s)"
}

revert() {
	gov_all schedutil
	# 6.12 defaults (walt_config.c): up first now (95 >= the 65/85 down), then down
	w $WALT/sched_upmigrate 95 95
	w $WALT/sched_downmigrate 85 85
	w $WALT/sched_group_upmigrate 100
	w $WALT/sched_group_downmigrate 95
	w $WALT/sched_walt_rotate_big_tasks 0
	w $WALT/sched_coloc_busy_hysteresis_enable_cpus 112
	w $WALT/sched_busy_hysteresis_enable_cpus 0
	w $WALT/sched_min_task_util_for_boost 51
	w $WALT/sched_min_task_util_for_colocation 35
	w $WALT/sched_task_unfilter_period 100000000
	w $WALT/sched_conservative_pl 0
	w $WALT/input_boost/input_boost_ms 40
	log "revert done, $FAIL failed write(s)"
}

status() {
	for p in $POLICIES; do
		echo "$p governor=$(rdv $CPUFREQ/$p/scaling_governor) min=$(rdv $CPUFREQ/$p/scaling_min_freq) max=$(rdv $CPUFREQ/$p/scaling_max_freq) cur=$(rdv $CPUFREQ/$p/scaling_cur_freq)"
		if [ -d $CPUFREQ/$p/walt ]; then
			for f in $GOV_FILES; do echo "  $p/walt/$f = $(rdv $CPUFREQ/$p/walt/$f)"; done
			for f in $(ls $CPUFREQ/$p/walt 2>/dev/null); do
				case " $GOV_FILES " in *" $f "*) ;; *) echo "  $p/walt/$f = $(rdv $CPUFREQ/$p/walt/$f)  (not managed)";; esac
			done
		else
			echo "  $p/walt: absent (governor is not walt)"
		fi
	done
	for s in $SYSCTLS; do echo "walt/$s = $(rdv $WALT/$s)"; done
}

case "${1:-}" in
	apply) apply;;
	revert) revert;;
	status) status;;
	*) echo "usage: $0 apply|revert|status" >&2; exit 2;;
esac
[ "$FAIL" = 0 ]
