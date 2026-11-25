#!/bin/bash
# Offline checks of out/input_booster.ko (run after build.sh):
#  - vermagic, depends
#  - no GOT relocations (R_AARCH64_*GOT*: the 6.12 arm64 module loader rejects them -> insmod fails)
#  - every undefined symbol is exported by GKI vmlinux (lahaina Module.symvers) or weak (set_freq_limit)
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$D/../../.." && pwd)
K=$D/out/input_booster.ko
B=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
fail=0
echo "vermagic: $(modinfo -F vermagic "$K")"; echo "depends:  $(modinfo -F depends "$K")"
if "$B/llvm-readelf" -r "$K" | grep -q 'GOT'; then echo "FAIL: GOT relocation present"; fail=1; else echo "ok: no GOT relocations"; fi
while read -r t s; do
	if [ "$t" = w ]; then echo "weak: $s"; continue; fi
	grep -qP "\t$s\t" "$TOP/bsp612/out/lahaina/Module.symvers" || { echo "FAIL: $s not exported by GKI"; fail=1; }
done < <("$B/llvm-nm" -u "$K" | awk '{print $1, $2}')
[ $fail = 0 ] && echo "ALL OK"
exit $fail
