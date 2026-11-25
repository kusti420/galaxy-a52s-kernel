#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t configfs none /sys/kernel/config
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
$B insmod /fakewalt.ko; r "fakewalt rc=$?"
$B insmod /cpufreq_limit.ko; r "cflm rc=$?"
$B ls -l /sys/power/ | $B grep -E "cpufreq|limit" | $B sed 's/^/SMK: ls /'
r "table=[$($B cat /sys/power/cpufreq_table)] min=$($B cat /sys/power/cpufreq_min_limit) max=$($B cat /sys/power/cpufreq_max_limit) over=$($B cat /sys/power/over_limit)"
echo 1324800 > /sys/power/cpufreq_min_limit; r "min write rc=$? -> $($B cat /sys/power/cpufreq_min_limit)"
echo 1056000 > /sys/power/cpufreq_max_limit; r "max write rc=$? -> $($B cat /sys/power/cpufreq_max_limit)"
echo bogus > /sys/power/cpufreq_max_limit; r "bogus write rc=$?"
$B cat /sys/devices/system/cpu/cflm/info | $B sed 's/^/SMK: info /'
$B cat /sys/power/limit_stat | $B sed 's/^/SMK: stat /'
echo -1 > /sys/power/cpufreq_min_limit; echo -1 > /sys/power/cpufreq_max_limit
$B insmod /sec_core.ko; r "sec_core rc=$?"
$B insmod /ufs_sec_sysfs.ko; r "ufs rc=$?"
$B ls -l /sys/class/sec/ufs/ | $B sed 's/^/SMK: ufs /'
r "un=[$($B cat /sys/class/sec/ufs/un)] lc=$($B cat /sys/class/sec/ufs/lc) wb=$($B cat /sys/class/sec/ufs/sec_wb_enable)"
$B insmod /usb_f_ss_mon_gadget.ko; r "ss_mon rc=$?"
$B insmod /usb_f_ss_conn_gadget.ko; r "conn rc=$?"
G=/sys/kernel/config/usb_gadget/g1; $B mkdir -p $G/configs/b.1 $G/functions/ffs.mtp 2>/dev/null
$B mkdir $G/functions/ss_mon.mtp; r "mkdir ss_mon.mtp rc=$?"
$B mkdir $G/functions/ss_mon.ptp; r "mkdir ss_mon.ptp rc=$?"
$B mkdir $G/functions/conn_gadget.0; r "mkdir conn_gadget.0 rc=$?"
$B ln -s $G/functions/ss_mon.mtp $G/configs/b.1/f2; r "symlink rc=$?"
$B ls /sys/class/misc/ | $B sed 's/^/SMK: misc /' | $B grep -E "mtp|ssusbcon"
$B rm $G/configs/b.1/f2; $B rmdir $G/functions/ss_mon.ptp; r "rmdir ptp rc=$? misc=$($B ls /sys/class/misc | $B grep -c usb_mtp_gadget)"
$B rmdir $G/functions/ss_mon.mtp $G/functions/conn_gadget.0; r "rmdir rest rc=$? misc=$($B ls /sys/class/misc | $B grep -cE 'usb_mtp_gadget|ssusbcon')"
for m in usb_f_ss_conn_gadget usb_f_ss_mon_gadget ufs_sec_sysfs cpufreq_limit; do $B rmmod $m; r "rmmod $m rc=$?"; done
$B ls /sys/power | $B grep -c limit | $B sed 's/^/SMK: power nodes after rmmod: /'
$B dmesg | $B grep -iE "cpufreq_limit|ufs_sec|ss_mon|conn_gadget|WARN|BUG|Oops|Call trace" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
