#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3; $B mknod /dev/zero c 1 5
r() { echo "SMK: $*"; }
for m in virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci virtio_blk; do $B insmod /$m.ko; done
for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /sys/class/block/vda ] && break; $B sleep 1; done
r "vda present $($B ls /sys/class/block | $B grep -c '^vda$')"
d=$($B cat /sys/class/block/vda/dev); $B mknod /dev/vda b ${d%:*} ${d#*:}

# --- mem_boost_mode / am_app_launch
V=/sys/kernel/mm/vmscan
$B insmod /a52sxq_mm_boost.ko; r "mmb rc=$?"
$B ls -l $V/ | $B sed 's/^/SMK: ls /'
r "mbm initial=[$($B cat $V/mem_boost_mode)]"
echo 2 > $V/mem_boost_mode; r "mbm write 2 rc=$? -> [$($B cat $V/mem_boost_mode)]"
echo 3 > $V/mem_boost_mode; r "mbm write 3 rc=$? -> [$($B cat $V/mem_boost_mode)]"
echo 4 > $V/mem_boost_mode 2>/dev/null; r "mbm write 4 rc=$? -> [$($B cat $V/mem_boost_mode)]"
echo -1 > $V/mem_boost_mode 2>/dev/null; r "mbm write -1 rc=$?"
echo abc > $V/mem_boost_mode 2>/dev/null; r "mbm write abc rc=$?"
$B sleep 6; r "mbm after 6s=[$($B cat $V/mem_boost_mode)]"
echo 1 > $V/am_app_launch; a=$?; v1=$($B cat $V/am_app_launch)
echo 2 > $V/am_app_launch 2>/dev/null; r "aal write 1 rc=$a -> [$v1] write 2 rc=$? -> [$($B cat $V/am_app_launch)]"
echo 0 > $V/am_app_launch

# --- blk_sec_stats without a matching disk (phone default sda,mmcblk0)
S=/sys/kernel/blk_sec_stats
$B insmod /blk_sec_stats.ko; r "bss0 rc=$?"
$B cat $S/diskios >/dev/null 2>&1; r "bss0 diskios rc=$?"
$B rmmod blk_sec_stats; r "rmmod bss0 rc=$?"

# --- blk_sec_stats on vda
$B insmod /blk_sec_stats.ko disks=vda; r "bss rc=$?"
$B ls -l $S/ | $B sed 's/^/SMK: ls /'
r "defaults en=[$($B cat $S/pios_enable)] dur=[$($B cat $S/pios_duration_ms)]"
r "diskios1 $($B cat $S/diskios)"
$B dd if=/dev/vda of=/dev/null bs=1M count=8 2>/dev/null
r "diskios2 $($B cat $S/diskios)"
$B dd if=/dev/zero of=/dev/vda bs=1M count=4 seek=32 conv=fsync 2>&1 | $B sed "s/^/SMK: dd4 /"; $B sync; $B blockdev --flushbufs /dev/vda 2>&1 | $B sed "s/^/SMK: flush /"
r "diskios3 $($B cat $S/diskios)"
$B dd if=/dev/vda of=/dev/null bs=1M count=1 skip=8 2>/dev/null
r "pios disabled=[$($B cat $S/pios)]"
echo 1 > $S/pios_enable; r "enable rc=$? -> [$($B cat $S/pios_enable)]"
$B dd if=/dev/vda of=/dev/null bs=1M count=2 skip=16 2>/dev/null &
($B dd if=/dev/zero of=/dev/vda bs=1M count=1 seek=48 conv=fsync 2>/dev/null; $B sync) &
wait
$B cat $S/pios | $B sed 's/^/SMK: pios line /'
r "pios reread=[$($B cat $S/pios)]"
echo 20000 > $S/pios_duration_ms; a=$($B cat $S/pios_duration_ms)
echo 100 > $S/pios_duration_ms; r "dur 20000 -> [$a] 100 -> [$($B cat $S/pios_duration_ms)]"
echo 1 > $S/pios_enable; $B sleep 1
$B dd if=/dev/vda of=/dev/null bs=1M count=2 skip=24 2>/dev/null
r "pios after timeout=[$($B cat $S/pios)]"
echo 5000 > $S/pios_duration_ms; echo 0 > $S/pios_enable
for m in blk_sec_stats a52sxq_mm_boost; do $B rmmod $m; r "rmmod $m rc=$?"; done
r "nodes after rmmod: vmscan=$($B ls /sys/kernel/mm | $B grep -c vmscan) bss=$($B ls /sys/kernel | $B grep -c blk_sec_stats)"
$B dmesg | $B grep -iE "mm_boost|blk_sec_stats|WARN|BUG|Oops|Call trace" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
