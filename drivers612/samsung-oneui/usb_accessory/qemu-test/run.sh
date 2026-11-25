#!/bin/bash
# Offline QEMU test of the optional USB accessory set (GKI dist modules + samsung-oneui/hid_samsung): every module
# insmods on the bsp612 GKI Image, QEMU's usb-net (CDC Ethernet) binds cdc_ether and pings the user-net gateway,
# hid-samsung registers its HID driver, rmmod clean, no WARN. No phone.
#   drivers612/samsung-oneui/usb_accessory/qemu-test/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/../.." && pwd); TOP=$(cd "$S/../.." && pwd)
CL=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
DM=$TOP/bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
for m in mii usbnet cdc_ether cdc_ncm cdc_eem r8152 r8153_ecm ax88179_178a asix aqc111 rtl8150; do
	f=$(find "$DM" -name "$m.ko" | head -1); [ -n "$f" ] || { echo "missing $m"; exit 1; }
	cp "$f" "$WORK/rd/$m.ko"; "$CL/llvm-strip" --strip-debug "$WORK/rd/$m.ko"; done
cp "$S/hid_samsung/out/hid-samsung.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
timeout 300 qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 2G -nographic -no-reboot \
	-device qemu-xhci -netdev user,id=n0 -device usb-net,netdev=n0 -device usb-kbd \
	-kernel "$TOP/bsp612/out/dist/Image" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
for m in mii usbnet cdc_ether cdc_ncm cdc_eem r8152 r8153_ecm ax88179_178a asix aqc111 rtl8150 hid-samsung; do chk "UAT: insmod $m rc=0" "insmod $m"; done
chk "UAT: bound .* -> cdc_ether" "QEMU usb-net bound by cdc_ether"
chk "UAT: net (eth|usb)[0-9]+ driver=cdc_ether" "net device from cdc_ether"
chk "UAT: ping gateway rc=0" "ping over the USB Ethernet"
chk "UAT: hiddrv samsung" "hid-samsung HID driver registered"
chk "UAT: bound .* -> usbhid" "QEMU usb-kbd bound by built-in usbhid"
for m in hid-samsung rtl8150 aqc111 asix ax88179_178a r8153_ecm r8152 cdc_eem; do chk "UAT: rmmod $m rc=0" "rmmod $m"; done
chk "UAT: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
