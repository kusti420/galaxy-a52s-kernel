#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mknod /dev/null c 1 3
for a in cat ls cut insmod rmmod; do $B ln -s busybox /bin/$a; done
P=/sys/module/a52sxq/parameters; T=/sys/module/a52us_test/parameters/is_samsung
s() { echo "SMK: $*"; }
insmod /a52us_test.ko; s "consumer first rc=$? is_samsung=$(cat $T)"
insmod /a52sxq.ko; s "core rc=$? userspace=$(cat $P/userspace) source=$(cat $P/source) consumer=$(cat $T)"
s "ls $(ls -l $P/userspace | cut -c1-10) $(ls -l $P/source | cut -c1-10)"
echo aosp > $P/userspace; s "write aosp rc=$? userspace=$(cat $P/userspace) source=$(cat $P/source) consumer=$(cat $T)"
echo samsung > $P/userspace; s "write samsung rc=$? userspace=$(cat $P/userspace) consumer=$(cat $T)"
echo oneui > $P/userspace; s "write oneui rc=$? userspace=$(cat $P/userspace)"
echo bogus > $P/userspace 2>/dev/null; s "write bogus rc=$? userspace=$(cat $P/userspace)"
echo auto > $P/userspace; s "write auto rc=$? userspace=$(cat $P/userspace) source=$(cat $P/source) consumer=$(cat $T)"
rmmod a52sxq 2>/dev/null; s "rmmod core rc=$? (must fail: permanent)"
s "depends=[$(cat /sys/module/a52us_test/holders 2>/dev/null)] refcnt=$(cat /sys/module/a52sxq/refcnt 2>/dev/null)"
s END
$B poweroff -f
