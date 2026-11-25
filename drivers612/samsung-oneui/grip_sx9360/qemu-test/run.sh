#!/bin/bash
# Offline QEMU smoke (bsp612 GKI Image on QEMU virt, no phone) of sx9360.ko + i2c-gpio.ko + i2c-algo-bit.ko:
# insmod/rmmod without a device, -EPROBE_DEFER until adsp_factory_dlkm's /sys/class/sensors exists, a no-chip probe on
# an i2c-gpio bus shaped like the a52sxq node (clean -ENODEV), a full probe against sxfake (test-only adapter + SX9360
# register file), the sysfs/input ABI, enable/disable, rmmod, a second round, no WARN/BUG.
# Pattern: drivers612/samsung-oneui/qemu-smoke/run.sh.
#   drivers612/samsung-oneui/grip_sx9360/qemu-test/run.sh     -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); G=$(cd "$Q/.." && pwd); S=$(cd "$G/.." && pwd); TOP=$(cd "$S/../.." && pwd)
FIRST=$TOP/drivers612/realboot/out/rbich45/work/plan/first
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/rd/m"
"$S/build.sh" "$Q/sxfake" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
for m in switch_class sec_core usb_notify_layer vbus_notifier common_muic pdic_notifier_module usb_typec_manager adsp_factory_dlkm; do
	cp "$FIRST/$m.ko" "$WORK/rd/m/"; done
cp "$G/out/sx9360.ko" "$G/i2c-gpio/out/i2c-gpio.ko" "$G/i2c-gpio/out/i2c-algo-bit.ko" "$Q/sxfake/out/sxfake.ko" "$WORK/rd/m/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb"
cat "$WORK/virt.dts" "$Q/grip-test.dtsi" > "$WORK/v.dts"
dtc -q -I dts -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/v.dts"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
for m in switch_class sec_core usb_notify_layer vbus_notifier common_muic pdic_notifier_module usb_typec_manager; do
	chk "SMK: insmod $m rc=0" "dep $m loads in QEMU"; done
chk "SMK: insmod sx9360 rc=0" "sx9360 loads without a device"
chk "SMK: rmmod sx9360 \(no device\) rc=0" "rmmod without a device"
chk "SMK: insmod i2c-algo-bit rc=0" "i2c-algo-bit loads"
chk "SMK: insmod i2c-gpio rc=0" "i2c-gpio loads"
chk "SMK: gpio bus client=[0-9]+-0028 driver=none grip_sensor=no inputs=0" "i2c-gpio bus instantiates sx9360@28 from the a52sxq-shaped node; probe defers, creates nothing"
chk "deferring" "probe logs the deferral (no sensors class yet)"
chk "SMK: insmod adsp_factory_dlkm rc=0" "class owner adsp_factory_dlkm loads"
chk "SMK: no-chip probe: driver=none grip_sensor=no symlink=no inputs=0" "no-chip probe fails cleanly, unwinds everything"
chk "SMK: insmod sxfake rc=0" "test adapter loads"
chk "SMK: after class: grip_sensor=yes" "/sys/class/sensors/grip_sensor created in adsp_factory's class"
chk "SMK: name=SX9360 vendor=SEMTECH" "name SX9360 / vendor SEMTECH"
chk "SMK: symlink=yes input-name=grip_sensor" "/sys/class/sensor_event/symlink/grip_sensor -> input grip_sensor"
chk "SMK: inputs: .*grip_sensor.*grip_notifier" "input devices grip_sensor + grip_notifier"
chk "SMK: irq: .*sx9360_irq" "nIRQ requested"
chk "SMK: irq-thread: [1-9]" "IRQ handled by a thread (irq/N-sx9360_irq)"
chk "whoami 0x60" "WHOAMI read through the adapter"
chk "SMK: enable 1 rc=0 -> 1" "input enable 1"
chk "SMK: enable 0 rc=0 -> 0" "input enable 0"
chk "SMK: grip_stats: grip_stats v1 .*enabled=0 .*en_on=1 en_off=1 irq=[0-9]+ .*cal_mode=1 .*ccic_attach=" "read-only grip_stats on the i2c device (enable 1/0 counted, boot calibration counted)"
chk "another sx9360 is already bound" "second instance (deferred no-chip client retried) refused before touching the ABI"
chk "SMK: rmmod sx9360 rc=0" "rmmod with a bound device"
chk "SMK: after rmmod: grip_sensor=no symlink=no inputs=0 sensor_dev=yes" "remove drops all ABI nodes, adsp_factory's class intact"
chk "SMK: round2: grip_sensor=yes inputs=2" "second load probes again (no leaked names/gpios)"
chk "SMK: debug work: hall-open-fail lines=1([^0-9]|$)" "debug work runs; missing hall node logged once, not every 2 s"
chk "SMK: rmmod sxfake rc=0" "adapter removal unbinds"
chk "SMK: after adapters gone: grip_sensor=no inputs=0" "nothing left after the adapter goes"
chk "SMK: rmmod sx9360 final rc=0" "final rmmod"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|sysfs: cannot create duplicate" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
