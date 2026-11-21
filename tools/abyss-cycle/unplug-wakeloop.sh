#!/system/bin/sh
# Off-cable test of the daily phone's AOD wake loop (root, on the phone, detached):
#   setsid nohup sh unplug-wakeloop.sh [phase_s=180] >/dev/null 2>&1 &
# Unplug the phone, and leaves the phone alone for 3 x phase_s (+ a minute), then plug it back in.
# Phase 0: AOD doze, nothing added (baseline); phase 1: /data/local/tmp/wakeloop with a 600 ms
# CLOCK_MONOTONIC timerfd in an EPOLLWAKEUP epoll set (the "[timerfd]" wakeup source of the daily
# phone); phase 2: the same with CLOCK_BOOTTIME. Counts per phase: suspend entries, "[timerfd]"
# aborts / wakes, ticks of wakeloop. Expected if s2idle freezes non-wake timers: phase 1/2 sleep as
# long as phase 0 and wakeloop ticks only while awake. Report: /data/local/tmp/unplug-wl/report.txt
PH=${1:-180}; O=/data/local/tmp/unplug-wl; rm -rf $O; mkdir -p $O; R=$O/report.txt
now() { date +%s; }; usb() { cat /sys/class/power_supply/usb/online 2>/dev/null; }
stats() { echo "suspend_stats success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"; }
{ echo "unplug-wakeloop start $(date '+%F %T') $(uname -r) governor $(cat /sys/devices/system/cpu/cpuidle/current_governor) mem_sleep $(cat /sys/power/mem_sleep)"
  input keyevent SLEEP; sleep 6; echo "waiting for the unplug (max 30 min)"; } > $R 2>&1
t=$(now); while [ "$(usb)" = 1 ] && [ $(( $(now) - t )) -lt 1800 ]; do sleep 1; done
[ "$(usb)" = 1 ] && { echo "never unplugged" >> $R; exit 0; }
dmesg -c > /dev/null
for p in 0 1 2; do
  { echo "=== phase $p at $(date +%T) up=$(cut -d' ' -f1 /proc/uptime)"; stats; } >> $R
  case $p in 1) /data/local/tmp/wakeloop 600 $PH 1 > $O/wl-$p.txt 2>&1 & ;; 2) /data/local/tmp/wakeloop 600 $PH 7 > $O/wl-$p.txt 2>&1 & ;; esac
  T0=$(now); while [ $(( $(now) - T0 )) -lt $PH ] && [ "$(usb)" != 1 ]; do sleep 5; done
  wait 2>/dev/null
  dmesg -c > $O/dmesg-$p.txt
  { echo "phase $p end $(date +%T) up=$(cut -d' ' -f1 /proc/uptime) wall $(( $(now) - T0 ))s"; stats
    echo "  suspend entries $(grep -c 'PM: suspend entry' $O/dmesg-$p.txt), [timerfd] pending aborts $(grep -c 'Pending Wakeup Sources: \[timerfd\]' $O/dmesg-$p.txt), resume lines: $(grep 'Resume caused by' $O/dmesg-$p.txt | sed 's/.*Resume caused by //' | sort | uniq -c | sort -rn | head -4 | tr '\n' ';')"
    [ -f $O/wl-$p.txt ] && echo "  wakeloop: $(grep -c '^tick' $O/wl-$p.txt) ticks, first/last: $(grep '^tick' $O/wl-$p.txt | head -1 | cut -c1-60) / $(grep '^tick' $O/wl-$p.txt | tail -1 | cut -c1-60)"; } >> $R
  [ "$(usb)" = 1 ] && { echo "USB back early" >> $R; break; }
done
echo "waiting for USB (max 20 min)" >> $R; t=$(now); while [ "$(usb)" != 1 ] && [ $(( $(now) - t )) -lt 1200 ]; do sleep 2; done
echo "=== end $(date '+%F %T') usb=$(usb)" >> $R; stats >> $R; echo DONE >> $R
