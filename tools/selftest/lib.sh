# tools/selftest/lib.sh: helpers for run.sh and tests/*.sh (sourced, not run).
# Device access:  A = adb shell as adbd's uid; X = highest privilege available (root when the phone has it,
# else shell); R = root only (fails when there is none); U = shell uid (app_process tools need the shell
# package identity; on root adbd they go through `su shell`).
A() { timeout "${TMO:-60}" adb -s "$S" shell "$@" 2>&1 | tr -d '\r'; }
R() { case "$ROOT" in adbd) A "$@";; su) printf '%s\n' "$*" | timeout "${TMO:-60}" adb -s "$S" shell 'su 0 sh' 2>&1 | tr -d '\r';; *) return 1;; esac; }
X() { if [ "$ROOT" = su ]; then R "$@"; else A "$@"; fi; }
U() { if [ "$ROOT" = adbd ]; then printf '%s\n' "$*" | timeout "${TMO:-60}" adb -s "$S" shell "${USH:-su shell sh}" 2>&1 | tr -d '\r'; else A "$@"; fi; }
have_root() { [ "$ROOT" != none ]; }
rd() { X "cat $1 2>/dev/null"; }                       # read a node with the best privilege, empty when unreadable
dex() { local d=$1; shift; TMO=${TMO:-120} U "app_process -cp /data/local/tmp/st/$d.dex / $*"; }
st() { dex st St "$@"; }                               # the suite's own multi-tool (tools/selftest/java/St.java)
gs() { A "settings get $1 $2"; }                       # settings get <ns> <key>
# ps: remember a setting once and restore it at exit (run.sh trap)
ps() { local ns=$1 k=$2 v=$3 old; if ! grep -q "^$ns $k " "$RUN/restore.txt" 2>/dev/null; then old=$(gs $ns $k); echo "$ns $k $old" >> "$RUN/restore.txt"; fi; A "settings put $ns $k $v"; }
restore_settings() { [ -f "$RUN/restore.txt" ] || return 0; tac "$RUN/restore.txt" | while read -r ns k old; do if [ "$old" = null ] || [ -z "$old" ]; then A "settings delete $ns $k" >/dev/null; else A "settings put $ns $k $old" >/dev/null; fi; done; rm -f "$RUN/restore.txt"; }
mute() { A 'for st in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $st --set 0 >/dev/null 2>&1; done' >/dev/null; }
unlock() { "$HERE/unlock.sh" "$S" 2>&1 | tail -1; }
locked() { A dumpsys window policy | grep -m1 -o 'showing=[a-z]*' | grep -q true; }
wake() { A 'input keyevent KEYCODE_WAKEUP' >/dev/null; locked && unlock >/dev/null; return 0; }
home() { A 'input keyevent KEYCODE_HOME' >/dev/null; }
now_dev() { A "date +'%m-%d %H:%M:%S.000'"; }

# ---- result bookkeeping (inside a test function) ----
ok()   { echo "  ok: $*";   T_OK=$((T_OK+1));   T_MSG="${T_MSG:+$T_MSG; }$*"; }
fail() { echo "  FAIL: $*"; T_FAIL=$((T_FAIL+1)); T_FMSG="${T_FMSG:+$T_FMSG; }$*"; }
skip() { echo "  skip: $*"; T_SKIP=$((T_SKIP+1)); T_SMSG="${T_SMSG:+$T_SMSG; }$*"; }
note() { echo "  note: $*"; }
hands() { echo "$*" >> "$RUN/hands-on.txt"; echo "  hands-on: $*"; }
# chk "<description>" <command...>: ok when the command succeeds
chk() { local d=$1; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
num() { echo "${1:-0}" | grep -oE -- '-?[0-9]+' | head -1; }
between() { local v; v=$(num "$1"); [ -n "$v" ] && [ "$v" -ge "$2" ] && [ "$v" -le "$3" ]; }

# ---- kernel log ----
# root: dmesg; user builds: /sys/devices/system/cpu/a52kmsg (a52sxq_dsp_boot, DEBUG=1 builds; a tail of the log).
klog() { case "$KLOG" in dmesg) X dmesg;; a52kmsg) A 'cat /sys/devices/system/cpu/a52kmsg';; *) :;; esac; }
klog_last() { klog | grep -oE '^\[ *[0-9]+\.[0-9]+\]' | tail -1 | tr -d '[] '; }
klog_since() { klog | awk -v t="${1:-0}" '{ s=$0; if (match(s, /^\[ *[0-9]+\.[0-9]+\]/)) { v=substr(s, 2, RLENGTH-2)+0; if (v > t+0) print } }'; }
KBAD='WARNING: CPU|WARNING: at |BUG:|Internal error|Unable to handle kernel|Oops|Kernel panic|soft lockup|rcu_(preempt|sched).*(stall|detected)|hung_task|blocked for more than|page allocation failure|Out of memory: Kill|kgsl.*(out of memory|GPU PAGE FAULT|gpu fault|snapshot created|hang detected)|arm-smmu.*(context fault|Unhandled)|ufshcd.*(abort|error handler)|watchdog: BUG|UBSAN|KASAN|refcount_t:|sysfs: cannot create duplicate|deadlock'
# init's view of a native daemon dying (HAL crash); our own tests never kill daemons except in tests that say so.
KSVC="init: Service '[^']+' \(pid [0-9]+\) (received signal [0-9]+|exited with status [1-9][0-9]*)"
SVC_IGNORE="${SVC_IGNORE:-'(bootanim|gsid|flash_recovery|vendor.macloader|a52sxq[a-z_0-9-]*|logcatd|dumpstate|bugreport[a-z]*|adbd|usbd|vendor.qcrild_dummy)'}"

