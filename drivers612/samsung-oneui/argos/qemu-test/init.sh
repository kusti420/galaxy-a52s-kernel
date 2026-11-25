#!/bin/busybox sh
# QEMU init for the sec_argos.ko smoke test (see run.sh).
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
mkdevnode() { d=$($B cat /sys/class/misc/network_throughput/dev 2>/dev/null); $B rm -f /dev/network_throughput
	[ -n "$d" ] && $B mknod /dev/network_throughput c ${d%%:*} ${d##*:}; }
if [ -d /proc/device-tree/soc/argos ]; then
	r "dt: argos node present, entries with @: $($B ls /proc/device-tree/soc/argos | $B grep -c @)"
	r "dt: @1 node=[$($B cat /proc/device-tree/soc/argos/boot_device@1/net_boost,node)] label=[$($B cat /proc/device-tree/soc/argos/boot_device@1/net_boost,label)]"
	r "dt: @4 sysnode=[$($B cat /proc/device-tree/soc/argos/boot_device@4/net_boost,sysnode)]"
else
	r "dt: no argos node"
fi
# A: without cpufreq_limit (weak link -> loads, no CPU vote, no crash)
$B insmod /sec_argos.ko; r "A argos rc=$?"
mkdevnode; r "A dev $($B ls -l /dev/network_throughput)"
/bin/nttest > /tmp/a.txt 2>&1; r "A nttest rc=$? lines=$($B grep -c NTT /tmp/a.txt)"
$B grep -E "^cpu:" /sys/class/misc/network_throughput/argos_status | $B sed 's/^/SMK: A status /'
$B rmmod sec_argos; r "A rmmod rc=$?"
r "A misc after rmmod: $($B ls /sys/class/misc | $B grep -c network_throughput)"
# B: with fakewalt + cpufreq_limit
$B insmod /fakewalt.ko; r "fakewalt rc=$?"
$B insmod /cpufreq_limit.ko; r "cflm rc=$?"
$B insmod /sec_argos.ko; r "argos rc=$?"
mkdevnode; r "dev $($B ls -l /dev/network_throughput)"
$B cat /sys/class/misc/network_throughput/argos_status | $B sed 's/^/SMK: status0 /'
/bin/nttest | $B sed 's/^/SMK: /'
$B cat /sys/class/misc/network_throughput/argos_status | $B sed 's/^/SMK: status1 /'
$B ls /sys/bus/platform/drivers/argos 2>/dev/null | $B grep -c argos | $B sed 's/^/SMK: platform bound: /'
r "debug on"; echo 1 > /sys/module/sec_argos/parameters/debug
/bin/nttest > /dev/null
$B rmmod sec_argos; r "rmmod sec_argos rc=$?"
$B rmmod cpufreq_limit; r "rmmod cpufreq_limit rc=$?"
r "misc after rmmod: $($B ls /sys/class/misc | $B grep -c network_throughput)"
$B dmesg | $B grep -iE "sec_argos|argos|WARN|BUG|Oops|Call trace" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
