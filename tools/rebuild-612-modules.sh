#!/bin/bash
# Rebuilds every out-of-tree 6.12 module of the project against bsp612/out/lahaina. Needed after
# any kernel config change that alters ABI details (e.g. CONFIG_RUST -> normalized kCFI hashes:
# old modules then die at init with "CFI failure at do_one_initcall"). Logs: logs/rebuild-612/.
cd "$(dirname "$0")/.."
TOP=$PWD; L=$TOP/logs/rebuild-612; mkdir -p $L
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
M() { # M <name> <module dir> [extra make args]: plain M= build
  local n=$1 d=$2; shift 2
  make -C bsp612/kernel ARCH=arm64 LLVM=$CLANG/ O=$TOP/bsp612/out/lahaina M=$TOP/$d "$@" modules > $L/$n.log 2>&1 \
    && echo "ok   $n" || echo "FAIL $n (log $L/$n.log)"; }
S() { # S <name> <dir with build.sh>
  ( cd $1 && ./build.sh ) > $L/$(echo $1 | tr / _).log 2>&1 && echo "ok   $1" || echo "FAIL $1 (log $L/$(echo $1 | tr / _).log)"; }
M sec_core samsung612/modules/sec_core
M qfprom-sys drivers612/qfprom-sys
M testguard drivers612/androidboot/testguard
for d in drivers612/secure/ioncompat drivers612/secure/securemsm drivers612/secure/adsprpc \
         drivers612/display drivers612/touch drivers612/power drivers612/audio drivers612/audio/samsung \
         drivers612/gpu-video/gpu drivers612/gpu-video/video drivers612/conn/subsys_compat \
         drivers612/conn/data drivers612/conn/wlan drivers612/conn/bt; do S $d; done
