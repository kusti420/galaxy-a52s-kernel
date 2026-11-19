#!/bin/bash
# Runs the A52 Kernel Bench app on a phone and collects everything.
# Usage: tools/bench-app/run-bench.sh <serial> [tests=all] [seconds=0] [--audible] [extra am extras...]
#   tests: all | comma list of ids or prefixes (gpu,camera.still,soak.mixed)     seconds: per-test duration override (0 = defaults)
#   extra: passed to am start, e.g.  --es gpu_mb 512  --es storage_mb 64  --es url https://...
# Output: logs/bench/<serial>-<time>/ (results.json, evidence, logcat, kernel log delta, kbad.txt), table on stdout; exit 1 on FAIL.
# Takes the per-phone lock (flock) for the whole phone session so parallel suites do not collide.
set -u
S=${1:?serial}; TESTS=${2:-all}; SECS=${3:-0}; shift; shift 2>/dev/null; shift 2>/dev/null
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
# Silent by default: the tests that make sound (audio.out, audio.offload, soak.mixed plays a tone)
# only run with --audible (anywhere after the serial) or AUDIBLE=1. "all" then means all silent tests.
AUD=${AUDIBLE:-0}; _x=(); for _a in "$@"; do if [ "$_a" = --audible ]; then AUD=1; else _x+=("$_a"); fi; done; set -- "${_x[@]}"
[ "$TESTS" = --audible ] && { AUD=1; TESTS=all; }; [ "$SECS" = --audible ] && { AUD=1; SECS=0; }
if [ "$AUD" != 1 ]; then
  [ "$TESTS" = all ] && TESTS=gpu.render,gpu.torture,gpu.vulkan,display.pattern,display.refresh,audio.mic,camera.still,camera.video,camera.flash,codec.roundtrip,sensors.all,wifi.net,bt.le,storage.io,storage.sd,crypto.keystore,drm.widevine,cpu.perf,thermal.load,gnss.fix
  _t=; for _i in $(echo "$TESTS" | tr , ' '); do case "$_i" in audio|audio.out|audio.offload|soak|soak.mixed) echo "silent run: $_i left out (--audible to include)";; *) _t="${_t:+$_t,}$_i";; esac; done
  [ "$TESTS" != "$_t" ] && case ",$TESTS," in *,audio,*) _t="${_t:+$_t,}audio.mic";; esac
  TESTS=$_t; [ -n "$TESTS" ] || { echo "nothing left to run without --audible"; exit 0; }
