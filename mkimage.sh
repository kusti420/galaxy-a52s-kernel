#!/bin/sh
# Builds the recovery-format test image.
# Usage: ./mkimage.sh <name>   -> images/a52sxq-mainline-<name>-recovery.img
set -e
cd "$(dirname "$0")"
NAME="${1:?name}"
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
CMDLINE="${CMDLINE:-console=tty0 loglevel=7 clk_ignore_unused pd_ignore_unused pmos.nosplash pmos.debug-shell}"
# Generic build identity: the kernel version string must not carry the builder's login or host.
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
( cd linux && make ARCH=arm64 LLVM=1 O=../out -j20 Image qcom/sm7325-samsung-a52sxq.dtb >/dev/null )
dtc -q -@ -I dts -O dtb -o out/a52sxq-mainline-overlay.dtbo dtbo/a52sxq-mainline-overlay.dts
python3 "$MKDTBOIMG" create out/recovery_dtbo.img --page_size=4096 out/a52sxq-mainline-overlay.dtbo >/dev/null
fdtoverlay -i out/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dtb -o /dev/null out/a52sxq-mainline-overlay.dtbo
mkdir -p images
mkbootimg --header_version 2 --kernel out/arch/arm64/boot/Image \
  --ramdisk "${RAMDISK:-pmos-kodiak/binaries/initramfs.cpio.gz}" \
  --dtb out/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dtb --recovery_dtbo out/recovery_dtbo.img \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 --pagesize 4096 --os_version 17.0.0 --os_patch_level 2026-06 \
  --cmdline "$CMDLINE" -o "images/a52sxq-mainline-$NAME-recovery.img"
# The Samsung bootloader refuses a recovery image without a valid AVB footer ("AVB Fail", back to
# Download mode), even on an unlocked phone. Sign it the way the ROM's recovery is signed
# (.buildlogs/sign_ichthys.sh): same key, algorithm, partition size and rollback index.
AVBTOOL=${ANDROID_TREE:-$HOME/android}/external/avb/avbtool.py
AVB_KEY="${AVB_KEY:-$HOME/.android-certs/avb.pem}"
python3 "$AVBTOOL" add_hash_footer --image "images/a52sxq-mainline-$NAME-recovery.img" \
  --partition_name recovery --partition_size 81788928 \
  --algorithm SHA256_RSA4096 --key "$AVB_KEY" --rollback_index 1780617600
ls -la "images/a52sxq-mainline-$NAME-recovery.img"
