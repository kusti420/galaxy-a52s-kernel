#!/bin/bash
# BT off/on cycles on a test phone, watching the pinctrl module refcounts (btpower GPIO free fix, 2026-11-25).
#   tools/camloop/btloop.sh [cycles=20]   -> logs/camloop/btloop-<timestamp>.txt
# Silent (no audio is played), root adb needed (does not call adb root), never touches adb/USB settings.
S=${SERIAL:-PHONE2}; case "$S" in PHONE2|PHONE1) ;; *) echo "test phones only (got $S)" >&2; exit 2;; esac
N=${1:-20}; cd "$(dirname "$0")/../.." || exit 2; mkdir -p logs/camloop
O=logs/camloop/btloop-$(date +%Y%m%d-%H%M%S).txt; A() { adb -s "$S" "$@"; }
exec > >(tee "$O") 2>&1
[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 2; }
[ "$(A shell id -u | tr -d '\r')" = 0 ] || { echo "needs root adb"; exit 2; }
A shell 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done' >/dev/null 2>&1
PAT='request fails|WARNING|module_put'
refs() { A shell 'echo "pinctrl_yupik=$(cat /sys/module/pinctrl_yupik/refcnt) pinctrl_msm=$(cat /sys/module/pinctrl_msm/refcnt)"' | tr -d '\r'; }
bad() { A shell "dmesg | grep -cE '$PAT'" | tr -d '\r'; }
bton() { A shell 'settings get global bluetooth_on' | tr -d '\r'; }
# wait-for-state exists on AOSP's bluetooth_manager shell; if it is missing, poll the setting
waitbt() { A shell "timeout 15 cmd bluetooth_manager wait-for-state:$1" >/dev/null 2>&1
	local want=1 i; [ "$1" = STATE_OFF ] && want=0
	for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(bton)" = "$want" ] && return 0; sleep 1; done; return 1; }
INIT=$(bton); R0=$(refs); B0=$(bad)
echo "== btloop $(date +%T) serial $S build $(A shell 'cat /proc/device-tree/soc/a52sxq,realboot' | tr -d '\0\r') cycles $N; bluetooth_on=$INIT"
echo "start: $R0 bad-dmesg-lines=$B0 (pattern: $PAT)"
fail=0
for i in $(seq "$N"); do
	[ "$(A get-state 2>/dev/null)" = device ] || { echo "PHONE GONE at cycle $i"; exit 9; }
	A shell 'cmd bluetooth_manager disable' >/dev/null 2>&1; waitbt STATE_OFF; so=$?; roff=$(refs)
	A shell 'cmd bluetooth_manager enable' >/dev/null 2>&1; waitbt STATE_ON; sn=$?
	[ $so = 0 ] && [ $sn = 0 ] || fail=$((fail + 1))
	echo "cycle $i: off $([ $so = 0 ] && echo ok || echo TIMEOUT) [$roff] on $([ $sn = 0 ] && echo ok || echo TIMEOUT) [$(refs)] bluetooth_on=$(bton) bad=$(bad)"
done
# back to the initial state
if [ "$INIT" = 0 ]; then A shell 'cmd bluetooth_manager disable' >/dev/null 2>&1; waitbt STATE_OFF; else A shell 'cmd bluetooth_manager enable' >/dev/null 2>&1; waitbt STATE_ON; fi
sleep 3; R1=$(refs); B1=$(bad); END=$(bton)
echo "== end: $R0 -> $R1; bluetooth_on $INIT -> $END; state timeouts $fail; bad dmesg lines $B0 -> $B1"
echo "btpower lines: $(A shell "dmesg | grep -cE 'bt_configure_gpios|unable to request gpio'" | tr -d '\r') (bt_configure_gpios/unable to request)"
if [ "$R0" = "$R1" ] && [ "$INIT" = "$END" ]; then echo "RESULT btloop PASS refcnt constant, BT back in its initial state"; rc=0
else echo "RESULT btloop FAIL"; rc=1; fi
echo "log: $O"; exit $rc
