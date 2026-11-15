#!/bin/sh
# Regenerates orig/ and src/ from the phone's 5.4 NFC driver (read-only source) and builds the
# module against the 6.12 BSP. Every change to the Samsung code is in patches/*.patch (applied
# in order), so the port can be redone from the 5.4 tree at any time.
#   ./port.sh            copy + patch + ./build.sh + stage/ + pack-nfc.tgz
#   ./port.sh nobuild    copy + patch only
#   SRC=<dir> ./port.sh  another copy of drivers/nfc (default: the phone's kernel)
# After editing src/ by hand, regenerate the patch with ./mkpatch.sh before running this again
# (this script overwrites the source files in src/).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HOME/git/android/kernel/samsung/sm7325/drivers/nfc}
# the sources the a52sxq config builds into nfc_sec.ko (Makefile: CONFIG_SAMSUNG_NFC=m ->
# nfc_sec-$(CONFIG_SEC_NFC) sec_nfc.o, nfc_sec-$(CONFIG_SEC_NFC_LOGGER) nfc_logger/nfc_logger.o)
FILES="sec_nfc.c sec_nfc.h nfc_wakelock.h nfc_logger/nfc_logger.c nfc_logger/nfc_logger.h"
mkdir -p "$HERE/orig/nfc_logger" "$HERE/src/nfc_logger"
for f in $FILES Kconfig Makefile; do cp "$SRC/$f" "$HERE/orig/$f"; chmod 644 "$HERE/orig/$f"; done
for f in $FILES; do cp "$HERE/orig/$f" "$HERE/src/$f"; done
for p in "$HERE"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -s -p1 -d "$HERE/src" --no-backup-if-mismatch < "$p"
done
cp "$HERE/Kbuild" "$HERE/src/Kbuild"
[ "$1" = nobuild ] && exit 0
"$HERE/build.sh"
# module stage for drivers612/androidboot/pack-kexec-rd.sh (STAGES="nfc:<this dir>/stage")
mkdir -p "$HERE/stage"
cp "$HERE/src/nfc_sec.ko" "$HERE/stage/00-nfc_sec.ko"
printf '00-nfc_sec.ko\n' > "$HERE/stage/load.list"
echo "stage/: $(ls "$HERE/stage" | tr '\n' ' ')"
# test pack for the busybox ramdisk (KX_PACK): module (debug info stripped), nfctest, nfc-test.sh
make -s -C "$HERE/nfctest"
mkdir -p "$HERE/pack"
cp "$HERE"/stage/*.ko "$HERE/nfctest/build/nfctest" "$HERE/nfc-test.sh" "$HERE/pack/"
# the SE9 I2C controller for the busybox ramdisk (in Android: androidboot stage "i2c")
L=$(dirname "$HERE")/../bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734
cp "$L/drivers/dma/qcom/msm_gpi.ko" "$HERE/pack/i2c-01-msm_gpi.ko"
cp "$L/drivers/i2c/busses/i2c-msm-geni.ko" "$HERE/pack/i2c-02-i2c-msm-geni.ko"
$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-strip --strip-debug "$HERE"/pack/*.ko
tar czf "$HERE/pack-nfc.tgz" -C "$HERE/pack" .
echo "pack-nfc.tgz: $(tar tzf "$HERE/pack-nfc.tgz" | tr '\n' ' ')"
