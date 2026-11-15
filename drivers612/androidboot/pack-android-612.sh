#!/bin/bash
# Packs an ANDROID test image for the A52s on the Qualcomm 6.12 GKI kernel: the installed ROM's
# own first-stage init + the 6.12 modules, in RECOVERY-partition format (boot header v2, as
# bsp612/mkimage-612.sh). PACKS ONLY: writes under drivers612/androidboot/, flashes nothing.
#
#   ./pack-android-612.sh <name>       -> images/a52sxq-android612-<name>-recovery.img
# Environment:
#   DUMP=<dir>      partition dumps of the phone whose ROM is booted (boot.img, vendor_boot.img);
#                   default ../../testdev-PHONE2 (LineageOS userdebug, test phone 2)
#   MODSET=first    (default) the bring-up first-stage set of bsp612 (out/bringup/load.paths)
#   MODSET=all      every module of bsp612/out/dist, first-stage set first, rest in dependency
#                   order, minus BLOCK
#   EXTRA_MODULES="a.ko b.ko"   more modules (other drivers612 agents), appended to modules.load
#   DATA=zram|tmpfs /data on zram1+ext4 (default) or tmpfs (pure GKI has no TMPFS_XATTR/ACL)
#   DEADMAN=600     seconds until the helper restarts into Download mode by itself, unless
#                   /dev/.a52test/keep exists (adb shell touch /dev/.a52test/keep)
#   FNB=1           add androidboot.force_normal_boot=1 (not needed: see README "normal boot")
#   EXTRA_CMDLINE=  appended to the kernel command line
#   BIND="file:/target ..."     more RAM-only bind shims over files of the mounted ROM
# Layout of the ramdisk = <ROM boot.img ramdisk, untouched> + <overlay cpio> (the kernel unpacks
# concatenated archives in order, later files replace earlier ones; this is how vendor_boot and
# boot ramdisks are combined on a normal boot, and it keeps the device nodes of the ROM ramdisk
# that a non-root repack would lose).
set -eu   # no pipefail: "x | grep -q" ends x with SIGPIPE
HERE=$(cd "$(dirname "$0")" && pwd)
# MODE=kexec-rd (2026-11-12, the way tests are run now): emit only the RAMDISK for
# kexec/kx-cycle.sh and stop (no boot image, no AVB footer): see pack-kexec-rd.sh. It reuses the
# fstabs and the unpacked ROM ramdisk this script leaves in out/los1.
if [ "${MODE:-}" = kexec-rd ]; then exec "$HERE/pack-kexec-rd.sh" "$@"; fi
TOP=$(cd "$HERE/../.." && pwd)
BSP=$TOP/bsp612
NAME="${1:?name}"
DUMP=$(cd "${DUMP:-$TOP/testdev-PHONE2}" && pwd)
MODSET="${MODSET:-first}"
DATA="${DATA:-zram}"
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
AVBTOOL=${ANDROID_TREE:-$HOME/android}/external/avb/avbtool.py
AVB_KEY="${AVB_KEY:-$HOME/.android-certs/avb.pem}"
DIST=$BSP/out/dist
KREL=$(ls "$DIST/lib/modules" | head -1)
MODS=$DIST/lib/modules/$KREL
KERNEL=$DIST/Image
DTB=$DIST/dtb/yupik.dtb
DTS=$BSP/dts/a52sxq-bringup-overlay.dts
W=$HERE/out/$NAME
IMG=$HERE/images/a52sxq-android612-$NAME-recovery.img
# never shipped: see bsp612/BRINGUP.md and the redwood lessons
BLOCK="qcom_edac qcom-dload-mode gh_virt_wdt qcom_wdt_core tz_log_dlkm sdhci-msm cqhci phy-msm-ssusb-qmp msm_sharedmem"
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
rm -rf "$W"; mkdir -p "$W"/{boot,vboot,ov,dep} "$HERE/images"

