#!/bin/sh
# Compile check against the shared 6.12 BSP output (read-only use). Extra args go to make,
# e.g. ./build.sh PDIC=1 DIRECT=1
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
W=$P/drivers612/power
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost exec make -C $P/bsp612/kernel ARCH=arm64 \
 LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/ \
 O=$P/bsp612/out/lahaina M=$W \
 KBUILD_EXTRA_SYMBOLS="$P/samsung612/modules/sec_core/Module.symvers $P/bsp612/soc-repo-staging/build/Module.symvers" -j20 "$@" modules
