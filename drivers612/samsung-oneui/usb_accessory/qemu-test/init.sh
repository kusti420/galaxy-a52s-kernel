#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mknod /dev/null c 1 3
r() { echo "UAT: $*"; }
for m in mii usbnet cdc_ether cdc_ncm cdc_eem r8152 r8153_ecm ax88179_178a asix aqc111 rtl8150 hid-samsung; do $B insmod /$m.ko; r "insmod $m rc=$?"; done
$B sleep 4
for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && r "usbdev $($B cat $d/idVendor):$($B cat $d/idProduct) $($B cat $d/product 2>/dev/null)"; done
for i in /sys/bus/usb/devices/*:*; do [ -e $i/driver ] && r "bound $($B basename $i) -> $($B basename $($B readlink $i/driver))"; done
for n in /sys/class/net/*; do r "net $($B basename $n) driver=$($B basename $($B readlink $n/device/driver 2>/dev/null) 2>/dev/null)"; done
N=$($B ls /sys/class/net | $B grep -E '^(eth|usb)' | $B head -1)
if [ -n "$N" ]; then $B ifconfig $N 10.0.2.15 netmask 255.255.255.0 up; r "ifup $N rc=$?"; $B sleep 2; r "carrier=$($B cat /sys/class/net/$N/carrier 2>/dev/null)"; $B ping -c 2 -W 2 10.0.2.2 >/dev/null 2>&1; r "ping gateway rc=$?"; fi
$B ls /sys/bus/hid/drivers/ | $B sed 's/^/UAT: hiddrv /'
for m in hid-samsung rtl8150 aqc111 asix ax88179_178a r8153_ecm r8152 cdc_eem; do $B rmmod $m; r "rmmod $m rc=$?"; done
$B dmesg | $B grep -iE "usbnet|cdc_ether|r8152|WARN|BUG|Oops|Call trace" | $B sed 's/^/UAT: dmesg /'
echo "UAT: END"
$B poweroff -f
