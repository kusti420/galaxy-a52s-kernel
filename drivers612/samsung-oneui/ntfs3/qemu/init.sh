#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t devtmpfs dev /dev 2>/dev/null
r() { echo "NTF: $*"; }
$B mkdir -p /mnt /tmp
$B insmod /ntfs3.ko; r "insmod rc=$?"
r "filesystems: $($B grep -c ntfs3 /proc/filesystems)"
for m in virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci virtio_blk; do $B insmod /$m.ko || r "insmod $m failed"; done
i=0; while [ ! -e /sys/block/vda ] && [ $i -lt 50 ]; do $B sleep 0.1; i=$((i+1)); done
[ -e /dev/vda ] || $B mknod /dev/vda b $($B sed 's/:/ /' /sys/block/vda/dev)
r "vda sectors=$($B cat /sys/block/vda/size)"
[ -e /dev/urandom ] || $B mknod /dev/urandom c 1 9
$B mount -t ntfs3 -o ro /dev/vda /mnt; r "mount ro rc=$?"
r "read hello=[$($B cat /mnt/hello.txt)]"
r "read big sha=$($B sha256sum /mnt/big.bin | $B cut -c1-16)"
$B umount /mnt; r "umount ro rc=$?"
# vold-style options (uid/gid/masks as Samsung vold passes for public volumes)
$B mount -t ntfs3 -o rw,nosuid,nodev,noatime,uid=1023,gid=1023,fmask=0007,dmask=0007,iocharset=utf8 /dev/vda /mnt; r "mount rw rc=$?"
$B grep ntfs3 /proc/mounts | $B sed 's/^/NTF: mounts /'
echo "written by 6.12 ntfs3" > /mnt/new.txt; r "write rc=$?"
$B dd if=/dev/urandom of=/tmp/rnd bs=1024 count=3000 2>/dev/null; $B cp /tmp/rnd /mnt/rnd.bin; r "write 3M rc=$? size=$($B stat -c %s /mnt/rnd.bin)"
W=$($B sha256sum /tmp/rnd | $B cut -c1-16)
$B mkdir /mnt/newdir; $B mv /mnt/hello.txt /mnt/newdir/moved.txt; r "mkdir+rename rc=$?"
echo "utf8 ok" > "/mnt/täht õ.txt"; r "utf8 name rc=$?"
$B rm /mnt/big.bin; r "unlink rc=$?"
$B sync; $B umount /mnt; r "umount rw rc=$?"
$B mount -t ntfs3 -o ro,uid=1023,gid=1023,fmask=0007,dmask=0007,iocharset=utf8 /dev/vda /mnt; r "remount rc=$?"
r "readback new=[$($B cat /mnt/new.txt)]"
R=$($B sha256sum /mnt/rnd.bin | $B cut -c1-16); [ "$R" = "$W" ] && r "readback 3M sha match" || r "readback 3M MISMATCH $R $W"
r "readback moved=[$($B cat /mnt/newdir/moved.txt)] big_gone=$([ -e /mnt/big.bin ] && echo no || echo yes) utf8=[$($B cat '/mnt/täht õ.txt')]"
r "owner host-made file: $($B ls -ln /mnt/newdir/moved.txt | $B awk '{print $1,$3,$4}')"
r "owner kernel-made file (WSL EA): $($B ls -ln /mnt/new.txt | $B awk '{print $1,$3,$4}')"
$B df -k /mnt | $B tail -1 | $B sed 's/^/NTF: df /'
$B umount /mnt; r "umount final rc=$?"
$B rmmod ntfs3; r "rmmod rc=$? left=$($B grep -c ntfs3 /proc/filesystems)"
$B dmesg | $B grep -iE "ntfs|Protected symbol|WARN|BUG|Oops|Call trace" | $B sed 's/^/NTF: dmesg /'
echo "NTF: END"
$B poweroff -f
