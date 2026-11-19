#!/bin/bash
# Builds adsp_factory_dlkm.ko against bsp612 6.12 (as build-realboot.sh builds a52sxq_dsp_boot). Offline only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); BSP=$TOP/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SYM="$BSP/soc-repo-staging/build/Module.symvers $TOP/drivers612/power/Module.symvers ${EXTRA_SYM:-}"
make -s -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" M="$HERE" -k \
	KBUILD_EXTRA_SYMBOLS="$SYM" KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost modules 2>&1 | tee "$HERE/build.log" | grep -E "error|undefined|warning: \"" | head -60
[ -f "$HERE/adsp_factory_dlkm.ko" ] || exit 1
cp "$HERE/adsp_factory_dlkm.ko" "$HERE/adsp_factory_dlkm.stripped.ko"; "$CLANG/llvm-strip" --strip-debug "$HERE/adsp_factory_dlkm.stripped.ko"
modinfo "$HERE/adsp_factory_dlkm.stripped.ko" | grep -E "vermagic|depends"
