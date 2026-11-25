#!/bin/bash
# swap-vendor-boot.sh <rb> <new.ko>...: vendor_boot of drivers612/realboot/out/<rb> with ONLY the given modules replaced.
#  1. our vendor ramdisk fragment (work/vr-add.cpio.lz4) -> raw cpio; recompressing it must give the same bytes back
#  2. drivers612/realboot/tools/rd-swap-ko.py on the raw cpio (headers kept, only sizes/contents of NEW.ko entries change)
#  3. same lz4 recipe + end marker as build-realboot.sh, ROM part (work/vb/vendor_ramdisk) unchanged in front
#  4. CONTROL: mkbootimg + AVB footer recipe from the shipped image's own footer, applied to the ORIGINAL ramdisk,
#     must rebuild <rb>/vendor_boot.img byte-identical; then the same recipe on the new ramdisk
# Output: ramdisk/<rb>/{vendor-ramdisk.new,vendor_boot.img,REPORT.txt}. Nothing is flashed.
set -euo pipefail
T=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel); H=$(cd "$(dirname "$0")" && pwd)
RB=$1; shift; O=$T/drivers612/realboot/out/$RB; W=$O/work; D=$H/ramdisk/$RB; mkdir -p "$D"; R=$D/REPORT.txt; : > "$R"
say() { echo "$*" | tee -a "$R"; }
LZ='lz4 -l -12 --favor-decSpeed -q'
A=$W/vr-add.cpio.lz4; MARK=0
[ "$(tail -c 4 "$A" | od -An -tx1 | tr -d ' \n')" = 00000000 ] && [ "$(head -c 4 "$W/boot-ramdisk" | od -An -tx1 | tr -d ' \n')" != 02214c18 ] && MARK=1
if [ $MARK = 1 ]; then head -c -4 "$A" > "$D/frag.lz4"; else cp "$A" "$D/frag.lz4"; fi
lz4 -d -c "$D/frag.lz4" > "$D/frag.cpio"
$LZ < "$D/frag.cpio" > "$D/frag.re.lz4"; cmp -s "$D/frag.re.lz4" "$D/frag.lz4" || { say "FAIL: lz4 recompress of the original fragment differs"; exit 1; }
say "fragment: lz4 legacy, end marker=$MARK, recompress byte-identical"
python3 -I "$T/drivers612/realboot/tools/rd-swap-ko.py" "$D/frag.cpio" "$D/frag.new.cpio" "$@" | tee -a "$R"
$LZ < "$D/frag.new.cpio" > "$D/frag.new.lz4"; [ $MARK = 1 ] && printf '\0\0\0\0' >> "$D/frag.new.lz4"
cat "$W/vb/vendor_ramdisk" "$D/frag.new.lz4" > "$D/vendor-ramdisk.new"
VB_ARGS=$(sed -e "s/--vendor_cmdline '[^']*'//" -e 's/--dtb [^ ]*//' -e 's/--vendor_ramdisk [^ ]*//' "$W/vb.args")
VC=$(sed -n 's/^vendor command line args: //p' "$W/chk-vb.info")
info=$(avbtool info_image --image "$O/vendor_boot.img")
salt=$(echo "$info" | sed -n 's/^ *Salt: *//p' | head -1); props=()
while IFS= read -r l; do props+=(--prop "$l"); done < <(echo "$info" | sed -n "s/^ *Prop: \(.*\) -> '\(.*\)'$/\1:\2/p")
sign=(); echo "$info" | grep -q 'Algorithm: *SHA256_RSA4096' && sign=(--algorithm SHA256_RSA4096 --key "$HOME/git/MonsterROM/security/avb/testkey_rsa4096.pem")
orig=$(echo "$info" | sed -n 's/^Original image size: *\([0-9]*\) bytes/\1/p')
# control: original ramdisk -> must equal the shipped image (AVB padding: the shipped raw size must equal mkbootimg's)
eval mkbootimg $VB_ARGS --vendor_cmdline "'$VC'" --dtb "$O/vendor_boot.dtb" --vendor_ramdisk "$W/vendor-ramdisk" --vendor_boot "$D/ctl.img"
[ "$(stat -c %s "$D/ctl.img")" = "$orig" ] || { say "FAIL: control raw size $(stat -c %s "$D/ctl.img") != original $orig (AVB padding)"; exit 1; }
avbtool add_hash_footer --image "$D/ctl.img" --partition_name vendor_boot --partition_size 100663296 --salt "$salt" "${sign[@]}" "${props[@]}"
cmp -s "$D/ctl.img" "$O/vendor_boot.img" || { say "FAIL: control vendor_boot differs from $O/vendor_boot.img"; exit 1; }
say "control: $RB/vendor_boot.img rebuilt byte-identical from its own ramdisk (mkbootimg + footer recipe proven, sign=${#sign[@]})"
rm -f "$D/ctl.img"
eval mkbootimg $VB_ARGS --vendor_cmdline "'$VC'" --dtb "$O/vendor_boot.dtb" --vendor_ramdisk "$D/vendor-ramdisk.new" --vendor_boot "$D/vendor_boot.img"
avbtool add_hash_footer --image "$D/vendor_boot.img" --partition_name vendor_boot --partition_size 100663296 --salt "$salt" "${sign[@]}" "${props[@]}"
# read back + diff of the unpacked ramdisks: only the swapped modules may differ
rm -rf "$D/chk" "$D/x-old" "$D/x-new"; unpack_bootimg --boot_img "$D/vendor_boot.img" --out "$D/chk" > "$D/chk.info"
cmp -s "$D/chk/vendor_ramdisk" "$D/vendor-ramdisk.new" && cmp -s "$D/chk/dtb" "$O/vendor_boot.dtb" || { say "FAIL: read-back"; exit 1; }
diff <(grep -v 'ramdisk.*size' "$W/chk-vb.info") <(grep -v 'ramdisk.*size' "$D/chk.info") > /dev/null || { say "FAIL: header differs"; exit 1; }
python3 -I "$T/drivers612/realboot/tools/cpiox.py" "$W/vendor-ramdisk" "$D/x-old" > /dev/null
python3 -I "$T/drivers612/realboot/tools/cpiox.py" "$D/vendor-ramdisk.new" "$D/x-new" > /dev/null
say "files differing between the old and new vendor ramdisk: $(diff -rq "$D/x-old" "$D/x-new" | sed "s|$D/||g" | tr '\n' ' ')"
say "vendor_boot.img: $(stat -c %s "$D/vendor_boot.img") bytes sha256 $(sha256sum < "$D/vendor_boot.img" | cut -c1-16) (was $(sha256sum < "$O/vendor_boot.img" | cut -c1-16))"
avbtool info_image --image "$D/vendor_boot.img" | grep -E 'Algorithm|Partition Name|Salt' | tee -a "$R"
rm -rf "$D/chk" "$D/x-old" "$D/x-new" "$D/frag.re.lz4" "$D/frag.cpio" "$D/frag.new.cpio" "$D/frag.lz4"
