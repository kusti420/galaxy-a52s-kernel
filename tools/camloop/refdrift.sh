#!/bin/bash
# Module refcount drift over mixed activity (same bug class as the camera pinctrl leak): snapshot
# /sys/module/*/refcnt, run N cycles of screen off/on, BT off/on, Wi-Fi off/on, tone + 1 s record, one camera
# photo, every 5th cycle a fingerprint HAL restart; snapshot again; print every module whose refcnt changed.
#   tools/camloop/refdrift.sh [cycles=20]            all activities per cycle
#   tools/camloop/refdrift.sh --attribute [reps=5]   each activity alone <reps> times, diff after each group
# -> logs/camloop/refdrift-<timestamp>.txt. Needs root adb. Silent (all streams 0), no vibration, never touches
# adb/USB settings. Ends with Wi-Fi on, BT in its initial state, screen on, muted.
# Uses tools/tone/tone.dex, tools/rec/rec.dex, tools/photo/photo.dex (pushed here).
set -u
S=${SERIAL:-PHONE2}; case "$S" in PHONE2|PHONE1) ;; *) echo "refusing serial $S (test phones only)" >&2; exit 2;; esac
ATTR=0; [ "${1:-}" = --attribute ] && { ATTR=1; shift; }
N=${1:-$([ $ATTR = 1 ] && echo 5 || echo 20)}; case "$N" in ''|*[!0-9]*) echo "usage: refdrift.sh [--attribute] [count]" >&2; exit 2;; esac
cd "$(dirname "$0")/../.." || exit 2
TS=$(date +%Y%m%d-%H%M%S); L=logs/camloop; mkdir -p "$L"; O=$L/refdrift-$TS.txt; W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
A() { adb -s "$S" "$@"; }
sh() { A shell "$@" 2>/dev/null | tr -d '\r'; }
exec > >(tee "$O") 2>&1
[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 1; }
[ "$(sh id -u)" = 0 ] || { echo "needs root adb (adb -s $S root)"; exit 1; }
mute() { sh 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done' >/dev/null; }
mute; sh 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' >/dev/null
for t in tone rec photo; do A push tools/$t/$t.dex /data/local/tmp/$t.dex >/dev/null 2>&1 || echo "push $t.dex failed"; done
BT0=$(sh 'settings get global bluetooth_on'); WIFI0=$(sh 'settings get global wifi_on')
FPSVC=$(sh 'getprop | sed -n "s/^\[init\.svc\.\(vendor\.fingerprint[^]]*\)\]: \[running\]/\1/p" | head -1')
snap() { sh 'for m in /sys/module/*/refcnt; do d=${m%/refcnt}; echo "${d##*/} $(cat $m)"; done' | sort > "$1"; }
drift() {	# drift <before> <after> <label>: modules whose refcnt changed
	join -a1 -a2 -e - -o 0,1.2,2.2 "$1" "$2" | awk -v l="$3" '$2!=$3 { d = ($2=="-"||$3=="-") ? "n/a" : $3-$2; printf "  DRIFT %-28s %s -> %s (%s) [%s]\n", $1, $2, $3, d, l; n++ } END { if (!n) printf "  no module refcnt changed [%s]\n", l }'
}
bad() { sh "dmesg | grep -cE 'WARNING|module_put|Oops|BUG:'"; }
a_screen() { sh 'input keyevent KEYCODE_SLEEP; sleep 2; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; sleep 1' >/dev/null; }
a_bt() { sh 'cmd bluetooth_manager disable >/dev/null 2>&1; cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null 2>&1; sleep 1; cmd bluetooth_manager enable >/dev/null 2>&1; cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null 2>&1; sleep 1' >/dev/null; }
a_wifi() { sh 'cmd wifi set-wifi-enabled disabled >/dev/null 2>&1; sleep 3; cmd wifi set-wifi-enabled enabled >/dev/null 2>&1; sleep 4' >/dev/null; }
a_audio() { mute; sh 'app_process -cp /data/local/tmp/tone.dex / Tone >/dev/null 2>&1; app_process -cp /data/local/tmp/rec.dex / Rec 1 >/dev/null 2>&1' >/dev/null; }
a_camera() { sh 'app_process -cp /data/local/tmp/photo.dex / Photo 0 /data/local/tmp/refdrift.jpg >/dev/null 2>&1' >/dev/null; }
a_fp() {
	if [ -n "$FPSVC" ]; then sh "stop $FPSVC; sleep 1; start $FPSVC; sleep 3" >/dev/null
	else sh 'p=$(pidof android.hardware.biometrics.fingerprint-service.samsung android.hardware.biometrics.fingerprint@2.3-service.samsung 2>/dev/null | cut -d" " -f1); [ -n "$p" ] && kill $p; sleep 3' >/dev/null; fi
}
alive() { [ "$(A get-state 2>/dev/null)" = device ] || { echo "PHONE GONE ($1): reset?"; exit 3; }; }
echo "== refdrift $TS serial $S kernel $(sh uname -r) $([ $ATTR = 1 ] && echo "attribute x$N" || echo "cycles $N"); bt_on=$BT0 wifi_on=$WIFI0 fingerprint service: ${FPSVC:-not found (pid kill)}"
B0=$(bad); snap "$W/s0"; echo "modules with a refcnt: $(wc -l < "$W/s0"); bad dmesg lines: $B0"
if [ $ATTR = 1 ]; then
	prev=$W/s0
	for act in screen bt wifi audio camera fp; do
		i=0; while [ $i -lt "$N" ]; do a_$act; alive "$act"; i=$((i + 1)); done
		snap "$W/s-$act"; echo "after $N x $act:"; drift "$prev" "$W/s-$act" "$act x$N"; prev=$W/s-$act
	done
else
	c=0; while [ $c -lt "$N" ]; do c=$((c + 1))
		a_screen; a_bt; a_wifi; a_audio; a_camera; [ $((c % 5)) = 0 ] && a_fp
		alive "cycle $c"; echo "cycle $c done: pinctrl_yupik=$(sh 'cat /sys/module/pinctrl_yupik/refcnt') bad=$(bad)"
	done
fi
# restore: Wi-Fi on (wait for the link), BT as found, screen on, muted
sh 'cmd wifi set-wifi-enabled enabled >/dev/null 2>&1' >/dev/null
[ "$BT0" = 0 ] && sh 'cmd bluetooth_manager disable >/dev/null 2>&1; cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null 2>&1' >/dev/null
[ "$BT0" = 1 ] && sh 'cmd bluetooth_manager enable >/dev/null 2>&1; cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null 2>&1' >/dev/null
for i in $(seq 20); do sh 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 2; done
sh 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; rm -f /data/local/tmp/refdrift.jpg' >/dev/null; mute
sleep 5; snap "$W/s1"; B1=$(bad)
echo "== total (start -> end, after restore + 5 s settle):"; drift "$W/s0" "$W/s1" total
echo "bad dmesg lines $B0 -> $B1; wifi: $(sh 'cmd wifi status' | grep -m1 -E 'Wifi is (connected|enabled|disabled)' | cut -c1-60); bt_on=$(sh 'settings get global bluetooth_on')"
cp "$W/s0" "$L/refdrift-$TS-before.txt"; cp "$W/s1" "$L/refdrift-$TS-after.txt"; echo "log: $O"
