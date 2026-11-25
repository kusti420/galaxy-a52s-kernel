#!/bin/bash
# idle residency by time_in_state (no adb traffic during the window): 60 s screen on (home), 60 s screen off. tools/waltbench/idle.sh <label>
S=${SERIAL:-PHONE2}; case "$S" in PHONE2|PHONE1) ;; *) exit 2;; esac
cd "$(dirname "$0")/../.."; O=logs/walt/idle-$1.txt; A() { adb -s $S "$@"; }; exec > >(tee "$O") 2>&1
tis() { A shell 'for p in 0 4 7; do echo "P$p"; cat /sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state; done; echo I; cat /sys/devices/system/cpu/cpu*/cpuidle/state*/time | tr "\n" " "'; }
rep() { paste $1 $2 | awk '/^P/{if(p!="")pr(); p=$1; n=0; tot=0; s=0; next} /^I/{next} NF==4{d=$4-$2; f[n]=$1; t[n]=d; n++; tot+=d; s+=$1*d} function pr(){printf "%s avg %.0f MHz, at min-or-below %.0f%%, top %.0f%%\n", p, s/tot/1000, 100*(t[0]+t[1]+t[2]+t[3])/tot, 100*t[n-1]/tot} END{pr()}'; }
echo "== idle $1 gov $(A shell cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
A shell 'input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_HOME'; sleep 5
tis > /tmp/wi0.$$; sleep 60; tis > /tmp/wi1.$$; echo "screen ON 60 s:"; rep /tmp/wi0.$$ /tmp/wi1.$$
A shell 'input keyevent KEYCODE_SLEEP'; sleep 5; tis > /tmp/wi0.$$; sleep 60; tis > /tmp/wi1.$$; echo "screen OFF 60 s:"; rep /tmp/wi0.$$ /tmp/wi1.$$
echo "battery uA: $(A shell cat /sys/class/power_supply/battery/current_now)"
A shell 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'; rm -f /tmp/wi?.$$
