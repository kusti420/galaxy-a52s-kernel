#!/bin/sh
# Compile check against the 6.12 BSP output (read-only use of bsp612).
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
D=$(cd "$(dirname "$0")" && pwd)
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -C $P/bsp612/kernel ARCH=arm64 \
  LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/ \
  O=$P/bsp612/out/lahaina M=$D \
  KBUILD_EXTRA_SYMBOLS=$P/bsp612/soc-repo-staging/build/Module.symvers "${@:-modules}"
