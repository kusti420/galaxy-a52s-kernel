#!/bin/sh
# Regenerates orig/ and src/ from the phone's 5.4 fingerprint driver (read-only source) and
# builds the modules against the 6.12 BSP. Every change to the Samsung code is in
# patches/*.patch (applied in order), so the port can be redone from the 5.4 tree at any time.
#   ./port.sh            copy + patch + ./build.sh + stage/
#   ./port.sh nobuild    copy + patch only
#   SRC=<dir> ./port.sh  another copy of drivers/fingerprint (default: the phone's kernel)
# After editing src/ by hand, regenerate the patch with ./mkpatch.sh before running this again
# (this script overwrites the source files in src/).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HOME/git/android/kernel/samsung/sm7325/drivers/fingerprint}
# the sources the a52sxq config builds (Makefile: fingerprint_sysfs.o + fingerprint-y with
# SENSORS_FINGERPRINT, SENSORS_FINGERPRINT_QCOM, SENSORS_ET7XX); Kconfig/Makefile for reference
FILES="fingerprint.h fingerprint_common.c fingerprint_common.h fingerprint_common_qcom.c
fingerprint_sysfs.c fingerprint_sysfs.h et7xx.h et7xx-spi.c et7xx-spi_data_transfer.c"
mkdir -p "$HERE/orig" "$HERE/src"
for f in $FILES Kconfig Makefile; do cp "$SRC/$f" "$HERE/orig/$f"; chmod 644 "$HERE/orig/$f"; done
for f in $FILES; do cp "$HERE/orig/$f" "$HERE/src/$f"; done
for p in "$HERE"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -s -p1 -d "$HERE/src" --no-backup-if-mismatch < "$p"
done
cp "$HERE/Kbuild" "$HERE/src/Kbuild"
[ "$1" = nobuild ] && exit 0
"$HERE/build.sh"
# module stage for drivers612/androidboot/pack-kexec-rd.sh (STAGES="fingerprint:<this dir>/stage")
mkdir -p "$HERE/stage"
cp "$HERE/src/fingerprint_sysfs.ko" "$HERE/stage/00-fingerprint_sysfs.ko"
cp "$HERE/src/fingerprint.ko" "$HERE/stage/01-fingerprint.ko"
printf '00-fingerprint_sysfs.ko\n01-fingerprint.ko\n' > "$HERE/stage/load.list"
echo "stage/: $(ls "$HERE/stage" | tr '\n' ' ')"
# test pack for the busybox ramdisk (KX_PACK): modules (debug info stripped), esfptest, fp-test.sh
make -s -C "$HERE/esfptest"
mkdir -p "$HERE/pack"
cp "$HERE"/stage/*.ko "$HERE/esfptest/build/esfptest" "$HERE/fp-test.sh" "$HERE/pack/"
$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-strip --strip-debug "$HERE"/pack/*.ko
tar czf "$HERE/pack-fingerprint.tgz" -C "$HERE/pack" .
echo "pack-fingerprint.tgz: $(tar tzf "$HERE/pack-fingerprint.tgz" | tr '\n' ' ')"
