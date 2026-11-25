#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
r "cmdline $($B cat /proc/cmdline)"
r "before extra=$([ -e /proc/extra ] && echo 1 || echo 0)"
$B insmod /a52sxq_lpm_nodes.ko; r "insmod rc=$?"
r "lpm=$($B cat /sys/module/a52sxq_lpm_nodes/parameters/lpm)"
r "ls $($B stat -c '%A %u:%g %n' /proc/extra)"
r "param $($B stat -c '%A' /sys/module/a52sxq_lpm_nodes/parameters/lpm)"
n=$($B cat /proc/extra | $B wc -c); r "extra read rc=$? bytes=$n"
echo x > /proc/extra 2>/dev/null; r "extra write rc=$?"
echo 1 > /sys/module/a52sxq_lpm_nodes/parameters/lpm 2>/dev/null; r "param write rc=$?"
$B insmod /a52sxq_lpm_nodes.ko 2>/dev/null; r "second insmod rc=$?"
$B rmmod a52sxq_lpm_nodes; r "rmmod rc=$?"
r "after extra=$([ -e /proc/extra ] && echo 1 || echo 0)"
$B insmod /a52sxq_lpm_nodes.ko; r "reload rc=$? extra=$([ -e /proc/extra ] && echo 1 || echo 0)"
r "END"
$B poweroff -f
