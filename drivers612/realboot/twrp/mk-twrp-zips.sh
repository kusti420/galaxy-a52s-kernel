#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Builds the recovery-flashable (TWRP / LineageOS recovery) zips from an alpha package dir.
#   drivers612/realboot/twrp/mk-twrp-zips.sh <pkg dir> [out dir]
# <pkg dir> = drivers612/realboot/out/<name>/pkg (README.txt, SHA256SUMS, vendor-addon/,
# a52s-k612-<name>-AP.tar, a52s-lineage-<date>-stock-AP.tar). Default out dir: <pkg>/../twrp.
# Env: NAME (default: name of the pkg's parent dir, e.g. alpha1), TITLE (shown by the zip),
#      PART_SIZES ("boot vendor_boot dtbo" byte sizes the images must have; a52sxq default).
# Output: a52s-k612-<name>-twrp.zip, a52s-lineage-stock-restore-twrp.zip, README-TWRP.txt,
# SHA256SUMS. Deterministic (detzip.py). The zips are not committed (~65 MB each).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: $0 <pkg dir> [out dir]" >&2; exit 2; }
PKG=$(cd "$1" && pwd)
NAME=${NAME:-$(basename "$(dirname "$PKG")")}
OUT=${2:-$(dirname "$PKG")/twrp}
PART_SIZES=${PART_SIZES:-"100663296 100663296 25165824"}
die() { printf "mk-twrp-zips: %b\n" "$*" >&2; exit 1; }

KTAR=$PKG/a52s-k612-$NAME-AP.tar
STAR=$(ls "$PKG"/a52s-lineage-*-stock-AP.tar 2>/dev/null | head -n 1)
[ -f "$KTAR" ] || die "missing $KTAR"
[ -n "$STAR" ] || die "missing a52s-lineage-<date>-stock-AP.tar in $PKG"
STOCK=$(basename "$STAR" | sed -n 's/^a52s-lineage-\([0-9]\{8\}\)-stock-AP\.tar$/\1/p')
[ -n "$STOCK" ] || die "cannot read the stock date from $(basename "$STAR")"
[ -d "$PKG/vendor-addon" ] || die "missing $PKG/vendor-addon"

echo "== verifying $PKG/SHA256SUMS"
(cd "$PKG" && sha256sum -c --quiet SHA256SUMS) || die "package checksums do not match"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ST=$(mktemp -d "$OUT/.stage.XXXXXX")
trap 'rm -rf "$ST"' EXIT

# images from an AP tar: exactly the three regular files
untar_images() { # <tar> <dir>
	local list want="boot.img dtbo.img vendor_boot.img"
	list=$(tar -tvf "$1" | awk '{ if (substr($1,1,1) != "-") bad=1; print $NF } END { if (bad) print "NONREG" }' | sort | tr '\n' ' ')
	[ "$list" = "$want " ] || die "$(basename "$1"): unexpected content: $list"
	mkdir -p "$2"
	tar -xf "$1" -C "$2" --no-same-owner --no-same-permissions boot.img vendor_boot.img dtbo.img
	local i=0 p sz sizes
	read -r -a sizes <<< "$PART_SIZES"
	for p in boot vendor_boot dtbo; do
		sz=$(stat -c %s "$2/$p.img")
		[ "$sz" = "${sizes[$i]}" ] || die "$p.img is $sz bytes, expected ${sizes[$i]} (full partition image)"
		i=$((i + 1))
	done
}

kver() { grep -a -o -m 1 'Linux version [0-9][^ ]*' "$1" | head -n 1 | sed 's/^Linux version //'; }

stage_common() { # <dir> <mode> <title> <images src dir>
	local d=$1
	mkdir -p "$d/META-INF/com/google/android" "$d/images"
	install -m 0755 "$HERE/update-binary" "$d/META-INF/com/google/android/update-binary"
	install -m 0644 "$HERE/updater-script" "$d/META-INF/com/google/android/updater-script"
	# AOSP/LineageOS recovery refuses a zip without it ("Failed to parse metadata in the zip
	# file"); for a non-A/B package its content is not checked further
	mkdir -p "$d/META-INF/com/android"
	printf 'ota-type=BLOCK\npre-device=a52sxq\n' > "$d/META-INF/com/android/metadata"
	cp "$4"/boot.img "$4"/vendor_boot.img "$4"/dtbo.img "$d/images/"
	sed -e "s/@NAME@/$NAME/g" -e "s/@STOCK@/$STOCK/g" "$HERE/README-TWRP.txt" > "$d/README-TWRP.txt"
	local kb
	kb=$(du -sk --apparent-size "$d" | cut -f1)
	{
		echo "MODE=$2"
		echo "TITLE=$3"
		echo "EXPECT_ROM=24.0-$STOCK"
		echo "NEED_TMP_KB=$((kb + 16384))"
	} > "$d/a52s-k612.conf"
}

