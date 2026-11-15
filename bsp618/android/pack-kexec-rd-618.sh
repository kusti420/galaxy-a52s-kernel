#!/bin/bash
# The Android TEST RAMDISK for kexec on the 6.18 kernel: drivers612/androidboot/pack-kexec-rd.sh
# (the working 6.12 recipe, read 2026-11-14) with the 6.18 inputs. That script is not changed or
# called; keep this one in step with it.
#   bsp618/android/pack-kexec-rd-618.sh <name>   -> bsp618/android/out/<name>-rd.cpio.gz
# = one gzip stream of three cpio archives, unpacked in order by the kernel:
#   1. the ROM's boot.img ramdisk (drivers612/androidboot/out/los1/boot/ramdisk), untouched
#   2. bsp618/android/out/bringup/ramdisk-618.cpio.gz (mkramdisk-618.sh: busybox, telnetd,
#      unudhcpd, rb, the 6.18 first-stage modules + load.list, hhwdt.ko, sec_core.ko)
#   3. the overlay, same as 6.12: /init = a52init, /init.android = ROM init, /a52/{helper.sh,
#      helper2.sh,leave,a52bind,bind/fstab.qcom,mods/} (helpers from drivers612/androidboot/
#      kexec-rd, unchanged), /lib/modules/{testguard,zram,zsmalloc}.ko (6.18 builds) + modules.load
#      /.dep for the ROM init, first-stage fstab, /force_debuggable + /adb_debug.prop.
# Stages: every bsp618/android/stage-618/<name>/ is packed as /a52/mods/<name>/ (+ <name>.list,
#   <name>.pre); a52.mods=<name>,... on the command line selects them. STAGES="name:dir ..."
#   replaces the set. BINDS="file:/target ..." as in the 6.12 script; default = the 6.12 runs'
#   drivers612/androidboot/shims/netd.rc:/system/etc/init/netd.rc. LEAVE=<file> packs another
#   /a52/leave (default kexec-rd/leave; a5 = a4's pre-1f273ce copy). /adb_debug.prop = the 6.12
#   one with ro.bpf.kver_override=<this kernel> (BPF_KVER=x.y.z to override).
# Checks (fail = nothing written): vermagic of every .ko = the 6.18 dist release; the insmod
# simulation (check-load.py) of the CHECK_MODS order (default: the 6.12 best run's a52.mods).
# Packs only; nothing is flashed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); B=$(dirname "$HERE"); TOP=$(dirname "$B")
AB=$TOP/drivers612/androidboot
NAME="${1:?name}"
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
DIST=$HERE/out/dist; KREL=$(ls "$DIST/lib/modules" | head -1); MODS=$DIST/lib/modules/$KREL
BRINGUP=$HERE/out/bringup/ramdisk-618.cpio.gz
TESTGUARD=$B/src/drivers612/androidboot/testguard/testguard.ko
SRC=$AB/out/los1          # fstabs + unpacked ROM ramdisk from pack-android-612.sh (read only)
CHECK_MODS=${CHECK_MODS:-debug,secure,display,kgsl,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,audio@adsp,wlan@adsp}
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ -f "$SRC/fstab.first" ] && [ -f "$SRC/fstab.second" ] && [ -f "$SRC/boot/ramdisk" ] && [ -f "$SRC/boot/x/init" ] || fail "drivers612/androidboot/out/los1 missing: run drivers612/androidboot/pack-android-612.sh los1 first"
[ -f "$BRINGUP" ] || fail "run mkramdisk-618.sh first"
[ -f "$TESTGUARD" ] || fail "no 6.18 testguard.ko (bsp618/port/build618.sh)"
case "$KREL" in 6.18.*) ;; *) fail "dist release is $KREL, not 6.18";; esac
grep -q 'by-name/userdata' "$SRC/fstab.second" && fail "test fstab names userdata"
grep -E 'formattable' "$SRC/fstab.second" | grep -v zram && fail "a real partition is formattable"
grep -Ev 'logical' "$SRC/fstab.first" | grep -q . && fail "first-stage fstab has a non-logical entry"
# the netd.rc shim of the 6.12 runs (netd1shot without reboot_on_failure); BINDS= (empty) packs none
BINDS=${BINDS-$AB/shims/netd.rc:/system/etc/init/netd.rc}
if [ -z "${STAGES:-}" ]; then
  for d in "$HERE"/stage-618/*/; do d=${d%/}; STAGES="${STAGES:-} $(basename "$d"):$d"; done
fi
W=$HERE/out/kx-$NAME; rm -rf "$W"; mkdir -p "$W/ov/a52/bind" "$W/ov/a52/mods" "$W/ov/lib/modules" "$W/ov/first_stage_ramdisk"
# a52init/a52bind (static, freestanding, kernel-independent): the 6.12 script's compiler, so the
# binaries are byte-identical to the proven 6.12 ones
CC612=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
CC="$CC612/clang --target=aarch64-linux-gnu -Os -Wall -Werror -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fuse-ld=lld -Wl,--build-id=none"
$CC -o "$W/ov/init" "$AB/a52init/a52init.c"
$CC -o "$W/ov/a52/a52bind" "$AB/a52init/a52bind.c"
cp "$SRC/boot/x/init" "$W/ov/init.android"
cp "$AB/kexec-rd/helper.sh" "$AB/kexec-rd/helper2.sh" "$W/ov/a52/"
cp "${LEAVE:-$AB/kexec-rd/leave}" "$W/ov/a52/leave"
chmod 755 "$W/ov/init" "$W/ov/init.android" "$W/ov/a52/"*
cp "$SRC/fstab.second" "$W/ov/a52/bind/fstab.qcom"
cp "$SRC/fstab.first" "$W/ov/first_stage_ramdisk/fstab.qcom"; cp "$SRC/fstab.first" "$W/ov/fstab.qcom"
: > "$W/ov/force_debuggable"
# adb_debug.prop of the 6.12 test with ro.bpf.kver_override = this kernel (6.12 used 6.12.81: the
# ROM's own 5.10.239 makes netd abort). BPF_KVER=6.12.81 keeps the proven 6.12 value instead.
KVER=${BPF_KVER:-${KREL%%-*}}
grep -q '^ro.bpf.kver_override=' "$AB/adb_debug.prop" || fail "adb_debug.prop has no ro.bpf.kver_override line"
sed "s/^ro.bpf.kver_override=.*/ro.bpf.kver_override=$KVER/" "$AB/adb_debug.prop" > "$W/ov/adb_debug.prop"
: > "$W/ov/a52/bind/binds.txt"
# HARD RULE (2026-11-13 incident): never carry signed firmware into a test run.
for b in ${BINDS:-}; do case "${b%%:*}${b#*:}" in *.mdt*|*.mbn*|*.b[0-9][0-9]*|*firmware*)
	fail "BINDS entry '$b' looks like firmware: refused (only the phone's own firmware may be loaded)";; esac; done
