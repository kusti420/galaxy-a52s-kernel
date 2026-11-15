#!/bin/bash
# Emits the Android TEST RAMDISK for kexec (kexec/kx-cycle.sh takes Image, ramdisk, dtb, cmdline):
#   ./pack-kexec-rd.sh <name>   -> out/<name>-rd.cpio.gz   (+ out/<name>-cmdline.txt)
# = one gzip stream of three cpio archives, unpacked in order by the kernel:
#   1. the ROM's boot.img ramdisk (first-stage init, device nodes), untouched
#   2. bsp612's bring-up ramdisk (busybox, telnetd, unudhcpd, rb, the 6.12 first-stage modules
#      + load.list, hhwdt.ko)
#   3. our overlay: /init = a52init, /init.android = ROM init, /a52/{helper.sh,helper2.sh,leave,
#      a52bind,bind/fstab.qcom,mods/}, /lib/modules/{testguard,zram,zsmalloc}.ko + a tiny
#      modules.load/.dep for the ROM init (the helper has loaded everything before it starts),
#      first-stage fstab (logical partitions only), /force_debuggable + /adb_debug.prop.
# Env: DUMP=<dir> (default ../../testdev-PHONE2), STAGES="name:dir ..." extra module stages:
#   BINDS="file:/target ..." extra bind shims (e.g. shims/netd.rc:/system/etc/init/netd.rc);
#   every <dir>/*.ko is packed as /a52/mods/<name>/ with <dir>/load.list (or the sorted file
#   names) as /a52/mods/<name>.list; load them with a52.mods=<name>,... on the command line.
# Reuses the fstab generation of pack-android-612.sh (out/los1/fstab.first, fstab.second): run
# that script once for the ROM dump if out/los1 is missing. Packs only; nothing is flashed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); BSP=$TOP/bsp612
NAME="${1:?name}"; DUMP=$(cd "${DUMP:-$TOP/testdev-PHONE2}" && pwd)
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
DIST=$BSP/out/dist; KREL=$(ls "$DIST/lib/modules" | head -1); MODS=$DIST/lib/modules/$KREL
SRC=$HERE/out/los1          # fstabs + unpacked ROM ramdisk from pack-android-612.sh
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ -f "$SRC/fstab.first" ] && [ -f "$SRC/fstab.second" ] && [ -f "$SRC/boot/ramdisk" ] && [ -f "$SRC/boot/x/init" ] || fail "run ./pack-android-612.sh los1 first"
grep -q 'by-name/userdata' "$SRC/fstab.second" && fail "test fstab names userdata"
grep -E 'formattable' "$SRC/fstab.second" | grep -v zram && fail "a real partition is formattable"
grep -Ev 'logical' "$SRC/fstab.first" | grep -q . && fail "first-stage fstab has a non-logical entry"
W=$HERE/out/kx-$NAME; rm -rf "$W"; mkdir -p "$W/ov/a52/bind" "$W/ov/a52/mods" "$W/ov/lib/modules" "$W/ov/first_stage_ramdisk"
CC="$CLANG/clang --target=aarch64-linux-gnu -Os -Wall -Werror -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fuse-ld=lld -Wl,--build-id=none"
$CC -o "$W/ov/init" "$HERE/a52init/a52init.c"
$CC -o "$W/ov/a52/a52bind" "$HERE/a52init/a52bind.c"
cp "$SRC/boot/x/init" "$W/ov/init.android"
cp "$HERE/kexec-rd/helper.sh" "$HERE/kexec-rd/helper2.sh" "$HERE/kexec-rd/leave" "$W/ov/a52/"
chmod 755 "$W/ov/init" "$W/ov/init.android" "$W/ov/a52/"*
cp "$SRC/fstab.second" "$W/ov/a52/bind/fstab.qcom"
cp "$SRC/fstab.first" "$W/ov/first_stage_ramdisk/fstab.qcom"; cp "$SRC/fstab.first" "$W/ov/fstab.qcom"
: > "$W/ov/force_debuggable"; cp "$HERE/adb_debug.prop" "$W/ov/adb_debug.prop"
# BINDS="file:/target ...": more RAM-only shims bound over files of the mounted ROM (fstab is fixed)
: > "$W/ov/a52/bind/binds.txt"
# HARD RULE (2026-11-13 incident): never carry signed firmware (remoteproc/PIL/zap images) into a
# test run. Loading phone 1's rollback-5 wpss on bit-2 phone 2 fused its firmware counter to 5.
# Test runs use only the firmware already on the phone's own partitions.
for b in ${BINDS:-}; do case "${b%%:*}${b#*:}" in *.mdt*|*.mbn*|*.b[0-9][0-9]*|*firmware*)
	fail "BINDS entry '$b' looks like firmware: refused (only the phone's own firmware may be loaded)";; esac; done
