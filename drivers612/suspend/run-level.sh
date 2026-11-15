#!/bin/bash
# PC side of ONE suspend test level on a test phone that is ALREADY running the 6.12 test Android
# (or the 6.18 one, bsp618/android package a5+: same stage susp)
# by kexec with KX_HOLD=1 (README.md, step 2). Uses only tools/tput.py and tools/tsh.py (telnet
# over the USB NCM link). Never detaches USB, never flashes, never calls adb/heimdall/odin4.
#   PHONE=2 drivers612/suspend/run-level.sh <level> [env words for susp2.sh, e.g. A52_WDT=1]
# Levels: preflight freezer devices platform s2idle-shallow (s2idle-deep needs A52_DEEP_OK=1)
set -u
cd "$(dirname "$0")/../.."
LEVEL=${1:?level}; shift; ENVW="$*"
case "${PHONE:-2}" in 1) export TSH_IP=172.16.42.1;; 2) export TSH_IP=172.16.43.1;; *) exit 1;; esac
H=drivers612/suspend
# Transport: telnet over NCM (bring-up ramdisk) or, in the Android test boot where Android owns the
# gadget, adb (root, debuggable). VIA=adb forces adb; default: adb if the device is listed there.
SER=$([ "${PHONE:-2}" = 1 ] && echo PHONE1 || echo PHONE2)
[ -z "${VIA:-}" ] && { adb devices | grep -q "^$SER[[:space:]]*device" && VIA=adb || VIA=tsh; }
if [ "$VIA" = adb ]; then
	T() { [ "$1" = -t ] && { local to=$2; shift 2; timeout "$to" adb -s "$SER" shell "$*"; return; }; adb -s "$SER" shell "$*"; }
	PUT() { adb -s "$SER" push "$1" "$2" >/dev/null; }
	SH="B= setsid sh"
else
	T() { python3 tools/tsh.py "$@"; }
	PUT() { python3 tools/tput.py "$1" "$2"; }
	SH="setsid /bin/busybox sh"
fi
O=logs/susp-$LEVEL-p${PHONE:-2}-$(date +%H%M%S); mkdir -p "$O"
say() { echo "[$(date +%T)] $*" | tee -a "$O/run.txt"; }
[ "$(date +%H%M)" -lt 2115 ] || { say "after 21:15: not starting (PC sleeps at 22:00)"; exit 1; }
T -t 10 'uname -r' | grep -qE '^6\.(12|18)\.' || { say "the phone is not in the 6.12/6.18 test kernel"; exit 1; }
for f in susp2.sh:/tmp/susp2.sh; do
	PUT "$H/${f%%:*}" "${f#*:}" >> "$O/run.txt" 2>&1 || { say "push ${f%%:*} failed"; exit 1; }
done
say "start $LEVEL $ENVW"
T -t 10 "chmod 755 /tmp/susp2.sh; $ENVW $SH /tmp/susp2.sh $LEVEL </dev/null >/tmp/susp2.out 2>&1 &" >> "$O/run.txt" 2>&1
# preflight ~15 s; pm_test levels ~5 s test + 10 s around it; s2idle: RTC +15 s, backstop 30 s
case $LEVEL in preflight) W=20;; s2idle-*) W=60;; *) W=40;; esac
sleep $W
for i in 1 2 3 4 5 6 7 8 9 10; do
	if T -t 10 'ls /tmp/susp2/lock 2>/dev/null || echo NOLOCK' 2>/dev/null | grep -q NOLOCK; then break; fi
	say "still running or no answer ($i)"; sleep 15
done
T -t 20 "cat /tmp/susp2.out; cat \$(ls -t /tmp/susp2/$LEVEL-*.log | head -1)" > "$O/result.txt" 2>&1
T -t 30 "cat /tmp/susp2/$LEVEL-dmesg.txt 2>/dev/null" > "$O/dmesg.txt" 2>&1
grep -E 'RESULT|ABORT' "$O/result.txt" | tee -a "$O/run.txt"
grep -q 'RESULT' "$O/result.txt" || say "no RESULT line: the phone may be rebooting (panic -> harness/Android) or wedged; do NOT start anything else; check adb get-state in 10 minutes"
say "logs: $O"
