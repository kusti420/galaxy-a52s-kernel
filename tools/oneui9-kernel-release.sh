#!/bin/bash
# OneUI 9 kernel release line (owner 2026-11-15/16): publish the kernel that ships in the OneUI 9 port
# (5.4.302 bone-machine + ReSukiSU + SUSFS) as its own occasional GitHub release, ONLY when it changed.
# Usage: tools/oneui9-kernel-release.sh <a52sxq_OneUI9.x.y.zip> [--publish]
# - extracts boot.img + vendor_boot.img from the build zip
# - kernel id = sha256 of the boot.img kernel payload (unpack_bootimg) + its "Linux version" string
# - compares with release/oneui9-kernel.last (committed); same id -> "no change", nothing to do
# - builds release/oneui9-kernel-<ver>/ (boot.img, vendor_boot.img, Odin AP tar, README.txt, SHA256SUMS)
# - --publish: gh pre-release "oneui9-kernel-<ver>" on a52sxq-kernel/galaxy-a52s-kernel, then updates the .last file
set -euo pipefail
Z=${1:?OneUI 9 build zip}; PUB=${2:-}
TOP=$(cd "$(dirname "$0")/.." && pwd)
VER=$(basename "$Z" .zip | sed 's/^a52sxq_OneUI//')
OUT=$TOP/release/oneui9-kernel-$VER; LAST=$TOP/release/oneui9-kernel.last
SRC_URL=https://github.com/mna08072-cmyk/android_kernel_samsung_sm7325_a52s_5g
SRC_BRANCH=resukisu-oneui
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -q -o "$Z" boot.img vendor_boot.img -d "$T"
unpack_bootimg --boot_img "$T/boot.img" --out "$T/u" >/dev/null 2>&1 || { echo "unpack_bootimg failed" >&2; exit 1; }
KSHA=$(sha256sum "$T/u/kernel" | cut -d' ' -f1)
KVER=$( (gzip -dc "$T/u/kernel" 2>/dev/null || cat "$T/u/kernel") | strings | grep -m1 "Linux version" | cut -c1-160 || true)
ID="$KSHA $KVER"
echo "OneUI $VER kernel: $KVER"; echo "payload sha256: $KSHA"
if [ -f "$LAST" ] && [ "$(sed -n 2p "$LAST")" = "$KSHA" ]; then
	echo "no change since $(sed -n 1p "$LAST"): nothing to release"; exit 0; fi
rm -rf "$OUT"; mkdir -p "$OUT"; cp "$T/boot.img" "$T/vendor_boot.img" "$OUT/"
(cd "$OUT" && tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "a52s-oneui9-kernel-$VER-AP.tar" boot.img vendor_boot.img)
cat > "$OUT/README.txt" <<EOF
Galaxy A52s 5G (SM-A528B) - kernel of the OneUI 9 port, from build $VER
$KVER
Source (GPL-2.0): $SRC_URL (branch $SRC_BRANCH)

For the OneUI 9 port only (its boot/vendor_boot ramdisks belong to that ROM). Not for LineageOS.
Install: TWRP -> Install -> Install Image: boot.img -> Boot, vendor_boot.img -> Vendor Boot;
or Odin AP = a52s-oneui9-kernel-$VER-AP.tar. Roll back: the same files from your current OneUI 9 build zip.
Root: includes ReSukiSU (KernelSU) + SUSFS.
EOF
(cd "$OUT" && sha256sum boot.img vendor_boot.img "a52s-oneui9-kernel-$VER-AP.tar" README.txt > SHA256SUMS)
echo "built: $OUT"
if [ "$PUB" = --publish ]; then
	gh release create "oneui9-kernel-$VER" --repo a52sxq-kernel/galaxy-a52s-kernel --prerelease \
		--title "OneUI 9 port kernel ($VER): 5.4.302 bone-machine + ReSukiSU" --notes-file "$OUT/README.txt" \
		"$OUT/boot.img" "$OUT/vendor_boot.img" "$OUT/a52s-oneui9-kernel-$VER-AP.tar" "$OUT/SHA256SUMS"
	printf '%s\n%s\n%s\n' "$VER" "$KSHA" "$KVER" > "$LAST"
	echo "published; recorded in $LAST (commit it)"
fi
