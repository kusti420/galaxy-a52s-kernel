#!/bin/bash
# Reproducible build of Qualcomm securemsm-kernel (sec-kernel.lnx.14.16.r27-rel, donor commit
# b1c5edcf) for lahaina/yupik against the shared 6.12 BSP output. Writes only below this directory.
#   src/                       pristine donor copy + patches/*.patch applied in order
#   out/*.ko                   stripped-debug copies of the modules
# Usage: ./build.sh [clean]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PRJ=$(cd "$HERE/../../.." && pwd)
BSP=$PRJ/bsp612; DON=$PRJ/donors/securemsm-kernel; SRC=$HERE/src
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging; SYM=$SOC/build/Module.symvers
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
rsync -a --delete --exclude=.git/ "$DON/" "$SRC/"
for p in "$HERE"/patches/*.patch; do
  patch -d "$SRC" -p1 --batch -s < "$p"; echo "applied $(basename "$p")"
done
# the tracepoint headers are included as vendor/qcom/opensource/securemsm-kernel/...
# (resolved relative to -I src/include/uapi/linux, i.e. from the parent of src/)
mkdir -p "$HERE/vendor/qcom/opensource"; ln -sfn ../../../src "$HERE/vendor/qcom/opensource/securemsm-kernel"
MK=(make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" -j20
    M="$SRC" SSG_MODULE_ROOT="$SRC" KBUILD_EXTRA_SYMBOLS="$SYM" CONFIG_ARCH_LAHAINA=y
    CONFIG_DISABLE_TEST_MODULES=y CONFIG_QSEECOM=m "SOCINCLUDE=-I$SOC/include -I$SOC/include/uapi" "KCFLAGS=-I$HERE")
[ "${1:-}" = clean ] && { "${MK[@]}" clean; exit 0; }
"${MK[@]}" modules 2>&1 | tee "$HERE/build.log" | grep -E 'error|ERROR|WARNING: modpost|\.ko$' || true
mkdir -p "$HERE/out"; rm -rf "$HERE"/out/*
for k in "$SRC"/*.ko; do "$CLANG/llvm-strip" --strip-debug -o "$HERE/out/$(basename "$k")" "$k"; done
# Second smcinvoke variant: the SCM "compat" transport, which is the direct descendant of the 5.4
# driver (the default above is built on soc-repo's si_core because CONFIG_QCOM_SI_CORE=m).
# Which one the phone's 5.4-era QTEE accepts is a hardware question, so both are kept.
"${MK[@]}" CONFIG_QCOM_SI_CORE= modules 2>&1 | tee "$HERE/build-smcinvoke-compat.log" | grep -E 'error|ERROR|WARNING: modpost' || true
mkdir -p "$HERE/out/smcinvoke-compat"
"$CLANG/llvm-strip" --strip-debug -o "$HERE/out/smcinvoke-compat/smcinvoke_dlkm.ko" "$SRC/smcinvoke_dlkm.ko"
cat "$HERE/build-smcinvoke-compat.log" >> "$HERE/build.log"
echo "errors: $(grep -c 'error:' "$HERE/build.log" || true), modpost errors: $(grep -c 'ERROR: modpost' "$HERE/build.log" || true)"
ls -la "$HERE/out"
