#!/bin/bash
# Build ioncompat.ko against the Qualcomm 6.12 BSP (read-only use of bsp612/). Usage: ./build.sh [clean]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BSP=$(cd "$HERE/../../../bsp612" && pwd)
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
make -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" M="$HERE" W=1 \
  KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers" \
  SOCINCLUDE="-I$SOC/include -I$SOC/include/uapi" "${1:-modules}"
if [ "${1:-modules}" = modules ]; then
  echo "== undefined symbols and where they come from"
  "$CLANG/llvm-nm" -u "$HERE/ioncompat.ko" | awk '{print $2}' | while read -r s; do
    w=$(grep -hP "\t$s\t" "$BSP/out/lahaina/Module.symvers" "$SOC/build/Module.symvers" | awk '{print $3}' | head -1)
    echo "  $s <- ${w:-UNRESOLVED}"
  done
  "$CLANG/llvm-readelf" -p .modinfo "$HERE/ioncompat.ko" | grep -E "depends|softdep|vermagic|import_ns" || true
fi
