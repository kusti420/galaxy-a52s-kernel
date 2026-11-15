#!/bin/sh
# First on-device test of drivers612/nfc on the 6.12 test kernel (busybox ramdisk, root).
# Needs a board tree with a52sxq-nfc.dtsi applied (dt-work/merged.dtb or a tree that includes
# the fragment) and the first-stage modules (pinctrl-yupik, rpmh-regulator) loaded.
#
# Files next to this script (KX_PACK): 00-nfc_sec.ko nfctest, and for the busybox ramdisk the
# SE9 I2C controller modules i2c-01-msm_gpi.ko i2c-02-i2c-msm-geni.ko (skipped if loaded).
#   sh /p/nfc-test.sh          probe + nodes + sysfs + ioctl error paths; chip NOT powered up
#                              beyond what probe does (PVDD on, VEN off = as on 5.4 at boot)
#   sh /p/nfc-test.sh chip     also talks to the chip: bootloader-info over I2C twice (driver's
#                              own /sys/class/nfc_test/test, then /dev/sec-nfc like the HAL) and
#                              the HAL's mode sequence 2 -> 1 -> 0. Bootloader mode starts no RF
#                              field; mode 1 boots the NFC firmware without NCI init (no polling).
#   sh /p/nfc-test.sh reload   also rmmod + insmod twice (teardown paths, class/proc cleanup)
# Never with the Android NFC HAL running (only one opener; the HAL would lose the chip).
D=$(cd "$(dirname "$0")" && pwd)
B=/bin/busybox
say() { echo "== $*"; }
k() { $B dmesg | $B grep -E 'sec_nfc|sec-nfc|nfc_pvdd|fixed_regulator1|a84000' | $B tail -n "${1:-40}"; }

say "0. SE9 I2C controller (i2c@a84000)"
for m in i2c-01-msm_gpi i2c-02-i2c-msm-geni; do
	n=${m#i2c-0?-}; n=$(echo $n | $B tr - _)
	$B grep -q "^$n " /proc/modules && continue
	[ -f $D/$m.ko ] && { $B insmod $D/$m.ko || say "insmod $m FAILED"; }
done
$B sleep 1
$B ls -l /sys/bus/platform/devices/a84000.i2c/driver 2>&1
$B ls /sys/bus/i2c/devices/ | $B grep -- '-0027' || say "no i2c client 0x27 (tree without the fragment, or bus not probed)"

say "1. PVDD regulator before the driver (expect fixed_regulator1, disabled)"
for r in /sys/class/regulator/regulator.*; do
	[ "$($B cat $r/name 2>/dev/null)" = fixed_regulator1 ] || continue
	echo "$r: $($B cat $r/state) users=$($B cat $r/num_users)"; R=$r
done
[ -n "$R" ] || say "fixed_regulator1 NOT FOUND (regulator-fixed node missing / not probed)"

say "2. load"
$B insmod $D/00-nfc_sec.ko || say "insmod nfc_sec FAILED"
$B sleep 1
k 30
[ "$($B dmesg | $B grep -c 'sec_nfc: probe() success')" -ge 2 ] && say "probe OK" || say "probe NOT successful"
say "deferred? (empty = no)"; $B cat /sys/kernel/debug/devices_deferred 2>/dev/null | $B grep -iE 'nfc|0027'

say "3. nodes (expect /dev/sec-nfc misc 10,N; /proc/nfclog; classes nfc_sec, nfc_test)"
echo "/proc/misc: $($B grep sec-nfc /proc/misc)"; $B cat /sys/class/misc/sec-nfc/dev
[ -e /dev/sec-nfc ] || { say "no /dev/sec-nfc from devtmpfs, mknod"; $B mknod /dev/sec-nfc c 10 "$($B cat /sys/class/misc/sec-nfc/dev | $B cut -d: -f2)"; }
$B ls -l /dev/sec-nfc; $B readlink -f /sys/class/misc/sec-nfc
$B ls /sys/class/nfc_sec /sys/class/nfc_test
echo "nfc_support: '$($B cat /sys/class/nfc_sec/nfc_support)' (empty, as on 5.4)"
$B head -c 600 /proc/nfclog; echo

say "4. pins + rail after probe (expect nfc_ven out hi, nfc_firm out lo, nfc_int in, nfc_clk_req in; PVDD enabled)"
$B grep -E 'nfc_|fixed_regulator' /sys/kernel/debug/gpio 2>/dev/null
[ -n "$R" ] && echo "rail: $($B cat $R/state) users=$($B cat $R/num_users)"
$B grep -E 'sec-nfc' /proc/interrupts
$B ls /sys/class/wakeup/ 2>/dev/null | while read w; do $B cat /sys/class/wakeup/$w/name; done | $B grep -E 'nfc'

say "5. ioctl/fops error paths (expect 25, 19, 19, poll revents 0x9 = POLLIN|POLLERR from the -ENODEV mask)"
$D/nfctest bad

if [ "$1" = chip ]; then
	say "6a. driver self-test (expect 'BL ver: xx.xx.xx.xx, INT: OK')"
	$B cat /sys/class/nfc_test/test
	say "6b. bootloader info through /dev/sec-nfc (HAL path)"
	$D/nfctest bl
	say "6c. HAL mode sequence 2 -> 1 -> 0 (5.4 dmesg: 'NFC mode is : 2/1/0')"
	$D/nfctest modes
	k 25
fi

if [ "$1" = reload ]; then
	for i in 1 2; do
		say "7.$i rmmod + insmod"
		$B rmmod nfc_sec || say "rmmod FAILED"
		$B ls /dev/sec-nfc /proc/nfclog /sys/class/nfc_sec 2>&1
		[ -n "$R" ] && echo "rail after rmmod: $($B cat $R/state) (expect disabled)"
		$B insmod $D/00-nfc_sec.ko || say "re-insmod FAILED"
		$B ls /sys/class/nfc_sec; $D/nfctest bad | $B head -1
	done
	k 20
fi
say "done"
