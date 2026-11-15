#!/bin/bash
# Builds the kexec test ramdisk for the bus-DCVS fix WITHOUT repacking anything that ran:
#   drivers612/busdcvs/mkrd.sh [IN=s76] [OUT=s77]
# OUT = IN (drivers612/androidboot/out/<IN>-rd.cpio.gz, byte for byte) + one appended gzip'd
# newc cpio (the kernel unpacks concatenated archives in order, later files replace earlier
# ones) with:
#   /a52/helper2.sh               drivers612/androidboot/kexec-rd/helper2.sh (+ <stage>.post hook)
#   /a52/mods/dcvs.post           drivers612/busdcvs/post.sh
#   /a52/mods/dcvs/busdcvs.conf   drivers612/busdcvs/busdcvs.conf
# Also writes out/stage-dcvs/ (bwmon.ko + memlat.ko of IN's dcvs stage, load.list, post.sh,
# busdcvs.conf) so that a full pack-kexec-rd.sh STAGES="... dcvs:drivers612/busdcvs/out/stage-dcvs"
# gives the same stage. Packs only; nothing is run or flashed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); A=$TOP/drivers612/androidboot
IN=${1:-s76}; OUT=${2:-s77}
SRC=$A/out/$IN-rd.cpio.gz; DST=$A/out/$OUT-rd.cpio.gz
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ -f "$SRC" ] || fail "no $SRC"
[ "$SRC" != "$DST" ] || fail "IN = OUT"
W=$HERE/out/work-$OUT; rm -rf "$W"; mkdir -p "$W"
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$SRC" "$W/in" > /dev/null
[ -f "$W/in/a52/mods/dcvs.list" ] || fail "$IN has no dcvs stage"
[ "$(tr '\n' ' ' < "$W/in/a52/mods/dcvs.list")" = "bwmon.ko memlat.ko " ] || fail "$IN dcvs.list is not 'bwmon.ko memlat.ko'"
grep -qx 'governor_msm_adreno_tz.ko' "$W/in/a52/mods/kgsl.list" || fail "$IN kgsl stage has no GPU governors (want kgsl2)"
for m in qcom-dcvs qcom-pmu-lib qcom_llcc_pmu qcom_scmi_client; do grep -qx "$m.ko" "$W/in/lib/modules/load.list" || fail "$IN first stage lacks $m"; done
# the helper we put in must differ from IN's only by the post hook
diff "$W/in/a52/helper2.sh" "$A/kexec-rd/helper2.sh" > "$W/helper2.diff" && fail "helper2.sh has no post hook?"
[ "$(grep -c '^[<>]' "$W/helper2.diff")" -le 4 ] && ! grep -q '^<' "$W/helper2.diff" || { cat "$W/helper2.diff"; fail "helper2.sh differs from $IN's beyond the post hook"; }
sh -n "$HERE/post.sh" || fail "post.sh syntax"
# stage dir for future full packs
S=$HERE/out/stage-dcvs; rm -rf "$S"; mkdir -p "$S"
cp "$W/in/a52/mods/dcvs/bwmon.ko" "$W/in/a52/mods/dcvs/memlat.ko" "$W/in/a52/mods/dcvs.list" "$S/"; mv "$S/dcvs.list" "$S/load.list"
cp "$HERE/post.sh" "$HERE/busdcvs.conf" "$S/"
# the appended archive
X=$W/add; mkdir -p "$X/a52/mods/dcvs"
install -m 755 "$A/kexec-rd/helper2.sh" "$X/a52/helper2.sh"
install -m 755 "$HERE/post.sh" "$X/a52/mods/dcvs.post"
install -m 644 "$HERE/busdcvs.conf" "$X/a52/mods/dcvs/busdcvs.conf"
chmod 755 "$X/a52" "$X/a52/mods" "$X/a52/mods/dcvs"
find "$X" -exec touch -h -d @0 {} +
( cd "$X" && find a52 | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet ) | gzip -9n > "$W/add.cpio.gz"
cat "$SRC" "$W/add.cpio.gz" > "$DST"
# read back: everything of IN unchanged, the three files new
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$DST" "$W/out" > /dev/null
diff -r -q "$W/in" "$W/out" > "$W/readback.diff" || true
[ "$(sort "$W/readback.diff")" = "$(printf '%s\n' "Files $W/in/a52/helper2.sh and $W/out/a52/helper2.sh differ" "Only in $W/out/a52/mods/dcvs: busdcvs.conf" "Only in $W/out/a52/mods: dcvs.post" | sort)" ] \
	|| { cat "$W/readback.diff"; fail "read-back of $OUT differs from $IN beyond the three files"; }
cmp -s "$W/out/a52/mods/dcvs.post" "$HERE/post.sh" && cmp -s "$W/out/a52/helper2.sh" "$A/kexec-rd/helper2.sh" || fail "read-back content"
echo "$DST: $(stat -c %s "$DST") bytes = $IN ($(stat -c %s "$SRC")) + $(stat -c %s "$W/add.cpio.gz") (helper2.sh post hook, dcvs.post, busdcvs.conf)"
rm -rf "$W/in" "$W/out"