# ---- 1. the ROM's ramdisks
unpack_bootimg --boot_img "$DUMP/boot.img" --out "$W/boot" --format info > "$W/boot.info"
unpack_bootimg --boot_img "$DUMP/vendor_boot.img" --out "$W/vboot" --format info > "$W/vboot.info"
OSV=$(sed -n 's/^os version: //p' "$W/boot.info"); OSP=$(sed -n 's/^os patch level: //p' "$W/boot.info")
decomp() { case "$(file -b "$1")" in LZ4*) lz4 -dc "$1";; gzip*) gzip -dc "$1";; *) fail "unknown ramdisk compression: $1";; esac; }
mkdir -p "$W/boot/x" "$W/vboot/x"
( cd "$W/boot/x" && decomp ../ramdisk | cpio -id --quiet init 2>/dev/null ) || true
[ -f "$W/boot/x/init" ] && [ ! -L "$W/boot/x/init" ] || fail "no first-stage /init binary in $DUMP/boot.img ramdisk"
file -b "$W/boot/x/init" | grep -q "ARM aarch64.*statically linked" || fail "boot ramdisk /init is not a static arm64 binary"
decomp "$W/boot/ramdisk" | cpio -t --quiet 2>/dev/null | grep -qx "system/bin/recovery" && fail "boot ramdisk has /system/bin/recovery (recovery-as-boot): use FNB=1 and check README"
decomp "$W/boot/ramdisk" | cpio -t --quiet 2>/dev/null | grep -qx "dev/kmsg" || echo "WARNING: boot ramdisk has no /dev/kmsg node: the helper cannot log"
( cd "$W/vboot/x" && decomp ../vendor_ramdisk | cpio -id --quiet 2>/dev/null ) || true
FSTAB_SRC=$(find "$W/vboot/x" -name 'fstab.*' | head -1)
[ -n "$FSTAB_SRC" ] || fail "no fstab in the vendor ramdisk"
FSTAB_NAME=$(basename "$FSTAB_SRC")
HW=$(sed -n 's/.*androidboot.hardware=\([^ ]*\).*/\1/p' "$W/vboot.info" | head -1)
[ "fstab.$HW" = "$FSTAB_NAME" ] || fail "vendor cmdline androidboot.hardware=$HW does not match $FSTAB_NAME"

# ---- 2. fstabs for the test mode (derived from the ROM's own)
# first stage: only the logical partitions of super, read-only, as the ROM mounts them.
# NOT here: metadata (the ROM's entry is 'formattable': a mount failure on the new kernel
# would reformat the partition that holds the userdata key) and misc.
awk '$0 ~ /^#/ || NF < 5 { next } $5 ~ /first_stage_mount/ && $5 ~ /logical/ { print }' "$FSTAB_SRC" > "$W/fstab.first"
grep -q '^system' "$W/fstab.first" || fail "no logical system entry in the ROM fstab"
grep -Eq 'avb|slotselect' "$W/fstab.first" && fail "ROM fstab uses avb/slotselect: this script assumes neither (LineageOS non-A/B)"
# second stage (bound over /vendor/etc/$FSTAB_NAME): userdata and metadata replaced by
# throwaway RAM disks, every other writable partition read-only without journal replay.
{
  echo "# A52s 6.12 TEST fstab (generated by pack-android-612.sh from the ROM's $FSTAB_NAME). RAM only."
  awk -v data="$DATA" '
    /^#/ || NF < 5 { next }
    $2 == "/data" {
      if (data == "tmpfs") print "tmpfs /data tmpfs nosuid,nodev,noatime,mode=0771,uid=1000,gid=1000,size=3g latemount";
      else print "/dev/block/zram1 /data ext4 noatime,nosuid,nodev,discard latemount,wait,formattable";
      next }
    $2 == "/metadata" {
      if (data == "tmpfs") print "tmpfs /metadata tmpfs nosuid,nodev,noatime,mode=0755 defaults";
      else print "/dev/block/zram2 /metadata ext4 noatime,nosuid,nodev,discard wait,formattable";
      next }
    $5 ~ /logical/ { print; next }
    $3 == "ext4" { print $1, $2, "ext4", "ro,noload,noatime,nosuid,nodev", "wait"; next }
    $3 == "f2fs" { next }
    $3 == "vfat" && $4 !~ /(^|,)ro(,|$)/ { $4 = "ro," $4 }
    { print }' "$FSTAB_SRC"
} > "$W/fstab.second"
grep -q 'by-name/userdata' "$W/fstab.second" && fail "test fstab still names userdata"
grep -Eq '(^|[[:space:]])/data[[:space:]]' "$W/fstab.second" || fail "test fstab has no /data"
grep -E 'formattable' "$W/fstab.second" | grep -v zram && fail "a real partition is formattable in the test fstab"
grep -E '[[:space:]]ext4[[:space:]]' "$W/fstab.second" | grep -v zram | grep -v logical | grep -v 'ro,noload' && fail "a real ext4 partition is not ro,noload"

