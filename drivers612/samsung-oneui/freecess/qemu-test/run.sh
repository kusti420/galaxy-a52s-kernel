#!/bin/bash
# Offline QEMU smoke test of freecess.ko on the bsp612 GKI Image (QEMU virt, no phone): module loads, protocol 27
# registers, hello round trip for all four mods, then every report is provoked for real: MOD_SIG (SIGKILL to a
# frozen uid), MOD_BINDER (oneway with interface token + sync call into a frozen binder context manager: this
# checks the private binder struct layouts against the Image), MOD_CFB (queued sync call found through the
# binder_procs list from the vendor hook), MOD_PKG (TCP data for a recorded uid), in cgroup2 mode (S26-style
# framework) and in cgroup1 mode (/dev/freezer/frozen as in the ROM's init.rc). Also: v1 freezer mount on GKI.
#   drivers612/samsung-oneui/freecess/qemu-test/run.sh            -> default module (max_version=1 = 5.4 answer): v1 tests
#   FC_ARGS="max_version=6" KFT_ARG=full .../run.sh               -> S26 negotiation: cgroup2 tests, then the v1 fallback
# PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); F=$(cd "$Q/.." && pwd); S=$(cd "$F/.." && pwd); TOP=$(cd "$S/../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$F" >/dev/null; "$F/test/build.sh" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$F/out/freecess.ko" "$F/test/out/kfreecess_test" "$WORK/rd/"
{ echo '#!/bin/busybox sh'; echo "FC_ARGS='${FC_ARGS:-}'; KFT_ARG='${KFT_ARG:-v1}'"; tail -n +2 "$Q/init.sh"; } > "$WORK/rd/init"
chmod +x "$WORK/rd/init" "$WORK/rd/bin/"* "$WORK/rd/kfreecess_test"
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "KFT: ok   no module: socket\(\) = -1" "without the module: EPROTONOSUPPORT"
chk "SMK: v1 freezer mount rc=0" "cgroup v1 freezer mounts on GKI 6.12"
chk "SMK: v1 frozen FROZEN rc=0 state=FROZEN" "/dev/freezer/frozen FROZEN"
chk "SMK: insmod rc=0" "freecess.ko loads"
chk "NETLINK_KFREECESS 27 registered" "protocol registered"
chk "SMK: kfreecess_test rc=0" "userspace test: 0 failures"
chk "KFT: END fails=0" "userspace test ran to the end"
chk "SMK: param binder_procs_known=1" "binder_procs captured from the vendor hook"
chk "SMK: rmmod rc=0" "rmmod"
chk "SMK: END" "script ran to the end"
grep -a "KFT: " "$C" | sed 's/\r$//'
if grep -aq "KFT: FAIL" "$C"; then f=1; fi
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
