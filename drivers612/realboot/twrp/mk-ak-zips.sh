#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Builds the ROM-independent ("AnyKernel") recovery zips (2026-11-18) from a real-boot build:
#   drivers612/realboot/twrp/mk-ak-zips.sh <src> [out dir]
# <src> = a build-realboot.sh output dir (drivers612/realboot/out/<name>: boot.img, vendor_boot.img,
#         dtbo.img, [vendor-addon/], REPORT.txt) or an alpha package dir (out/<name>/pkg: the
#         a52s-k612-<name>-AP.tar, vendor-addon/, a52s-lineage-<date>-stock-AP.tar).
# The zip does NOT carry images. It carries our parts only and bin/a52boot (static arm64,
# ../anykernel/a52boot) builds the new images on the phone from the CURRENT ones:
#   kernel/Image                       the kernel (from <src>'s boot.img)
#   kernel/vendor_boot.dtb             our merged dtb            (from <src>'s vendor_boot.img)
#   kernel/vendor-cmdline.txt          our vendor command line   (")
#   kernel/vendor-ramdisk-a52.cpio.lz4 our first-stage ramdisk fragment (the lz4 stream(s) after
#                                      the ROM's vendor ramdisk)
#   kernel/dtbo.raw                    our dtbo (without footer)
#   vendor-addon/                      the /vendor add-on (ADDON=vendor builds; none for ADDON=vendor_boot)
# Self-check: the host build of a52boot must rebuild <src>'s three images byte for byte from the
# ROM images they were built from (DUMP=<dir>, default: REPORT.txt's dump= or the pkg's stock tar).
# The kernel-only zip (no vendor-addon/) is ROM-generic: update-binary accepts any Android ROM of the SM-A528B and
# only warns on ROMs it was not tested with; a zip with vendor-addon/ stays LineageOS 24 only.
# Env: NAME (default: <src>'s name), TITLE, DUMP, CHECK_DUMPS (more "<dir>" ROM image dirs that
# must give valid images too: AVB footer verifies, ROM ramdisk kept), LEAK_EXTRA (privacy grep).
# Output: a52s-k612-<name>-twrp.zip, a52s-k612-restore-twrp.zip, README-TWRP.txt, SHA256SUMS.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AKD=$(cd "$HERE/../anykernel/a52boot" && pwd)
[ $# -ge 1 ] || { echo "usage: $0 <realboot out dir | alpha pkg dir> [out dir]" >&2; exit 2; }
SRC=$(cd "$1" && pwd)
die() { printf "mk-ak-zips: %b\n" "$*" >&2; exit 1; }

"$AKD/build.sh" > /dev/null
AKH=$AKD/out/a52boot-host
AKA=$AKD/out/a52boot-arm64

ST=$(mktemp -d "${TMPDIR:-/tmp}/a52s-ak.XXXXXX")
trap 'rm -rf "$ST"' EXIT

# ---------------------------------------------------------------- the build's images
if [ -f "$SRC/boot.img" ] && [ -f "$SRC/vendor_boot.img" ]; then
	NAME=${NAME:-$(basename "$SRC")}
	IMG=$SRC
	ADDON_DIR=$SRC/vendor-addon
	if [ -z "${DUMP:-}" ] && [ -f "$SRC/REPORT.txt" ]; then
		DUMP=$(sed -n '1s/.* dump=\([^ ]*\) .*/\1/p' "$SRC/REPORT.txt")
	fi
elif [ -f "$SRC/SHA256SUMS" ] && ls "$SRC"/a52s-k612-*-AP.tar > /dev/null 2>&1; then
	(cd "$SRC" && sha256sum -c --quiet SHA256SUMS) || die "package checksums do not match"
	NAME=${NAME:-$(basename "$(dirname "$SRC")")}
	KTAR=$SRC/a52s-k612-$NAME-AP.tar
	[ -f "$KTAR" ] || die "missing $KTAR"
	IMG=$ST/img
	mkdir -p "$IMG"
	tar -xf "$KTAR" -C "$IMG" --no-same-owner --no-same-permissions boot.img vendor_boot.img dtbo.img
	ADDON_DIR=$SRC/vendor-addon
	STAR=$(ls "$SRC"/a52s-lineage-*-stock-AP.tar 2>/dev/null | head -n 1)
	if [ -z "${DUMP:-}" ] && [ -n "$STAR" ]; then
		DUMP=$ST/dump
		mkdir -p "$DUMP"
		tar -xf "$STAR" -C "$DUMP" --no-same-owner --no-same-permissions boot.img vendor_boot.img dtbo.img
	fi
else
	die "$SRC is neither a build-realboot.sh output dir nor an alpha package dir"
fi
for i in boot vendor_boot dtbo; do [ -f "$IMG/$i.img" ] || die "missing $IMG/$i.img"; done
OUT=${2:-$(dirname "$SRC")/$NAME-ak}
case $SRC in */pkg) OUT=${2:-$(dirname "$SRC")/twrp-ak};; esac
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