fi
case "$S" in DAILYPHONE|OTHERPHONE) [ "${OWNER_OK:-}" = 1 ] || { echo "refusing $S (not a kernel test phone); OWNER_OK=1 to override"; exit 2; };; esac
APK=$TOP/out/a52bench.apk; [ -f "$APK" ] || "$HERE/build.sh" || exit 2
PKG=org.a52sxq.bench; DEVDIR=/sdcard/Android/data/$PKG/files
OUT=$TOP/logs/bench/$S-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
case "$S" in PHONE1) LOCK=/tmp/claude-1000/a52-bs.lock;; *) LOCK=/tmp/claude-1000/a52-$S.lock;; esac
mkdir -p "$(dirname "$LOCK")"; exec 9>"$LOCK"
flock -w "${LOCK_WAIT:-900}" 9 || { echo "could not get $LOCK"; exit 2; }
a() { adb -s "$S" shell "$@" 2>&1 | tr -d '\r'; }
KBAD='WARNING: CPU|WARNING: at |BUG:|Internal error|Unable to handle kernel|Oops|Kernel panic|soft lockup|rcu_(preempt|sched).*(stall|detected)|hung_task|blocked for more than|page allocation failure|Out of memory: Kill|kgsl.*(out of memory|GPU PAGE FAULT|gpu fault|snapshot created|hang detected)|arm-smmu.*(context fault|Unhandled)|ufshcd.*(abort|error handler)|watchdog: BUG|UBSAN|KASAN|refcount_t:|sysfs: cannot create duplicate|deadlock'
if a 'su 0 id' | grep -q 'uid=0'; then klog() { a 'su 0 dmesg'; }; KSRC=dmesg
elif a id | grep -q 'uid=0'; then klog() { a dmesg; }; KSRC=dmesg
elif a 'ls /sys/devices/system/cpu/a52kmsg' | grep -q '^/sys'; then klog() { a 'cat /sys/devices/system/cpu/a52kmsg'; }; KSRC=a52kmsg
else klog() { :; }; KSRC=none; fi
adb -s "$S" install -r -g "$APK" 2>&1 | tail -1
"$HERE/grant.sh" "$S"
OLD_STAYON=$(a settings get global stay_on_while_plugged_in)
restore() { a am force-stop $PKG >/dev/null; a settings put global stay_on_while_plugged_in "${OLD_STAYON:-0}" >/dev/null; }
trap restore EXIT
a svc power stayon usb >/dev/null
a input keyevent KEYCODE_WAKEUP >/dev/null
[ -x "$TOP/tools/selftest/unlock.sh" ] && echo "keyguard: $("$TOP/tools/selftest/unlock.sh" "$S" 2>&1 | tail -1)"
a am force-stop $PKG >/dev/null; a rm -f $DEVDIR/results.json >/dev/null
klog > "$OUT/kmsg-before.txt"; K0=$(grep -oE '^\[ *[0-9]+\.[0-9]+\]' "$OUT/kmsg-before.txt" | tail -1 | tr -d '[] ')
T0=$(a "date +'%m-%d %H:%M:%S.000'")
a am start -n $PKG/.RunActivity --es tests "$TESTS" --ei seconds "$SECS" "$@" | tail -1
LIMIT=${LIMIT:-2400}; t=0; dead=0; DONE=
while [ $t -lt "$LIMIT" ]; do
  sleep 4; t=$((t+4))
  DONE=$(a "logcat -d -T '$T0' -s A52BENCH:I" | grep -m1 'A52BENCH DONE') && break
  # logcat may have been cleared by a parallel suite: results.json gets "finished_ms" at the same moment
  a "grep -c finished_ms $DEVDIR/results.json 2>/dev/null" | grep -q '^1' && { DONE="A52BENCH DONE (from results.json)"; break; }
  if [ -z "$(a pidof $PKG)" ]; then dead=$((dead+1)); [ $dead -ge 3 ] && { echo "app process died"; break; }; else dead=0; fi
done
[ -n "$DONE" ] && echo "$DONE" | sed 's/.*A52BENCH DONE/A52BENCH DONE/' || echo "NO 'A52BENCH DONE' after ${t}s"
adb -s "$S" pull "$DEVDIR/." "$OUT/" >/dev/null 2>&1
a "logcat -d -T '$T0'" > "$OUT/logcat.txt"; grep -E 'A52BENCH|AndroidRuntime|FATAL|Fatal signal' "$OUT/logcat.txt" > "$OUT/logcat-bench.txt"
klog > "$OUT/kmsg-after.txt"
awk -v t="${K0:-0}" '{ s=$0; if (match(s, /^\[ *[0-9]+\.[0-9]+\]/)) { v=substr(s, 2, RLENGTH-2)+0; if (v > t+0) print } }' "$OUT/kmsg-after.txt" > "$OUT/kmsg-new.txt"
grep -E "$KBAD" "$OUT/kmsg-new.txt" > "$OUT/kbad.txt"
NB=$(wc -l < "$OUT/kbad.txt"); NK=$(wc -l < "$OUT/kmsg-new.txt")
echo
python3 "$HERE/table.py" "$OUT/results.json"; RC=$?
echo "kernel log ($KSRC): $NK new lines, $NB WARN/oops/kgsl-OOM line(s)$([ "$NB" -gt 0 ] && echo ": $(head -3 "$OUT/kbad.txt" | cut -c1-160)")"
[ "$KSRC" = a52kmsg ] && echo "  (a52kmsg is a tail of the log: lines that scrolled out during the run are not counted)"
echo "results: $OUT"
[ "$NB" -gt 0 ] && RC=1
[ -n "$DONE" ] || RC=1
exit $RC
