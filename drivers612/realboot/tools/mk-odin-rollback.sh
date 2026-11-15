#!/bin/bash
# Builds the odin4 rollback package for a real-boot attempt: a plain ustar AP.tar holding the
# phone's own boot.img, vendor_boot.img and dtbo.img (complete partition images with footers),
# as used on phone 2 after rb7/rb8/rb9 (`odin4 -a AP.tar -d /dev/bus/usb/BBB/DDD`, from a
# Download mode entered by hand). Nothing else goes in: no vbmeta, recovery, firmware.
#
#   tools/mk-odin-rollback.sh <dir with the 3 images> <out dir> [SHA256SUMS that must match]
#
# Phone 1 (PHONE1, LineageOS 24.0-20261028 since 2026-11-15) runs the same build as phone 2:
#   tools/mk-odin-rollback.sh testdev-PHONE2/backup-2026-11-14-prerealboot \
#       testdev-PHONE1/odin-rollback-lineage-20261028
# (those three images are byte-identical to boot.img/vendor_boot.img/dtbo.img of
# lineage-24.0-20261028-nightly-a52sxq-signed.zip, which writes them unconditionally).
# Builds only: no phone is touched.
set -euo pipefail
SRC=${1:?source dir}; OUT=${2:?out dir}; SUMS=${3:-$SRC/SHA256SUMS}
for i in boot vendor_boot dtbo; do [ -f "$SRC/$i.img" ] || { echo "no $SRC/$i.img" >&2; exit 1; }; done
sizes="boot 100663296 vendor_boot 100663296 dtbo 25165824"   # BoardConfigCommon.mk partition sizes
set -- $sizes; while [ $# -gt 0 ]; do
	[ "$(stat -c %s "$SRC/$1.img")" = "$2" ] || { echo "$1.img is not $2 bytes (not a full partition dump)" >&2; exit 1; }; shift 2; done
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for i in boot vendor_boot dtbo; do cp "$SRC/$i.img" "$T/"; done
( cd "$T" && sha256sum boot.img vendor_boot.img dtbo.img ) > "$OUT/SHA256SUMS"
if [ -f "$SUMS" ]; then
	grep -E '  (boot|vendor_boot|dtbo)\.img$' "$SUMS" | sort -k2 | diff - <(sort -k2 "$OUT/SHA256SUMS") > /dev/null \
		|| { echo "images differ from $SUMS" >&2; exit 1; }
fi
( cd "$T" && tar -H ustar --owner=0 --group=0 --numeric-owner -cf "$OUT/AP.tar.part" boot.img vendor_boot.img dtbo.img )
mv "$OUT/AP.tar.part" "$OUT/AP.tar"
# read back: the members are the images, byte for byte
mkdir "$T/x"; tar -xf "$OUT/AP.tar" -C "$T/x"
( cd "$T/x" && sha256sum -c --quiet "$OUT/SHA256SUMS" ) || { echo "AP.tar read-back differs" >&2; exit 1; }
[ "$(tar -tf "$OUT/AP.tar" | tr '\n' ' ')" = "boot.img vendor_boot.img dtbo.img " ] || { echo "unexpected AP.tar members" >&2; exit 1; }
( cd "$OUT" && sha256sum AP.tar >> SHA256SUMS )
echo "$OUT/AP.tar: $(stat -c %s "$OUT/AP.tar") bytes, ustar, members boot.img vendor_boot.img dtbo.img (read back OK)"
cat "$OUT/SHA256SUMS"
