#!/bin/bash
# Builds the DIAGNOSTIC 6.12 Image for real-boot attempts (rb6 and later): the bsp612 GKI kernel
# (6.12.81-4k-g8a69376da734, COMMAND_LINE_SIZE 4096) + a52bc.c (breadcrumbs + RAM early console
# at 0xf0be0000, see the file header). BUILDS ONLY, flashes nothing.
#
#   drivers612/realboot/kernel-diag/build-diag-kernel.sh     -> bsp612/out/diag/{Image,System.map,BUILDINFO}
#
# How it stays compatible with every tested module (vermagic, modversion CRCs):
#  - the build runs in its own output dir bsp612/out/gki-diag, a reflink copy of bsp612/out/gki
#    (same .config, same objects: only setup.o, a52bc.o and the vmlinux link are redone);
#  - the two tracked files touched (arch/arm64/kernel/setup.c, Makefile) are marked
#    `git update-index --assume-unchanged` for the build, so setlocalversion sees a clean tree and
#    the release stays 6.12.81-4k-g8a69376da734; a52bc.[ch] are
#    untracked (setlocalversion uses status -uno);
#  - afterwards the source tree is put back exactly (git checkout of the two files, a52bc.[ch]
#    removed, assume-unchanged cleared): bsp612/out/gki and bsp612/out/dist are never touched;
#  - checks: same kernel.release and "Linux version" release as out/gki, every __crc_* of
#    vmlinux identical to out/gki/vmlinux, a52bc symbols present, a52bc.o has no exports.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../.." && pwd)
BSP=$TOP/bsp612; KS=$BSP/kernel; GKI=$BSP/out/gki; OD=$BSP/out/gki-diag; DIST=$BSP/out/diag
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
RUSTBIN=${RUSTBIN:-$HOME/.rustup/toolchains/1.82.0-x86_64-unknown-linux-gnu/bin}
export LIBCLANG_PATH=$(dirname "$CLANG")/lib KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
K=(make -s -C "$KS" ARCH=arm64 LLVM="$CLANG/" RUSTC="$RUSTBIN/rustc" HOSTRUSTC="$RUSTBIN/rustc"
	BINDGEN=${ANDROID_TREE:-$HOME/android}/prebuilts/clang-tools/linux-x86/bin/bindgen O="$OD")
FILES="arch/arm64/kernel/setup.c arch/arm64/kernel/Makefile"
fail() { echo "FAILED: $*" >&2; exit 1; }

[ -f "$GKI/vmlinux" ] && [ -f "$GKI/include/config/kernel.release" ] || fail "no bsp612/out/gki build"
REL=$(cat "$GKI/include/config/kernel.release")
cd "$KS"
[ -z "$(git status --porcelain -uno)" ] || { git status --porcelain -uno; fail "bsp612/kernel has tracked changes"; }
for f in $FILES; do git ls-files -v "$f" | grep -q '^H ' || fail "$f is not a plain tracked file"; done
[ ! -e arch/arm64/kernel/a52bc.c ] && [ ! -e arch/arm64/kernel/a52bc.h ] || fail "a52bc.[ch] already in the tree"

restore() {
	cd "$KS"
	git update-index --no-assume-unchanged $FILES
	git checkout -- $FILES
	rm -f arch/arm64/kernel/a52bc.c arch/arm64/kernel/a52bc.h
	[ -z "$(git status --porcelain -uno)" ] && echo "source tree restored" || echo "WARNING: bsp612/kernel not clean after restore" >&2
}
trap restore EXIT
cp "$HERE/a52bc.c" "$HERE/a52bc.h" arch/arm64/kernel/
patch -s -p1 < "$HERE/0001-a52bc-hooks.patch"
git update-index --assume-unchanged $FILES
[ -z "$(git status --porcelain -uno)" ] || fail "tree still dirty for setlocalversion"

if [ ! -f "$OD/vmlinux" ]; then rm -rf "$OD"; cp -a --reflink=auto "$GKI" "$OD"; fi
echo "building Image in $OD (log $OD/diag-build.log)"
"${K[@]}" -j"${J:-20}" Image > "$OD/diag-build.log" 2>&1 || { tail -30 "$OD/diag-build.log"; fail "make Image"; }
grep -E 'warning:.*a52bc|error:' "$OD/diag-build.log" && fail "warnings/errors in a52bc (see $OD/diag-build.log)"

# checks
DREL=$(cat "$OD/include/config/kernel.release")
[ "$DREL" = "$REL" ] || fail "kernel.release $DREL != $REL (dirty tree?)"
IREL=$(strings "$OD/arch/arm64/boot/Image" | sed -n 's/^Linux version \([^ ]*\) .*/\1/p' | head -1)
[ "$IREL" = "$REL" ] || fail "Image says $IREL"
grep -q ' a52bc_stage$' "$OD/System.map" && grep -q ' a52ram_write$' "$OD/System.map" || fail "a52bc not linked"
"$CLANG/llvm-nm" "$OD/arch/arm64/kernel/a52bc.o" | grep -q '__ksymtab\|__crc_' && fail "a52bc.o exports symbols"
# vmlinux.symvers (modpost of vmlinux: CRC, symbol, namespace) must be byte-identical
[ "$OD/vmlinux.symvers" -nt "$OD/diag-build.log" ] || [ "$OD/vmlinux.symvers" -nt "$GKI/vmlinux.symvers" ] || echo "note: vmlinux.symvers not rewritten by this build"
cmp -s <(sort "$GKI/vmlinux.symvers") <(sort "$OD/vmlinux.symvers") || { diff <(sort "$GKI/vmlinux.symvers") <(sort "$OD/vmlinux.symvers") > "$OD/crc.diff"; fail "exports/CRCs differ ($OD/crc.diff)"; }
NCRC=$(wc -l < "$OD/vmlinux.symvers")
[ "$NCRC" -gt 10000 ] || fail "only $NCRC exports in vmlinux.symvers"

mkdir -p "$DIST"
cp "$OD/arch/arm64/boot/Image" "$OD/System.map" "$DIST/"
cp "$HERE/a52bc.c" "$HERE/a52bc.h" "$HERE/0001-a52bc-hooks.patch" "$DIST/"
{ echo "release=$REL"; echo "base=$GKI (same .config, objects reflinked)";
  echo "a52bc.c sha256 $(sha256sum < "$HERE/a52bc.c" | cut -d' ' -f1)"
  echo "Image sha256 $(sha256sum < "$DIST/Image" | cut -d' ' -f1), image_size $(printf %#x "$(od -An -tu8 -j16 -N8 "$DIST/Image" | tr -d ' ')")"
  echo "modversion CRCs: $NCRC, all identical to $GKI/vmlinux"
  echo "built $(date '+%F %T')"; } > "$DIST/BUILDINFO"
cat "$DIST/BUILDINFO"