for st in ${STAGES:-}; do d=${st#*:}; [ -d "$d" ] || continue
	ls "$d" | grep -qE '\.(mdt|mbn|b[0-9][0-9])$' && fail "stage dir $d contains firmware images: refused"; done
for b in ${BINDS:-}; do cp "${b%%:*}" "$W/ov/a52/bind/"; echo "$(basename "${b%%:*}") ${b#*:}" >> "$W/ov/a52/bind/binds.txt"; done
LM=$W/ov/lib/modules
cp "$TESTGUARD" "$LM/"; "$CLANG/llvm-strip" --strip-debug "$LM/testguard.ko"
cp "$MODS/kernel/mm/zsmalloc.ko" "$MODS/kernel/drivers/block/zram/zram.ko" "$LM/"   # GKI: keep signatures
printf 'testguard.ko\nzram.ko\n' > "$LM/modules.load"; cp "$LM/modules.load" "$LM/modules.load.recovery"
printf 'testguard.ko:\nzsmalloc.ko:\nzram.ko: zsmalloc.ko\n' > "$LM/modules.dep"
echo "options zram num_devices=3" > "$LM/modules.options"
for st in ${STAGES:-}; do
  n=${st%%:*}; d=${st#*:}; mkdir -p "$W/ov/a52/mods/$n"
  cp "$d"/*.ko "$W/ov/a52/mods/$n/"
  if [ -f "$d/load.list" ]; then cp "$d/load.list" "$W/ov/a52/mods/$n.list"; else ( cd "$d" && ls *.ko ) > "$W/ov/a52/mods/$n.list"; fi
  [ -f "$d/pre.sh" ] && cp "$d/pre.sh" "$W/ov/a52/mods/$n.pre"
  for k in "$W/ov/a52/mods/$n"/*.ko; do "$CLANG/llvm-strip" --strip-debug "$k" 2>/dev/null || true; done
done
for k in $(find "$W/ov" -name '*.ko'); do strings "$k" | grep -q "^vermagic=$KREL " || fail "wrong vermagic: $k"; done
# zram's dependencies on 6.18 must still be only zsmalloc (the ROM init reads the tiny modules.dep)
grep -q "^kernel/drivers/block/zram/zram.ko: kernel/mm/zsmalloc.ko$" "$MODS/modules.dep" || fail "zram.ko dependencies changed on 6.18: $(grep '/zram.ko:' "$MODS/modules.dep")"
# offline insmod simulation of the helper's order (first stage, zram, stages of CHECK_MODS)
RD=$W/rd2; mkdir -p "$RD"; ( cd "$RD" && zcat "$BRINGUP" | cpio -id --quiet 'lib/modules/*' )
CRC=0; python3 -I "$HERE/check-load.py" --krel "$KREL" --symvers "$B/out-survey/gki/Module.symvers" --builtin "$MODS/modules.builtin" \
  --first "$RD/lib/modules" --extra "$LM" --stages "$W/ov/a52/mods" --mods "$CHECK_MODS" > "$W/check-load.txt" || CRC=$?
cat "$W/check-load.txt"
[ $CRC = 0 ] || [ "${CHECK_IGNORE:-0}" = 1 ] || fail "insmod simulation failed ($W/check-load.txt); CHECK_IGNORE=1 packs anyway"
rm -rf "$RD"
decomp() { case "$(file -b "$1")" in LZ4*) lz4 -dc "$1";; gzip*) gzip -dc "$1";; *) fail "unknown compression: $1";; esac; }
{ decomp "$SRC/boot/ramdisk"; zcat "$BRINGUP"; ( cd "$W/ov" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ); } | gzip -6 > "$HERE/out/$NAME-rd.cpio.gz"
# the helper copies /lib + /a52/mods into a 400 MiB tmpfs (kexec-rd/helper.sh)
SZ=$(( $(du -sb "$W/ov/a52/mods" | cut -f1) + $(zcat "$BRINGUP" | wc -c) ))
[ $SZ -lt 360000000 ] || echo "WARNING: modules ~$((SZ / 1048576)) MiB, close to the helper's 400 MiB tmpfs"
ls -la "$HERE/out/$NAME-rd.cpio.gz"
