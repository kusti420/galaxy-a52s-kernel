#!/bin/bash
# Builds mm-drivers (dependency) and the display techpack (msm_drm.ko with the Samsung
# ss_dsi_panel framework + S6E3FC3_AMS646YD01 panel) against the shared 6.12 BSP output.
# Only reads bsp612/; writes only under this directory. Logs: logs/<name>.log
# Usage: ./build.sh [mm-drivers] [sec_panel_notifier_v2] [lcd_class] [display-drivers]     (default: all)
#        SAMSUNG=0 ./build.sh display-drivers           (plain Qualcomm r7, no Samsung code)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); P=$(cd "$HERE/../.." && pwd); BSP=$P/bsp612
T=${TREE:-$HERE/techpack}; L=$HERE/logs; mkdir -p "$L"
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
SOC=$BSP/soc-repo-staging
SYM=$SOC/build/Module.symvers
MK="make -C $BSP/kernel O=$BSP/out/lahaina ARCH=arm64 LLVM=$CLANG/ KCONFIG_EXT_PREFIX=$BSP/soc-repo/ -j${JOBS:-20} ${KEEP:+-k}"
FENCE="-I$T/mm-drivers/hw_fence/include -I$T/mm-drivers/sync_fence/include"
INC="-I$SOC/include -I$SOC/include/uapi"
SS=
[ "${SAMSUNG:-1}" = 1 ] && SS="CONFIG_DISPLAY_SAMSUNG=y"
rc=0
for tp in ${@:-mm-drivers sec_panel_notifier_v2 lcd_class display-drivers}; do
  case "$tp" in
    mm-drivers)
      $MK M="$T/mm-drivers" MM_ROOT="$T/mm-drivers" KBUILD_EXTRA_SYMBOLS="$SYM" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y \
        SOCINCLUDE="$INC" modules > "$L/$tp.log" 2>&1 || rc=1 ;;
    sec_panel_notifier_v2|lcd_class)
      $MK M="$HERE/$tp" modules > "$L/$tp.log" 2>&1 || rc=1
      echo "$tp: $(find "$HERE/$tp" -name '*.ko' | wc -l) modules, $(grep -c 'error:' "$L/$tp.log") compile errors"; continue ;;
    display-drivers)
      $MK M="$T/display-drivers" DISPLAY_ROOT="$T/display-drivers" KBUILD_EXTRA_SYMBOLS="$SYM $T/mm-drivers/Module.symvers $HERE/sec_panel_notifier_v2/Module.symvers $HERE/lcd_class/Module.symvers" \
        CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y CONFIG_DRM_MSM=m $SS \
        SOCINCLUDE="$INC $FENCE -I$T/mm-drivers/msm_ext_display/include" modules > "$L/$tp.log" 2>&1 || rc=1 ;;
  esac
  echo "$tp: $(find "$T/$tp" -name '*.ko' | wc -l) modules, $(grep -c 'error:' "$L/$tp.log") compile errors, $(grep -c 'ERROR: modpost' "$L/$tp.log") modpost errors"
done
exit $rc
