#!/bin/bash
# Read-only SX9360 grip capture for a phone on 5.4 or 6.12 (One UI or IchthysOS). Classifies the grip IRQ rate.
#   capture-grip.sh [serial]            one snapshot -> $OUT/grip_<krel>_<mmdd_HHMM>.txt, prints the summary
#   capture-grip.sh --diff a.txt b.txt  rate between two snapshots of the same boot (IRQ/h, per cause)
# Reads only. Never touches grip_sensor/reset (its show() recalibrates), enable, onoff, motion, noti_enable,
# unknown_state, register_write, irq_count, menual_calibrate. No input, no vibration, no sound.
# Take one snapshot right after unplugging in the morning and one in the evening (same boot); --diff gives the rate.
set -u
OUT=${OUT:-/mnt/B1/OneUi9/scratch/k612_daily/grip}
num() { grep -ao "\b$2=[0-9]*" "$1" | head -n1 | cut -d= -f2; }
if [ "${1:-}" = "--diff" ]; then
	a=$2; b=$3
	ta=$(num "$a" boot_s); tb=$(num "$b" boot_s); dt=$((tb - ta))
	[ "$dt" -gt 0 ] || { echo "not the same boot / wrong order"; exit 1; }
	echo "interval ${dt}s ($(awk "BEGIN{printf \"%.2f\", $dt/3600}") h)"
	for k in proc_irq ws_events ws_wakeups ws_ms susp_ok susp_fail irq touch release compdone status0 nirq_high cal_usb cal_hall cal_mode ccic_attach ccic_dup suspend_dropped_irq enabled_s en_on; do
		va=$(num "$a" $k); vb=$(num "$b" $k); [ -n "$va" ] && [ -n "$vb" ] || continue
		awk "BEGIN{d=$vb-$va; printf \"%-20s +%-8d %.1f /h\n\", \"$k\", d, d*3600/$dt}"
	done
	ea=$(num "$a" enabled_s); eb=$(num "$b" enabled_s); ia=$(num "$a" irq); ib=$(num "$b" irq)
	[ -n "$ea" ] && [ -n "$eb" ] && [ "$eb" -gt "$ea" ] && awk "BEGIN{printf \"irq per ENABLED hour  %.1f (sensor enabled %.0f %% of the interval)\n\", ($ib-$ia)*3600/($eb-$ea), ($eb-$ea)*100/$dt}"
	exit 0
