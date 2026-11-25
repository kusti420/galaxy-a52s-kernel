#!/bin/bash
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of a52sxq_vrr_state.ko (vrr_state + panel_vcom_type).
# QEMU has no panel: the phone's lcd.ko (from the rbich45 plan) + fakepanel.ko (lcd_device_register("panel"))
# stand in for msm_drm's ss_create_sysfs(). Checks load without a panel (retry), late attach, "\n" content,
# 0444 + write refused, rmmod while attached, panel removed first, existing vrr_state left alone, give-up,
# rmmod while retrying, no WARN/BUG. Pattern from drivers612/samsung-oneui/qemu-smoke/run.sh.
#   drivers612/samsung-oneui/vrr_state/qemu-smoke/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); V=$(cd "$Q/.." && pwd); S=$(cd "$V/.." && pwd); TOP=$(cd "$S/../.." && pwd)
LCD=${LCD:-$TOP/drivers612/realboot/out/rbich45/work/plan/first/lcd.ko}
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$V" >/dev/null
python3 "$S/ko2symvers.py" "$Q/fakepanel/lcd.symvers" "$LCD" >/dev/null
EXTRA_SYMVERS="$Q/fakepanel/lcd.symvers" "$S/build.sh" "$Q/fakepanel" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$V/out/a52sxq_vrr_state.ko" "$Q/fakepanel/out/fakepanel.ko" "$WORK/rd/"; cp "$LCD" "$WORK/rd/lcd.ko"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 2G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: vrr rc=0" "init returns 0 without lcd class / panel"
chk "SMK: tries-before-panel: 1" "retry message once"
chk "SMK: fakepanel rc=0" "lcd.ko + fake panel load"
chk "SMK: ls -r--r--r-- .* /sys/class/lcd/panel/vrr_state" "vrr_state 0444"
chk "SMK: readlink /sys/devices/virtual/lcd/panel" "panel device at /sys/devices/virtual/lcd/panel"
chk "SMK: bytes=1 od=\[ \\\\n\]" "content is exactly \"\\n\" (stock A528BXXU5FWK4)"
chk "SMK: write rc=1" "write refused"
chk "SMK: ls -r--r--r-- .* /sys/class/lcd/panel/panel_vcom_type" "panel_vcom_type 0444"
chk "SMK: vcom bytes=2 od=\[ 0 \\\\n\]" "panel_vcom_type is exactly \"0\\n\" (stock A528BXXU5FWK4)"
chk "SMK: vcom write rc=1 after=\[0\]" "panel_vcom_type write refused"
chk "SMK: bytes after write=1" "content unchanged after write"
chk "SMK: init-like chmod/chown rc=0 bytes=1" "init's chown/chmod 0440 works"
chk "a52sxq_vrr_state: added /sys/class/lcd/panel/panel_vcom_type \(after [0-9]+ lookups\)" "late attach logged"
chk "a52sxq_vrr_state: added /sys/class/lcd/panel/vrr_state \(after [0-9]+ lookups\)" "late attach logged (vrr_state)"
chk "SMK: rmmod1 rc=0 present=0" "rmmod removes both nodes"
chk "SMK: present2=2 bytes=1" "attach with panel already present"
chk "SMK: rmmod panel-first rc=0" "panel unregistered while attached"
chk "SMK: rmmod2 rc=0" "rmmod after panel went away"
chk "SMK: dup content=\[fake\] vcom=\[0\]" "existing vrr_state kept, panel_vcom_type still added"
chk "panel already has vrr_state, not adding" "duplicate detected, no sysfs dup warning"
chk "SMK: rmmod3 rc=0 dup still=\[fake\] vcom gone=0" "rmmod leaves the foreign node, removes its own"
chk "giving up" "gives up after max_tries"
chk "SMK: rmmod4 rc=0" "rmmod after give-up"
chk "SMK: rmmod5 rc=0" "rmmod while retrying"
chk "SMK: rmmod lcd rc=0" "lcd.ko unloads (no leaked reference)"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|cannot create duplicate|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops/duplicate"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
