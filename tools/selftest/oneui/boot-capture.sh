#!/bin/bash
# Early capture for the OneUI parity sweep: saves the kernel log and logcat of THIS boot while the first seconds are
# still in the ring buffers (qseecom "App with id N (name) now loaded" lines = the TA set, keymaster/gatekeeper/
# Widevine provisioning start-up, init "Unable to write"/"open() failed" lines). sweep.sh copies the capture into its
# run directory when the boot id matches; collect.py then fills tee.ta_boot_set / tee.ta_requested / drm.widevine_log_level.
#   tools/selftest/oneui/boot-capture.sh <serial> [max wait s, default 300]
# Start it BEFORE or WHILE the phone boots (it waits for adb), or any time later (then it says how far back the log
# reaches). READ-ONLY and SILENT: it never reboots the phone, changes no setting, writes nothing on the phone.
# Privacy: same as the sweep: no radio buffer, runs of 14+ digits masked.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
S=${1:?usage: boot-capture.sh <serial> [max wait s]}; MAXW=${2:-300}
case "$S" in DAILYPHONE|OTHERPHONE) [ "${OWNER_OK:-}" = 1 ] || { echo "refusing $S (protected phones) without OWNER_OK=1"; exit 3; };; esac
a() { timeout "${TMO:-30}" adb -s "$S" shell "$@" 2>/dev/null | tr -d '\r'; }
t0=$(date +%s)
until adb -s "$S" get-state 2>/dev/null | grep -q device; do [ $(( $(date +%s) - t0 )) -gt "$MAXW" ] && { echo "$S not on adb after $MAXW s"; exit 4; }; sleep 1; done
# the kernel log is the one that rolls over first: take it as soon as a root shell answers, do not wait for boot_completed
ROOT=none; for i in $(seq 1 40); do
	if [ "$(a "su -c 'id -u'" | tail -1)" = 0 ]; then ROOT=su-c; break; fi
	if [ "$(a id -u)" = 0 ]; then ROOT=adbd; break; fi
	[ "$(a getprop sys.boot_completed)" = 1 ] && [ "$i" -gt 15 ] && break; sleep 2; done
r() { if [ $ROOT = su-c ]; then a "su -c '$1'"; else a "$1"; fi; }
BID=$(a 'cat /proc/sys/kernel/random/boot_id' | tr -dc 'a-f0-9-'); [ -n "$BID" ] || { echo "cannot read the boot id"; exit 5; }
OUT=$REPO/logs/selftest/early/$S-$BID; mkdir -p "$OUT"
UP=$(a 'cut -d. -f1 /proc/uptime'); echo "$UP" > "$OUT/uptime.txt"
[ $ROOT != none ] && TMO=60 r dmesg | sed -E 's/[0-9]{14,}/<digits>/g' > "$OUT/kmsg.txt"
# second pass after boot_completed: logcat of the whole boot (main,system,crash,events: never the radio buffer)
until [ "$(a getprop sys.boot_completed)" = 1 ] || [ $(( $(date +%s) - t0 )) -gt "$MAXW" ]; do sleep 2; done
sleep 20
[ $ROOT != none ] && TMO=60 r dmesg | sed -E 's/[0-9]{14,}/<digits>/g' > "$OUT/kmsg-2.txt"
# keep the copy that reaches further back; append what the later one adds
if [ -s "$OUT/kmsg.txt" ] && [ -s "$OUT/kmsg-2.txt" ]; then last=$(tail -1 "$OUT/kmsg.txt" | grep -oE '^\[ *[0-9.]+\]'); [ -n "$last" ] && awk -v l="$last" 'f{print} index($0,l)==1{f=1}' "$OUT/kmsg-2.txt" >> "$OUT/kmsg.txt"; rm -f "$OUT/kmsg-2.txt"
elif [ -s "$OUT/kmsg-2.txt" ]; then mv "$OUT/kmsg-2.txt" "$OUT/kmsg.txt"; fi
TMO=120 r 'logcat -d -b main,system,crash,events' | sed -E 's/[0-9]{14,}/<digits>/g' > "$OUT/logcat.txt"
first=$(head -1 "$OUT/kmsg.txt" 2>/dev/null | grep -oE '^\[ *[0-9]+' | tr -dc 0-9)
{ echo "serial $S boot_id $BID root=$ROOT kernel $(a uname -r)"; echo "first dmesg at uptime ${UP}s; kernel log starts at ${first:-?} s, $(grep -c . "$OUT/kmsg.txt" 2>/dev/null) lines; logcat $(grep -c . "$OUT/logcat.txt") lines"
  echo "TA loads in the kernel log: $(grep -aoE 'App with id [0-9]+ \([A-Za-z0-9_.-]+\) now loaded' "$OUT/kmsg.txt" 2>/dev/null | grep -oE '\([^)]+\)' | sort -u | tr -d '()' | tr '\n' ' ')"; } | tee "$OUT/summary.txt"
[ "${first:-99}" -le 3 ] || echo "NOTE: the kernel log does not reach back to boot (starts at ${first:-?} s): start this script before the phone boots, or boot with a larger log buffer (drivers612/samsung-oneui/DLOAD-LOGBUF.md: log_buf_len=1M)"
echo "saved: $OUT (the next sweep of this boot picks it up)"
