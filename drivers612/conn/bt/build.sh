#!/bin/sh
# Compile check of conn/bt modules against the shared 6.12 BSP output (read-only use).
# usage: ./build.sh [btpower|btfmslim|all] [clean]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
KSRC=$TOP/bsp612/kernel
KOUT=$TOP/bsp612/out/lahaina
LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/
what=${1:-all}; tgt=${2:-modules}
mk() { # dir [extra symvers]
	KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
	make -s -C "$KSRC" ARCH=arm64 LLVM="$LLVM" O="$KOUT" M="$HERE/$1" \
		KBUILD_EXTRA_SYMBOLS="$2" -j"$(nproc)" "$tgt"
}
SOCSYM=$TOP/bsp612/soc-repo-staging/build/Module.symvers
case $what in
btpower|all) mk btpower "$SOCSYM" ;;
esac
case $what in
btfmslim|all) [ -d "$HERE/btfmslim" ] && mk btfmslim "$SOCSYM $HERE/btpower/Module.symvers" ;;
esac
