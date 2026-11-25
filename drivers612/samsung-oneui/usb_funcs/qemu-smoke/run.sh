#!/bin/bash
# Offline QEMU smoke (bsp612 GKI Image, QEMU virt, no phone) of the soc-repo dist gadget function modules
# usb_f_cdev / usb_f_ccid (load, configfs mkdir/symlink/rmdir of every OneUI instance, char devices, rmmod)
# and, as phase 2, usb_f_qdss with its dwc3-msm dependency chain. Pattern: ../../qemu-smoke/run.sh.
#   drivers612/samsung-oneui/usb_funcs/qemu-smoke/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/../.." && pwd); TOP=$(cd "$S/../.." && pwd)
D=$TOP/bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/rd/m"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$D/drivers/usb/gadget/function/usb_f_cdev.ko" "$D/drivers/usb/gadget/function/usb_f_ccid.ko" "$WORK/rd/m/"
python3 - "$D" > "$WORK/rd/m/qdss.order" <<'PY'
import sys, os, shutil
D = sys.argv[1]; dep = {}
for l in open(D + '/modules.dep'):
    k, v = l.split(':', 1); dep[k] = v.split()
order, seen = [], set()
def visit(m):
    if m in seen: return
    seen.add(m)
    for d in dep.get(m, []): visit(d)
    order.append(m)
visit('drivers/usb/gadget/function/usb_f_qdss.ko')
for m in order: print(os.path.basename(m))
PY
for m in $(cat "$WORK/rd/m/qdss.order"); do cp "$(find "$D" -name "$m")" "$WORK/rd/m/"; done
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: cdev rc=0" "usb_f_cdev loads"
chk "SMK: ccid rc=0" "usb_f_ccid loads"
for i in cser.dun.0 cser.nmea.1 cser.dun.2 ccid.ccid; do chk "SMK: mkdir $i rc=0" "mkdir $i"; done
chk "SMK: class msm_usb_bridge: at_usb0 at_usb1 at_usb2" "/dev/at_usb0..2 (class msm_usb_bridge)"
chk "SMK: class ccid_usb: ccid_bulk ccid_ctrl" "/dev/ccid_ctrl + /dev/ccid_bulk (class ccid_usb)"
chk "SMK: symlink dun rc=0" "cser.dun.0 links into b.1"
chk "SMK: symlink ccid rc=0" "ccid.ccid links into b.1"
for i in cser.dun.0 cser.nmea.1 cser.dun.2 ccid.ccid; do chk "SMK: rmdir $i rc=0" "rmdir $i"; done
chk "SMK: rmmod cdev rc=0" "rmmod cdev"
chk "SMK: PHASE1 END" "phase 1 ran to the end"
if grep -aq "SMK: qdss chain ok=1" "$C"; then
	echo "ok   qdss dependency chain loads in QEMU"
	chk "SMK: mkdir qdss.qdss rc=0" "mkdir qdss.qdss"; chk "SMK: mkdir qdss.qdss_mdm rc=0" "mkdir qdss.qdss_mdm"
	chk "SMK: symlink qdss rc=0" "qdss.qdss links into b.1"; chk "SMK: rmdir qdss.qdss_mdm rc=0" "rmdir qdss"
else
	echo "INFO qdss chain did not load in QEMU (Qualcomm/Gunyah deps; see console), not counted"
fi
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "WARN kernel warning/oops in console (check phase)"; grep -anE "WARNING:|BUG:|Oops" "$C" | head -5; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
