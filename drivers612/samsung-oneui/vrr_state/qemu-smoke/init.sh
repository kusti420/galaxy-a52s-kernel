#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
N=/sys/class/lcd/panel/vrr_state
# 1. module first, no lcd class at all: init must return 0 and retry
$B insmod /a52sxq_vrr_state.ko retry_ms=100; r "vrr rc=$?"
$B sleep 1
r "tries-before-panel: $($B dmesg | $B grep -c 'retrying every 100 ms')"
# 2. lcd.ko + panel appear later -> attach from the delayed work
$B insmod /lcd.ko; r "lcd rc=$?"
$B insmod /fakepanel.ko; r "fakepanel rc=$?"
$B sleep 1
$B ls -l $N | $B sed 's/^/SMK: ls /'
r "readlink $($B readlink -f /sys/class/lcd/panel)"
r "bytes=$($B cat $N | $B wc -c) od=[$($B cat $N | $B od -An -c | $B tr -s ' ')]"
V=/sys/class/lcd/panel/panel_vcom_type
$B ls -l $V | $B sed 's/^/SMK: ls /'
r "vcom bytes=$($B cat $V | $B wc -c) od=[$($B cat $V | $B od -An -c | $B tr -s ' ')]"
echo 1 > $V; r "vcom write rc=$? after=[$($B cat $V)]"
echo 1 > $N; r "write rc=$?"
r "bytes after write=$($B cat $N | $B wc -c)"
$B chmod 0440 $N; $B chown 1000:1000 $N; r "init-like chmod/chown rc=$? bytes=$($B cat $N | $B wc -c)"
# 3. rmmod while attached
$B rmmod a52sxq_vrr_state; r "rmmod1 rc=$? present=$($B ls /sys/class/lcd/panel | $B grep -cE 'vrr_state|panel_vcom_type')"
# 4. insmod with the panel already there, then the panel goes away first
$B insmod /a52sxq_vrr_state.ko; r "vrr2 rc=$?"
$B sleep 1
r "present2=$($B ls /sys/class/lcd/panel | $B grep -cE 'vrr_state|panel_vcom_type') bytes=$($B cat $N | $B wc -c)"
$B rmmod fakepanel; r "rmmod panel-first rc=$?"
$B rmmod a52sxq_vrr_state; r "rmmod2 rc=$?"
# 5. panel that already has vrr_state: leave it alone
$B insmod /fakepanel.ko dup=1; r "fakepanel dup rc=$?"
$B insmod /a52sxq_vrr_state.ko; r "vrr3 rc=$?"
$B sleep 1
r "dup content=[$($B cat $N)] vcom=[$($B cat $V)]"
$B rmmod a52sxq_vrr_state; r "rmmod3 rc=$? dup still=[$($B cat $N)] vcom gone=$($B ls /sys/class/lcd/panel | $B grep -c panel_vcom_type)"
$B rmmod fakepanel
# 6. no panel: give up after max_tries, rmmod after give-up
$B insmod /a52sxq_vrr_state.ko retry_ms=20 max_tries=5; r "vrr4 rc=$?"
$B sleep 1
$B rmmod a52sxq_vrr_state; r "rmmod4 rc=$?"
# 7. rmmod while still retrying
$B insmod /a52sxq_vrr_state.ko retry_ms=50; r "vrr5 rc=$?"
$B sleep 1
$B rmmod a52sxq_vrr_state; r "rmmod5 rc=$?"
$B rmmod lcd; r "rmmod lcd rc=$?"
$B dmesg | $B grep -iE "a52sxq_vrr_state|fakepanel|WARN|BUG|Oops|Call trace|duplicate" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
