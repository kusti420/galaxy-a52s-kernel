#!/bin/bash
# Builds adsp_factory_dlkm.ko from the current sources in a private copy (out-p1/w/) and puts the
# stripped module + SHA256SUMS in out-p1/. The in-place adsp_factory_dlkm.ko (which
# realboot/build-realboot.sh ADSPFAC=1 picks up directly) is NOT touched: run ./build.sh to
# replace that one. Offline only. *.ko is gitignored: SHA256SUMS is what the repo records.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$(cd "$HERE/.." && pwd); TOP=$(cd "$D/.." && pwd); BSP=$TOP/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
VM="6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64"
W=$HERE/out-p1/w; rm -rf "$W"; mkdir -p "$W/sensors-factory"
# Kbuild reaches ../power/include, ../vibrator/src/include, ../touch/src/include: same layout, links
for s in power vibrator touch; do ln -s "$D/$s" "$W/$s"; done
cp -r "$HERE"/{Kbuild,*.c,*.h,include} "$W/sensors-factory/"
SYM="$BSP/soc-repo-staging/build/Module.symvers $D/power/Module.symvers"
make -s -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" M="$W/sensors-factory" \
	KBUILD_EXTRA_SYMBOLS="$SYM" KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost modules > "$HERE/out-p1/build.log" 2>&1 \
	|| { grep -E "error|undefined" "$HERE/out-p1/build.log" | head -40; exit 1; }
"$CLANG/llvm-strip" --strip-debug -o "$HERE/out-p1/adsp_factory_dlkm.ko" "$W/sensors-factory/adsp_factory_dlkm.ko"
cp "$W/sensors-factory/Module.symvers" "$HERE/out-p1/Module.symvers.txt"
[ "$(modinfo -F vermagic "$HERE/out-p1/adsp_factory_dlkm.ko")" = "$VM" ] || { echo "bad vermagic"; exit 1; }
( cd "$HERE/out-p1" && sha256sum adsp_factory_dlkm.ko > SHA256SUMS )
echo "out-p1/adsp_factory_dlkm.ko depends=[$(modinfo -F depends "$HERE/out-p1/adsp_factory_dlkm.ko")] $(cut -c1-16 "$HERE/out-p1/SHA256SUMS")"
