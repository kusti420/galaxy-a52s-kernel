#!/bin/bash
# Build ntfs3.ko from the unmodified bsp612/kernel/fs/ntfs3 sources as an external module (no GKI rebuild).
#   drivers612/samsung-oneui/ntfs3/mk.sh   -> out/ntfs3.ko (stripped), imports.txt, missing.txt
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$D/../../.." && pwd); K=$TOP/bsp612/kernel/fs/ntfs3
rm -rf "$D/src"; mkdir -p "$D/src/lib"
cp "$K"/*.c "$K"/*.h "$D/src/"; cp "$K"/lib/*.c "$K"/lib/*.h "$D/src/lib/"; cp "$D/Kbuild.src" "$D/src/Kbuild"
( cd "$K" && sha256sum *.c *.h lib/*.c lib/*.h | sha256sum | cut -c1-16 ) > "$D/src.sha"
"$D/../build.sh" "$D/src"
mkdir -p "$D/out"; cp "$D/src/out/ntfs3.ko" "$D/out/ntfs3.ko"
NM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-nm
"$NM" -u "$D/out/ntfs3.ko" | awk '{print $2}' | sort -u > "$D/imports.txt"
awk '$3=="vmlinux"{print $2}' "$TOP/bsp612/out/lahaina/Module.symvers" | sort -u > "$D/src/vmlinux.syms"
comm -23 "$D/imports.txt" "$D/src/vmlinux.syms" > "$D/missing.txt"
echo "imports $(wc -l < "$D/imports.txt"), not exported by the GKI vmlinux: $(wc -l < "$D/missing.txt")"; cat "$D/missing.txt"
