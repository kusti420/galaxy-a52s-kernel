#!/bin/bash
# One-shot read-only diagnosis bundle for a phone in daily use (IchthysOS + 6.12, KernelSU root).
#   OWNER_OK=1 tools/abyss-cycle/daily-diag.sh <serial> [secs=20]
# No reboot, no setting changed, nothing installed (only scripts in /data/local/tmp). It:
#  1. pushes timerfd-rank.sh + wlan-dropwatch.sh to /data/local/tmp,
#  2. waits (max 5 min) until the screen is off (AOD/doze), asking for it on the terminal,
#  3. runs timerfd-rank for <secs> with the screen off, then snapshots every timerfd owner
#     (clockid, it_value, it_interval, EPOLLWAKEUP or not), /sys/kernel/debug/wakeup_sources (top 40
#     by active count), suspend_stats, the top 20 kernel/native wakelocks (dumpsys suspend_control_internal)
#     and the kernel log tail, plus a redacted IMS/VoLTE snapshot (ims-diag.sh: no SIM ids, keys or IPs),
#  4. starts wlan-dropwatch detached (kernel-log dump around the next WLAN suspend timeout),
#  5. copies everything to logs/daily-<date>-<serial>/.
# Root through /system/bin/su (KernelSU: Superuser must be granted to Shell).
set -u
S=${1:?serial}; SECS=${2:-20}
[ "$S" = DAILYPHONE ] && [ "${OWNER_OK:-0}" != 1 ] && { echo "daily phone: needs OWNER_OK=1 from the user"; exit 2; }
cd "$(dirname "$0")/../.." || exit 1
A="adb -s $S"
D=logs/daily-$(date +%Y%m%d-%H%M)-$S; mkdir -p "$D"
SU() { $A shell "/system/bin/su -c '$1'"; }
SU id | grep -q "uid=0" || { echo "no root over adb (grant Superuser to Shell in the KernelSU manager)"; exit 3; }
$A push tools/abyss-cycle/timerfd-rank.sh tools/abyss-cycle/wlan-dropwatch.sh /data/local/tmp/ >/dev/null || exit 4
echo "kernel: $($A shell uname -r) uptime: $($A shell cat /proc/uptime)" | tee "$D/info.txt"
w() { $A shell dumpsys power 2>/dev/null | grep -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2; }
i=0; while [ "$(w)" = Awake ] && [ $i -lt 60 ]; do
	[ $((i % 6)) = 0 ] && echo "waiting for the screen to go off (press power once, leave the phone alone) ..."
	sleep 5; i=$((i+1)); done
echo "wakefulness: $(w)" | tee -a "$D/info.txt"
[ "$(w)" = Awake ] && echo "screen still on after 5 min: running anyway" | tee -a "$D/info.txt"
SU "sh /data/local/tmp/timerfd-rank.sh $SECS" > "$D/timerfd-rank.txt" 2>&1
echo "wakefulness after rank: $(w)" >> "$D/info.txt"
# timerfd owners in one pass: fdinfo of every timerfd (clockid/it_value/it_interval) and every epoll
# entry (tfd + events), joined on the PC (the per-fd shell loop took minutes on a full phone)
SU 'grep -H -E "^(clockid|it_value|it_interval):|^tfd:" /proc/[0-9]*/fdinfo/* 2>/dev/null; for p in /proc/[0-9]*; do echo "COMM ${p#/proc/} $(cat $p/comm 2>/dev/null)"; done' > "$D/fdinfo-raw.txt" 2>&1
awk '
  /^COMM / { comm[$2] = $3; next }
  { split($1, a, "/"); pid = a[3]; fd = a[5]; sub(/:.*/, "", fd); line = $0; sub(/^[^:]*:/, "", line) }
  line ~ /^clockid:/ { ck[pid" "fd] = $2; next }
  line ~ /^it_value:/ { v = line; gsub(/[^0-9,]/, "", v); val[pid" "fd] = v; next }
  line ~ /^it_interval:/ { v = line; gsub(/[^0-9,]/, "", v); iv[pid" "fd] = v; next }
  line ~ /^tfd:/ { t = line; sub(/^tfd: */, "", t); split(t, b, " "); ev = ""; if (match(line, /events: *[0-9a-f]+/)) { ev = substr(line, RSTART, RLENGTH); sub(/events: */, "", ev) }
                   k = pid" "b[1]; if (ev != "" && and(strtonum("0x" ev), 536870912)) wk[k] = "EPOLLWAKEUP"; else if (!(k in wk)) wk[k] = "epoll" }
  END { for (k in ck) { split(k, c, " "); printf "%s %s fd=%s clockid=%s value=%s interval=%s %s\n", c[1], comm[c[1]], c[2], ck[k], val[k], iv[k], (k in wk) ? wk[k] : "no-epoll" } }' "$D/fdinfo-raw.txt" | sort -k2 > "$D/timerfd-owners.txt"
SU 'mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug; head -1 /sys/kernel/debug/wakeup_sources; tail -n +2 /sys/kernel/debug/wakeup_sources | sort -k2,2nr | head -40' > "$D/wakeup_sources-top40.txt" 2>&1
SU 'for f in /sys/power/suspend_stats/*; do echo "${f##*/}: $(cat $f)"; done; cat /sys/power/mem_sleep; cat /sys/devices/system/cpu/cpuidle/current_governor' > "$D/suspend_stats.txt" 2>&1
SU 'dumpsys suspend_control_internal' > "$D/suspend_control_internal.txt" 2>&1
grep -A25 -iE "wakelock stats|Kernel Wakelock|wake lock stats" "$D/suspend_control_internal.txt" | head -60 > "$D/wakelocks-top.txt"
SU 'dmesg | tail -400' > "$D/dmesg-tail.txt" 2>&1
tools/abyss-cycle/ims-diag.sh "$S" "$D"   # VoLTE: redacted registration trail, SA/PDN/netfilter state
# exact argv match (pgrep -f would match this su shell, whose command line holds the script path)
DW() { SU 'ps -A -o PID,ARGS | awk "\$2==\"sh\" && \$3==\"/data/local/tmp/wlan-dropwatch.sh\" {print \$1}"'; }
[ -n "$(DW)" ] || SU 'setsid nohup sh /data/local/tmp/wlan-dropwatch.sh >/dev/null 2>&1 < /dev/null &'; sleep 1
DW > "$D/dropwatch-pid.txt" 2>&1
echo "wlan-dropwatch pid: $(cat "$D/dropwatch-pid.txt")" | tee -a "$D/info.txt"
echo "== bundle in $D"; ls "$D"
echo "== timerfd arms (top):"; sed -n '1,12p' "$D/timerfd-rank.txt"
echo "== EPOLLWAKEUP timerfds:"; grep EPOLLWAKEUP "$D/timerfd-owners.txt" | head -15
