#!/bin/bash
# One complete key-free kexec rehearsal of a realboot build on white cable (PHONE2 only):
# rehearse.sh (offline) -> kx-cycle (KX_HOLD) -> wait for the helper's "a52rh: SUMMARY" -> save dmesg/logcat
# -> optional EXTRA commands -> kx-finish (back to the flashed system) -> mute.
#   drivers612/realboot/rh-run.sh <rb name> <rehearsal name> [extra shell command run on the phone before leaving]
# Env: DEADMAN=<s> (rehearse.sh; default 480: raise it for a long HOST_CMD), HOST_CMD (below),
#      RH_WORDS="word ..." extra kernel words for the test boot (appended to the kx-cycle cmdline as "+words"),
#      BASE=<dmesg of an accepted rehearsal> (default logs/rh612p2a50-dmesg.txt): FAIL lines are compared with it.
# Output: logs/<rh name>-dmesg.txt, -logcat.txt, -extra.txt; exit 0 = booted to boot_completed with no FAIL
# line that the base does not have; 2 = the test kernel never answered (read logs/kx-<rh name>-p2-*/).
set -u
cd "$(dirname "$0")/../.."
RBN=${1:?rb name}; RH=${2:?rehearsal name}; EXTRA=${3:-}
S=PHONE2; BASE=${BASE:-logs/rh612p2a50-dmesg.txt}
A() { adb -s $S "$@"; }
mute() { A shell 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done' >/dev/null 2>&1; }
RB=$PWD/drivers612/realboot/out/$RBN PHONE=2 drivers612/realboot/rehearse.sh 612 "$RH" > "drivers612/realboot/out/rh-$RH.prep.log" 2>&1 || { tail -5 "drivers612/realboot/out/rh-$RH.prep.log"; echo "rehearse.sh failed"; exit 1; }
D=drivers612/realboot/out/rh-$RH
KXCMD=-; [ -n "${RH_WORDS:-}" ] && KXCMD="+$RH_WORDS"
PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img KEXEC_BASE=$D/rh-base.dtb KEXEC_OVERLAY=none KX_PACK=$D/pack.tgz \
	HARNESS_EXTRA="$(cat $D/harness-extra.sh)" KX_HOLD=1 KX_WAIT=300 kexec/kx-cycle.sh "$RH" $D/Image $D/rd.cpio.gz gen "$KXCMD" 2>&1 | tail -12 | cut -c1-240
UP=0
if [ "$(A get-state 2>/dev/null)" = device ] && A shell 'awk '"'"'$2=="/data"{print $1}'"'"' /proc/mounts' 2>/dev/null | grep -q zram; then
	UP=1
	for i in $(seq 60); do A shell dmesg 2>/dev/null | grep -q 'a52rh: SUMMARY' && break; sleep 5; done
	mute
	A shell dmesg > "logs/$RH-dmesg.txt" 2>/dev/null; A logcat -d > "logs/$RH-logcat.txt" 2>/dev/null
	[ -n "$EXTRA" ] && A shell "$EXTRA" > "logs/$RH-extra.txt" 2>&1
	# HOST_CMD: a PC-side command run while the test Android is held (e.g. the bench app: its /data is empty, no keyguard)
	[ -n "${HOST_CMD:-}" ] && { eval "$HOST_CMD" > "logs/$RH-host.txt" 2>&1; A shell dmesg > "logs/$RH-dmesg-end.txt" 2>/dev/null; }
fi
( TSH_IP=172.16.43.1 timeout 15 tools/tsh.py -t 5 /leave >/dev/null 2>&1 )
PHONE=2 kexec/kx-finish.sh "$RH" 2>&1 | tail -3
timeout 120 adb -s $S wait-for-device; A root >/dev/null 2>&1; sleep 3; timeout 60 adb -s $S wait-for-device
for i in $(seq 60); do [ "$(A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
mute
echo "home: $(A shell 'uname -r; cat /proc/device-tree/soc/a52sxq,realboot' 2>/dev/null | tr '\0\n' '  ')"
[ "$UP" = 1 ] || { echo "RESULT $RH: the test kernel never answered (crash?) -> logs/kx-$RH-p2-*"; exit 2; }
grep -E 'a52rh: (FAIL|SUMMARY)' "logs/$RH-dmesg.txt" | sed 's/^\[[^]]*\] *//' | cut -c1-200
NEW=$(diff <(grep -E 'a52rh: FAIL' "$BASE" | sed 's/^\[[^]]*\] *//' | cut -c1-40 | sort) <(grep -E 'a52rh: FAIL' "logs/$RH-dmesg.txt" | sed 's/^\[[^]]*\] *//' | cut -c1-40 | sort) | grep '^>')
echo "WARN lines: $(grep -c 'WARNING: CPU' "logs/$RH-dmesg.txt") (base $(grep -c 'WARNING: CPU' "$BASE")); oops: $(grep -cE 'Unable to handle kernel|Internal error|Kernel panic' "logs/$RH-dmesg.txt")"
grep -q 'a52rh: PASS boot_completed' "logs/$RH-dmesg.txt" || { echo "RESULT $RH: no boot_completed"; exit 1; }
[ -z "$NEW" ] && echo "RESULT $RH: OK (no FAIL beyond the base)" || { echo "RESULT $RH: NEW FAILS:"; echo "$NEW"; exit 1; }
