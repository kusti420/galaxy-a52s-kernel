#!/bin/bash
# Offline QEMU smoke (bsp612 GKI Image on QEMU virt, no phone, no motor) of the vibrator -> accelerometer
# motor notifier (SPEC/01 gap 8): sec_vibrator.ko + dc_vibrator.ko from ../../vibrator/out-p1 and
# adsp_factory_dlkm.ko from ../out-p1, both load orders, reference handling, no WARN/BUG.
# Pattern: drivers612/samsung-oneui/grip_sx9360/qemu-test/run.sh.   ./run.sh -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); F=$(cd "$Q/.." && pwd); D=$(cd "$F/.." && pwd); TOP=$(cd "$D/.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/rd/m"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "${VBUS:-$D/realboot/out/rbich45/work/plan/first/vbus_notifier.ko}" "$WORK/rd/m/vbus_notifier.ko"
cp "$F/out-p1/adsp_factory_dlkm.ko" "$D/vibrator/out-p1/sec_vibrator.ko" "$D/vibrator/out-p1/dc_vibrator.ko" "$WORK/rd/m/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 2G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb"
cat "$WORK/virt.dts" "$Q/vib-test.dtsi" > "$WORK/v.dts"
dtc -q -I dts -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/v.dts"
run() { timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M $1" > "$2" 2>&1 || true; }
run "" "$WORK/console.txt"; run vibfirst "$WORK/console2.txt"
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: insmod adsp_factory_dlkm rc=0" "adsp_factory_dlkm loads with no sec_vibrator in the kernel"
chk "SMK: phase1 registered-lines=0 " "no listener while sec_vibrator.ko is absent (retries silently)"
chk "SMK: insmod sec_vibrator rc=0" "sec_vibrator loads later"
chk "SMK: insmod dc_vibrator rc=0" "dc_vibrator loads"
chk "SMK: phase2 registered-lines=1 " "listener registered after sec_vibrator arrived"
chk "SMK: motor_type=COINDC" "timed_output node works"
chk "SMK: enable 300 rc=0" "vibration request accepted"
chk "SMK: phase3 notify-on=1 work-on=1" "vibrator ON reaches ssc_motor_notify and the SSC message work (msg_buf = 1)"
chk "SMK: phase3 stop-timer=1 work-off=1" "motor stop timer (8 s) sends msg_buf = 0"
chk "SMK: rmmod sec_vibrator while bound rc=[1-9]" "sec_vibrator pinned while the listener is registered"
chk "SMK: END" "script ran to the end"
C=$WORK/console2.txt
chk "SMK: vibfirst try1=1" "other order (vibrator first): binds on the first try"
chk "SMK: phase3 notify-on=1 work-on=1" "other order: vibrator ON reaches the SSC message work"
chk "SMK: END" "other order: script ran to the end"
C="$WORK/console.txt $WORK/console2.txt"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|sysfs: cannot create duplicate" $C; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
