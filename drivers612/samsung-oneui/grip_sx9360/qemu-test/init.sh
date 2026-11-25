#!/bin/busybox sh
# QEMU smoke for sx9360.ko (+ i2c-gpio/i2c-algo-bit). Run by run.sh as /init.
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
ld() { $B insmod /m/$1.ko $2; r "insmod $1 rc=$?"; }
gs=/sys/class/sensors/grip_sensor; ev=/sys/class/sensor_event/symlink
# 0. no class, no deps loaded except the notifier chain sx9360 links against
for m in switch_class sec_core usb_notify_layer vbus_notifier common_muic pdic_notifier_module usb_typec_manager; do ld $m; done
ld sx9360
$B rmmod sx9360; r "rmmod sx9360 (no device) rc=$?"
ld sx9360
# 1. the i2c-gpio bus (a52sxq node shape) comes up before /sys/class/sensors exists -> its sx9360 must defer
ld i2c-algo-bit
ld i2c-gpio
$B sleep 1
c=$($B ls /sys/bus/i2c/devices | $B grep -- '-0028$' | $B head -1)
r "gpio bus client=$c driver=$([ -e /sys/bus/i2c/devices/$c/driver ] && echo bound || echo none) grip_sensor=$([ -e $gs ] && echo yes || echo no) inputs=$($B grep -c 'grip_' /proc/bus/input/devices)"
# 2. the class owner (real adsp_factory_dlkm.ko) arrives; re-probe the deferred client: no chip on that bus -> clean -ENODEV
ld adsp_factory_dlkm
echo $c > /sys/bus/i2c/drivers_probe; r "reprobe $c rc=$?"
$B sleep 2
r "no-chip probe: driver=$([ -e /sys/bus/i2c/devices/$c/driver ] && echo bound || echo none) grip_sensor=$([ -e $gs ] && echo yes || echo no) symlink=$([ -L $ev/grip_sensor ] && echo yes || echo no) inputs=$($B grep -c 'grip_' /proc/bus/input/devices)"
# 3. a chip that answers (sxfake register file, r02 setup values)
ld sxfake
$B sleep 2
r "after class: grip_sensor=$([ -e $gs ] && echo yes || echo no)"
r "name=$($B cat $gs/name) vendor=$($B cat $gs/vendor)"
r "symlink=$([ -L $ev/grip_sensor ] && echo yes || echo no) input-name=$($B cat $ev/grip_sensor/name)"
r "inputs: $($B grep -E 'N: Name=\"grip_(sensor|notifier)\"' /proc/bus/input/devices | $B tr '\n' ' ')"
r "attrs=$($B ls $gs | $B wc -l) onoff=$($B cat $gs/onoff) mode=$($B cat $gs/mode) threshold=$($B cat $gs/normal_threshold)"
r "irq: $($B grep sx9360 /proc/interrupts | $B tr -s ' ')"
r "irq-thread: $($B ps | $B grep -c '\[irq/.*sx9360')"
$B ls -l $gs/ | $B grep -E ' (onoff|motion|noti_enable|register_write|name)$' | $B sed 's/^/SMK: ls /'
$B sleep 1
echo 1 > $ev/grip_sensor/enable; r "enable 1 rc=$? -> $($B cat $ev/grip_sensor/enable)"
$B sleep 1
echo 0 > $ev/grip_sensor/enable; r "enable 0 rc=$? -> $($B cat $ev/grip_sensor/enable)"
gst=$(for d in /sys/bus/i2c/devices/*-0028; do [ -e $d/grip_stats ] && echo $d/grip_stats; done | $B head -n1)
r "grip_stats: $($B head -n4 $gst | $B tr '\n' ' ')"
r "i2cgpio bus: $($B ls /sys/bus/i2c/devices | $B tr '\n' ' ')"
# 4. teardown and a second round (leaks would make the 2nd probe fail on names/gpios)
$B rmmod sx9360; r "rmmod sx9360 rc=$?"
r "after rmmod: grip_sensor=$([ -e $gs ] && echo yes || echo no) symlink=$([ -L $ev/grip_sensor ] && echo yes || echo no) inputs=$($B grep -c 'grip_' /proc/bus/input/devices) sensor_dev=$([ -e /sys/class/sensors/sensor_dev ] && echo yes || echo no)"
ld sx9360
$B sleep 4
r "round2: grip_sensor=$([ -e $gs ] && echo yes || echo no) inputs=$($B grep -c 'N: Name=\"grip_' /proc/bus/input/devices)"
# debug work (first run 20 s after probe, then every 2 s): hall-IC poll + zero-detect defence
$B sleep 26
r "debug work: hall-open-fail lines=$($B dmesg | $B grep -c 'sx9360_check_hallic_state: file open fail')"
$B rmmod sxfake; r "rmmod sxfake rc=$?"
$B rmmod i2c-gpio; r "rmmod i2c-gpio rc=$?"
$B rmmod i2c-algo-bit; r "rmmod i2c-algo-bit rc=$?"
r "after adapters gone: grip_sensor=$([ -e $gs ] && echo yes || echo no) inputs=$($B grep -c 'grip_' /proc/bus/input/devices)"
$B rmmod sx9360; r "rmmod sx9360 final rc=$?"
$B dmesg | $B grep -iE "GRIP|sx9360|i2c-gpio|sxfake|WARN|BUG|Oops|Call trace" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
