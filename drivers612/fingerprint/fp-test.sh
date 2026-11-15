#!/bin/sh
# First on-device test of drivers612/fingerprint on the 6.12 test kernel (busybox ramdisk or the
# Android test boot, as root). Kernel side only: no TrustZone app, no HAL, no SPI traffic.
# Needs the board tree with a52sxq-fingerprint.dtsi applied (dt-work/merged.dtb or a tree that
# includes the fragment) and the first-stage modules (pinctrl-yupik, rpmh-regulator) loaded.
#
# Files next to this script (KX_PACK): 00-fingerprint_sysfs.ko 01-fingerprint.ko esfptest
#   sh /p/fp-test.sh          probe + sysfs + ioctl checks, NO power-on
#   sh /p/fp-test.sh power    also FP_POWER_CONTROL 1/0 (L3C 3.3 V at the tree's own voltage
#                             through the driver, exactly what the HAL does at every unlock;
#                             run only with the main session's go-ahead)
#   sh /p/fp-test.sh reload   also rmmod + insmod twice (unbind / rebind paths)
D=$(cd "$(dirname "$0")" && pwd)
B=/bin/busybox
say() { echo "== $*"; }
k() { $B dmesg | $B grep -E 'fps_|fingerprint|etspi|VDD_BTP' | $B tail -n "${1:-40}"; }

say "1. load"
$B insmod $D/00-fingerprint_sysfs.ko || say "insmod fingerprint_sysfs FAILED"
$B insmod $D/01-fingerprint.ko || say "insmod fingerprint FAILED"
$B sleep 1
k 30
$B dmesg | $B grep -q 'fps_et7xx_probe: is successful' && say "probe OK" || say "probe NOT successful"
[ -d /sys/bus/platform/drivers/egis_fingerprint ] && $B ls /sys/bus/platform/drivers/egis_fingerprint
say "deferred? (empty = no)"; $B cat /sys/kernel/debug/devices_deferred 2>/dev/null | $B grep -i etspi

say "2. device node (expect c 152,0; Android: system system 0660 after 'on boot')"
[ -e /dev/esfp0 ] || { say "no /dev/esfp0 from devtmpfs, mknod"; $B mknod /dev/esfp0 c 152 0; }
$B ls -l /dev/esfp0; $B cat /sys/class/egis_fingerprint/esfp0/dev
$B readlink -f /sys/class/egis_fingerprint/esfp0

say "3. sysfs (expect EGISTEC / ET713 / 1 / position / 547,-1,-1,FFFFFF / -1 / FP_SPICLK 20000000)"
F=/sys/class/fingerprint/fingerprint
$B readlink -f $F
for a in vendor name adm position rb type_check bfs_values; do echo "$a: $($B cat $F/$a)"; done

say "4. rail (expect VDD_BTP_3P3 3300000 disabled, 1 user = this driver)"
for r in /sys/class/regulator/regulator.*; do
	[ "$($B cat $r/name 2>/dev/null)" = VDD_BTP_3P3 ] || continue
	echo "$r: $($B cat $r/microvolts) $($B cat $r/state) users=$($B cat $r/num_users)"
	$B ls $r | $B grep -i etspi; R=$r
done
[ -n "$R" ] || say "VDD_BTP_3P3 regulator NOT FOUND"

say "5. ioctls (expect model info \"A528\"; bad: -1 errno 25 then -1 errno 14; type 8 -> type_check 1)"
$D/esfptest info
$D/esfptest bad
$D/esfptest type 8; echo "type_check: $($B cat $F/type_check)"
$D/esfptest clk 20000000; $B grep -l et7xx_wake_lock /sys/class/wakeup/*/name 2>/dev/null
$B cat /sys/kernel/debug/wakeup_sources 2>/dev/null | $B grep et7xx
$D/esfptest noclk
k 12

if [ "$1" = power ]; then
	say "6. power on (expect state enabled, 3300000; debug line after <=10 s: ldo: 1, sleep: 1)"
	$D/esfptest on; [ -n "$R" ] && echo "rail: $($B cat $R/state) $($B cat $R/microvolts)"
	$B sleep 11; k 6
	$D/esfptest reset
	$D/esfptest off; [ -n "$R" ] && echo "rail: $($B cat $R/state)"
	$B sleep 11; k 4
fi

if [ "$1" = reload ]; then
	for i in 1 2; do
		say "7.$i rmmod + insmod"
		$B rmmod fingerprint && $B rmmod fingerprint_sysfs || say "rmmod FAILED"
		$B ls /sys/class/fingerprint 2>&1; $B ls /dev/esfp0 2>&1
		$B insmod $D/00-fingerprint_sysfs.ko && $B insmod $D/01-fingerprint.ko || say "re-insmod FAILED"
		$B cat $F/vendor; $D/esfptest info
	done
	k 20
fi
say "done"