# ---- 3. helper binaries built here
[ "$DATA" = zram ] || echo "NOTE: DATA=tmpfs: a52init still requires zram disks; build it with care (README)"
"$CLANG/clang" --target=aarch64-linux-gnu -Os -Wall -Werror -static -nostdlib -ffreestanding -fno-builtin \
  -fno-stack-protector -fuse-ld=lld -Wl,--build-id=none $([ "$DATA" = zram ] || echo -DNO_ZRAM) -DDEADMAN_S="${DEADMAN:-600}" \
  -o "$W/a52init" "$HERE/a52init/a52init.c"
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" \
  O="$BSP/out/lahaina" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" M="$HERE/testguard" modules > "$W/testguard.log" 2>&1 \
  || { tail -20 "$W/testguard.log"; fail "testguard build"; }

# ---- 4. modules: flat /lib/modules as first-stage init expects (no release sub-directory)
OV=$W/ov; LM=$OV/lib/modules; mkdir -p "$LM"
SECCORE=$TOP/samsung612/modules/sec_core/sec_core.ko
python3 - "$MODS" "$BSP/out/bringup/load.paths" "$MODSET" "$BLOCK" "$W/order.paths" <<'EOF'
import sys, os
mods, first, modset, block, out = sys.argv[1:6]
block = set(block.split())
deps = {}
for l in open(os.path.join(mods, 'modules.dep')):
    k, _, v = l.partition(':'); deps[k.strip()] = v.split()
name = lambda p: os.path.basename(p)[:-3]
def find(p):
    if p in deps: return p
    hits = [k for k in deps if os.path.basename(k) == os.path.basename(p)]
    if len(hits) != 1: sys.exit("module %s: %d matches" % (p, len(hits)))
    return hits[0]
order, seen, skipped = [], set(), []
def visit(p, top):
    p = find(p)
    if p in seen: return True
    if name(p) in block: return False
    for d in deps[p]:
        if not visit(d, False):
            skipped.append("%s (needs blocked %s)" % (name(p), name(d))); return False
    seen.add(p); order.append(p); return True
want = [l.strip() for l in open(first) if l.strip()]
want += ['zram.ko']                      # GKI module: throwaway /data and /metadata, ROM swap
if modset == 'all':
    want += sorted(deps)
for w in want: visit(w, True)
open(out, 'w').write('\n'.join(order) + '\n')
for s in skipped: print("left out:", s)
EOF
: > "$W/modules.load"
echo testguard.ko >> "$W/modules.load"
cp "$HERE/testguard/testguard.ko" "$LM/"
while read -r p; do
  f=$(basename "$p")
  [ -e "$LM/$f" ] && fail "duplicate module file name $f"
  cp "$MODS/$p" "$LM/$f"
  # GKI modules keep their signature (stripping drops it; modules that use protected symbols
  # must be signed); vendor modules are unsigned anyway and are stripped of debug info
  grep -qxF "$f" "$DIST/modules-gki.list" || "$CLANG/llvm-strip" --strip-debug "$LM/$f"
  echo "$f" >> "$W/modules.load"
