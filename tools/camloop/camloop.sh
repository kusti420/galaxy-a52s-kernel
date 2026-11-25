#!/bin/bash
# Camera session loop for the pinctrl module refcount leak: N sessions across all
# camera ids (photo; every 5th session also a 2 s video record), one line per session with the pinctrl refcounts
# and the running count of bad dmesg lines; at the end refcnt first vs last, JPEG sizes, torch on/off.
#   tools/camloop/camloop.sh [sessions=60]        -> logs/camloop/<timestamp>.txt (+ last front/rear JPEG)
# Needs root adb (as verify-realboot.sh). Silent, no vibration, never touches adb/USB settings.
# Uses tools/photo/photo.dex, tools/torch/torch.dex, tools/selftest/java/st.dex (pushed here).
set -u
S=${SERIAL:-PHONE2}; case "$S" in PHONE2|PHONE1) ;; *) echo "refusing serial $S (test phones only)" >&2; exit 2;; esac
N=${1:-60}; case "$N" in ''|*[!0-9]*) echo "usage: camloop.sh [sessions]" >&2; exit 2;; esac
cd "$(dirname "$0")/../.." || exit 2
TS=$(date +%Y%m%d-%H%M%S); L=logs/camloop; mkdir -p "$L"; O=$L/$TS.txt
A() { adb -s "$S" "$@"; }
sh() { A shell "$@" 2>/dev/null | tr -d '\r'; }
exec > >(tee "$O") 2>&1
[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 1; }
[ "$(sh id -u)" = 0 ] || { echo "needs root adb (adb -s $S root)"; exit 1; }
sh 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' >/dev/null
sh 'mkdir -p /data/local/tmp/st' >/dev/null
A push tools/photo/photo.dex /data/local/tmp/photo.dex >/dev/null 2>&1 || { echo "push photo.dex failed"; exit 1; }
A push tools/torch/torch.dex /data/local/tmp/torch.dex >/dev/null 2>&1
HAVE_ST=0; [ -f tools/selftest/java/st.dex ] && A push tools/selftest/java/st.dex /data/local/tmp/st/st.dex >/dev/null 2>&1 && HAVE_ST=1
BAD='request fails|WARNING|module_put|Oops'
refs() { sh 'echo "$(cat /sys/module/pinctrl_yupik/refcnt 2>/dev/null) $(cat /sys/module/pinctrl_msm/refcnt 2>/dev/null)"'; }
bad() { sh "dmesg | grep -cE '$BAD'"; }
# camera ids: Photo prints "photo: cameras [0, 1, 2, 3, 54]" before it opens anything
IDS=$(sh 'app_process -cp /data/local/tmp/photo.dex / Photo 0 /data/local/tmp/camloop-0.jpg' | sed -n 's/^photo: cameras \[\(.*\)\]/\1/p' | tr -d ',' | head -1)
[ -n "$IDS" ] || IDS="0 1 2 3"
read -r Y0 M0 <<<"$(refs)"; B0=$(bad)
echo "== camloop $TS serial $S kernel $(sh uname -r) build $(sh 'cat /proc/device-tree/soc/a52sxq,realboot' | tr -d '\0') sessions $N ids: $IDS"
echo "start: pinctrl_yupik=$Y0 pinctrl_msm=$M0 bad-dmesg-lines=$B0 (pattern: $BAD)"
SKIP=" "; ok=0; fail=0; vid=0; vidok=0; i=0; n=0
set -- $IDS; NID=$#
while [ "$n" -lt "$N" ]; do
	[ "$(A get-state 2>/dev/null)" = device ] || { echo "PHONE GONE after session $n (reset?)"; break; }
	i=$((i + 1)); idx=$(( (i - 1) % NID + 1 )); id=$(eval "echo \${$idx}")
	case "$SKIP" in *" $id "*) [ "$(echo $SKIP | wc -w)" -ge "$NID" ] && { echo "every id failed"; break; }; continue;; esac
	n=$((n + 1))
	R=$(sh "app_process -cp /data/local/tmp/photo.dex / Photo $id /data/local/tmp/camloop-$id.jpg" | grep -E '^photo: (cam |no|open|configure|device)' | tail -1)
	if echo "$R" | grep -q 'bytes [0-9]\{5,\}'; then res="photo ok ($(echo "$R" | sed 's/^photo: cam [^ ]* //; s/ ->.*//'))"; ok=$((ok + 1))
	else res="photo FAIL (${R:-no output})"; fail=$((fail + 1))
		# an id that never worked (logical/secure) is dropped from the rotation; one that worked before stays
		[ ! -s "$L/.seen-$TS-$id" ] && SKIP="$SKIP$id " && res="$res -> id $id dropped"
	fi
	echo "$R" | grep -q 'bytes' && : > "$L/.seen-$TS-$id" && echo 1 > "$L/.seen-$TS-$id"
	if [ $((n % 5)) = 0 ] && [ "$HAVE_ST" = 1 ]; then
		V=$(sh "app_process -cp /data/local/tmp/st/st.dex / St camrec $id 2" | grep '^RESULT' | cut -c1-110); vid=$((vid + 1))
		echo "$V" | grep -q '^RESULT camrec PASS' && vidok=$((vidok + 1)); res="$res; video: ${V:-no output}"
	fi
	read -r Y M <<<"$(refs)"
	echo "session $n id $id: $res | pinctrl_yupik=$Y pinctrl_msm=$M bad=$(bad)"
done
rm -f "$L"/.seen-"$TS"-*
read -r Y1 M1 <<<"$(refs)"; B1=$(bad)
echo "== end: sessions $n photo ok $ok fail $fail, video $vidok/$vid; dropped ids:${SKIP:- none}"
echo "refcnt pinctrl_yupik $Y0 -> $Y1, pinctrl_msm $M0 -> $M1: $([ "$Y0" = "$Y1" ] && [ "$M0" = "$M1" ] && echo PASS || echo "FAIL (drift $((Y1 - Y0)) / $((M1 - M0)))")"
echo "bad dmesg lines $B0 -> $B1: $([ "$B0" = "$B1" ] && echo PASS || echo FAIL)"
sh "dmesg | grep -E '$BAD' | tail -5" | cut -c1-200
for p in 0:rear 1:front; do id=${p%%:*}; nm=${p##*:}
	A pull /data/local/tmp/camloop-$id.jpg "$L/$TS-$nm.jpg" >/dev/null 2>&1
	echo "last $nm JPEG (id $id): $(stat -c %s "$L/$TS-$nm.jpg" 2>/dev/null || echo missing) bytes $(file -b "$L/$TS-$nm.jpg" 2>/dev/null | cut -c1-60)"
done
T=$(sh 'app_process -cp /data/local/tmp/torch.dex / Torch 500 0 2>&1' | tr '\n' ' ')
echo "torch: ${T:-no output} -> $(echo "$T" | grep -q 'torch: on' && echo "$T" | grep -q 'torch: off' && echo PASS || echo FAIL)"
read -r Y2 M2 <<<"$(refs)"; echo "after torch: pinctrl_yupik=$Y2 pinctrl_msm=$M2"
sh 'rm -f /data/local/tmp/camloop-*.jpg; input keyevent KEYCODE_HOME' >/dev/null
echo "log: $O"
