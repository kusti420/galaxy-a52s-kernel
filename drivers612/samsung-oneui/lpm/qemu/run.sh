#!/bin/bash
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of a52sxq_lpm_nodes.ko: /proc/extra as 5.4
# (0222, empty read) and the lpm detection of a52_lpm_bootargs.h (the same header patch 0001 puts into
# sec-battery / sm5714_fuelgauge) against 5 command lines (-append ends up in /chosen/bootargs).
#   drivers612/samsung-oneui/lpm/qemu/run.sh   -> PASS/FAIL, $WORK/console-*.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/.." && pwd); TOP=$(cd "$S/../../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$S/out/a52sxq_lpm_nodes.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 2G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
BASE="console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on"
# name | expected lpm | extra words
CASES=("normal|0|androidboot.mode=normal sec_mparam.lpcharge=0"
       "charger|1|androidboot.mode=charger"
       "mparam|1|sec_mparam.lpcharge=1 androidboot.bootreason=usb"
       "nearmiss|0|androidboot.mode=charger2 xlpcharge=1 sec_mparam.lpcharge=10"
       "last|1|foo=1 lpcharge=1")
for c in "${CASES[@]}"; do IFS='|' read -r n e w <<<"$c"
	timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
		-append "$BASE $w" > "$WORK/console-$n.txt" 2>&1 &
done; wait
f=0
chk() { if grep -aqE -- "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3"; f=1; fi; }
for c in "${CASES[@]}"; do IFS='|' read -r n e w <<<"$c"; C=$WORK/console-$n.txt
	chk "$C" "SMK: lpm=$e" "[$n] lpm=$e for '$w'"
	chk "$C" "a52sxq_lpm_nodes: lpm=$e, /proc/extra created" "[$n] kernel log line"
	chk "$C" "SMK: END" "[$n] script ran to the end"
	if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL [$n] kernel warning/oops"; f=1; else echo "ok   [$n] no WARN/BUG/oops"; fi
done
C=$WORK/console-normal.txt
chk "$C" "SMK: before extra=0" "no /proc/extra before the module"
chk "$C" "SMK: insmod rc=0" "insmod"
chk "$C" "SMK: ls --w--w--w- 0:0 /proc/extra" "/proc/extra mode 0222 root:root (5.4 S_IWUGO)"
chk "$C" "SMK: param -r--r--r--" "lpm parameter 0444"
chk "$C" "SMK: extra read rc=0 bytes=0" "/proc/extra reads 0 bytes (5.4 after a clean boot)"
chk "$C" "SMK: extra write rc=1" "/proc/extra write refused (no write op, as 5.4)"
chk "$C" "SMK: param write rc=1" "lpm parameter not writable"
chk "$C" "SMK: second insmod rc=1" "double insmod refused"
chk "$C" "SMK: rmmod rc=0" "rmmod"
chk "$C" "SMK: after extra=0" "/proc/extra removed on rmmod"
chk "$C" "SMK: reload rc=0 extra=1" "reload"
echo "consoles: $WORK/console-*.txt"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
