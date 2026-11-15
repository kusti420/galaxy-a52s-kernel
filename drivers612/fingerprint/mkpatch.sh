#!/bin/sh
# Writes the complete change record orig/ -> src/ to patches/0001-et7xx-fingerprint-6.12.patch
# (sources only). Run after editing src/; port.sh then reproduces src/ from the 5.4 tree.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/patches/0001-et7xx-fingerprint-6.12.patch
mkdir -p "$HERE/patches"
: > "$OUT.tmp"
for f in fingerprint.h fingerprint_common.c fingerprint_common.h fingerprint_common_qcom.c \
	 fingerprint_sysfs.c fingerprint_sysfs.h et7xx.h et7xx-spi.c et7xx-spi_data_transfer.c; do
	(cd "$HERE" && diff -u --label "a/$f" --label "b/$f" "orig/$f" "src/$f") >> "$OUT.tmp" || true
done
mv "$OUT.tmp" "$OUT"
echo "$OUT: $(grep -c '^+[^+]' "$OUT") added, $(grep -c '^-[^-]' "$OUT") removed lines"
