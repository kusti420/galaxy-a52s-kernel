#!/bin/bash
# Voice-call audio snapshot for "call connects, no audio" / "calls not working" reports (drivers612/SPEC/02 section 11).
# Run it THREE times on the same phone and kernel: idle, while a call is ringing/dialling, and 10 s into the connected
# call (someone has to place the call: this script never dials). Compare a 5.4 set with a 6.12 set.
#   tools/selftest/oneui/callcap.sh <serial> <label>        e.g. callcap.sh PHONE1 incall-612
# SILENT and read-only on the phone (pushes its own files to /data/local/tmp/st-callcap, removed at the end; reads
# mixer control VALUES through actl, dmesg, the main/system log buffers filtered to audio tags, dumpsys enum fields).
# No number, IMEI, IMSI or operator name is stored: see callcap-dev.sh. Output: logs/callcap/<serial>-<time>-<label>.txt
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
S=${1:?usage: callcap.sh <serial> <label>}; L=${2:-snap}
case "$S" in DAILYPHONE|OTHERPHONE) [ "${OWNER_OK:-}" = 1 ] || { echo "refusing $S (protected phones) without OWNER_OK=1"; exit 3; };; esac
adb -s "$S" get-state 2>/dev/null | grep -q device || { echo "$S not on adb"; exit 4; }
a() { timeout "${TMO:-120}" adb -s "$S" shell "$@" 2>&1 | tr -d '\r'; }
D=/data/local/tmp/st-callcap
a "rm -rf $D; mkdir -p $D" >/dev/null
adb -s "$S" push "$HERE/callcap-dev.sh" $D/ >/dev/null 2>&1
[ -f "$HERE/actl/actl-arm64" ] && adb -s "$S" push "$HERE/actl/actl-arm64" $D/actl >/dev/null 2>&1
a "chmod -R a+rX $D; chmod 755 $D/actl" >/dev/null
trap 'a "rm -rf $D" >/dev/null 2>&1' EXIT
O=$REPO/logs/callcap; mkdir -p "$O"; F=$O/$S-$(date +%Y%m%d-%H%M%S)-$L.txt
if [ "$(a "su -c 'id -u'" | tail -1)" = 0 ]; then a "su -c 'sh $D/callcap-dev.sh'" > "$F"
elif [ "$(a id -u)" = 0 ]; then a "sh $D/callcap-dev.sh" > "$F"
else echo "NOTE: no root: control values and dmesg are missing" >&2; a "sh $D/callcap-dev.sh" > "$F"; fi
sed -i -E 's/[0-9]{7,}/<digits>/g' "$F"
echo "$F ($(wc -l < "$F") lines)"
grep -E '^(kernel|rom) |mCallState|mForegroundCallState|DisconnectCause|card state|VAL .*Voice Mixer VoiceMMode|VAL .*Tx Mixer .*MMode' "$F" | head -30
