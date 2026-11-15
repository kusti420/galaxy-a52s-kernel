#!/bin/bash
# Builds sec_audio_sysfs.ko then tas256x_dlkm.ko against bsp612/out/lahaina (read-only use).
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel); S=$P/drivers612/audio/samsung
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
MK="make -C $P/bsp612/kernel ARCH=arm64 LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/ O=$P/bsp612/out/lahaina -j12"
SYM="$S/sec_audio/Module.symvers"
for d in $P/drivers612/audio/audio-kernel $P/drivers612/audio/audio-kernel/dsp; do [ -f $d/Module.symvers ] && SYM="$SYM $d/Module.symvers"; done
$MK M=$S/sec_audio modules 2>&1 | tee $S/sec_audio/build.log
$MK M=$S/tas256x KBUILD_EXTRA_SYMBOLS="$SYM" KBUILD_MODPOST_WARN=1 modules 2>&1 | tee $S/tas256x/build.log
