#!/bin/sh
# Build the COPY of drivers612/power in ./tree (same make line as drivers612/power/build.sh, M= the copy),
# then strip the replaced module(s) like drivers612/samsung-oneui/build.sh into ./out.
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
W=$(cd "$(dirname "$0")" && pwd)
CL=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -s -C $P/bsp612/kernel ARCH=arm64 \
 LLVM=$CL/ O=$P/bsp612/out/lahaina M=$W/tree \
 KBUILD_EXTRA_SYMBOLS="$P/samsung612/modules/sec_core/Module.symvers $P/bsp612/soc-repo-staging/build/Module.symvers" -j20 "$@" modules
mkdir -p $W/out
for n in sec-battery; do
	cp $W/tree/$n.ko $W/out/$n.ko
	$CL/llvm-strip --strip-debug $W/out/$n.ko
	$CL/llvm-objcopy --remove-section=.BTF --remove-section=.BTF.base $W/out/$n.ko
	vm=$(modinfo -F vermagic $W/out/$n.ko)
	[ "$vm" = "6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64" ] || { echo "bad vermagic $vm"; exit 1; }
	echo "$W/out/$n.ko $(stat -c %s $W/out/$n.ko) bytes sha256 $(sha256sum < $W/out/$n.ko | cut -c1-16)"
done
