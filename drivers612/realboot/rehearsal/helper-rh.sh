#!/bin/busybox sh
# Stage A of the REAL-BOOT REHEARSAL helper (packed as /a52/helper.sh; a52init forks it in its
# own mount namespace). Same as drivers612/androidboot/kexec-rd/helper.sh, except that all of
# /a52 (testguard, a52ovl, the vendor add-on, the check script) goes into the private root.
B=/bin/busybox
R=/a52/root
$B mkdir -p $R
$B mount -t tmpfs -o mode=755,size=400m tmpfs $R || { echo "<0>a52sxq-init: helper: no tmpfs" > /dev/kmsg; exit 1; }
$B cp -a /bin /lib /usr /sbin /rb $R/
$B mkdir -p $R/a52 $R/old $R/proc $R/sys $R/dev $R/tmp $R/config $R/mnt
for f in /a52/*; do [ "$f" = $R ] || $B cp -a "$f" $R/a52/; done
$B cp /a52/leave $R/leave
$B mount -o bind / $R/old
exec $B chroot $R /bin/busybox sh /a52/helper2.sh
