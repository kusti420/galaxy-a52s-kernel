#!/bin/sh
# Writes the complete change record orig/ -> src/ to patches/0001-sec-nfc-6.12.patch
# (sources only). Run after editing src/; port.sh then reproduces src/ from the 5.4 tree.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/patches/0001-sec-nfc-6.12.patch
mkdir -p "$HERE/patches"
: > "$OUT.tmp"
for f in sec_nfc.c sec_nfc.h nfc_wakelock.h nfc_logger/nfc_logger.c nfc_logger/nfc_logger.h; do
	(cd "$HERE" && diff -u --label "a/$f" --label "b/$f" "orig/$f" "src/$f") >> "$OUT.tmp" || true
done
mv "$OUT.tmp" "$OUT"
echo "$OUT: $(grep -c '^+[^+]' "$OUT") added, $(grep -c '^-[^-]' "$OUT") removed lines"
