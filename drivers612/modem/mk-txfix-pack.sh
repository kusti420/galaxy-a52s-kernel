#!/bin/bash
# The modem pack with ONLY m/ipam.ko replaced by the build with drivers612/conn/data/patches/0002
# (IPA TX completions on the qcom,tx-napi path, drivers612/modem/LTE-DATA-REALBOOT.md):
#   drivers612/modem/mk-txfix-pack.sh <pack.tgz> <ipam.ko> <out.tgz>
# 6.12: out/pack-modem.tgz + drivers612/conn/data/out/lib/modules/<krel>/extra/ipam.ko
#       -> out/pack-modem-txfix.tgz (made by hand on 2026-11-15 with the same recipe)
# 6.18: out-618/pack-modem-618.tgz (the pack of run kx-m2k618) + bsp618/src/drivers612/conn/data/
#       out/lib/modules/6.18.33-4k-g00c8666046c2-dirty/extra/ipam.ko -> out-618/pack-modem-618-txfix.tgz
# Checks: same vermagic, a different file, same export/import CRC sections (the rmnet modules still
# bind), every other member byte-identical. That the .ko is the 0002 build is the caller's part
# (build log of conn/data/build.sh after the patch). Packs only; nothing is run.
set -euo pipefail
IN=${1:?pack.tgz}; KO=${2:?ipam.ko}; OUT=${3:?out.tgz}
OC=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-objcopy
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ "$(realpath "$IN")" != "$(realpath -m "$OUT")" ] || fail "IN = OUT"
W=$(mktemp -d "${TMPDIR:-/tmp}/txfix.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/a" "$W/b"; tar xzf "$IN" -C "$W/a"; tar xzf "$IN" -C "$W/b"
[ -f "$W/a/m/ipam.ko" ] || fail "$IN has no m/ipam.ko"
vm() { strings "$1" | sed -n 's/^vermagic=//p' | head -1; }
[ "$(vm "$W/a/m/ipam.ko")" = "$(vm "$KO")" ] || fail "vermagic differs: $(vm "$W/a/m/ipam.ko") vs $(vm "$KO")"
cmp -s "$W/a/m/ipam.ko" "$KO" && fail "$KO is the pack's own ipam.ko (not the patched build?)"
for s in __kcrctab __kcrctab_gpl __version_ext_crcs __version_ext_names __versions __ksymtab_strings; do
	$OC -O binary --only-section=$s "$W/a/m/ipam.ko" "$W/o.bin" 2>/dev/null || : > "$W/o.bin"
	$OC -O binary --only-section=$s "$KO" "$W/n.bin" 2>/dev/null || : > "$W/n.bin"
	cmp -s "$W/o.bin" "$W/n.bin" || fail "ipam.ko section $s differs (CRCs changed: rebuild the rmnet modules too)"
done
cp "$KO" "$W/b/m/ipam.ko"
(cd "$W/b" && tar czf "$W/out.tgz" --owner=0 --group=0 .)
mkdir -p "$W/c"; tar xzf "$W/out.tgz" -C "$W/c"
diff -r -q "$W/a" "$W/c" > "$W/d.txt" || true
[ "$(cat "$W/d.txt")" = "Files $W/a/m/ipam.ko and $W/c/m/ipam.ko differ" ] || { cat "$W/d.txt"; fail "read-back differs beyond m/ipam.ko"; }
cmp -s "$W/c/m/ipam.ko" "$KO" || fail "read-back ipam.ko"
mv "$W/out.tgz" "$OUT"
echo "$OUT: = $(basename "$IN") with m/ipam.ko $(sha256sum < "$W/a/m/ipam.ko" | cut -c1-16) -> $(sha256sum < "$KO" | cut -c1-16) (CRC sections identical)"
