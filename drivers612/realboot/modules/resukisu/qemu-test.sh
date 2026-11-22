#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Key-free QEMU proof of out/ksuinit + out/kernelsu.ko on the 6.12 diag Image (the Image of every real boot so far):
#   drivers612/realboot/modules/resukisu/qemu-test.sh [scratch dir]   -> qemu-crashguard-console.txt
# Three boots in one QEMU run (RAM, and so ramoops at 0x13f000000 above mem=, survives the guest reset):
# 1 = ReSukiSU loads, init (qemu-guard-init.sh) crashes on purpose (sysrq c, panic=-1 -> reset);
# 2 = ksuinit finds dmesg-ramoops-0, does NOT load kernelsu.ko, removes the record, init reboots;
# 3 = kernelsu loads again, init sees boot 2's guard line in console-ramoops: "GUARD PASS", power off.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd); DQ=$TOP/bsp612/out/diag/qemu
Q=${1:-$(mktemp -d)}; rm -rf "$Q/rd"; mkdir -p "$Q/rd/bin" "$Q/rd/lib" "$Q/rd/dev" "$Q/rd/proc" "$Q/rd/sys"
cp "$DQ/bin/busybox" "$Q/rd/bin/"; cp "$DQ/lib/ld-musl-aarch64.so.1" "$Q/rd/lib/" 2> /dev/null || true
install -m 0755 "$HERE/out/ksuinit" "$Q/rd/ksuinit"; install -m 0644 "$HERE/out/kernelsu.ko" "$Q/rd/kernelsu.ko"
install -m 0755 "$HERE/qemu-guard-init.sh" "$Q/rd/init"
( cd "$Q/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$Q/rd.cpio.gz"
timeout 300 qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 4G -nographic \
	-kernel "$TOP/bsp612/out/diag/Image" -initrd "$Q/rd.cpio.gz" -dtb "$DQ/nores.dtb" -append "console=ttyAMA0 \
rdinit=/ksuinit printk.devkmsg=on loglevel=7 panic=-1 kvm-arm.mode=none mem=0xF0000000 ramoops.mem_address=0x13f000000 \
ramoops.mem_size=0x100000 ramoops.record_size=0x20000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x10000" \
	< /dev/null > "$HERE/qemu-crashguard-console.txt" 2>&1 || true
grep -a 'QRSK:' "$HERE/qemu-crashguard-console.txt"
grep -a -q 'GUARD PASS' "$HERE/qemu-crashguard-console.txt"
