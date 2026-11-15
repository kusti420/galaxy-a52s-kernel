#!/bin/bash
# Builds sec_vibrator.ko + dc_vibrator.ko against the shared 6.12 BSP output. ./port.sh first.
H=$(cd "$(dirname "$0")" && pwd); P=$(cd "$H/../.." && pwd)
CLANG=$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -C "$P/bsp612/kernel" ARCH=arm64 \
	LLVM=$CLANG/ O="$P/bsp612/out/lahaina" M="$H/src" modules 2>&1 | tee "$H/build.log" | grep -E "error|warning:|LD \[M\]"