# guard_begin / guard_end bracket every test: new kernel WARN/BUG/oops, new kernel-side SELinux denial
# signatures, daemon crashes (init) and app/native crashes (logcat crash buffer) fail the test.
guard_begin() { G_K=$(klog_last); G_T=$(now_dev); }
guard_end() {
	local d=$1 n CRASH_IGN=; [ -n "${NOMODEM:-}" ] && CRASH_IGN='\((rild|ril-daemon)\)'
	if [ "$KLOG" != none ]; then
		klog_since "${G_K:-0}" > "$d.kmsg"
		# initcall_debug builds (DIAG bootargs): "calling  hung_task_init+0x0/..." style lines are not errors
		grep -E "$KBAD" "$d.kmsg" | grep -vE "${KBAD_ALLOW:-^$}" | grep -vE '\] (calling|initcall) +[A-Za-z_0-9.]+\+0x|\] probe of [^ ]+ returned ' > "$d.kbad"
		n=$(wc -l < "$d.kbad"); [ "$n" -gt 0 ] && fail "kernel: $n new WARN/BUG/error line(s): $(head -1 "$d.kbad" | cut -c1-160)"
		grep -E "$KSVC" "$d.kmsg" | grep -vE "Service $SVC_IGNORE" | grep -vE "${SVC_ALLOW:-^$}" > "$d.svc"
		n=$(wc -l < "$d.svc"); [ "$n" -gt 0 ] && fail "daemon died: $(sed -E "s/.*Service '([^']+)'.*(received signal [0-9]+|exited with status [0-9]+).*/\1 \2/" "$d.svc" | sort | uniq -c | tr -s ' ' | tr '\n' ',' | cut -c1-200)"
	fi
	A "logcat -d -T '$G_T' 2>/dev/null" > "$d.logcat"
	A "logcat -b crash -d -T '$G_T' 2>/dev/null" > "$d.crash"
	# NOMODEM (run.sh): rild segfaults in a loop on a phone without a modem (5.4 too): not a finding
	n=$(grep -E 'Fatal signal|AndroidRuntime: Process: ' "$d.crash" | grep -cvE "${CRASH_IGN:-^\$}"); [ "$n" -gt 0 ] && [ -z "${CRASH_OK:-}" ] && fail "crash: $n fatal in logcat: $(grep -m1 -A2 -E 'Fatal signal|FATAL EXCEPTION' "$d.crash" | tr '\n' ' ' | cut -c1-220)"
	avc_sigs "$d.logcat" "$d.kmsg" > "$d.avc"
	local new; new=$(grep -vxFf "$RUN/avc-seen.txt" "$d.avc" | sort -u)
	if [ -n "$new" ]; then echo "$new" >> "$RUN/avc-seen.txt"; local k; k=$(echo "$new" | grep -E "$AVC_KERNEL_SIDE" | grep -v 'scontext=u:r:shell ' | grep -vE "$AVC_BACKGROUND"); [ -n "$k" ] && fail "SELinux (kernel side): $(echo "$k" | wc -l) new denial signature(s): $(echo "$k" | head -2 | tr '\n' ' ' | cut -c1-260)"; fi
	return 0
}
# one signature per denial: perms scontext tcontext tclass name/path
avc_sigs() { cat "$@" 2>/dev/null | grep 'avc:  *denied' | awk '{ p=""; n=""; s=""; t=""; c="";
	if (match($0, /denied +\{[^}]*\}/)) { p=substr($0, RSTART, RLENGTH); sub(/denied +/, "", p) }
	if (match($0, /(name|path)="[^"]*"/)) n=substr($0, RSTART, RLENGTH); if (match($0, /scontext=[^ ]+/)) s=substr($0, RSTART, RLENGTH);
	if (match($0, /tcontext=[^ ]+/)) t=substr($0, RSTART, RLENGTH); if (match($0, /tclass=[^ ]+/)) c=substr($0, RSTART, RLENGTH);
	gsub(/[0-9]+/, "N", n); sub(/:s0.*/, "", s); sub(/:s0.*/, "", t); print p, s, t, c, n }' | sort -u; }
