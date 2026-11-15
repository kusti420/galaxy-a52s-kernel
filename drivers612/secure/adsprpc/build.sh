#!/bin/bash
# Builds frpc-adsprpc.ko against the shared 6.12 BSP output (read-only use of bsp612/).
# Usage: ./build.sh [clean]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BSP=$(cd "$HERE/../../../bsp612" && pwd)
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" -j"$(nproc)" \
  M="$HERE" KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers" \
  SOCINCLUDE="-I$SOC/include -I$SOC/include/uapi" "${1:-modules}" 2>&1 | tee "$HERE/build.log"
if [ "${1:-modules}" = modules ]; then
  echo "== undefined-symbol check"; ! grep -E 'ERROR: modpost|undefined!' "$HERE/build.log"
  "$CLANG/llvm-modinfo" "$HERE/frpc-adsprpc.ko" 2>/dev/null | grep -E 'depends|vermagic|import_ns' || modinfo "$HERE/frpc-adsprpc.ko" | grep -E 'depends|vermagic|import_ns'
fi
