#!/bin/busybox sh
# Stage A of the test helper (forked by /init = a52init, own mount namespace, still on the
# initramfs). Builds a private root on tmpfs (first-stage init deletes the initramfs files when
# it switches root) and continues there. /old = the initramfs (shared with PID 1).
B=/bin/busybox
R=/a52/root
$B mkdir -p $R
$B mount -t tmpfs -o mode=755,size=400m tmpfs $R || { echo "<0>a52sxq-init: helper: no tmpfs" > /dev/kmsg; exit 1; }
$B cp -a /bin /lib /usr /sbin /rb $R/
$B mkdir -p $R/a52 $R/old $R/proc $R/sys $R/dev $R/tmp $R/config $R/mnt
$B cp -a /a52/helper2.sh /a52/a52bind /a52/bind /a52/leave $R/a52/
[ -d /a52/mods ] && $B cp -a /a52/mods $R/a52/
$B cp /a52/leave $R/leave
$B mount -o bind / $R/old
exec $B chroot $R /bin/busybox sh /a52/helper2.sh