sums() { # <dir>: SHA256SUMS of the payload (everything but META-INF)
	(cd "$1" && find . -type f ! -path './META-INF/*' ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort |
		xargs sha256sum) > "$1.sums"
	mv "$1.sums" "$1/SHA256SUMS"
}

echo "== staging"
untar_images "$KTAR" "$ST/k"
untar_images "$STAR" "$ST/s"
KV=$(kver "$ST/k/boot.img")
SV=$(kver "$ST/s/boot.img")
case $KV in 6.12.*) ;; *) die "kernel tar's boot.img is not 6.12 ($KV)";; esac
case $SV in 5.4.*) ;; *) die "stock tar's boot.img is not 5.4 ($SV)";; esac
TITLE_K=${TITLE:-"Linux 6.12 kernel $NAME ($KV)"}
TITLE_S="stock LineageOS 24.0-$STOCK kernel ($SV)"

Z1=$ST/z1
stage_common "$Z1" install "$TITLE_K" "$ST/k"
mkdir -p "$Z1/vendor-addon"
cp -r "$PKG/vendor-addon/." "$Z1/vendor-addon/"
find "$Z1/vendor-addon" -type d -exec chmod 0755 {} +
find "$Z1/vendor-addon" -type f -exec chmod 0644 {} +
[ -z "$(find "$Z1/vendor-addon" ! -type f ! -type d)" ] || die "vendor-addon has non-regular files"
# the conf's size was computed before the add-on was copied in: redo it
kb=$(du -sk --apparent-size "$Z1" | cut -f1)
sed -i "s/^NEED_TMP_KB=.*/NEED_TMP_KB=$((kb + 16384))/" "$Z1/a52s-k612.conf"
sums "$Z1"

Z2=$ST/z2
stage_common "$Z2" restore "$TITLE_S" "$ST/s"
sums "$Z2"

# privacy gate on everything that is not a kernel/module binary
echo "== privacy check"
# personal strings come from the environment (LEAK_EXTRA, e.g. your user/handle/mail) so this file has none
leak="(/home/|/root/|/Users/|R5C[A-Z0-9]{8}|RFCT[A-Z0-9]{7}|HQ62[A-Z0-9]{6}|192\\.168\\.${LEAK_EXTRA:+|$LEAK_EXTRA})"
for d in "$Z1" "$Z2"; do
	hits=$(find "$d" -type f ! -name '*.img' ! -name '*.ko' -print0 | xargs -0 grep -EIn "$leak" |
		grep -v 'https://github.com/a52sxq-kernel/galaxy-a52s-kernel' || true)
	[ -z "$hits" ] || die "personal data in the zip text files:\n$hits"
done
nbin=$(find "$Z1" "$Z2" -type f \( -name '*.img' -o -name '*.ko' \) -print0 | xargs -0 grep -Elc '/home/' || true)
if [ -n "$nbin" ]; then
	echo "NOTE: build paths (/home/...) inside kernel/module binaries (payload, unchanged):"
	printf '  %s\n' $(echo "$nbin" | sed "s#^$ST/##")
fi

echo "== zipping"
ZK=a52s-k612-$NAME-twrp.zip
ZS=a52s-lineage-stock-restore-twrp.zip
python3 -I "$HERE/detzip.py" "$OUT/$ZK" "$Z1"
python3 -I "$HERE/detzip.py" "$OUT/$ZS" "$Z2"
cp "$Z1/README-TWRP.txt" "$OUT/README-TWRP.txt"
chmod 0644 "$OUT/$ZK" "$OUT/$ZS" "$OUT/README-TWRP.txt"
(cd "$OUT" && sha256sum "$ZK" "$ZS" README-TWRP.txt > SHA256SUMS)

# self-check: unzip -t and the payload sums from inside each zip
for z in "$ZK" "$ZS"; do
	unzip -tq "$OUT/$z" > /dev/null || die "$z: unzip -t failed"
done
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
