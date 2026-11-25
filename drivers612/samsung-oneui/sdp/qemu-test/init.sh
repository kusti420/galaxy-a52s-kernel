#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t devtmpfs dev /dev 2>/dev/null || { $B mount -t tmpfs tmpfs /dev; NODEV=1; }
[ -e /dev/null ] || $B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
mk() { for n in dek_evt dek_req dek_log; do [ -e /dev/$n ] || $B mknod /dev/$n c 10 $($B cat /sys/class/misc/$n/dev | $B cut -d: -f2); done; }
/sdp_test absent
$B insmod /sdp_dek.ko; r "insmod rc=$?"
mk
$B ls /sys/class/misc | $B grep dek | $B tr '\n' ' ' | $B sed 's/^/SMK: misc /'; echo
r "asym_alg=$($B cat /sys/class/misc/dek_req/asym_alg) mode=$($B ls -l /sys/class/misc/dek_req/asym_alg | $B cut -c1-10)"
/sdp_test; r "sdp_test rc=$?"
$B sleep 1
$B rmmod sdp_dek; r "rmmod rc=$?"
$B rm -f /dev/dek_evt /dev/dek_req /dev/dek_log
/sdp_test absent
$B insmod /sdp_dek.ko; r "second insmod rc=$?"; $B rmmod sdp_dek; r "second rmmod rc=$?"
$B dmesg | $B grep -iE "dek|sdp|WARN|BUG|Oops|Call trace|KEK_PACK" | $B tail -40 | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
