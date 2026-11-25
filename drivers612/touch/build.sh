#!/bin/sh
# Compile check against the shared 6.12 BSP output (read-only use of bsp612/out/lahaina).
#   ./build.sh            default since 2026-11-24: stm_ts.ko WITH the charger (VBUS) hook, bound late with
#                         symbol_get (no dependency on vbus_notifier.ko, same depends line as before)
#   VBUS=0 ./build.sh     the old module without the hook
#   ./build.sh clean
# Modules to ship: ./mk-out-flavor.sh (stripped copies + sha256 in out-flavor/).
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
HERE=$P/drivers612/touch
SYM=$P/samsung612/modules/sec_core/Module.symvers
EXTRA=
[ "${VBUS:-1}" = 1 ] || EXTRA="SEC_INPUT_VBUS=0"
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
make -C $P/bsp612/kernel ARCH=arm64 \
	LLVM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/ \
	O=$P/bsp612/out/lahaina M=$HERE/src \
	KBUILD_EXTRA_SYMBOLS="$SYM" $EXTRA \
	-j16 "${@:-modules}"
