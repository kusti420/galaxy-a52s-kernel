#!/bin/busybox sh
# QEMU smoke: sec_vibrator.ko -> adsp_factory_dlkm.ko motor notifier, bound late with symbol_get. Run by run.sh as /init.
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
ld() { $B insmod /m/$1.ko $2; r "insmod $1 rc=$?"; }
V=/sys/class/timed_output/vibrator
dep() { $B grep "^$1 " /proc/modules | $B awk '{print $3 "/" $4}'; }
if $B grep -q vibfirst /proc/cmdline; then
# other order (second QEMU run): vibrator first, the listener binds on its first try
ld sec_vibrator
ld dc_vibrator
ld vbus_notifier
ld adsp_factory_dlkm
$B sleep 4
r "vibfirst try1=$($B dmesg | $B grep -c 'vibrator notifier registered (try 1)')"
else
# 1. ramdisk order: adsp_factory first, no vibrator module yet
ld vbus_notifier
ld adsp_factory_dlkm
$B sleep 5
r "phase1 registered-lines=$($B dmesg | $B grep -c 'vibrator notifier registered') adsp=$(dep adsp_factory_dlkm)"
# 2. the vibrator stage arrives later
ld sec_vibrator
ld dc_vibrator
$B sleep 5
r "phase2 registered-lines=$($B dmesg | $B grep -c 'vibrator notifier registered') sec_vibrator=$(dep sec_vibrator)"
fi
r "motor_type=$($B cat $V/motor_type)"
# 3. one vibration (no hardware: the driver has no GPIO here)
echo 300 > $V/enable; r "enable 300 rc=$?"
$B sleep 1
r "phase3 notify-on=$($B dmesg | $B grep -c 'ssc_motor_notify: ON') work-on=$($B dmesg | $B grep -c 'slpi_motor_work_func: msg_buf = 1')"
$B sleep 9
r "phase3 stop-timer=$($B dmesg | $B grep -c 'motor_stop_timer_func') work-off=$($B dmesg | $B grep -c 'slpi_motor_work_func: msg_buf = 0')"
# 4. references: sec_vibrator is pinned while adsp_factory listens (adsp_factory has no module_exit by design)
$B rmmod dc_vibrator; r "rmmod dc_vibrator rc=$?"
$B rmmod sec_vibrator 2>/dev/null; r "rmmod sec_vibrator while bound rc=$?"
r "END"
$B dmesg | $B grep -E 'FACTORY|vib' | $B tail -60
$B poweroff -f
