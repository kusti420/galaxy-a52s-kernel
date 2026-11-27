#!/system/bin/sh
# Off-the-cable DRAIN recorder (SPEC/09 section 4). Root, ON the phone, detached, silent, passive: it writes nothing
# outside $O, touches no setting, no input, no vibration. Start it, then the user unplugs USB (the only physical step).
#   setsid nohup sh drain-rec.sh <label> [hours=2] [wait_unplug_s=1800] >/dev/null 2>&1 &
# It waits for USB to go away, records until USB is back or <hours> have passed (wall clock: the script is frozen while
# the phone is suspended, so every timing is from `date`), then writes $O/report.txt.
# Energy = the fuel gauge's own integration: batt_read_raw_soc (0.01 % steps) x charge_full_design. current_now is only
# sampled while awake (cross-check, biased high: the awake moments are the expensive ones).
# Self-test on the cable (no unplug wait, 60 s window, draw reads ~0):  DRAIN_TEST_S=60 sh drain-rec.sh selftest
L=${1:-run}; H=${2:-2}; WAITU=${3:-1800}
O=/data/local/tmp/drain/$L; rm -rf $O; mkdir -p $O; R=$O/report.txt
B=/sys/class/power_supply/battery
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
usb() { cat /sys/class/power_supply/usb/online 2>/dev/null; }
now() { date +%s; }
rd() { cat "$1" 2>/dev/null || echo NA; }
snap() { # $1 = tag
	d=$O/$1; mkdir -p $d
	for p in 0 4 7; do cat /sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state > $d/tis$p 2>/dev/null; done
	for c in 0 4 7; do for s in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do echo "cpu$c $(rd $s/name) $(rd $s/usage) $(rd $s/time)"; done; done > $d/idle
	cat /sys/class/kgsl/kgsl-3d0/gpu_trans_stat > $d/gpu 2>/dev/null
	for f in success fail failed_freeze failed_suspend; do echo "$f $(rd /sys/power/suspend_stats/$f)"; done > $d/susp
	cat /sys/kernel/debug/wakeup_sources > $d/ws 2>/dev/null
	cat /sys/block/zram0/mm_stat > $d/zram 2>/dev/null
	echo "t=$(now) raw_soc=$(rd $B/batt_read_raw_soc) cap=$(rd $B/capacity) mv=$(( $(rd $B/batt_voltage_now) / 1000 )) temp=$(rd $B/temp) ma=$(rd $B/current_now)" > $d/batt
}
ident() {
	echo "kernel: $(uname -r)  build: $(getprop ro.build.display.id)  realboot: $(G=/proc/device-tree/soc/a52sxq,realboot-base; [ -e $G ] && tr -d '\0' < $G)"
	echo "governor: $(for p in 0 4 7; do rd /sys/devices/system/cpu/cpufreq/policy$p/scaling_governor; done | tr '\n' ' ') cpuidle: $(rd /sys/devices/system/cpu/cpuidle/current_governor)"
	echo "zram: $(rd /sys/block/zram0/comp_algorithm)  io: $(rd /sys/block/sda/queue/scheduler)  gpu-uv: $(G=/proc/device-tree/soc/a52sxq,gpu-uv; [ -e $G ] && tr -d '\0' < $G || echo off)"
	echo "refresh: peak $(settings get system peak_refresh_rate) min $(settings get system min_refresh_rate)  aod: $(settings get secure doze_always_on)  wifi-ps: $(iw dev wlan0 get power_save 2>/dev/null)"
}
{ echo "drain-rec $L: waiting up to ${WAITU}s for USB unplug ($(date))"; ident; } > $R
t0=$(now); [ -n "${DRAIN_TEST_S:-}" ] && WAITU=0
while [ -z "${DRAIN_TEST_S:-}" ] && [ "$(usb)" = 1 ]; do [ $(( $(now) - t0 )) -ge $WAITU ] && { echo "USB never unplugged, giving up" >> $R; exit 1; }; sleep 5; done
[ -z "${DRAIN_TEST_S:-}" ] && sleep 20   # let the unplug transient (charger IC, gadget teardown) settle before the start sample
snap start; ts=$(now); end=$(( ts + ${DRAIN_TEST_S:-$(( H * 3600 ))} ))
while :; do
	sleep 30
	t=$(now); echo "$t $(rd $B/current_now) $(rd $B/batt_read_raw_soc)" >> $O/samples
	[ -z "${DRAIN_TEST_S:-}" ] && [ "$(usb)" = 1 ] && { why="USB back"; break; }
	[ "$t" -ge "$end" ] && { why="duration reached"; break; }
done
snap end; te=$(now)
FULL=$(( $(rd $B/charge_full_design) / 1000 ))   # mAh
. $O/start/batt; s_raw=$raw_soc; s_mv=$mv; s_t=$temp
. $O/end/batt; e_raw=$raw_soc; e_mv=$mv; e_t=$temp
dt=$(( te - ts )); draw=$(( s_raw - e_raw ))
{
	echo "stopped: $why  window: ${dt}s ($(( dt / 60 )) min)"
	echo "raw_soc: $s_raw -> $e_raw (0.01 % steps)  voltage: $s_mv -> $e_mv mV  temp: $s_t -> $e_t (0.1 C)"
	if [ "$dt" -gt 0 ] && [ "$FULL" -gt 0 ]; then
		echo "used: $(( draw * FULL / 10000 )) mAh of $FULL  =>  avg $(( draw * FULL * 3600 / 10000 / dt )) mA  ($(( draw * 3600 / dt )) x0.01 %/h)"; fi
	echo "awake current samples (mA, biased high): n=$(wc -l < $O/samples) avg=$(awk '{s+=$2;n++} END {if(n) printf "%d", s/n}' $O/samples)"
	echo "suspend_stats delta:"; paste $O/start/susp $O/end/susp | awk '{printf "  %s %d\n", $1, $4-$2}'
	echo "time_in_state delta (s) per policy, top 4:"
	for p in 0 4 7; do echo "  policy$p: $(paste $O/start/tis$p $O/end/tis$p | awk '{d=($4-$2)/100; if (d>0) printf "%s:%d\n", $1/1000, d}' | sort -t: -k2 -rn | head -4 | tr '\n' ' ')"; done
	echo "cpuidle usage delta:"; paste $O/start/idle $O/end/idle | awk '{printf "  %s %s %d\n", $1, $2, $7-$3}'
	echo "gpu_trans_stat (end):"; sed 's/^/  /' $O/end/gpu
	echo "top wakeup sources by wakeup_count delta:"
	awk 'FNR==1{next} NR==FNR{a[$1]=$4; next} {d=$4-a[$1]; if (d>0) print d, $1}' $O/start/ws $O/end/ws | sort -rn | head -10 | sed 's/^/  /'
	ident
} >> $R
