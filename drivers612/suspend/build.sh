#!/bin/bash
# Compile-checks a52susp.ko against the shared 6.12 BSP output (read-only M= build; the kernel
# tree and bsp612/out are not modified). Output: a52susp/a52susp.ko, log: build.log.
set -o pipefail
H=$(cd "$(dirname "$0")" && pwd); P=$(cd "$H/../.." && pwd)
CLANG=$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -C "$P/bsp612/kernel" ARCH=arm64 \
	LLVM=$CLANG/ O="$P/bsp612/out/lahaina" M="$H/a52susp" modules 2>&1 | tee "$H/build.log" |
	grep -E "error|warning:|LD \[M\]|WARNING"
# small copy for tools/tput.py (pushes in base64 over telnet)
$CLANG/llvm-strip --strip-debug -o "$H/a52susp/a52susp-strip.ko" "$H/a52susp/a52susp.ko" && ls -la "$H/a52susp/a52susp-strip.ko"
