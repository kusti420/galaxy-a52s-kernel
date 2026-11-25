#!/bin/bash
# Offline QEMU smoke test of sdp_dek.ko on the bsp612 GKI Image (QEMU virt, no phone): module loads, the three
# misc nodes + asym_alg sysfs appear, netlink 28 and 29 register, then test/sdp_test plays system_server, an
# app of the engine's user, the fs-handler listener and the public-key crypto daemon: engine add/boot/unlock/
# lock/remove events, DEK generate, AES-GCM wrap/unwrap with the symmetric key, the ECDH path through the
# netlink 29 daemon while locked, refusals (wrong uid, locked, tampered blob), dek_log records; rmmod, reload.
#   drivers612/samsung-oneui/sdp/qemu-test/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); F=$(cd "$Q/.." && pwd); S=$(cd "$F/.." && pwd); TOP=$(cd "$S/../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$F" >/dev/null; "$F/test/build.sh" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$F/out/sdp_dek.ko" "$F/test/out/sdp_test" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"* "$WORK/rd/sdp_test"
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SDT: ok   no module: netlink 28" "without the module: EPROTONOSUPPORT"
chk "SMK: insmod rc=0" "sdp_dek.ko loads"
chk "SMK: misc dek_evt dek_log dek_req" "misc devices dek_evt dek_req dek_log"
chk "SMK: asym_alg=ECDH mode=-rw-------" "sysfs asym_alg (ECDH, 0600)"
chk "SMK: sdp_test rc=0" "userspace test: 0 failures"
chk "SDT: END fails=0" "userspace test ran to the end"
chk "SMK: rmmod rc=0" "rmmod"
chk "SMK: second rmmod rc=0" "reload + rmmod"
chk "SMK: END" "script ran to the end"
grep -a "SDT: " "$C" | sed 's/\r$//'
if grep -aq "SDT: FAIL" "$C"; then f=1; fi
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
