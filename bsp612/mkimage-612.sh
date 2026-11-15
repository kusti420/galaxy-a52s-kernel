#!/bin/sh
# Packs the Qualcomm 6.12 BSP bring-up as a recovery-format test image. PACKS ONLY, flashes
# nothing (test flashes are done by the main session with ../test-cycle.sh, test phones only).
# Usage: bsp612/mkimage-612.sh <name>   -> images/a52sxq-bsp612-<name>-recovery.img
#   NET=43      ramdisk network 172.16.43.1 (second test phone); default 42
#   CMDLINE=... replace the whole command line
#   EXTRA_CMDLINE=...  append (e.g. "a52.skip=sched-walt" or "a52.nomods=1")
# Modelled on ../mkimage-ack.sh (same header v2 arguments, same AVB footer); the checks follow
# research/bootloader-acceptance.md. Inputs: out/dist/Image (pure GKI 6.12.81),
# out/dist/dtb/yupik.dtb (the ONLY dtb in the image), dts/a52sxq-bringup-overlay.dts (the ONE
# recovery dtbo entry), mkramdisk-612.sh.
set -e
cd "$(dirname "$0")"
NAME="${1:?name}"
TOP=..
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
AVBTOOL=${ANDROID_TREE:-$HOME/android}/external/avb/avbtool.py
AVB_KEY="${AVB_KEY:-$HOME/.android-certs/avb.pem}"
# clk_ignore_unused pd_ignore_unused: the bootloader's display keeps running, nothing owns it.
# printk.devkmsg=on: the ramdisk logs every insmod through /dev/kmsg; the default ratelimit
# would drop most of those lines (they are what the crash guard and the PC read).
# The ABL replaces console= with ttynull; GKI has no VT/fbcon anyway, the log goes to ramoops.
CMDLINE="${CMDLINE:-loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused a52.deadman=300 a52.net=${NET:-42}${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}}"
OUT=out/bringup
KERNEL=out/dist/Image
DTB=out/dist/dtb/yupik.dtb
DTS=dts/a52sxq-bringup-overlay.dts
DTBO=$OUT/a52sxq-bringup.dtbo
RAMDISK="${RAMDISK:-$OUT/ramdisk-612.cpio.gz}"
IMG="$TOP/images/a52sxq-bsp612-$NAME-recovery.img"
mkdir -p $OUT
[ -n "$SKIP_RAMDISK" ] || ./mkramdisk-612.sh >/dev/null
dtc -q -@ -I dts -O dtb -o $DTBO $DTS
python3 "$MKDTBOIMG" create $OUT/recovery_dtbo.img --page_size=4096 $DTBO >/dev/null
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
# The ABL's libufdt refuses a base dtb without /__symbols__ and an overlay without /__fixups__.
strings "$DTB" | grep -q __symbols__ || fail "dtb has no __symbols__ (build with DTC_FLAGS=-@)"
strings $DTBO | grep -q __fixups__ || fail "overlay has no __fixups__"
for l in soc intc reserved_memory aliases firmware wdog arch_timer qcom_tzlog; do
  fdtget "$DTB" /__symbols__ $l >/dev/null 2>&1 || fail "dtb label '$l' missing"
done
# base ids: the ABL takes the dtb whose msm-id/board-id match (475/515, board 0)
[ "$(fdtget "$DTB" / qcom,msm-id)" = "475 65536 515 65536" ] || fail "base dtb msm-id is not 475/515"
[ "$(fdtget "$DTB" / qcom,board-id)" = "0 0" ] || fail "base dtb board-id is not <0 0>"
[ "$(fdtget $DTBO / qcom,board-id)" = "34 2" ] || fail "overlay board-id is not <0x22 2>"
fdtoverlay -i "$DTB" -o $OUT/merged.dtb $DTBO || fail "fdtoverlay cannot apply the overlay"
[ "$(stat -c %s $OUT/merged.dtb)" -lt 2097152 ] || fail "merged dtb is 2 MB or more"
# targets of the hypervisor's own overlay
fdtget $OUT/merged.dtb /soc/qcom,wdt@17c10000 compatible >/dev/null 2>&1 || fail "/soc/qcom,wdt@17c10000 missing"
fdtget $OUT/merged.dtb /soc/timer compatible >/dev/null 2>&1 || fail "/soc/timer missing"
# Samsung memory map
[ "$(fdtget -t x $OUT/merged.dtb /reserved-memory/kaslr_region@a0001000 reg)" = "0 a0001000 0 1000" ] || fail "kaslr@a0001000 reservation missing"
[ "$(fdtget -t x $OUT/merged.dtb /reserved-memory/adsp@86700000 reg)" = "0 84700000 0 4800000" ] || fail "ADSP region is not Samsung's"
[ "$(fdtget -t x $OUT/merged.dtb /reserved-memory/ramoops@f0b00000 reg)" = "0 f0b00000 0 e0000" ] || fail "ramoops@f0b00000 missing or not the harness layout"
[ "$(fdtget $OUT/merged.dtb /soc/pinctrl@f000000 qcom,gpios-reserved)" = "32 33 48 49 50 51 56 57 58 59" ] || fail "secure gpios 56..59 not reserved"
grep -q '^CONFIG_RELOCATABLE=y' out/dist/gki.config || fail "CONFIG_RELOCATABLE is off"
[ "$(od -An -tx4 -j56 -N4 $KERNEL | tr -d ' ')" = "644d5241" ] || fail "kernel has no ARMd magic"
# image_size (arm64 Image header, offset 16, little endian) + ramdisk must fit the load region.
ISZ=$(od -An -tu8 -j16 -N8 $KERNEL | tr -d ' ')
RSZ=$(stat -c %s "$RAMDISK")
TOT=$((ISZ + RSZ))
[ "$TOT" -le $((81 * 1048576)) ] || fail "kernel image_size + ramdisk = $TOT bytes, over 81 MiB"
mkdir -p $TOP/images
mkbootimg --header_version 2 --kernel $KERNEL --ramdisk "$RAMDISK" \
  --dtb "$DTB" --recovery_dtbo $OUT/recovery_dtbo.img \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 --pagesize 4096 --os_version 17.0.0 --os_patch_level 2026-06 \
  --cmdline "$CMDLINE" -o "$IMG"
RAW=$(stat -c %s "$IMG")
python3 "$AVBTOOL" add_hash_footer --image "$IMG" --partition_name recovery --partition_size 81788928 \
  --algorithm SHA256_RSA4096 --key "$AVB_KEY" --rollback_index 1780617600
[ "$(stat -c %s "$IMG")" -eq 81788928 ] || fail "image is not exactly the recovery partition size"
echo "checks passed: image_size=$ISZ ramdisk=$RSZ total=$TOT (limit $((81 * 1048576))); boot image before footer $RAW of 81788928"
echo "cmdline: $CMDLINE"
ls -la "$IMG"; sha256sum "$IMG" | cut -c1-16
