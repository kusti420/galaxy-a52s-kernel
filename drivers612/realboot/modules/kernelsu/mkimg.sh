#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Adds KernelSU (out/ksuinit + out/kernelsu.ko, rdinit=/ksuinit) to a finished real-boot build, by hand,
# until build-realboot.sh has a KSU=1 option:
#   drivers612/realboot/modules/kernelsu/mkimg.sh drivers612/realboot/out/<base> <new name>
# -> drivers612/realboot/out/<new name>/{boot,vendor_boot,dtbo}.img + REPORT.txt (then twrp/mk-ak-zips.sh on it).
# The two files go to the ROOT of our first-stage cpio (same lz4 stream as the modules, so the any-ROM zip's
# "remove our old fragment" logic still sees one fragment); boot.img and dtbo.img are copied unchanged.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd)
BASE=$(cd "$1" && pwd); NAME=$2; O=$(dirname "$BASE")/$NAME; W=$O/work
A=$TOP/drivers612/realboot/anykernel/a52boot/out/a52boot-host
DUMP=$(sed -n '1s/.* dump=\([^ ]*\) .*/\1/p' "$BASE/REPORT.txt")
rm -rf "$O"; mkdir -p "$W/x" "$W/ksu"
"$A" extract "$BASE/boot.img" "$BASE/vendor_boot.img" "$BASE/dtbo.img" "$W/x" > /dev/null
grep -q 'rdinit=' "$W/x/vendor-cmdline.txt" && { echo "base already has rdinit=" >&2; exit 1; }
lz4 -dc "$W/x/vendor-ramdisk-a52.cpio.lz4" > "$W/frag.cpio" 2> /dev/null || true
cpio -it < "$W/frag.cpio" > "$W/frag.list" 2> /dev/null || true
grep -qx 'lib/modules' "$W/frag.list" || { echo "cannot read the base fragment" >&2; exit 1; }
install -m 0755 "$HERE/out/ksuinit" "$W/ksu/ksuinit"; install -m 0644 "$HERE/out/kernelsu.ko" "$W/ksu/kernelsu.ko"
touch -d "2008-01-01 00:00:00 UTC" "$W/ksu/ksuinit" "$W/ksu/kernelsu.ko"   # same bytes on every run
( cd "$W/ksu" && printf 'ksuinit\nkernelsu.ko\n' | cpio -o -H newc -R 0:0 --reproducible 2> /dev/null ) > "$W/ksu.cpio"
cat "$W/frag.cpio" "$W/ksu.cpio" > "$W/frag2.cpio"
lz4 -l -9 -f -q "$W/frag2.cpio" "$W/frag2.cpio.lz4"
printf '%s rdinit=/ksuinit\n' "$(cat "$W/x/vendor-cmdline.txt")" > "$W/cmdline.txt"
"$A" mkvendor "$DUMP/vendor_boot.img" "$W/x/vendor_boot.dtb" "$W/cmdline.txt" "$W/frag2.cpio.lz4" "$O/vendor_boot.img" > "$W/mkvendor.txt"
cp "$BASE/boot.img" "$BASE/dtbo.img" "$O/"
"$A" budget "$O/boot.img" "$O/vendor_boot.img" > "$W/budget.txt"
{ sed "1s/realboot $(basename "$BASE") /realboot $NAME /" "$BASE/REPORT.txt" | head -n 2
  echo "$NAME = $(basename "$BASE") + KernelSU-Next LKM: /ksuinit + /kernelsu.ko in the first-stage cpio, rdinit=/ksuinit (modules/kernelsu/mkimg.sh)"; } > "$O/REPORT.txt"
rm -f "$W/frag.cpio" "$W/frag2.cpio"
( cd "$O" && sha256sum boot.img vendor_boot.img dtbo.img | tee SHA256SUMS )
