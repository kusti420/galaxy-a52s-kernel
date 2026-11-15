#!/bin/bash
# Build the legacy (Elite/APR) audio techpack for lahaina/yupik against bsp612/out/lahaina.
# Reads bsp612 only; writes only under drivers612/audio. Usage: ./build.sh [make args, e.g. -k]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); P=$(cd "$HERE/../.." && pwd); BSP=$P/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
A=$HERE/audio-kernel
SOC=$BSP/soc-repo-staging
SYM="$SOC/build/Module.symvers $BSP/techpacks/mm-drivers/Module.symvers"
make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" -j20 \
  M="$A" MODNAME=audio_dlkm AUDIO_ROOT="$A" KERNEL_SRC="$BSP/kernel" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y \
  KBUILD_EXTRA_SYMBOLS="$SYM" \
  KCFLAGS="-I$SOC/include -I$SOC/include/uapi -I$BSP/techpacks/mm-drivers/msm_ext_display/include" \
  "$@" modules 2>&1 | tee "$HERE/build.log" | tail -5
echo "modules: $(find "$A" -name '*.ko' | wc -l); compile errors: $(grep -c 'error:' "$HERE/build.log"); modpost errors: $(grep -c 'ERROR: modpost' "$HERE/build.log")"
