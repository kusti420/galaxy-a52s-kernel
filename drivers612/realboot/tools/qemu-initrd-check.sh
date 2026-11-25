#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Key-free proof that the kernel can unpack the initrd exactly as the ABL hands it over (header v3: vendor ramdisk
# section of vendor_boot.img + boot ramdisk of boot.img, concatenated byte for byte), on the build's own Image in QEMU:
#   drivers612/realboot/tools/qemu-initrd-check.sh <out/rbNN> [scratch dir]   -> <out/rbNN>/qemu-initrd.txt
# PASS = no "rootfs image is not initramfs" / "Decoding failed" and the kernel runs the ramdisk's init (rdinit from the
# vendor cmdline, /init otherwise). Why: rbou2 (OneUI 9) booted to "Decoding failed" -> no /init -> panic loop: the ROM's
# boot ramdisk is gzip and our lz4 legacy fragment before it had no end marker (2026-11-22). The kexec rehearsal can not
# see this (it re-packs the whole initrd).
set -euo pipefail
B=$(cd "${1:?out/rbNN}" && pwd); Q=${2:-$(mktemp -d)}; mkdir -p "$Q"
TOP=$(cd "$(dirname "$0")/../../.." && pwd); DQ=$TOP/bsp612/out/diag/qemu
fail() { echo "QEMU INITRD CHECK FAILED: $*" | tee -a "$B/qemu-initrd.txt" >&2; exit 1; }
: > "$B/qemu-initrd.txt"
rm -rf "$Q/b" "$Q/v"; unpack_bootimg --boot_img "$B/boot.img" --out "$Q/b" > /dev/null
unpack_bootimg --boot_img "$B/vendor_boot.img" --out "$Q/v" > "$Q/v.info"
[ -f "$Q/v/vendor_ramdisk" ] || fail "no single vendor_ramdisk (v4 table?): not handled here"
cat "$Q/v/vendor_ramdisk" "$Q/b/ramdisk" > "$Q/initrd"
RDI=$(grep -o 'rdinit=[^ ]*' "$Q/v.info" | head -1 | cut -d= -f2 || true)
echo "initrd = vendor ramdisk $(stat -c %s "$Q/v/vendor_ramdisk") + boot ramdisk $(stat -c %s "$Q/b/ramdisk") bytes; rdinit=${RDI:-none}" | tee -a "$B/qemu-initrd.txt"
timeout 120 qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 4G -nographic -no-reboot \
	-kernel "$Q/b/kernel" -initrd "$Q/initrd" -dtb "$DQ/nores.dtb" -append "console=ttyAMA0 loglevel=7 panic=-1 \
kvm-arm.mode=none mem=0xF0000000 ${RDI:+rdinit=$RDI}" < /dev/null > "$Q/console.txt" 2>&1 || true
{ grep -a -E 'Trying to unpack rootfs|initramfs|Decoding failed|data corrupted|Freeing initrd|Run .* as init process|init first stage started|Kernel panic' "$Q/console.txt" || true; } > "$Q/key.txt"
head -12 "$Q/key.txt" | tee -a "$B/qemu-initrd.txt"; echo "first-stage modules loaded in QEMU: $(grep -a -c 'Loaded kernel module' "$Q/console.txt" || true)" | tee -a "$B/qemu-initrd.txt"
grep -a -q 'Trying to unpack rootfs image as initramfs' "$Q/console.txt" || fail "kernel did not reach the initramfs unpack (console $Q/console.txt)"
grep -a -q -E 'rootfs image is not initramfs|Decoding failed|data corrupted|broken padding|junk within compressed archive' "$Q/console.txt" && fail "initramfs unpack error"
grep -a -q -E "Run ${RDI:-/init} as init process" "$Q/console.txt" || fail "init not started"
grep -a -q 'init first stage started' "$Q/console.txt" || fail "the ROM's first-stage init never started (ramdisk /init missing?)"
echo "QEMU INITRD CHECK PASS" | tee -a "$B/qemu-initrd.txt"
