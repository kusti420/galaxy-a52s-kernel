#!/bin/bash
# Builds dataipa + datarmnet + datarmnet-ext (data-kernel.lnx.5.0.r30-rel) for lahaina/yupik
# against the shared bsp612 output (read only). Usage: ./build.sh [clean]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd); BSP=$ROOT/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
MK=(make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" -j20
    M="$HERE/src" KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers"
    SOCINCLUDE="-I$SOC/include -I$SOC/include/uapi" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y)
if [ "${1:-}" = clean ]; then "${MK[@]}" clean; exit; fi
"${MK[@]}" ${KEEP_GOING:+-k} modules > "$HERE/build.log" 2>&1; rc=$?
echo "make rc=$rc; $(find "$HERE/src" -name '*.ko' | wc -l) modules; $(grep -c 'error:' "$HERE/build.log") compile errors; $(grep -c 'ERROR: modpost' "$HERE/build.log") modpost errors; $(grep -c 'warning:' "$HERE/build.log") warnings"
[ $rc = 0 ] || exit $rc
# dist + depmod-level check over GKI + soc-repo + these modules
KREL=$(cat "$BSP/out/lahaina/include/config/kernel.release")
D=$HERE/out; rm -rf "$D"; mkdir -p "$D/lib/modules/$KREL/extra"
cp -a "$BSP/out/dist/lib/modules/$KREL/." "$D/lib/modules/$KREL/" 2>/dev/null
find "$HERE/src" -name '*.ko' -exec cp {} "$D/lib/modules/$KREL/extra/" \;
"$CLANG/llvm-strip" --strip-debug "$D/lib/modules/$KREL/extra/"*.ko
depmod -e -F "$BSP/out/gki/System.map" -b "$D" "$KREL" > "$HERE/depmod.log" 2>&1
echo "depmod: $(wc -l < "$HERE/depmod.log") lines of complaints (0 = every symbol resolves)"
ls -la "$D/lib/modules/$KREL/extra/"
