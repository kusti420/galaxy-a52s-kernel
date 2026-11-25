#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t tmpfs tmpfs /dev
$B mknod /dev/null c 1 3; $B mknod /dev/console c 5 1
r() { echo "SMK: $*"; }
$B ifconfig lo 127.0.0.1 up; r "lo rc=$?"
/kfreecess_test absent
# cgroup v2 with an always-frozen child (S26-style freecess)
$B mkdir /cg2; $B mount -t cgroup2 none /cg2; r "cgroup2 mount rc=$?"
$B mkdir /cg2/t; echo 1 > /cg2/t/cgroup.freeze; r "cgroup2 frozen child rc=$?"
r "v2 controllers=[$($B cat /cg2/cgroup.controllers)]"
# the ROM's cgroup v1 freezer hierarchy (init.a52sxq.rc mount + init.rc mkdirs)
$B mkdir /dev/freezer; $B mount -t cgroup -o freezer none /dev/freezer; r "v1 freezer mount rc=$?"
for g in frozen olaf abnormal; do $B mkdir /dev/freezer/$g; done
echo FROZEN > /dev/freezer/frozen/freezer.state; r "v1 frozen FROZEN rc=$? state=$($B cat /dev/freezer/frozen/freezer.state)"
echo THAWED > /dev/freezer/olaf/freezer.state; r "v1 olaf THAWED rc=$? state=$($B cat /dev/freezer/olaf/freezer.state)"
r "v1 files: $($B ls /dev/freezer/frozen | $B tr '\n' ' ')"
$B grep freezer /proc/cgroups | $B sed 's/^/SMK: cgroups /'
$B mkdir /dev/binderfs; $B mount -t binder binder /dev/binderfs; r "binderfs rc=$? $($B ls /dev/binderfs | $B tr '\n' ' ')"
$B insmod /freecess.ko $FC_ARGS; r "insmod rc=$?"
r "v1 files after insmod: $($B ls /dev/freezer/frozen | $B tr '\n' ' ')"
/kfreecess_test $KFT_ARG; r "kfreecess_test rc=$?"
$B sleep 1
P=/sys/module/freecess/parameters
for f in $($B ls $P); do echo "SMK: param $f=$($B cat $P/$f)"; done
$B rmmod freecess; r "rmmod rc=$?"
r "v1 files after rmmod: $($B ls /dev/freezer/frozen | $B tr '\n' ' ')"
/kfreecess_test absent
$B dmesg | $B grep -iE "freecess|WARN|BUG|Oops|Call trace|binder" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
