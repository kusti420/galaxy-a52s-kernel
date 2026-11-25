#!/bin/busybox sh
# QEMU test of the a52 watchdog core variant with the a52_wdt_sim backend. See run.sh.
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mknod /dev/null c 1 3
for m in $($B cat /mods.order); do $B insmod /m/$m || echo "WT: insmod $m FAILED"; done
$B insmod /qcom_wdt_core.ko $($B cat /core.args); echo "WT: core rc=$?"
$B insmod /a52_wdt_sim.ko; echo "WT: sim rc=$?"
P=/sys/module/a52_wdt_sim/parameters
D=$($B find /sys/devices/platform -name a52_stats)
st() { echo "WT: $1: pet=$($B cat $P/n_pet) en=$($B cat $P/n_enable) dis=$($B cat $P/n_disable) BARK=$($B cat $P/n_bark) armed=$($B cat $P/armed) bark_ms=$($B cat $P/bark) bite_ms=$($B cat $P/bite) gap_ms=$($B cat $P/max_gap_ms) fail=$($B cat /sys/power/suspend_stats/fail) ok=$($B cat /sys/power/suspend_stats/success) | $([ -n "$D" ] && $B cat $D)"; }
sus() { echo freeze > /sys/power/state; echo "WT: $1 write rc=$?"; }
st load
$B sleep 21; st idle21
echo devices > /sys/power/pm_test; sus pmtest-devices; st pmtest-devices
echo platform > /sys/power/pm_test; sus pmtest-platform5; st pmtest-platform5
echo 26 > /sys/module/suspend/parameters/pm_test_delay; sus pmtest-platform26; st pmtest-platform26
echo 5 > /sys/module/suspend/parameters/pm_test_delay
echo 1 > $P/fail_disable; sus faildisable; st faildisable
echo "WT: last_failed_dev=$($B cat /sys/power/suspend_stats/last_failed_dev) errno=$($B cat /sys/power/suspend_stats/last_failed_errno)"
$B sleep 12; st faildisable+12
echo 26 > /sys/module/suspend/parameters/pm_test_delay; sus faildisable-26; st faildisable-26
echo 5 > /sys/module/suspend/parameters/pm_test_delay
echo 0 > $P/fail_disable
echo 1 > $P/fail_enable; sus failenable; st failenable; $B sleep 11; st failenable+11
echo 0 > $P/fail_enable; sus recover; st recover; $B sleep 11; st recover+11
echo none > /sys/power/pm_test
echo "WT: rtc=$($B ls /sys/class/rtc)"
echo +27 > /sys/class/rtc/rtc0/wakealarm; sus s2idle-rtc27; st s2idle-rtc27
$B sleep 11; st final
$B dmesg | $B grep -E "WDTSIM: BARK|Watchdog|refused|could not|WARNING|BUG:|Oops|Call trace" | $B sed 's/^/WT: dmesg /'
echo "WT: END"
$B poweroff -f