for st in ${STAGES:-}; do d=${st#*:}; [ -d "$d" ] || continue
	ls "$d" | grep -qE '\.(mdt|mbn|b[0-9][0-9])$' && fail "stage dir $d contains firmware images: refused"; done
for b in ${BINDS:-}; do cp "${b%%:*}" "$W/ov/a52/bind/"; echo "$(basename "${b%%:*}") ${b#*:}" >> "$W/ov/a52/bind/binds.txt"; done
LM=$W/ov/lib/modules
cp "$HERE/testguard/testguard.ko" "$LM/"; "$CLANG/llvm-strip" --strip-debug "$LM/testguard.ko"
cp "$MODS/kernel/mm/zsmalloc.ko" "$MODS/kernel/drivers/block/zram/zram.ko" "$LM/"   # GKI: keep signatures
printf 'testguard.ko\nzram.ko\n' > "$LM/modules.load"; cp "$LM/modules.load" "$LM/modules.load.recovery"
printf 'testguard.ko:\nzsmalloc.ko:\nzram.ko: zsmalloc.ko\n' > "$LM/modules.dep"
echo "options zram num_devices=3" > "$LM/modules.options"
for st in ${STAGES:-}; do
  n=${st%%:*}; d=${st#*:}; mkdir -p "$W/ov/a52/mods/$n"
  cp "$d"/*.ko "$W/ov/a52/mods/$n/"
  if [ -f "$d/load.list" ]; then cp "$d/load.list" "$W/ov/a52/mods/$n.list"; else ( cd "$d" && ls *.ko ) > "$W/ov/a52/mods/$n.list"; fi
  # optional shell script run by the helper right before the stage's modules (stage@adsp only)
  [ -f "$d/pre.sh" ] && cp "$d/pre.sh" "$W/ov/a52/mods/$n.pre"
  # optional script run in the background right after the stage's modules (non-@adsp stages),
  # plus its data files (<dir>/*.conf -> /a52/mods/<name>/)
  [ -f "$d/post.sh" ] && cp "$d/post.sh" "$W/ov/a52/mods/$n.post"
  for c in "$d"/*.conf; do [ -f "$c" ] && cp "$c" "$W/ov/a52/mods/$n/"; done
  for k in "$W/ov/a52/mods/$n"/*.ko; do "$CLANG/llvm-strip" --strip-debug "$k" 2>/dev/null || true; done
done
for k in $(find "$W/ov" -name '*.ko'); do strings "$k" | grep -q "^vermagic=$KREL " || fail "wrong vermagic: $k"; done
decomp() { case "$(file -b "$1")" in LZ4*) lz4 -dc "$1";; gzip*) gzip -dc "$1";; *) fail "unknown compression: $1";; esac; }
{ decomp "$SRC/boot/ramdisk"; zcat "$BSP/out/bringup/ramdisk-612.cpio.gz"; ( cd "$W/ov" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ); } | gzip -6 > "$HERE/out/$NAME-rd.cpio.gz"
ls -la "$HERE/out/$NAME-rd.cpio.gz"
