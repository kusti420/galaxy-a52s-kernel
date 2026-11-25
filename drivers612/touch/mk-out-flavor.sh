#!/bin/sh
# Stripped, shippable copies of the modules changed by SPEC/05 (userspace flavour switch + charger hook):
#   touch/out-flavor/stm_ts.ko                    (after ./build.sh)
#   power/out-flavor/vbus_notifier.ko             (after ../power/build.sh)
#   samsung-oneui/a52sxq_core/out/a52sxq.ko is made by samsung-oneui/build.sh a52sxq_core
# *.ko is gitignored: SHA256SUMS in each out-flavor/ is what the repo records.
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
C=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
VM="6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64"
one() {   # <src.ko> <outdir>
	mkdir -p "$2"; n=$(basename "$1")
	"$C/llvm-strip" --strip-debug -o "$2/$n" "$1"
	[ "$(modinfo -F vermagic "$2/$n")" = "$VM" ] || { echo "bad vermagic: $2/$n"; exit 1; }
	( cd "$2" && sha256sum "$n" > SHA256SUMS.new && { grep -v " $n\$" SHA256SUMS 2>/dev/null || true; } >> SHA256SUMS.new && sort -k2 SHA256SUMS.new > SHA256SUMS && rm SHA256SUMS.new )
	echo "$2/$n $(stat -c %s "$2/$n") bytes depends=[$(modinfo -F depends "$2/$n")]"
}
one "$D/touch/src/stm_ts.ko" "$D/touch/out-flavor"
one "$D/power/src/vbus_notifier/vbus_notifier.ko" "$D/power/out-flavor"
