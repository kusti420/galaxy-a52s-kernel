#!/bin/sh
# Compile check against the shared 6.12 BSP output (read-only use of bsp612/out/lahaina).
#   ./build.sh            default: no VBUS notifier (stm_ts.ko has no dependency on drivers612/power)
#   VBUS=1 ./build.sh     stm_ts.ko registers with vbus_notifier.ko from drivers612/power
#   ./build.sh clean
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
HERE=$P/drivers612/touch
SYM=$P/samsung612/modules/sec_core/Module.symvers
EXTRA=
if [ "$VBUS" = 1 ]; then
	SYM="$SYM $P/drivers612/power/Module.symvers"
	EXTRA="SEC_INPUT_VBUS=1 SEC_INPUT_VBUS_INC=$P/drivers612/power/include"
fi
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
make -C $P/bsp612/kernel ARCH=arm64 \
	LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/ \
	O=$P/bsp612/out/lahaina M=$HERE/src \
	KBUILD_EXTRA_SYMBOLS="$SYM" $EXTRA \
	-j16 "${@:-modules}"
