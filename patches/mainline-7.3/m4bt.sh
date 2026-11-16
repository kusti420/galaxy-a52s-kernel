#!/bin/sh
# /extra/m4bt.sh in the mainline 7.3 bring-up ramdisk (M4 part 1, Bluetooth). Boot with the BT tree
# (sm7325-samsung-a52sxq-wifi-bt.dtb = base + wifi + bt overlays); run /extra/m4wifi.sh first (it
# mounts the own vendor read-only at /vnd). Usage: /extra/m4bt.sh [le-scan-seconds]
# Firmware ONLY from this phone's own vendor (ro): qca/msbtfw11.mbn (rampatch, ELF) and
# qca/msnv11.bin (NVM) are runtime symlinks to /vnd/firmware/msbtfw11.mbn / msnv11.bin, hash-checked
# (.tlv is the fallback hci_qca tries when the .mbn is missing; linked too). Then btqca + hci_uart
# (serdev probe of qcom,wcn6750-bt: regulators, BT_EN, SW_CTRL), hci0, and /extra/bthci: raw HCI user
# channel (open = firmware download), reset, version, BD_ADDR, classic inquiry, passive LE scan.
# Nothing is paired or connected.
log() { echo "a52sxq-m4bt: $*" > /dev/kmsg; echo "$*"; }
B=/bin/busybox
grep -q " /vnd " /proc/mounts || { log "own vendor not mounted at /vnd (run /extra/m4wifi.sh first)"; exit 1; }
CHK="e699efcb872e55e3067e976401ee2e5e2cf671392d79d4fcd93c61ad9f5e8233 /vnd/firmware/msbtfw11.mbn
d832665624eab64ce5a74c0f3c61801500d2ceb413ac4dbbdfa0ee98d9aa354f /vnd/firmware/msbtfw11.tlv
d7aa1f2617734ab5bbb04a5d2cc53d3937116291612d65f1be8ccfc01d580948 /vnd/firmware/msnv11.bin"
rm -f /tmp/btfwbad
echo "$CHK" | while read h f; do
	[ "$($B sha256sum $f | cut -c1-64)" = "$h" ] && log "fw ok $f" || { log "fw HASH MISMATCH $f"; touch /tmp/btfwbad; }
done
[ -e /tmp/btfwbad ] && { log "firmware hash mismatch: STOP"; exit 1; }
mkdir -p /lib/firmware/qca
for f in msbtfw11.mbn msbtfw11.tlv msnv11.bin; do ln -sf /vnd/firmware/$f /lib/firmware/qca/$f; done
log "BT firmware: /lib/firmware/qca/{msbtfw11.mbn,msbtfw11.tlv,msnv11.bin} -> own vendor (ro)"
log "gpio85 BT_EN / gpio86 SW_CTRL before: $(grep -E 'gpio(85|86) ' /sys/kernel/debug/gpio 2>/dev/null | tr -s ' ' | tr '\n' ';')"
for m in btqca hci_uart; do
	grep -q "^$m " /proc/modules || insmod /extra/$m.ko || { log "insmod $m failed"; dmesg | tail -n 20; exit 2; }
done
i=0; while [ $i -lt 20 ] && [ ! -e /sys/class/bluetooth/hci0 ]; do sleep 1; i=$((i + 1)); done
sleep 3
dmesg | grep -iE "bluetooth|hci|qca|serdev|99c000|btqca" | tail -n 40
[ -e /sys/class/bluetooth/hci0 ] || { log "no hci0 after ${i}s"; exit 3; }
log "hci0 after ${i}s: $(cat /sys/class/bluetooth/hci0/name 2>/dev/null) bus $(cat /sys/class/bluetooth/hci0/type 2>/dev/null)"
grep -q " /sys/kernel/debug " /proc/mounts || mount -t debugfs none /sys/kernel/debug
log "gpio85/86 after: $(grep -E 'gpio(85|86) ' /sys/kernel/debug/gpio 2>/dev/null | tr -s ' ' | tr '\n' ';')"
/extra/bthci 0 ${1:-10} > /tmp/bt.txt 2>&1; R=$?
cat /tmp/bt.txt
log "bthci exit $R: $(tail -n 1 /tmp/bt.txt)"
dmesg | grep -iE "bluetooth|hci|qca" | tail -n 15
log "done ($R)"
exit $R
