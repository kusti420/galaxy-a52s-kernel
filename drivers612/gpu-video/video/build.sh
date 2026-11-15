#!/bin/bash
# Compile check of the 5.4 msm_vidc (v1 V4L2 dialect) against the Qualcomm 6.12 BSP output.
# Reads bsp612 only; writes only into this directory. Log: build.log
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PRJ=$(cd "$HERE/../../.." && pwd); BSP=$PRJ/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" \
  M="$HERE" KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers" \
  KCFLAGS="-I$SOC/include -I$SOC/include/uapi ${EXTRA:-}" -j20 ${K:+-k} "${@:-modules}" > "$HERE/build.log" 2>&1
rc=$?
echo "make rc=$rc, errors: $(grep -c ' error:' "$HERE/build.log"), warnings: $(grep -c ' warning:' "$HERE/build.log"), modpost: $(grep -c 'ERROR: modpost' "$HERE/build.log")"
ls -la "$HERE"/*.ko 2>/dev/null
exit $rc
