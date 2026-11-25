#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Key-free QEMU smoke test of the SUSFS Image variant (bsp612/out/susfs/Image, build-susfs-image.sh):
#   drivers612/realboot/modules/resukisu/qemu-susfs-test.sh [scratch dir]   -> qemu-susfs-console.txt, qemu-susfs-initrd.txt
# Env: IMAGE=, RB=<build dir>, BASE_N=<expected module count> (qemu-initrd-check.sh runs without printk.devkmsg=on, so a
# build without ksuinit logs only a few "Loaded kernel module" lines there: give the count of the KSU=1 sibling build).
# Boot 1: busybox initrd + susfsq (the supercall `ksud susfs show version|variant|enabled_features` uses):
#         built-in KernelSU initialises, SUSFS answers with its version, 0 WARN/BUG/Oops.
# Boot 2: the initrd of a real OneUI 9 build (RB=<out/rbouNN>, default the newest; its vendor ramdisk + boot ramdisk as
#         the ABL hands them over) WITHOUT rdinit=/ksuinit: the ROM's first-stage init must start and load the same
#         number of first-stage modules as on the build's own Image (RB/qemu-initrd.txt), with no vermagic/CRC refusal.
#         (/ksuinit and /kernelsu.ko of a KSU=1 build are then dead files in the ramdisk; a KSU_BUILTIN build has none.)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd); DQ=$TOP/bsp612/out/diag/qemu
IMG=${IMAGE:-$TOP/bsp612/out/susfs/Image}
RB=${RB:-$(ls -dt "$TOP"/drivers612/realboot/out/rbou*/ | grep -v -- '-zip/$' | head -1)}
Q=${1:-$(mktemp -d)}; rm -rf "$Q/rd"; mkdir -p "$Q/rd/bin" "$Q/rd/lib" "$Q/rd/dev" "$Q/rd/proc" "$Q/rd/sys" "$HERE/out"
RUSTC=$(ls "$HOME"/.rustup/toolchains/*/lib/rustlib/aarch64-unknown-linux-musl -d | tail -1 | sed 's|/lib/rustlib/.*|/bin/rustc|')
"$RUSTC" --edition 2021 -O -C panic=abort -C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static \
	--remap-path-prefix="$HOME=~" --target aarch64-unknown-linux-musl -o "$HERE/out/susfsq" "$HERE/susfs/susfsq/susfsq.rs"
cp "$DQ/bin/busybox" "$Q/rd/bin/"; cp "$DQ/lib/ld-musl-aarch64.so.1" "$Q/rd/lib/" 2> /dev/null || true
install -m 0755 "$HERE/out/susfsq" "$Q/rd/susfsq"; install -m 0755 "$HERE/susfs/qemu-init.sh" "$Q/rd/init"
( cd "$Q/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$Q/rd.cpio.gz"
qemu() { timeout 180 qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 4G -nographic -no-reboot \
	-kernel "$IMG" -initrd "$1" -dtb "$DQ/nores.dtb" -append "console=ttyAMA0 printk.devkmsg=on loglevel=7 panic=-1 kvm-arm.mode=none mem=0xF0000000" < /dev/null 2>&1 || true; }
fail() { echo "QEMU SUSFS TEST FAILED: $*" >&2; exit 1; }

C=$HERE/qemu-susfs-console.txt
qemu "$Q/rd.cpio.gz" > "$C"
grep -a 'QSUS:' "$C" | sed 's/\r$//'
grep -a -q 'QSUS: susfs version: v' "$C" || fail "SUSFS did not report a version"
grep -a -q 'QSUS: susfs variant: GKI' "$C" || fail "SUSFS variant is not GKI"
grep -a -q 'QSUS: WARN/BUG/Oops lines this boot: 0' "$C" || fail "WARN/BUG/Oops in boot 1"
grep -a -q 'QSUS: done' "$C" || fail "init did not finish"

R=$HERE/qemu-susfs-initrd.txt; : > "$R"
rm -rf "$Q/b" "$Q/v"; unpack_bootimg --boot_img "$RB/boot.img" --out "$Q/b" > /dev/null
unpack_bootimg --boot_img "$RB/vendor_boot.img" --out "$Q/v" > /dev/null
cat "$Q/v/vendor_ramdisk" "$Q/b/ramdisk" > "$Q/initrd"
qemu "$Q/initrd" > "$Q/console2.txt"
N=$(grep -a -c 'Loaded kernel module' "$Q/console2.txt" || true)
BASE=${BASE_N:-$(sed -n 's/^first-stage modules loaded in QEMU: //p' "$RB/qemu-initrd.txt" 2> /dev/null || true)}
{ echo "Image $IMG ($(sha256sum < "$IMG" | cut -c1-16)), initrd of $(basename "$RB") without rdinit=/ksuinit"
  grep -a -E 'Linux version|Trying to unpack rootfs|Freeing initrd|Run .* as init process|init first stage started|KernelSU|susfs_init|Kernel panic' "$Q/console2.txt" | sed 's/\r$//' | head -20
  echo "first-stage modules loaded in QEMU: $N (the build's own Image: ${BASE:-?})"
  echo "module refusals (disagrees about version / Unknown symbol / vermagic / Exec format): $(grep -a -c -E 'disagrees about version of symbol|Unknown symbol|version magic|Exec format error' "$Q/console2.txt" || true)"
  echo "WARN/BUG/Oops before init exits: $(grep -a -c -E 'WARNING:|BUG:|Oops' "$Q/console2.txt" || true)"; } | tee "$R"
grep -a -q 'Run /init as init process' "$Q/console2.txt" || fail "ROM /init not started"
grep -a -q 'init first stage started' "$Q/console2.txt" || fail "the ROM's first-stage init never started"
grep -a -q -E 'disagrees about version of symbol|version magic' "$Q/console2.txt" && fail "a module was refused (CRC/vermagic)"
[ -z "$BASE" ] || [ "$N" = "$BASE" ] || fail "loaded $N modules, the build's own Image loads $BASE"
cp "$Q/console2.txt" "$HERE/out/qemu-susfs-initrd-console.txt"
echo "QEMU SUSFS TEST PASS" | tee -a "$R"
