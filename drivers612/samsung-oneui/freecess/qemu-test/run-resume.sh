#!/bin/bash
# SPEC/07 offline proof on the bsp612 GKI Image (QEMU virt, no phone): a process in the v1 FROZEN cgroup
# (/dev/freezer/frozen, Freecess version 1) is half thawed by a system suspend/resume cycle on 6.12, and
# freecess.ko's resume re-freeze (parameter refreeze=1, default) puts it back. PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); F=$(cd "$Q/.." && pwd); S=$(cd "$F/.." && pwd); TOP=$(cd "$S/../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$F" >/dev/null; "$F/test/build.sh" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$F/out/freecess.ko" "$F/test/out/halfthaw" "$WORK/rd/"; cp "$Q/init-resume.sh" "$WORK/rd/init"
chmod +x "$WORK/rd/init" "$WORK/rd/bin/"* "$WORK/rd/halfthaw"
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "RSM: insmod rc=0" "freecess.ko loads"
chk "RSM: nofix: before suspend: frozen ok" "refreeze=0: frozen before suspend"
chk "RSM: nofix: after resume: HALF THAWED" "refreeze=0: the bug: half thawed after resume (sleeper runs, spinner frozen)"
chk "RSM: nofix: after thaw: both threads run" "refreeze=0: thaw by leaving the cgroup"
chk "RSM: fix: before suspend: frozen ok" "refreeze=1: frozen before suspend"
chk "RSM: fix: after resume: STILL FROZEN" "refreeze=1: still frozen after resume"
chk "RSM: fix: after 2nd resume: STILL FROZEN" "refreeze=1: still frozen after a second resume"
chk "RSM: fix: after thaw: both threads run" "refreeze=1: thaw by leaving the cgroup"
chk "RSM: fix: killed" "refreeze=1: SIGKILL after thaw"
chk "RSM: rmmod rc=0" "rmmod (no task work left)"
chk "RSM: END" "script ran to the end"
grep -a "RSM: " "$C" | sed 's/\r$//'
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
