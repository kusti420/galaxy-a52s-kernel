#!/bin/bash
# The 6.18 counterpart of drivers612/busdcvs/mkrd.sh + the s76 module set (GPU + bus DCVS), WITHOUT
# repacking anything that ran:
#   bsp618/android/mkrd-dcvs-618.sh [IN=a9] [OUT=a10]
# OUT = IN (bsp618/android/out/<IN>-rd.cpio.gz, byte for byte) + one appended gzip'd newc cpio (the
# kernel unpacks concatenated archives in order, later files replace earlier ones) with:
#   /a52/mods/kgsl/governor_msm_adreno_tz.ko, governor_gpubw_mon.ko   (6.18 builds, stage-618/kgsl2)
#   /a52/mods/kgsl.list         = stage-618/kgsl2/load.list (the governors before msm_kgsl: kgsl
#                                 looks its devfreq governor up once, at probe)
#   /a52/mods/dcvs/bwmon.ko, memlat.ko + /a52/mods/dcvs.list          (6.18 builds, stage-618/dcvs)
#   /a52/helper2.sh             drivers612/androidboot/kexec-rd/helper2.sh (+ the <stage>.post hook)
#   /a52/mods/dcvs.post         drivers612/busdcvs/post.sh
#   /a52/mods/dcvs/busdcvs.conf drivers612/busdcvs/busdcvs.conf
# = the 6.12 ramdisks s76 (kgsl2 + dcvs stages) and s77 (post script) in one step. The other kgsl
# stage files must be byte-identical to IN's (checked), so only the four new modules are new.
# Stage dirs come from `python3 -I bsp618/android/mkstages-618.py` (kgsl2, dcvs = the 6.12
# drivers612/androidboot/out/stage-{kgsl2,dcvs} mapped to their 6.18 builds).
# Kexec test (owner's OK, phone 2): a52.mods=debug,secure,display,kgsl,dcvs,video,i2c,... and the
# tree bsp618/android/out/android-r02-618.dtb (since 2026-11-15 with drivers612/busdcvs/dt-fix.sh).
# Packs only; nothing is run or flashed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); AB=$TOP/drivers612/androidboot; BD=$TOP/drivers612/busdcvs
IN=${1:-a9}; OUT=${2:-a10}
SRC=$HERE/out/$IN-rd.cpio.gz; DST=$HERE/out/$OUT-rd.cpio.gz
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
DIST=$HERE/out/dist; KREL=$(ls "$DIST/lib/modules" | head -1)
ST=$HERE/stage-618
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ -f "$SRC" ] || fail "no $SRC"
[ "$SRC" != "$DST" ] || fail "IN = OUT"
for f in "$ST/kgsl2/load.list" "$ST/dcvs/load.list" "$ST/kgsl2/governor_msm_adreno_tz.ko" "$ST/kgsl2/governor_gpubw_mon.ko" \
	"$ST/dcvs/bwmon.ko" "$ST/dcvs/memlat.ko"; do [ -f "$f" ] || fail "no $f (python3 -I bsp618/android/mkstages-618.py)"; done
W=$HERE/out/work-$OUT; rm -rf "$W"; mkdir -p "$W"
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$SRC" "$W/in" > /dev/null
[ -f "$W/in/a52/mods/kgsl.list" ] && ! [ -e "$W/in/a52/mods/dcvs.list" ] || fail "$IN: expected a kgsl stage and no dcvs stage"
grep -qx 'governor_msm_adreno_tz.ko' "$W/in/a52/mods/kgsl.list" && fail "$IN already has the GPU governors"
[ "$(tr '\n' ' ' < "$ST/kgsl2/load.list")" = "gpucc-sc7280.ko governor_msm_adreno_tz.ko governor_gpubw_mon.ko msm_sysstats.ko msm_performance.ko msm_kgsl.ko " ] \
	|| fail "stage-618/kgsl2/load.list is not the 6.12 kgsl2 order"
[ "$(tr '\n' ' ' < "$ST/dcvs/load.list")" = "bwmon.ko memlat.ko " ] || fail "stage-618/dcvs/load.list is not 'bwmon.ko memlat.ko'"
# the kgsl2 list minus the governors must be IN's kgsl list, and those files IN's bytes
[ "$(grep -v '^governor_' "$ST/kgsl2/load.list" | tr '\n' ' ')" = "$(tr '\n' ' ' < "$W/in/a52/mods/kgsl.list")" ] || fail "kgsl2 order differs from $IN's kgsl beyond the governors"
for k in $(grep -v '^governor_' "$ST/kgsl2/load.list"); do
	cp "$ST/kgsl2/$k" "$W/t.ko"; "$CLANG/llvm-strip" --strip-debug "$W/t.ko"
	cmp -s "$W/t.ko" "$W/in/a52/mods/kgsl/$k" || fail "stage-618/kgsl2/$k is not $IN's tested file (port tree rebuilt since?)"
