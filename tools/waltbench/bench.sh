#!/bin/bash
# cpufreq governor comparison on a test phone (runtime only, silent): cold launches, Settings scroll jank,
# time_in_state over the run, idle frequencies, temperatures.   tools/waltbench/bench.sh <label>   -> logs/walt/<label>.txt
S=${SERIAL:-PHONE2}; case "$S" in PHONE2|PHONE1) ;; *) echo "test phones only"; exit 2;; esac
cd "$(dirname "$0")/../.."; mkdir -p logs/walt; O=logs/walt/$1.txt; A() { adb -s $S "$@"; }
exec > >(tee "$O") 2>&1
A shell 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' >/dev/null 2>&1
tis() { A shell 'for p in 0 4 7; do echo "P$p"; cat /sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state; done'; }
temps() { A shell 'for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type); case $t in cpu-0-0*|cpu-1-0*|cpu-1-3*|gpuss-0*|battery|skin*|xo-therm*) echo "$t=$(cat $z/temp 2>/dev/null)";; esac; done' | tr '\n' ' '; echo; }
echo "== $1 $(date +%T) gov: $(A shell 'cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor' | tr '\n' ' ') kernel $(A shell uname -r)"
echo "temps start: $(temps)"; tis > /tmp/waltbench-tis0.$$
echo "== cold launch (am start -W TotalTime ms, force-stop before each)"
for pkg in com.android.settings com.android.dialer com.android.contacts org.lineageos.aperture com.android.documentsui; do
	c=$(A shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg" | tail -1 | tr -d '\r')
	v=""; for i in 1 2 3 4 5; do A shell "am force-stop $pkg; input keyevent KEYCODE_HOME" >/dev/null; sleep 1.5
		t=$(A shell "am start -W -n $c" | sed -n 's/^TotalTime: *//p' | tr -d '\r'); v="$v $t"; sleep 1.5; done
	echo "launch $pkg:$v  median $(echo $v | tr ' ' '\n' | sort -n | sed -n 3p)"
done
echo "== scroll jank (Settings, 20 swipes)"
A shell 'am force-stop com.android.settings; am start -W -n com.android.settings/.Settings >/dev/null; sleep 2; dumpsys gfxinfo com.android.settings reset >/dev/null
  i=0; while [ $i -lt 10 ]; do input swipe 540 1700 540 500 150; input swipe 540 500 540 1700 150; i=$((i+1)); done
  dumpsys gfxinfo com.android.settings | grep -E "Total frames rendered|Janky frames:|Janky frames \(legacy\)|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Slow UI|Number Frame deadline" | head -9; input keyevent KEYCODE_HOME'
tis > /tmp/waltbench-tis1.$$
echo "== time_in_state over launches+scroll (avg MHz, % at lowest, % at highest)"
paste /tmp/waltbench-tis0.$$ /tmp/waltbench-tis1.$$ | awk '/^P/{if(p!="")pr(); p=$1; n=0; tot=0; s=0; next} {d=$4-$2; f[n]=$1; t[n]=d; n++; tot+=d; s+=$1*d} function pr(){printf "%s avg %.0f MHz low %.0f%% high %.0f%% (ticks %d)\n", p, s/tot/1000, 100*t[0]/tot, 100*t[n-1]/tot, tot} END{pr()}'
echo "temps after load: $(temps)"
echo "== idle 60 s screen on (home), 20 samples of scaling_cur_freq over the last 20 s"
sleep 40; A shell 'i=0; while [ $i -lt 20 ]; do echo "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) $(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq) $(cat /sys/devices/system/cpu/cpufreq/policy7/scaling_cur_freq)"; sleep 1; i=$((i+1)); done' | awk '{a+=$1;b+=$2;c+=$3;n++} END{printf "idle avg kHz: policy0 %.0f policy4 %.0f policy7 %.0f\n", a/n,b/n,c/n}'
echo "temps idle: $(temps)"; echo "battery: $(A shell 'cat /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/voltage_now' | tr '\n' ' ')"
echo "kernel problems: $(A shell 'dmesg | grep -cE "WARNING|BUG:|Oops"')"
rm -f /tmp/waltbench-tis?.$$; echo "== done $(date +%T)"
