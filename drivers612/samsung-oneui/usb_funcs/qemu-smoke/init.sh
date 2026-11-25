#!/bin/busybox sh
# QEMU virt smoke of the soc-repo dist gadget functions usb_f_cdev (cser), usb_f_ccid (ccid), usb_f_qdss (qdss)
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t configfs none /sys/kernel/config
$B mount -t debugfs none /sys/kernel/debug 2>/dev/null
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
G=/sys/kernel/config/usb_gadget/g1; F=$G/functions
$B insmod /m/usb_f_cdev.ko; r "cdev rc=$?"
$B insmod /m/usb_f_ccid.ko; r "ccid rc=$?"
$B mkdir -p $G/configs/b.1
for i in cser.dun.0 cser.nmea.1 cser.dun.2 ccid.ccid; do $B mkdir $F/$i; r "mkdir $i rc=$?"; done
r "class msm_usb_bridge: $($B ls /sys/class/msm_usb_bridge 2>/dev/null | $B tr '\n' ' ')"
r "class ccid_usb: $($B ls /sys/class/ccid_usb 2>/dev/null | $B tr '\n' ' ')"
for d in /sys/class/msm_usb_bridge/* /sys/class/ccid_usb/*; do r "dev $($B basename $d)=$($B cat $d/dev)"; done
$B ln -s $F/cser.dun.0 $G/configs/b.1/f1; r "symlink dun rc=$?"
$B ln -s $F/ccid.ccid $G/configs/b.1/f2; r "symlink ccid rc=$?"
$B rm $G/configs/b.1/f1 $G/configs/b.1/f2; r "unlink rc=$?"
for i in cser.dun.0 cser.nmea.1 cser.dun.2 ccid.ccid; do $B rmdir $F/$i; r "rmdir $i rc=$?"; done
r "after rmdir: bridge=$($B ls /sys/class/msm_usb_bridge 2>/dev/null | $B wc -l) ccid=$($B ls /sys/class/ccid_usb 2>/dev/null | $B wc -l)"
$B rmmod usb_f_ccid; r "rmmod ccid rc=$?"; $B rmmod usb_f_cdev; r "rmmod cdev rc=$?"
r "PHASE1 END"
# phase 2: qdss with its dwc3-msm dependency chain (Qualcomm/Gunyah modules in QEMU: may not load)
ok=1
for m in $($B cat /m/qdss.order); do $B insmod /m/$m; rc=$?; r "dep $m rc=$rc"; [ $rc = 0 ] || ok=0; done
r "qdss chain ok=$ok"
if [ $ok = 1 ]; then
  for i in qdss.qdss qdss.qdss_mdm; do $B mkdir $F/$i; r "mkdir $i rc=$?"; done
  $B ln -s $F/qdss.qdss $G/configs/b.1/f3; r "symlink qdss rc=$?"; $B rm $G/configs/b.1/f3
  for i in qdss.qdss qdss.qdss_mdm; do $B rmdir $F/$i; r "rmdir $i rc=$?"; done
  $B rmmod usb_f_qdss; r "rmmod qdss rc=$?"
fi
$B dmesg | $B grep -iE "cser|ccid|qdss|at_usb|WARN|BUG|Oops|Call trace" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