done < "$W/order.paths"
if [ -f "$SECCORE" ]; then cp "$SECCORE" "$LM/"; "$CLANG/llvm-strip" --strip-debug "$LM/sec_core.ko"; echo sec_core.ko >> "$W/modules.load"
else echo "WARNING: no sec_core.ko: 'reboot download' will be a plain restart (sticky recovery!)"; fi
for m in ${EXTRA_MODULES:-}; do cp "$m" "$LM/"; "$CLANG/llvm-strip" --strip-debug "$LM/$(basename "$m")"; echo "$(basename "$m")" >> "$W/modules.load"; done
"$CLANG/llvm-strip" --strip-debug "$LM/testguard.ko"
for k in "$LM"/*.ko; do strings "$k" | grep -q "^vermagic=$KREL " || fail "wrong vermagic: $k"; done
# modules.dep/alias/softdep for the flat directory, paths relative to /lib/modules
mkdir -p "$W/dep/lib/modules/$KREL"; cp "$LM"/*.ko "$W/dep/lib/modules/$KREL/"
depmod -b "$W/dep" -F "$DIST/System.map" -e "$KREL" 2> "$W/depmod.err" || true
grep -v "^depmod: WARNING: could not open modules\.\(order\|builtin\)" "$W/depmod.err" > "$W/depmod.unresolved" || true
[ -s "$W/depmod.unresolved" ] && { head -20 "$W/depmod.unresolved"; fail "depmod: unresolved symbols or dependency problems (out/$NAME/depmod.unresolved)"; }
for f in modules.dep modules.alias modules.softdep; do cp "$W/dep/lib/modules/$KREL/$f" "$LM/$f"; done
cp "$W/modules.load" "$LM/modules.load"
cp "$W/modules.load" "$LM/modules.load.recovery"   # same set if init ever decides this is recovery
{ for b in $BLOCK; do echo "blocklist $b"; done; } > "$LM/modules.blocklist"
{ echo "options zram num_devices=3"; echo "options sec_core clear_on_load=0"; } > "$LM/modules.options"
while read -r m; do grep -q "^$m:" "$LM/modules.dep" || fail "$m of modules.load is not in modules.dep"; done < "$LM/modules.load"
[ "$(head -1 "$LM/modules.load")" = testguard.ko ] || fail "testguard must load first"

# ---- 5. overlay tree
cp "$W/a52init" "$OV/init"; cp "$W/boot/x/init" "$OV/init.android"; chmod 755 "$OV/init" "$OV/init.android"
mkdir -p "$OV/a52test/proc" "$OV/a52test/sys" "$OV/a52test/bind" "$OV/first_stage_ramdisk"
cp "$W/fstab.first" "$OV/first_stage_ramdisk/$FSTAB_NAME"
cp "$W/fstab.first" "$OV/$FSTAB_NAME"
cp "$W/fstab.second" "$OV/a52test/bind/$FSTAB_NAME"
echo "$FSTAB_NAME /vendor/etc/$FSTAB_NAME" > "$OV/a52test/binds.txt"
for b in ${BIND:-}; do cp "${b%%:*}" "$OV/a52test/bind/$(basename "${b%%:*}")"; echo "$(basename "${b%%:*}") ${b#*:}" >> "$OV/a52test/binds.txt"; done
if [ -n "${FNB:-}" ]; then mkdir -p "$OV/first_stage_ramdisk"/{dev,proc,sys,mnt,metadata,debug_ramdisk,second_stage_resources}; fi
# debug ramdisk mechanism of AOSP (first_stage_init.cpp: /force_debuggable): second-stage init
# loads /debug_ramdisk/adb_debug.prop AFTER every build.prop, on an unlocked bootloader.
: > "$OV/force_debuggable"
cp "$HERE/adb_debug.prop" "$OV/adb_debug.prop"
( cd "$OV" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) | lz4 -l -12 --favor-decSpeed -q > "$W/overlay.cpio.lz4"
cat "$W/boot/ramdisk" "$W/overlay.cpio.lz4" > "$W/ramdisk.img"

# ---- 6. command line. The Samsung ABL appends its own androidboot.* (verifiedbootstate=orange,
# bootdevice, boot_devices=soc/1d84000.ufshc, fstab_suffix=default, serialno, boot_recovery=1,
# ...) and replaces console=. Ours (+ Qualcomm's yupik DT bootargs that kexec_file_load drops:
# android_arch_task_struct_size=512 is REQUIRED, WALT keeps per-task data past task_struct and
# corrupted every task without it once cpufreq started it, bsp612/CPUFREQ-ANALYSIS.md):
CMDLINE="androidboot.hardware=$HW androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 \
androidboot.selinux=permissive androidboot.first_stage_console=1 \
androidboot.init_fatal_reboot_target=download firmware_class.path=/vendor/firmware_mnt/image \
loop.max_part=7 printk.devkmsg=on loglevel=7 clk_ignore_unused pd_ignore_unused \
regulator_ignore_unused a52.androidtest=1 \
android_arch_task_struct_size=512 rcupdate.rcu_expedited=1 rcu_nocbs=0-7 kpti=0 arm64.nosme sysctl.kernel.sched_pelt_multiplier=4 no-steal-acc irqaffinity=0-1 kasan=off cgroup_disable=pressure restrict_cma_redirect=false${FNB:+ androidboot.force_normal_boot=1}${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}"

# ---- 7. dtb, overlay, checks (as bsp612/mkimage-612.sh)
DTBO=$W/a52sxq-bringup.dtbo
dtc -q -@ -I dts -O dtb -o "$DTBO" "$DTS"
python3 "$MKDTBOIMG" create "$W/recovery_dtbo.img" --page_size=4096 "$DTBO" >/dev/null
strings "$DTB" | grep -q __symbols__ || fail "dtb has no __symbols__"
strings "$DTBO" | grep -q __fixups__ || fail "overlay has no __fixups__"
fdtoverlay -i "$DTB" -o "$W/merged.dtb" "$DTBO" || fail "fdtoverlay cannot apply the overlay"
[ "$(stat -c %s "$W/merged.dtb")" -lt 2097152 ] || fail "merged dtb is 2 MB or more"
fdtget "$W/merged.dtb" /soc/qcom,wdt@17c10000 compatible >/dev/null 2>&1 || fail "/soc/qcom,wdt@17c10000 missing"
fdtget "$W/merged.dtb" /soc/timer compatible >/dev/null 2>&1 || fail "/soc/timer missing"
[ "$(od -An -tx4 -j56 -N4 "$KERNEL" | tr -d ' ')" = "644d5241" ] || fail "kernel has no ARMd magic"
ISZ=$(od -An -tu8 -j16 -N8 "$KERNEL" | tr -d ' '); RSZ=$(stat -c %s "$W/ramdisk.img"); TOT=$((ISZ + RSZ))
[ "$TOT" -le $((81 * 1048576)) ] || fail "kernel image_size + ramdisk = $TOT bytes, over 81 MiB"
[ ${#CMDLINE} -lt 1536 ] || fail "command line too long for header v2 (cmdline + extra_cmdline)"
mkbootimg --header_version 2 --kernel "$KERNEL" --ramdisk "$W/ramdisk.img" \
  --dtb "$DTB" --recovery_dtbo "$W/recovery_dtbo.img" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 --pagesize 4096 --os_version "$OSV" --os_patch_level "$OSP" \
  --cmdline "$CMDLINE" -o "$IMG"
RAW=$(stat -c %s "$IMG")
[ "$RAW" -le $((81788928 - 69632)) ] || fail "image $RAW bytes leaves no room for the AVB footer"
python3 "$AVBTOOL" add_hash_footer --image "$IMG" --partition_name recovery --partition_size 81788928 \
  --algorithm SHA256_RSA4096 --key "$AVB_KEY" --rollback_index 1780617600
[ "$(stat -c %s "$IMG")" -eq 81788928 ] || fail "image is not exactly the recovery partition size"

echo "ROM dump: $DUMP (os $OSV / $OSP, fstab $FSTAB_NAME)"
echo "kernel $KREL; modules in first stage: $(wc -l < "$LM/modules.load") ($(du -sb "$LM" | cut -f1) bytes); ramdisk $RSZ bytes (ROM part $(stat -c %s "$W/boot/ramdisk"))"
echo "image_size+ramdisk=$TOT (limit $((81 * 1048576))); boot image before footer $RAW of 81788928"
echo "cmdline: $CMDLINE"
ls -la "$IMG"; sha256sum "$IMG" | cut -c1-16
echo "NOT FLASHED. Work files: $W"
