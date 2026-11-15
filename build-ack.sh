#!/bin/sh
# Builds the ACK android17-6.18 kernel for a52sxq into out-ack/. Offline only: flashes nothing.
# Usage: ./build-ack.sh [config|<make targets>]   (default: Image + a52sxq dtb)
set -e
cd "$(dirname "$0")/ack"
# The exact clang ACK pins in build.config.constants (CLANG_VERSION), from the AOSP prebuilts.
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
# Generic build identity: the kernel version string must not carry the builder's login or host.
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
# -@ keeps /__symbols__ in the dtb: the Samsung ABL refuses a base dtb without it.
MAKE="make ARCH=arm64 LLVM=$CLANG/ O=../out-ack DTC_FLAGS=-@"
if [ "$1" = config ] || [ ! -f ../out-ack/.config ]; then
  $MAKE gki_defconfig >/dev/null
  ARCH=arm64 LLVM=$CLANG/ ./scripts/kconfig/merge_config.sh -m -O ../out-ack ../out-ack/.config \
    arch/arm64/configs/a52sxq_gki.fragment >/dev/null
  $MAKE olddefconfig >/dev/null
  for s in $(grep -oE '^CONFIG_[A-Z0-9_]+' arch/arm64/configs/a52sxq_gki.fragment); do
    grep -q "^$s=" ../out-ack/.config || echo "WARNING: $s did not take"
  done
  [ "$1" = config ] && exit 0
fi
[ $# -eq 0 ] && set -- Image qcom/sm7325-samsung-a52sxq.dtb
$MAKE -j20 "$@"
