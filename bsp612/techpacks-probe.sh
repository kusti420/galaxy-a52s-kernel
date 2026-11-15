#!/bin/bash
# PROBE, not part of the deliverable build: do the first techpacks compile against out/lahaina with
# plain make? Copies the donors to techpacks/, applies redwood's patches for them, and builds
# with -k using the variables of redwood's scripts/stage2.sh. Logs: out/techpacks/<name>.log.
# Usage: ./techpacks-probe.sh [mm-drivers securemsm-kernel graphics-kernel display-drivers]
set -uo pipefail
BSP=$(cd "$(dirname "$0")" && pwd); DON=$BSP/../donors; T=$BSP/techpacks; L=$BSP/out/techpacks
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
SOC=$BSP/soc-repo-staging
SYM=$SOC/build/Module.symvers
mkdir -p "$T" "$L"
MK="make -C $BSP/kernel O=$BSP/out/lahaina ARCH=arm64 LLVM=$CLANG/ KCONFIG_EXT_PREFIX=$BSP/soc-repo/ -j20 -k"
FENCE="-I$T/mm-drivers/hw_fence/include -I$T/mm-drivers/sync_fence/include"
INC="-I$SOC/include -I$SOC/include/uapi"
prep() {  # copy donor, apply redwood's patches for it
  rsync -a --delete --exclude=.git/ "$DON/$1/" "$T/$1/"
  for p in "$DON"/redwood-6.12/patches/"$1"/*.patch; do
    [ -e "$p" ] || continue
    # all or nothing: redwood wrote some of these for another branch of the techpack
    if patch -d "$T/$1" -p1 --batch -s --dry-run < "$p" >/dev/null 2>&1; then
      patch -d "$T/$1" -p1 --batch -s < "$p"; echo "  applied $(basename "$p")"
    else
      echo "  skipped (does not apply to this donor tag): $(basename "$p")"
    fi
  done
}
report() { echo "$1: $(find "$T/$1" -name '*.ko' | wc -l) modules, $(grep -c 'error:' "$L/$1.log") compile errors, $(grep -c 'ERROR: modpost' "$L/$1.log") modpost errors"; }
for tp in ${@:-mm-drivers securemsm-kernel graphics-kernel display-drivers}; do
  echo "== $tp"; prep "$tp"
  case "$tp" in
    mm-drivers)
      $MK M="$T/mm-drivers" MM_ROOT="$T/mm-drivers" KBUILD_EXTRA_SYMBOLS="$SYM" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y \
        SOCINCLUDE="$INC" modules > "$L/$tp.log" 2>&1 ;;
    securemsm-kernel)
      # its tracepoint headers are included through vendor/qcom/opensource/securemsm-kernel
      mkdir -p "$T/vendor/qcom/opensource"; ln -sfn ../../../securemsm-kernel "$T/vendor/qcom/opensource/securemsm-kernel"
      $MK M="$T/securemsm-kernel" SSG_MODULE_ROOT="$T/securemsm-kernel" KBUILD_EXTRA_SYMBOLS="$SYM" CONFIG_ARCH_LAHAINA=y \
        CONFIG_DISABLE_TEST_MODULES=y CONFIG_QSEECOM=m SOCINCLUDE="$INC" KCFLAGS="-I$T" modules > "$L/$tp.log" 2>&1 ;;
    graphics-kernel)
      $MK M="$T/graphics-kernel" KGSL_PATH="$T/graphics-kernel" KBUILD_EXTRA_SYMBOLS="$SYM" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y \
        KCFLAGS="-I$BSP/kernel/drivers/devfreq" SOCINCLUDE="$INC $FENCE" modules > "$L/$tp.log" 2>&1 ;;
    display-drivers)
      # This display branch (display-kernel.lnx.1.11) has no SOCINCLUDE hook; the soc-repo headers
      # must come before ACK's (llcc-qcom.h, secure_buffer.h, msm_mmrm.h). Probe-only edit.
      grep -q SOCINCLUDE "$T/display-drivers/Kbuild" || sed -i '1a LINUXINCLUDE := $(SOCINCLUDE) $(LINUXINCLUDE)' "$T/display-drivers/Kbuild"
      $MK M="$T/display-drivers" DISPLAY_ROOT="$T/display-drivers" KBUILD_EXTRA_SYMBOLS="$SYM $T/mm-drivers/Module.symvers" \
        CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y CONFIG_DRM_MSM=m \
        SOCINCLUDE="$INC $FENCE -I$T/mm-drivers/msm_ext_display/include" modules > "$L/$tp.log" 2>&1 ;;
  esac
  report "$tp"
done
