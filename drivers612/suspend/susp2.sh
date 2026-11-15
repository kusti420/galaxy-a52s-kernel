#!/bin/busybox sh
# First system-suspend tests of the 6.12 test Android (a52sxq). Replaces ../androidboot/susptest.sh,
# which detached USB (lost phone 2 twice on 2026-11-14: never detach USB again).
# Nothing here touches USB beyond the PM core skipping the controller (a52susp usbkeep=1): the PC
# link stays enumerated through the whole test.
#
# Run as root in the helper namespace of the test kernel (telnet shell, tools/tsh.py), DETACHED,
# so the script survives a dropped session (an adb/telnet session that ends sends SIGHUP to its
# process group; that is the likely reason the old script's own deadman never fired):
#   setsid /bin/busybox sh /tmp/susp2.sh <level> </dev/null >/tmp/susp2.out 2>&1 &
# Files: /tmp/a52susp.ko next to this script (or A52SUSP_KO=<path>).
# Levels, one per test session (README.md, test plan):
#   preflight       read-only checks + RTC alarm IRQ self-test while awake; no suspend
#   freezer         pm_test freezer  (tasks frozen 5 s, no device callbacks)
#   devices         pm_test devices  (all .prepare/.suspend/.resume/.complete, 5 s)
#   platform        pm_test platform (+ late/noirq phases, wake IRQ interlock, 5 s)
#   s2idle-shallow  REAL suspend to idle, deepest cpuidle state disabled (tick keeps running:
#                   a52susp's hrtimer backstop and deadman work all the time), RTC wake +15 s
#   s2idle-deep     REAL suspend to idle with cluster power collapse and frozen tick: only the
#                   RTC alarm can wake it. Refused unless A52_DEEP_OK=1 (needs the owner's OK)
# Env: A52_WDT=1 arm the hypervisor watchdog (30 s busy / 35 s bite) for the run and pet it
#      (main session's decision only: PHONE-RULES forbids agents to arm it);
#      A52_KEEP_RADIOS=1 leave Wi-Fi/BT as they are (default: switched off for the run);
#      A52_WAKE_S (default 15) RTC wake delay for the s2idle levels.
# Result: /tmp/susp2/<level>-<time>.log, a "RESULT" line in the kernel log (ramoops keeps it).
trap '' HUP
B=${B-/bin/busybox}   # B= (empty) in the Android test boot: toybox/mksh commands
LEVEL=${1:?level: preflight|freezer|devices|platform|s2idle-shallow|s2idle-deep}
D=/tmp/susp2; $B mkdir -p $D; L=$D/$LEVEL-$($B date +%H%M%S).log; : > $L
KO=${A52SUSP_KO:-${0%/*}/a52susp.ko}
P=/sys/module/a52susp/parameters
if [ -x /bin/an ]; then AN=/bin/an; else AN="sh -c"; fi
log() { echo "$($B cut -d' ' -f1 /proc/uptime) $*" >> $L; echo "a52susp-test: $*" > /dev/kmsg; }
unlock() { [ "$($B cat $D/lock 2>/dev/null)" = $$ ] && $B rm -f $D/lock; return 0; }
die() { log "ABORT: $*"; unlock; exit 1; }
w() { echo "$2" > "$1" 2>/dev/null || log "write $2 > $1 failed"; }
[ "$($B id -u)" = 0 ] || die "not root"
[ -e $D/lock ] && [ -d /proc/$($B cat $D/lock) ] && die "another run is active (pid $($B cat $D/lock))"
echo $$ > $D/lock
case $LEVEL in preflight|freezer|devices|platform|s2idle-shallow|s2idle-deep) ;; *) die "unknown level $LEVEL";; esac
[ $LEVEL = s2idle-deep ] && [ "${A52_DEEP_OK:-0}" != 1 ] && die "s2idle-deep needs A52_DEEP_OK=1 (owner's OK: a missed wake-up there needs his keys)"
log "level=$LEVEL kernel=$($B uname -r) pid=$$"

# ---------- facts (all levels) ----------
grep -qw mem /sys/power/state || die "/sys/power/state has no mem: $(cat /sys/power/state)"
MS0=$(cat /sys/power/mem_sleep); log "mem_sleep before: $MS0"
RTCIRQ=$($B awk '/pm8xxx_rtc_alarm/ {sub(":","",$1); print $1; exit}' /proc/interrupts)
[ -n "$RTCIRQ" ] || die "no pm8xxx_rtc_alarm line in /proc/interrupts"
RTCW=$(cat /sys/class/rtc/rtc0/device/power/wakeup 2>/dev/null)
log "rtc0=$(cat /sys/class/rtc/rtc0/name 2>/dev/null) alarm irq=$RTCIRQ wakeup=$RTCW"
[ "$RTCW" = enabled ] || { w /sys/class/rtc/rtc0/device/power/wakeup enabled; log "rtc wakeup now $(cat /sys/class/rtc/rtc0/device/power/wakeup)"; }
stats() { for f in success fail last_failed_dev last_failed_errno last_failed_step; do printf '%s=%s ' $f "$(cat /sys/power/suspend_stats/$f 2>/dev/null)"; done; }
log "stats before: $(stats)"
{
	echo "== cpuidle (cpu0, cpu7)"; for c in 0 7; do for s in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do
		echo "cpu$c $(basename $s) $(cat $s/name)/$(cat $s/desc) disable=$(cat $s/disable) usage=$(cat $s/usage) s2idle=$(cat $s/s2idle/usage 2>/dev/null)"; done; done
	echo "== genpd"; cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -40
	for g in /sys/kernel/debug/pm_genpd/*cluster*/idle_states; do [ -f $g ] && { echo "-- $g"; cat $g; }; done
	echo "== wakeup sources (active ones)"; $B awk 'NR==1 || $6 > 0' /sys/kernel/debug/wakeup_sources 2>/dev/null
	echo "== wake-capable devices"; for d in /sys/class/wakeup/wakeup*; do echo "$(cat $d/name 2>/dev/null) events=$(cat $d/event_count 2>/dev/null)"; done
	echo "== usb"; for f in /sys/devices/platform/soc/a600000.ssusb/power/runtime_status /sys/devices/platform/soc/a600000.ssusb/a600000.dwc3/power/runtime_status /sys/class/udc/*/state; do echo "$f: $(cat $f 2>/dev/null)"; done
	echo "== battery"; cat /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/status 2>/dev/null
} >> $L 2>&1
BAT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
[ -n "$BAT" ] && [ "$BAT" -lt 30 ] 2>/dev/null && die "battery $BAT % < 30 %"

# ---------- RTC alarm IRQ self-test while awake (all levels: a dead wake path stops the run) ----------
irqcount() { $B awk -v n="$RTCIRQ:" '$1==n {s=0; for (i=2;i<=NF && $i ~ /^[0-9]+$/;i++) s+=$i; print s}' /proc/interrupts; }
C0=$(irqcount); w /sys/class/rtc/rtc0/wakealarm 0; w /sys/class/rtc/rtc0/wakealarm +3; $B sleep 6; C1=$(irqcount)
log "rtc alarm self-test: irq $RTCIRQ count $C0 -> $C1, wakealarm now '$(cat /sys/class/rtc/rtc0/wakealarm)'"
[ "$C1" -gt "$C0" ] 2>/dev/null || die "the RTC alarm IRQ did not fire while awake: no suspend may rely on it"
[ $LEVEL = preflight ] && { log "RESULT level=preflight ok (no suspend)"; unlock; exit 0; }

# ---------- safety net ----------
grep -q "^a52susp " /proc/modules || die "a52susp not loaded: it must come from a boot stage (a52.mods=...,susp), never a live insmod"
w $P/wake_irq $RTCIRQ; w $P/allow_tgid 0; w $P/allow_deep 0
w /proc/sys/kernel/sysrq 1
for f in hung_task_panic softlockup_panic panic_on_oops; do w /proc/sys/kernel/$f 1; done; w /proc/sys/kernel/panic -1
WQ0=$(cat /sys/module/workqueue/parameters/panic_on_stall 2>/dev/null); w /sys/module/workqueue/parameters/panic_on_stall 1
CS0=$(cat /sys/module/printk/parameters/console_suspend 2>/dev/null); w /sys/module/printk/parameters/console_suspend N
w /sys/power/pm_print_times 1; w /sys/power/pm_debug_messages 1; w /sys/power/pm_async 0
w /sys/power/mem_sleep s2idle
case "$(cat /sys/power/mem_sleep)" in *"[s2idle]"*) ;; *) die "mem_sleep is not s2idle: $(cat /sys/power/mem_sleep)";; esac
DIS=""
WDTPET=""
restore() {
	w $P/allow_tgid 0; w /sys/power/pm_test none
	for s in $DIS; do echo 0 > $s 2>/dev/null; done
	[ -e $P/usbkeep ] && w $P/usbkeep 0
	[ -n "$WQ0" ] && w /sys/module/workqueue/parameters/panic_on_stall "$WQ0"
	[ -n "$CS0" ] && w /sys/module/printk/parameters/console_suspend "$CS0"
	w /sys/power/pm_async 1
	if [ -n "$WDTPET" ]; then echo "5 2 0" > /sys/module/hhwdt/parameters/raw; kill $WDTPET 2>/dev/null; w $P/wdt_pet 0; log "hypervisor watchdog disabled"; fi
	unlock
}
trap restore EXIT
if [ "${A52_WDT:-0}" = 1 ]; then
	R=/sys/module/hhwdt/parameters/raw; [ -e $R ] || die "A52_WDT=1 but hhwdt is not loaded"
	# milliseconds of BUSY time (kexec/README.md): bark 30000 = 0x7530, bite 35000 = 0x88b8
	echo "8 7530 ffff" > $R; echo "8 ffff 88b8" > $R; echo "5 3 0" > $R; echo "7 0 0" > $R
	( while :; do echo "7 0 0" > $R; $B sleep 2; done ) & WDTPET=$!
	w $P/wdt_pet 1; log "hypervisor watchdog armed 30/35 s busy time, pet every 2 s (pid $WDTPET)"
fi

# ---------- quiet the system ----------
if [ "${A52_KEEP_RADIOS:-0}" != 1 ]; then
	$AN "svc wifi disable" >/dev/null 2>&1; $AN "cmd bluetooth_manager disable" >/dev/null 2>&1
	log "Wi-Fi and Bluetooth switched off for the run (BT HAL's UART vote makes msm_geni_serial refuse suspend)"
fi
$AN "input keyevent 223" >/dev/null 2>&1; $B sleep 5   # screen off (KEYCODE_SLEEP): panel and GPU idle first
log "screen: $($AN 'dumpsys power' 2>/dev/null | grep -m1 mWakefulness=)"

case $LEVEL in
freezer) w $P/usbkeep 0; w /sys/power/pm_test freezer;;
devices|platform) w $P/usbkeep 1; w /sys/power/pm_test $LEVEL;;
s2idle-shallow|s2idle-deep)
	w $P/usbkeep 1; w /sys/power/pm_test none
	if [ $LEVEL = s2idle-shallow ]; then
		# the deepest state of each CPU is the only one with ->enter_s2idle (cpuidle-psci); with it
		# disabled, s2idle idles in shallower states and never freezes the tick
		for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle; do
			s=$(ls -d $c/state* | $B tail -n 1)/disable   # state0..state2: lexical order is fine
			[ "$(cat $s)" = 0 ] && { echo 1 > $s && DIS="$DIS $s"; }
		done
		log "deepest cpuidle state disabled on: $DIS"
		w $P/backstop_ms 30000
	fi
	w $P/alarm_s 45
	w /sys/class/rtc/rtc0/wakealarm 0; w /sys/class/rtc/rtc0/wakealarm "+${A52_WAKE_S:-15}"
	log "RTC wakealarm at $(cat /sys/class/rtc/rtc0/wakealarm) (now $(cat /sys/class/rtc/rtc0/since_epoch))";;
esac
[ "$LEVEL" = freezer ] || [ "$(cat $P/usbkeep)" = 1 ] || die "usbkeep did not apply"

# ---------- the suspend ----------
echo "a52susp-test: ===== $LEVEL begin =====" > /dev/kmsg
w $P/allow_tgid $$
T0=$($B cut -d' ' -f1 /proc/uptime)
echo mem > /sys/power/state; RC=$?
T1=$($B cut -d' ' -f1 /proc/uptime)
w $P/allow_tgid 0
echo "a52susp-test: ===== $LEVEL end rc=$RC =====" > /dev/kmsg
log "RESULT level=$LEVEL rc=$RC uptime $T0 -> $T1 wakeup_irq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null) $(stats)"
$B dmesg | $B sed -n "/===== $LEVEL begin/,/===== $LEVEL end/p" | grep -v -E 'avc: |audit' > $D/$LEVEL-dmesg.txt
grep -E 'PM: |a52susp|Freezing|Restarting|refusing|failed|returns -|Abort|suspend debug|calling|returned [^0]' $D/$LEVEL-dmesg.txt | grep -v 'returned 0 after' | $B tail -n 120 >> $L
$AN "input keyevent 224" >/dev/null 2>&1   # screen back on (KEYCODE_WAKEUP)
log "done"