echo "== $NAME: extracting our parts from $IMG"
K=$ST/z1/kernel
"$AKH" extract "$IMG/boot.img" "$IMG/vendor_boot.img" "$IMG/dtbo.img" "$K" | sed 's/^/  /'
KREL=$("$AKH" info "$IMG/boot.img" | sed -n 's/^kernel_version=//p')
case $KREL in 6.12.*) ;; *) die "boot.img kernel is not 6.12 ($KREL)";; esac
VC=$(cat "$K/vendor-cmdline.txt")
ADDON=none
if [ -d "$ADDON_DIR" ]; then
	ADDON=vendor
	case " $VC " in *" androidboot.a52sxq.k612=1 "*) ;; *) die "vendor-addon present but the cmdline lacks the add-on gate androidboot.a52sxq.k612=1";; esac
else
	case " $VC " in *" androidboot.a52sxq.k612vb=1 "*) ;; *) die "no vendor-addon and no ADDON=vendor_boot gate (androidboot.a52sxq.k612vb=1) in the cmdline";; esac
fi
echo "  kernel $KREL, add-on: $ADDON"

# ---------------------------------------------------------------- self-check against the ROM images
if [ -n "${DUMP:-}" ]; then
	for i in boot vendor_boot dtbo; do [ -f "$DUMP/$i.img" ] || die "DUMP=$DUMP has no $i.img"; done
	echo "== self-check: a52boot rebuilds $NAME's images from the ROM images in $DUMP"
	"$AKH" mkboot "$DUMP/boot.img" "$K/Image" "$ST/c-boot.img" > /dev/null
	"$AKH" mkvendor "$DUMP/vendor_boot.img" "$K/vendor_boot.dtb" "$K/vendor-cmdline.txt" "$K/vendor-ramdisk-a52.cpio.lz4" "$ST/c-vendor_boot.img" > /dev/null
	"$AKH" mkdtbo "$DUMP/dtbo.img" "$K/dtbo.raw" "$ST/c-dtbo.img" > /dev/null
	for i in boot vendor_boot dtbo; do
		if cmp -s "$ST/c-$i.img" "$IMG/$i.img"; then continue; fi
		# OneUI 9 port: the build signs with the ROM's key (UN1CA testkey), a52boot (on the phone) writes the same
		# vbmeta unsigned: then everything but the signature must match: content incl. the AVB padding, digest, salt
		avbtool info_image --image "$IMG/$i.img" | grep -q 'Algorithm: *NONE' && die "self-check: $i.img made from $DUMP differs from $IMG/$i.img"
		o=$(avbtool info_image --image "$IMG/$i.img" | sed -n 's/^Original image size: *\([0-9]*\) bytes/\1/p')
		cmp -s <(head -c "$o" "$ST/c-$i.img") <(head -c "$o" "$IMG/$i.img") || die "self-check: $i.img content made from $DUMP differs from $IMG/$i.img"
		diff <(avbtool info_image --image "$IMG/$i.img" | grep -E 'Original image size|Image Size|Digest|Salt|Partition Name|Prop') \
			<(avbtool info_image --image "$ST/c-$i.img" | grep -E 'Original image size|Image Size|Digest|Salt|Partition Name|Prop') >/dev/null \
			|| die "self-check: $i.img footer (digest/salt/props) made from $DUMP differs from $IMG/$i.img"
		"$AKH" info "$ST/c-$i.img" | grep -qx avb_hash_ok=1 || die "self-check: AVB hash of $i.img made from $DUMP does not verify"
		echo "  $i: equal to the build except the signature (build: signed with the ROM's key; zip: unsigned on the phone)"
	done
	echo "  boot, vendor_boot, dtbo: match the build"
	rm -f "$ST"/c-*.img
else
	echo "WARNING: no DUMP (ROM images of the build): byte-identical self-check skipped"
fi
for D in ${CHECK_DUMPS:-}; do
	echo "== check: images from $D"
	"$AKH" mkboot "$D/boot.img" "$K/Image" "$ST/x-boot.img" > /dev/null
	"$AKH" mkvendor "$D/vendor_boot.img" "$K/vendor_boot.dtb" "$K/vendor-cmdline.txt" "$K/vendor-ramdisk-a52.cpio.lz4" "$ST/x-vendor_boot.img" > /dev/null
	"$AKH" mkdtbo "$D/dtbo.img" "$K/dtbo.raw" "$ST/x-dtbo.img" > /dev/null
	"$AKH" origin "$ST/x-boot.img" "$ST/x-vendor_boot.img" "$D/boot.img" "$D/vendor_boot.img" | sed 's/^/  /'
	for i in boot vendor_boot dtbo; do avbtool info_image --image "$ST/x-$i.img" > /dev/null || die "avbtool cannot read $i from $D"; done
	rm -f "$ST"/x-*.img
done

