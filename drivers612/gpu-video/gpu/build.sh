#!/bin/bash
# Builds msm_kgsl.ko (donor GRAPHICS.LA.16.1.r2-04700-LAHAINA.0 + patches/) against the shared,
# read-only 6.12 BSP output. Only reads bsp612/. Usage: ./build.sh [clean] ; KGSL_RECLAIM=y ./build.sh
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd); P=$(cd "$G/../../.." && pwd); BSP=$P/bsp612
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
SOC=$BSP/soc-repo-staging
INC="-I$SOC/include -I$SOC/include/uapi -I$BSP/techpacks/mm-drivers/hw_fence/include -I$BSP/techpacks/mm-drivers/sync_fence/include"
MK=(make -C "$BSP/kernel" O="$BSP/out/lahaina" ARCH=arm64 LLVM="$CLANG/" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" -j"${JOBS:-16}"
    M="$G/src" KGSL_PATH="$G/src" KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers"
    CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y KGSL_RECLAIM="${KGSL_RECLAIM:-n}"
    KCFLAGS="-I$BSP/kernel/drivers/devfreq ${A52_KCFLAGS:-}" SOCINCLUDE="$INC")
if [ "${1:-}" = clean ]; then "${MK[@]}" clean; exit; fi
"${MK[@]}" modules 2>&1 | tee "$G/build.log" | grep -E 'error|warning|ERROR|WARNING|LD \[M\]' || true
ls -l "$G/src/msm_kgsl.ko"
# unresolved-symbol check: every undefined symbol must be exported by vmlinux or a soc-repo module
export LC_ALL=C
"$CLANG/llvm-nm" -u "$G/src/msm_kgsl.ko" | awk '{print $2}' | sort -u > "$G/.undef"
awk '{print $2}' "$BSP/out/lahaina/Module.symvers" "$SOC/build/Module.symvers" | sort -u > "$G/.exported"
echo "undefined symbols not exported anywhere: $(comm -23 "$G/.undef" "$G/.exported" | tr '\n' ' ')"
echo "symbols taken from other modules (load those before msm_kgsl.ko):"
awk '$3!="vmlinux"{print $2" "$3}' "$BSP/out/lahaina/Module.symvers" "$SOC/build/Module.symvers" | sort -u | join - "$G/.undef" | awk '{print $2}' | sort | uniq -c
"$CLANG/llvm-readelf" -p .modinfo "$G/src/msm_kgsl.ko" 2>/dev/null | grep -E 'depends|vermagic|import_ns|firmware' || true