done
for m in qcom-dcvs qcom-pmu-lib qcom_llcc_pmu qcom_scmi_client sched-walt; do grep -qx "$m.ko" "$W/in/lib/modules/load.list" || fail "$IN first stage lacks $m"; done
diff "$W/in/a52/helper2.sh" "$AB/kexec-rd/helper2.sh" > "$W/helper2.diff" && fail "helper2.sh has no post hook?"
[ "$(grep -c '^[<>]' "$W/helper2.diff")" -le 4 ] && ! grep -q '^<' "$W/helper2.diff" || { cat "$W/helper2.diff"; fail "helper2.sh differs from $IN's beyond the post hook"; }
sh -n "$BD/post.sh" || fail "post.sh syntax"
# the appended archive
X=$W/add; mkdir -p "$X/a52/mods/kgsl" "$X/a52/mods/dcvs"
for k in governor_msm_adreno_tz governor_gpubw_mon; do cp "$ST/kgsl2/$k.ko" "$X/a52/mods/kgsl/"; done
cp "$ST/dcvs/bwmon.ko" "$ST/dcvs/memlat.ko" "$X/a52/mods/dcvs/"
for k in "$X"/a52/mods/*/*.ko; do "$CLANG/llvm-strip" --strip-debug "$k"; strings "$k" | grep -q "^vermagic=$KREL " || fail "wrong vermagic: $k"; done
install -m 644 "$ST/kgsl2/load.list" "$X/a52/mods/kgsl.list"
install -m 644 "$ST/dcvs/load.list" "$X/a52/mods/dcvs.list"
install -m 755 "$AB/kexec-rd/helper2.sh" "$X/a52/helper2.sh"
install -m 755 "$BD/post.sh" "$X/a52/mods/dcvs.post"
install -m 644 "$BD/busdcvs.conf" "$X/a52/mods/dcvs/busdcvs.conf"
chmod 644 "$X"/a52/mods/*/*.ko; chmod 755 "$X/a52" "$X/a52/mods" "$X/a52/mods/kgsl" "$X/a52/mods/dcvs"
find "$X" -exec touch -h -d @0 {} +
( cd "$X" && find a52 | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet ) | gzip -9n > "$W/add.cpio.gz"
# offline insmod simulation of the kexec helper's order with the new stages (first stage, zram,
# then a52.mods; the 6.12 run ab-s76's list on 6.18)
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$W/add.cpio.gz" "$W/addx" > /dev/null
cp -a "$W/in/a52/mods" "$W/mods"; cp -a "$W/addx/a52/mods/." "$W/mods/"
python3 -I "$HERE/check-load.py" --krel "$KREL" --symvers "$TOP/bsp618/out-survey/gki/Module.symvers" \
	--builtin "$DIST/lib/modules/$KREL/modules.builtin" --first "$W/in/lib/modules" --extra "$W/in/lib/modules" --stages "$W/mods" \
	--mods debug,secure,display,kgsl,dcvs,video,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,audio@adsp,wlan@adsp > "$W/check-load.txt" \
	|| { cat "$W/check-load.txt"; fail "insmod simulation"; }
tail -3 "$W/check-load.txt"
cat "$SRC" "$W/add.cpio.gz" > "$DST"
# read back: everything of IN unchanged except helper2.sh and kgsl.list, the new files added
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$DST" "$W/out" > /dev/null
diff -r -q "$W/in" "$W/out" | sed "s#$W/##g" | sort > "$W/readback.diff" || true
printf '%s\n' "Files in/a52/helper2.sh and out/a52/helper2.sh differ" "Files in/a52/mods/kgsl.list and out/a52/mods/kgsl.list differ" \
	"Only in out/a52/mods/kgsl: governor_gpubw_mon.ko" "Only in out/a52/mods/kgsl: governor_msm_adreno_tz.ko" \
	"Only in out/a52/mods: dcvs" "Only in out/a52/mods: dcvs.list" "Only in out/a52/mods: dcvs.post" | sort > "$W/readback.want"
cmp -s "$W/readback.diff" "$W/readback.want" || { diff "$W/readback.want" "$W/readback.diff"; fail "read-back of $OUT differs from $IN beyond the new files"; }
cmp -s "$W/out/a52/mods/kgsl.list" "$ST/kgsl2/load.list" && cmp -s "$W/out/a52/helper2.sh" "$AB/kexec-rd/helper2.sh" && cmp -s "$W/out/a52/mods/dcvs.post" "$BD/post.sh" \
	&& cmp -s "$W/out/a52/mods/dcvs/busdcvs.conf" "$BD/busdcvs.conf" || fail "read-back content"
echo "$DST: $(stat -c %s "$DST") bytes = $IN ($(stat -c %s "$SRC")) + $(stat -c %s "$W/add.cpio.gz") (GPU governors in kgsl, stage dcvs bwmon+memlat, helper2.sh post hook, dcvs.post, busdcvs.conf)"
rm -rf "$W/in" "$W/out" "$W/addx" "$W/mods"
