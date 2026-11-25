#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/uinput c 10 223; $B mknod /dev/null c 1 3
echo "IBS: phase A: input_booster WITHOUT cpufreq_limit/sched-walt"
$B insmod /input_booster.ko; echo "IBS: A ib rc=$?"
echo "IBS: A touch head=[$($B cat /sys/class/input_booster/touch/head)]"
$B rmmod input_booster; echo "IBS: A rmmod rc=$?"
echo "IBS: phase B: fakewalt + cpufreq_limit + input_booster"
$B insmod /fakewalt.ko; echo "IBS: fakewalt rc=$?"
$B insmod /cpufreq_limit.ko; echo "IBS: cflm rc=$?"
$B insmod /input_booster.ko; echo "IBS: ib rc=$?"
echo "IBS: ls class"; $B ls -l /sys/class/input_booster/ /sys/devices/virtual/input_booster/touch/
for f in enable_event debug_level sendevent ib_mode_state; do echo "IBS: $f=$($B cat /sys/class/input_booster/$f)"; done
for d in key touchkey touch multitouch keyboard MOUSE mouse_wheel pen_hover pen; do echo "IBS: $d head=[$($B cat /sys/class/input_booster/$d/head)] tail=[$($B cat /sys/class/input_booster/$d/tail)] level=$($B cat /sys/class/input_booster/$d/level)"; done
echo "250 1400000 0 2 0" > /sys/class/input_booster/pen/head; echo "IBS: pen head after write: $($B cat /sys/class/input_booster/pen/head)"
echo "1 2" > /sys/class/input_booster/pen/head; echo "IBS: pen head after short write (ignored): $($B cat /sys/class/input_booster/pen/head)"
echo "1 2 3 4 5 6" > /sys/class/input_booster/pen/head; echo "IBS: pen head after long write (ignored): $($B cat /sys/class/input_booster/pen/head)"
echo 1 > /sys/class/input_booster/touch/level; echo "IBS: level=$($B cat /sys/class/input_booster/key/level) (global)"
echo 7 > /sys/class/input_booster/touch/level; echo "IBS: level after 7 (ignored)=$($B cat /sys/class/input_booster/key/level)"
echo 3 > /sys/class/input_booster/ib_mode_state; echo "IBS: ib_mode_state=$($B cat /sys/class/input_booster/ib_mode_state)"
echo 0 > /sys/class/input_booster/ib_mode_state
echo 1 > /sys/class/input_booster/debug_level
$B cat /proc/bus/input/handlers
/bin/ibtest &
P=$!
$B sleep 1
for e in /sys/class/input/event*; do n=$($B basename $e); nm=$($B cat $e/device/name 2>/dev/null); echo "IBS: $n $nm"; if [ "$nm" = ibtest-ts ]; then MM=$($B cat $e/dev); $B mknod /dev/input/$n c ${MM%%:*} ${MM##*:}; exec 3</dev/input/$n; echo "IBS: opened $n"; fi; done
wait $P
echo "IBS: after exit: $($B cat /sys/devices/system/cpu/cflm/info | $B grep '\[1\]')"
exec 3<&-
$B sleep 1
echo "IBS: rmmod while an instance is held (60 s safety timer pending)"
$B rmmod input_booster; echo "IBS: held rmmod rc=$?"; echo "IBS: after rmmod: $($B cat /sys/devices/system/cpu/cflm/info | $B grep '\[1\]')"
$B insmod /input_booster.ko; echo "IBS: re-insmod rc=$?"
echo 0 > /sys/class/input_booster/debug_level
$B dmesg | $B grep -c "Input Booster" | $B sed 's/^/IBS: booster log lines /'
$B dmesg | $B grep -i "input_booster\|Input Booster\|cflm\|BUG\|WARN\|Oops\|lockdep\|sched_set" > /tmp.log; $B head -60 /tmp.log; echo ...; $B tail -40 /tmp.log
exec 3<&-
$B rmmod input_booster; echo "IBS: rmmod rc=$?"; $B cat /sys/devices/system/cpu/cflm/info | $B grep '\[1\]'
$B dmesg | $B tail -5
echo "IBS: END"
$B poweroff -f