ICE_RAW=0; [ -f "$SRC/BUILDINFO" ] && grep -q ' ice_raw=1' "$SRC/BUILDINFO" && ICE_RAW=1
# ---------------------------------------------------------------- staging
stage_meta() { # <dir> <mode> <title> <need tmp kb>
	local d=$1
	mkdir -p "$d/META-INF/com/google/android" "$d/META-INF/com/android" "$d/bin"
	install -m 0755 "$HERE/update-binary" "$d/META-INF/com/google/android/update-binary"
	install -m 0644 "$HERE/updater-script" "$d/META-INF/com/google/android/updater-script"
	printf 'ota-type=BLOCK\npre-device=a52sxq\n' > "$d/META-INF/com/android/metadata"
	install -m 0644 "$AKA" "$d/bin/a52boot"
	sed -e "s/@NAME@/$NAME/g" -e "s/@KREL@/$KREL/g" "$HERE/README-AK.txt" > "$d/README-TWRP.txt"
	{
		echo "MODE=$2"
		echo "TITLE=$3"
		echo "KREL=$KREL"
		echo "ADDON=$ADDON"
		echo "NEED_TMP_KB=$4"
		# ICE_RAW=1 builds (ICE legacy mode, standard keys only): the installer refuses ROMs with wrappedkey in fstab
		echo "ICE_RAW=$ICE_RAW"
		# no ROM keys: a kernel-only zip (ADDON=none) installs over any ROM, an add-on zip over LineageOS 24 based
		# ROMs only. ALLOW_ONEUI9 / ALLOW_ICHTHYS of older zips are still accepted by update-binary and ignored.
	} > "$d/a52s-k612.conf"
}
sums() { # <dir>: SHA256SUMS of the payload (everything but META-INF)
	(cd "$1" && find . -type f ! -path './META-INF/*' ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort |
		xargs sha256sum) > "$1.sums"
	mv "$1.sums" "$1/SHA256SUMS"
}
# the phone side keeps the current images (old/) and the new ones (new/) in /tmp, plus packed backups
PARTS_KB=$(( (100663296 + 100663296 + 25165824) / 1024 ))

Z1=$ST/z1
if [ "$ADDON" = vendor ]; then
	mkdir -p "$Z1/vendor-addon"
	cp -r "$ADDON_DIR/." "$Z1/vendor-addon/"
	find "$Z1/vendor-addon" -type d -exec chmod 0755 {} +
	find "$Z1/vendor-addon" -type f -exec chmod 0644 {} +
	[ -z "$(find "$Z1/vendor-addon" ! -type f ! -type d)" ] || die "vendor-addon has non-regular files"
	find "$Z1/vendor-addon" -type f -regextype posix-extended -regex '.*\.(mdt|mbn|b[0-9][0-9])$' | grep -q . && die "firmware image in the add-on"
fi
chmod 0644 "$K"/*
kb=$(du -sk --apparent-size "$Z1" | cut -f1)
if [ "$ADDON" = none ]; then DEF_TITLE="Linux 6.12 kernel $NAME ($KREL) for the Galaxy A52s 5G, any ROM"
else DEF_TITLE="Linux 6.12 kernel $NAME ($KREL) for the Galaxy A52s 5G, LineageOS 24 based ROMs (with /vendor add-on)"; fi
stage_meta "$Z1" ak "${TITLE:-$DEF_TITLE}" $((kb * 2 + PARTS_KB * 2 + 80000 + 16384))
sums "$Z1"

Z2=$ST/z2
stage_meta "$Z2" akrestore "restore the ROM's own boot/vendor_boot/dtbo from the 6.12 install's backup" $((PARTS_KB * 2 + 16384))
sums "$Z2"

echo "== privacy check"
leak="(/home/|/root/|/Users/|R5C[A-Z0-9]{8}|RFCT[A-Z0-9]{7}|HQ62[A-Z0-9]{6}|192\\.168\\.${LEAK_EXTRA:+|$LEAK_EXTRA})"
for d in "$Z1" "$Z2"; do
	hits=$(find "$d" -type f ! -name '*.ko' ! -name Image ! -name a52boot -print0 | xargs -0 grep -EIn "$leak" |
		grep -v 'https://github.com/a52sxq-kernel/galaxy-a52s-kernel' || true)
	[ -z "$hits" ] || die "personal data in the zip text files:\n$hits"
done
grep -aq '/home/' "$Z1/bin/a52boot" && die "a52boot binary has a /home path"
find "$Z1" -type f \( -name Image -o -name '*.ko' \) -print0 | xargs -0 grep -lc '/home/' > /dev/null 2>&1 &&
	echo "NOTE: build paths (/home/...) inside kernel/module binaries (payload, unchanged)"

echo "== zipping"
ZK=a52s-k612-$NAME-twrp.zip
ZS=a52s-k612-restore-twrp.zip
python3 -I "$HERE/detzip.py" "$OUT/$ZK" "$Z1"
python3 -I "$HERE/detzip.py" "$OUT/$ZS" "$Z2"
cp "$Z1/README-TWRP.txt" "$OUT/README-TWRP.txt"
chmod 0644 "$OUT/$ZK" "$OUT/$ZS" "$OUT/README-TWRP.txt"
(cd "$OUT" && sha256sum "$ZK" "$ZS" README-TWRP.txt > SHA256SUMS)
for z in "$ZK" "$ZS"; do unzip -tq "$OUT/$z" > /dev/null || die "$z: unzip -t failed"; done
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
