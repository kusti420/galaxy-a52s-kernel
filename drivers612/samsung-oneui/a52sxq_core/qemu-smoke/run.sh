#!/bin/bash
# Offline QEMU smoke test of a52sxq.ko (userspace switch) + the soft binding of the consumer header.
#   run.sh            command line carries a52sxq.userspace=samsung (plain insmod must still pick it up)
#   CMD= run.sh       no command line setting (default auto = aosp)
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/../.." && pwd); TOP=$(cd "$S/../.." && pwd)
CMD=${CMD-a52sxq.userspace=samsung}
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$Q/.." >/dev/null; "$S/build.sh" "$Q/a52us_test" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$Q/../out/a52sxq.ko" "$Q/a52us_test/out/a52us_test.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 2G -nographic -no-reboot)
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on $CMD" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: consumer first rc=0 is_samsung=0" "consumer loads without a52sxq.ko, reads aosp"
if [ -n "$CMD" ]; then
	chk "SMK: core rc=0 userspace=samsung source=cmdline consumer=1" "plain insmod picks a52sxq.userspace=samsung from /chosen/bootargs; consumer binds late"
else
	chk "SMK: core rc=0 userspace=aosp source=default consumer=0" "no setting: auto = aosp"
fi
chk "SMK: ls -rw-r--r-- -r--r--r--" "userspace 0644, source 0444"
chk "SMK: write aosp rc=0 userspace=aosp source=sysfs consumer=0" "sysfs write aosp"
chk "SMK: write samsung rc=0 userspace=samsung consumer=1" "sysfs write samsung"
chk "SMK: write oneui rc=0 userspace=samsung" "alias oneui"
chk "SMK: write bogus rc=1 userspace=samsung" "bad word refused, value kept"
chk "SMK: write auto rc=0 userspace=aosp source=default consumer=0" "auto = aosp until a hint"
chk "SMK: rmmod core rc=1" "a52sxq.ko cannot be unloaded"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|failing symbol_get" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
