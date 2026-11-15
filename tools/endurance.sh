#!/bin/bash
# Endurance run in a held test-Android session on phone 2 (6.12 or 6.18 with stage susp):
# samples every minute, one real s2idle-shallow suspend/resume every SUSP_EVERY minutes.
#   tools/endurance.sh <name> <minutes>   -> logs/<name>-endurance.txt
cd "$(dirname "$0")/.."; S=PHONE2; N=${1:?name}; M=${2:-45}; E=${SUSP_EVERY:-5}
L=logs/$N-endurance.txt; : > $L
adb -s $S shell 'for st in 1 2 3 5 7 8 9 10 11; do cmd media_session volume --stream $st --set 0 >/dev/null 2>&1; done; for st in 0 4 6; do cmd media_session volume --stream $st --set 1 >/dev/null 2>&1; done; cmd audio set-ringer-mode SILENT; settings put system sound_effects_enabled 0; settings put system haptic_feedback_enabled 0; cmd connectivity airplane-mode enable' >/dev/null 2>&1
for i in $(seq 1 $M); do
  o=$(adb -s $S shell 'echo "$(uname -r|cut -c1-4) up=$(cut -d" " -f1 /proc/uptime) load=$(cut -d" " -f1 /proc/loadavg) f=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)/$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq)/$(cat /sys/devices/system/cpu/cpufreq/policy7/scaling_cur_freq) t=$(cat /sys/class/thermal/thermal_zone1/temp) bat=$(cat /sys/class/power_supply/battery/capacity) crash=$(logcat -b crash -d | grep -c "Fatal signal") kwarn=$(dmesg | grep -cE "BUG:|Internal error|WARNING: CPU|context fault") susp=$(cat /sys/power/suspend_stats/success)/$(cat /sys/power/suspend_stats/fail)"' 2>/dev/null | tr '\n' ' ')
  [ -z "$o" ] && { echo "$(date +%T) LOST" >> $L; exit 1; }
  echo "$(date +%T) $o" >> $L
  if [ $((i % E)) = 0 ]; then r=$(PHONE=2 drivers612/suspend/run-level.sh s2idle-shallow A52_KEEP_RADIOS=1 2>&1 | grep -oE "RESULT.*|ABORT.*" | head -1); echo "$(date +%T) SUSP $r" >> $L; else sleep 60; fi
done
echo "$(date +%T) DONE" >> $L