# kernel side = the kernel domain itself, or a generic/unlabelled kernel object (6.x sysfs/proc/debugfs paths the
# ROM's 5.4-era genfscon does not know), or module loading
# periodic background readers (wakeup-source stats poll): reported once by the selinux test, not blamed on whichever
# test happens to run when the poll fires
AVC_BACKGROUND='scontext=u:r:(system_suspend|system_server) tcontext=u:object_r:sysfs tclass=(file|dir) name="(name|wakeup[N]*|active_count|event_count|wakeup_count|expire_count|active_time_ms|total_time_ms|max_time_ms|last_change_ms|prevent_suspend_time_ms)"'
AVC_KERNEL_SIDE='scontext=u:r:kernel|tcontext=u:object_r:(sysfs|proc|debugfs|unlabeled|device|configfs|tracefs|sysfs_devices_system_cpu)( |$)|tclass=(system|bpf|perf_event)'

# host-side image check: mean brightness (0..1) of a screencap; needs ImageMagick
shot_mean() { adb -s "$S" exec-out screencap -p > "$1" 2>/dev/null; magick "$1" -colorspace Gray -format '%[fx:mean] %[fx:standard_deviation] %w %h' info: 2>/dev/null; }

# ---- numbers for results.json / compare.sh ----
metric() { echo "$1	$2" >> "$RUN/metrics.tsv"; echo "  metric: $1 = $2"; }
# strun <subcommand...>: run an St subcommand, log it, collect its METRIC lines, turn its RESULT line into ok/fail/skip
strun() { local o r; o=$(st "$@"); echo "$o" | grep -vE '^\s*$' | tail -60; echo "$o" | awk '$1=="METRIC"{print $2"\t"$3}' >> "$RUN/metrics.tsv"
	r=$(echo "$o" | grep -m1 '^RESULT '); case "$r" in "RESULT $1 PASS"*) ok "$1: ${r#RESULT $1 PASS }";; "RESULT $1 SKIP"*) skip "$1: ${r#RESULT $1 SKIP }";; "RESULT $1 FAIL"*) fail "$1: ${r#RESULT $1 FAIL }";; *) fail "$1: no RESULT line ($(echo "$o" | tail -1 | cut -c1-120))";; esac; }
ms() { A 'echo $(( $(date +%s%N) / 1000000 ))'; }
suspended_ms() { TMO=30 U 'app_process -cp /data/local/tmp/st/clk.dex / Clk' | awk '/^clk:/{print $7}'; }
restore_one() { local l; l=$(grep "^$1 $2 " "$RUN/restore.txt" 2>/dev/null | head -1) || return 0; [ -z "$l" ] && return 0; set -- $l; if [ "${3:-null}" = null ]; then A "settings delete $1 $2" >/dev/null; else A "settings put $1 $2 $3" >/dev/null; fi; sed -i "/^$1 $2 /d" "$RUN/restore.txt"; }
NOWF='now() { read u _ < /proc/uptime; echo ${u%.*}${u#*.}0; };'   # ms clock for device-side timing (mksh arithmetic is 32 bit: no ns maths)