fi
S=${1:-OTHERPHONE}
read -r -d '' PHONE <<'P'
echo "krel=$(uname -r)"
echo "boot_s=$(cut -d. -f1 /proc/uptime)"
echo "mono_awake_s=$(dmesg | tail -n1 | sed 's/^\[ *\([0-9]*\)\..*/\1/')"
L=$(grep sx9360 /proc/interrupts); echo "interrupts: $L"
n=0; for c in $(echo "$L" | cut -d: -f2); do case $c in ''|*[!0-9]*) break;; *) n=$((n+c));; esac; done; echo "proc_irq=$n"
I=$(echo "$L" | cut -d: -f1 | tr -d ' ')
[ -n "$I" ] && for f in wakeup type chip_name hwirq actions; do echo "irq.$f=$(cat /sys/kernel/irq/$I/$f 2>/dev/null)"; done
for w in /sys/class/wakeup/wakeup*; do [ "$(cat $w/name 2>/dev/null)" = grip_wake_lock ] && echo "ws_events=$(cat $w/event_count) ws_wakeups=$(cat $w/wakeup_count) ws_ms=$(cat $w/total_time_ms) ws_max_ms=$(cat $w/max_time_ms)"; done
echo "susp_ok=$(cat /sys/power/suspend_stats/success 2>/dev/null) susp_fail=$(cat /sys/power/suspend_stats/fail 2>/dev/null) last_failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
echo "==grip_stats (6.12 module >= 2026-11-24 only)"
for d in /sys/bus/i2c/devices/*-0028; do [ -e $d/grip_stats ] && { echo "dev=$d"; cat $d/grip_stats; }; done
echo "==sysfs (safe reads only)"
G=/sys/class/sensors/grip_sensor
for f in name vendor mode onoff normal_threshold hysteresis motion noti_enable unknown_state raw_data; do echo "$f=$(cat $G/$f 2>&1)"; done
echo "hall_detect=$(cat /sys/class/sec/hall_ic/hall_detect 2>&1)"
echo "cover_cert=$(cat /sys/class/sensors/flip_cover_detector_sensor/nfc_cover_status 2>&1)"
echo "bus=$(ls -d /sys/bus/i2c/devices/*-0028 2>/dev/null) driver=$(readlink /sys/bus/i2c/devices/*-0028/driver 2>/dev/null)"
echo "module=$(cat /sys/module/sx9360/srcversion 2>/dev/null || echo builtin)"
echo "==dmesg window"
D=$(dmesg)
echo "first=$(echo "$D" | head -n1 | cut -c1-16) last=$(echo "$D" | tail -n1 | cut -c1-16)"
echo "$D" | grep -F '[GRIP]' | sed 's/^\[[ 0-9.]*\] //' | sed 's/capMain.*//;s/retry.*//;s/first working detected.*/first working detected/;s/Release detected.*/Release detected/' | sort | uniq -c | sort -rn | head -n40
echo "==dmesg tail"
echo "$D" | grep -E '\[GRIP\]|manager_muic_event_notify|i2c-gpio|i2c (read|write) error' | grep -v 'sx9360_get_data: retry' | tail -n80
echo "==battery"
dumpsys battery | grep -E 'AC powered|USB powered|Wireless powered|status:|level:'
echo "==sensorservice"
dumpsys sensorservice | grep -iE 'grip' | head -n12
echo "==SAR enable requests in logcat (window: $(logcat -d -t 1 -v time 2>/dev/null | tail -n1 | cut -c1-18))"
LC=$(logcat -d -b all 2>/dev/null | grep -E 'SARDEVICE_CP|SensorsGrip: \[grip_sensor\] (enable|readEvents)')
echo "logcat_first=$(logcat -d -b main 2>/dev/null | grep -m1 '^[0-9]' | cut -c1-18)"
echo "sar_cp_on=$(echo "$LC" | grep -c 'callAction = on') sar_cp_off=$(echo "$LC" | grep -c 'callAction = off') hal_grip=$(echo "$LC" | grep -c 'data = GRIP\|data = TOUCH\|data = ACTIVE') hal_release=$(echo "$LC" | grep -c 'data = RELEASE')"
echo "$LC" | tail -n12
echo "==batterystats (since last full charge / reset)"
B=$(dumpsys batterystats)
echo "$B" | grep -E 'Wakeup reason [0-9]+ sx9360_irq|Kernel Wake lock grip_wake_lock|Wakeup reason .*grip_wake_lock|Time on battery:|Start clock time'
echo "bs_wake_sx9360=$(echo "$B" | grep -c 'wake_reason=0:"[0-9]* sx9360_irq')"
echo "$B" | grep 'wake_reason=0:"[0-9]* sx9360_irq' | awk '{split($2,t,":"); h[$1" "t[1]]++} END{for(k in h) print "  wakes/hour " k ":00 " h[k]}' | sort
P
mkdir -p "$OUT"
k=$(adb -s "$S" shell uname -r | tr -d '\r') || exit 1
o=$OUT/grip_${k%%-*}_$(date +%m%d_%H%M).txt
adb -s "$S" shell "su -c 'echo $(printf '%s' "$PHONE" | base64 -w0) | base64 -d | sh'" > "$o" 2>&1
sed -i 's/\r$//' "$o"
echo "$o"
bs=$(num "$o" boot_s); pi=$(num "$o" proc_irq)
[ -n "$bs" ] && [ -n "$pi" ] && awk "BEGIN{printf \"since boot: %d irq in %.2f h = %.1f /h (all hours, enabled or not)\n\", $pi, $bs/3600, $pi*3600/$bs}"
grep -aE '^(krel|irq=|cal_mode|ccic_attach|grip_stats v1|ws_events|raw_data|normal_threshold|hysteresis)' "$o"
