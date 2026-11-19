#!/bin/bash
# Real flash of a realboot build on white cable (PHONE2 ONLY; refuses everything else) from its running,
# rooted Android: push to /data/local/tmp/a52rb, check sha256, dd the partitions that differ, read back after
# 5 s, reboot, wait for boot_completed, mute. Never touches adb settings. Rollback = the same with the old name.
#   drivers612/realboot/flash-rb.sh <rb name>     (NOREBOOT=1: write + verify only)
set -u
cd "$(dirname "$0")/../.."
N=${1:?rb name}; B=drivers612/realboot/out/$N; S=PHONE2
# "5.4" = the phone's own LineageOS 5.4 images (testdev-PHONE2 dumps; hashes in every build's rollback/)
[ "$N" = 5.4 ] && B=testdev-PHONE2
A() { adb -s $S "$@"; }
SUMS=$B/SHA256SUMS
if [ "$N" = 5.4 ]; then SUMS=$(mktemp); ( cd "$B" && sha256sum boot.img vendor_boot.img dtbo.img ) > "$SUMS"; fi
[ -f "$SUMS" ] || { echo "no $SUMS"; exit 1; }
[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 1; }
A root >/dev/null 2>&1; sleep 2; timeout 30 adb -s $S wait-for-device
[ "$(A shell id -u | tr -d '\r')" = 0 ] || { echo "no root"; exit 1; }
A shell 'awk '"'"'$2=="/data"{print $1}'"'"' /proc/mounts' | grep -q zram && { echo "this is a kexec test Android, not the flashed system"; exit 1; }
A shell 'mkdir -p /data/local/tmp/a52rb'
for p in dtbo vendor_boot boot; do
	want=$(awk -v f=$p.img '$2==f || $2=="*"f {print $1}' "$SUMS"); [ -n "$want" ] || { echo "no hash for $p"; exit 1; }
	have=$(A shell "sha256sum /dev/block/by-name/$p" | cut -c1-64)
	[ "$want" = "$have" ] && { echo "$p: already $N (${want:0:8})"; continue; }
	A push "$B/$p.img" /data/local/tmp/a52rb/$p.img >/dev/null || exit 1
	[ "$(A shell "sha256sum /data/local/tmp/a52rb/$p.img" | cut -c1-64)" = "$want" ] || { echo "$p: pushed file hash differs"; exit 1; }
	A shell "dd if=/data/local/tmp/a52rb/$p.img of=/dev/block/by-name/$p bs=1M conv=fsync 2>/dev/null; sync" || { echo "$p: dd failed"; exit 1; }
	echo "$p: written"
done
sleep 5; A shell 'sync; echo 3 > /proc/sys/vm/drop_caches'
for p in dtbo vendor_boot boot; do
	want=$(awk -v f=$p.img '$2==f || $2=="*"f {print $1}' "$SUMS"); have=$(A shell "sha256sum /dev/block/by-name/$p" | cut -c1-64)
	[ "$want" = "$have" ] || { echo "VERIFY FAILED $p: $have != $want  (DO NOT REBOOT)"; exit 3; }
	echo "$p: verified ${want:0:8}"
done
A shell 'rm -f /data/local/tmp/a52rb/*.img'
[ "${NOREBOOT:-0}" = 1 ] && exit 0
B0=$(A shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
A reboot; sleep 15
T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt 240 ]; do
	if [ "$(A get-state 2>/dev/null)" = device ] && [ "$(A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
		A root >/dev/null 2>&1; sleep 3; timeout 30 adb -s $S wait-for-device
		A shell 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done' >/dev/null 2>&1
		echo "booted: $(A shell 'uname -r; cat /proc/device-tree/soc/a52sxq,realboot 2>/dev/null; echo; getenforce; cut -d. -f1 /proc/uptime' | tr '\0\n\r' '   ') ($(( $(date +%s) - T0 + 15 )) s after reboot)"
		[ "$(A shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')" != "$B0" ] || { echo "boot_id unchanged?"; exit 1; }
		exit 0
	fi
	sleep 3
done
echo "NOT BACK after 255 s: USB state: $(for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && [ "$(cat $d/idVendor)" = 04e8 ] && echo "$(basename $d) $(cat $d/idProduct) $(cat $d/serial 2>/dev/null)"; done | tr '\n' ';')"
exit 4
