#!/bin/sh
# Packs the ACK 6.18 build (out-ack/) as a recovery-format test image. BUILDS ONLY, flashes
# nothing. Hard rule (2026-11-11): no test image goes on DAILYPHONE or OTHERPHONE; images
# from here are for the separate test device the owner will name.
# Usage: ./mkimage-ack.sh <name>   -> images/a52sxq-ack618-<name>-recovery.img
# Layout and checks follow research/bootloader-acceptance.md.
set -e
cd "$(dirname "$0")"
NAME="${1:?name}"
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
AVBTOOL=${ANDROID_TREE:-$HOME/android}/external/avb/avbtool.py
AVB_KEY="${AVB_KEY:-$HOME/.android-certs/avb.pem}"
# NET=43 builds the image for the second test phone (its ramdisk then uses 172.16.43.1)
CMDLINE="${CMDLINE:-console=tty0 loglevel=7 clk_ignore_unused pd_ignore_unused a52.deadman=300 a52.net=${NET:-42}}"
RAMDISK="${RAMDISK:-out-ack/ramdisk-a52.cpio.gz}"
DTB=out-ack/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dtb
IMG="images/a52sxq-ack618-$NAME-recovery.img"
./build-ack.sh >/dev/null
./mkramdisk.sh >/dev/null
dtc -q -@ -I dts -O dtb -o out-ack/a52sxq-overlay.dtbo dtbo/a52sxq-mainline-overlay.dts
python3 "$MKDTBOIMG" create out-ack/recovery_dtbo.img --page_size=4096 out-ack/a52sxq-overlay.dtbo >/dev/null
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
# The ABL's libufdt refuses a base dtb without /__symbols__ and an overlay without /__fixups__.
strings "$DTB" | grep -q __symbols__ || fail "dtb has no __symbols__ (build with DTC_FLAGS=-@)"
strings out-ack/a52sxq-overlay.dtbo | grep -q __fixups__ || fail "overlay has no __fixups__"
for l in soc intc; do fdtget "$DTB" /__symbols__ $l >/dev/null 2>&1 || fail "dtb label '$l' missing"; done
fdtget "$DTB" /reserved-memory/kaslr@a0001000 reg >/dev/null 2>&1 || fail "kaslr@a0001000 reservation missing"
fdtoverlay -i "$DTB" -o out-ack/merged.dtb out-ack/a52sxq-overlay.dtbo
[ "$(stat -c %s out-ack/merged.dtb)" -lt 2097152 ] || fail "merged dtb is 2 MB or more"
grep -q '^CONFIG_RELOCATABLE=y' out-ack/.config || fail "CONFIG_RELOCATABLE is off"
# image_size (arm64 Image header, offset 16, little endian) + ramdisk must fit the load region.
ISZ=$(od -An -tu8 -j16 -N8 out-ack/arch/arm64/boot/Image | tr -d ' ')
TOT=$((ISZ + $(stat -c %s "$RAMDISK")))
[ "$TOT" -le $((81 * 1048576)) ] || fail "kernel image_size + ramdisk = $TOT bytes, over 81 MiB"
mkdir -p images
mkbootimg --header_version 2 --kernel out-ack/arch/arm64/boot/Image --ramdisk "$RAMDISK" \
  --dtb "$DTB" --recovery_dtbo out-ack/recovery_dtbo.img \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 --pagesize 4096 --os_version 17.0.0 --os_patch_level 2026-06 \
  --cmdline "$CMDLINE" -o "$IMG"
python3 "$AVBTOOL" add_hash_footer --image "$IMG" --partition_name recovery --partition_size 81788928 \
  --algorithm SHA256_RSA4096 --key "$AVB_KEY" --rollback_index 1780617600
echo "checks passed: image_size=$ISZ total=$TOT"
ls -la "$IMG"; sha256sum "$IMG" | cut -c1-16
