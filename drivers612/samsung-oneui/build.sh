#!/bin/bash
# Build one Samsung OneUI compat module against bsp612 (6.12.81-4k-g8a69376da734), strip debug + BTF.
#   drivers612/samsung-oneui/build.sh <dir>     -> <dir>/out/<name>.ko (stripped) + vermagic check
set -euo pipefail
TOP=$(cd "$(dirname "$0")/../.." && pwd)
D=$(cd "$1" && pwd)
PB=${ANDROID_TREE:-$HOME/android}/prebuilts
CLANG=$PB/clang/host/linux-x86/clang-r547379/bin
BSP=$TOP/bsp612
# GKI symbols come from O= (out/lahaina/Module.symvers; BUILD_O=<out dir> overrides, e.g. out/gki for a GKI module); soc-repo/vendor module CRCs: EXTRA_SYMVERS="a.symvers b.symvers" (ko2symvers.py)
make -s -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="${BUILD_O:-$BSP/out/lahaina}" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" \
	KBUILD_EXTRA_SYMBOLS="${EXTRA_SYMVERS:-}" \
	KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost M="$D" modules
mkdir -p "$D/out"
for k in "$D"/*.ko; do
	n=$(basename "$k"); cp "$k" "$D/out/$n"
	"$CLANG/llvm-strip" --strip-debug "$D/out/$n"
	"$CLANG/llvm-objcopy" --remove-section=.BTF --remove-section=.BTF.base "$D/out/$n" 2>/dev/null || true
	vm=$(modinfo -F vermagic "$D/out/$n")
	[ "$vm" = "6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64" ] || { echo "bad vermagic $vm"; exit 1; }
	echo "$D/out/$n $(stat -c %s "$D/out/$n") bytes sha256 $(sha256sum < "$D/out/$n" | cut -c1-16) deps=$(modinfo -F depends "$D/out/$n")"
done
