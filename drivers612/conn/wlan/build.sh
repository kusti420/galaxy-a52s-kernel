#!/bin/bash
# Build the WCN6750 Wi-Fi stack (wlan-platform + qcacld-3.0) against the 6.12 BSP.
# Usage: ./build.sh prepare | platform | qcacld | check | all (all = platform qcacld check)
#     (logs: out-*.log)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$HERE/../../.." && pwd)
K=$P/bsp612/kernel; O=$P/bsp612/out/lahaina; SOC=$P/bsp612/soc-repo
SOCSYM=$P/bsp612/soc-repo-staging/build/Module.symvers
LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
WK=${WORK:-$HERE/work}; J=${J:-16}

prepare() {  # rebuild work/ from donors/ + patches/ (WORK=<dir> to build elsewhere)
  rm -rf $WK; mkdir -p $WK/inc-net/net $WK/inc-net/soc/qcom
  for r in platform qcacld-3.0 qca-wifi-host-cmn fw-api; do cp -a $HERE/donors/$r $WK/$r; rm -rf $WK/$r/.git; done
  for p in $HERE/patches/platform-*.patch; do patch -s -p1 -d $WK/platform < $p || exit 1; done
  for p in $HERE/patches/qcacld-*.patch; do patch -s -p1 -d $WK/qcacld-3.0 < $p || exit 1; done
  cp $HERE/patches/grep_defines_lahaina.h $WK/qcacld-3.0/configs/
  rm -rf $WK/qcacld-3.0/cmn; ln -s ../qca-wifi-host-cmn $WK/qcacld-3.0/cmn
  # qcacld includes the platform headers as <net/cnss2.h>, <soc/qcom/icnss2.h>
  for h in cnss2.h cnss_nl.h cnss_prealloc.h cnss_utils.h; do ln -s ../../platform/inc/$h $WK/inc-net/net/$h; done
  ln -s ../../../platform/inc/icnss2.h $WK/inc-net/soc/qcom/icnss2.h
  echo "prepared $WK"
}

platform() {
  cd $WK/platform
  make -C $K O=$O M=$PWD ARCH=arm64 LLVM=$LLVM \
    CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y CONFIG_CNSS_UTILS=m CONFIG_CNSS_GENL=m \
    CONFIG_WCNSS_MEM_PRE_ALLOC=m CONFIG_CNSS_QMI_SVC=m CONFIG_CNSS_OUT_OF_TREE=y CONFIG_SEC_SS_CNSS_FEATURE_SYSFS=y \
    KBUILD_EXTRA_SYMBOLS=$SOCSYM \
    SOCINCLUDE="-I$SOC/include -I$SOC/include/uapi -I$SOC/arch/arm64/include" \
    KCFLAGS="-I$SOC/include -I$PWD/inc -I$PWD/cnss_utils -I$PWD/cnss2 -I$PWD/icnss2 -I$PWD/cnss_prealloc" \
    -j$J modules > $HERE/out-platform.log 2>&1; echo "platform rc=$?"
  grep -E " error:|ERROR|undefined" $HERE/out-platform.log | sort -u | head -20
  find . -name '*.ko'
}

qcacld() {
  cd $WK/qcacld-3.0
  [ -e cmn/qdf ] || { rm -rf cmn; ln -s ../qca-wifi-host-cmn cmn; }
  cat $SOCSYM $WK/platform/Module.symvers > $WK/wlan-extra.symvers
  make -C $K O=$O M=$PWD ARCH=arm64 LLVM=$LLVM \
    WLAN_ROOT=$PWD WLAN_PROFILE=lahaina_gki_qca6750 MODNAME=wlan BUILD_DIAG_VERSION=y \
    CONFIG_QCA_CLD_WLAN=m DYNAMIC_SINGLE_CHIP=qca6750 CONFIG_WLAN_SAMSUNG_FEATURE=y CONFIG_QCA_WIFI_ISOC=0 CONFIG_QCA_WIFI_2_0=1 QCA_WIFI_FTM_NL80211=y \
    KBUILD_EXTRA_SYMBOLS=$WK/wlan-extra.symvers \
    KCFLAGS="-I$SOC/include -I$WK/platform/inc -I$WK/inc-net -include $PWD/configs/kbuild_defines.h -include $PWD/configs/config_to_feature.h -include $PWD/configs/grep_defines_lahaina.h -Wno-macro-redefined -DWLAN_OPEN_SOURCE -Wno-error=missing-prototypes -Wno-error=unused-variable -Wno-error=unused-but-set-variable" \
    -j$J modules > $HERE/out-qcacld.log 2>&1; echo "qcacld rc=$?"
  grep -E " error:|ERROR:|undefined" $HERE/out-qcacld.log | sort -u | head -30
  ls -la wlan.ko 2>&1
}

check() {  # every undefined symbol of our .ko must be exported by GKI, soc-repo or a sibling
  cat $O/Module.symvers $SOCSYM $WK/platform/Module.symvers $WK/qcacld-3.0/Module.symvers 2>/dev/null | awk '{print $2}' | sort -u > $WK/.exports
  for ko in $(find $WK/platform $WK/qcacld-3.0 -name '*.ko'); do
    miss=$($LLVM/llvm-nm -u $ko | awk '{print $2}' | sort -u | comm -23 - $WK/.exports | tr '\n' ' ')
    echo "$(basename $ko): unresolved: ${miss:-none}"
    $LLVM/llvm-readelf -p .modinfo $ko 2>/dev/null | grep -E "depends=|vermagic=" | sed 's/^/    /'
  done
}
case "${1:-all}" in prepare) prepare;; platform) platform;; qcacld) qcacld;; check) check;; all) platform; qcacld; check;; esac
