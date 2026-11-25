#!/bin/bash
# Build sec-battery.ko + sm5714_fuelgauge.ko with 0001 (lpcharge from /chosen/bootargs) from a COPY of
# drivers612/power (./tree, not committed; drivers612/power itself is not touched), strip like ../build.sh,
# then prove the two modules can replace the shipped ones (export/import CRCs, modinfo) -> CRC-CHECK.txt.
#   drivers612/samsung-oneui/lpm/build-power.sh [SHIPPED_MODULE_DIR]
set -euo pipefail
W=$(cd "$(dirname "$0")" && pwd); P=$(cd "$W/../../.." && pwd); PW=$P/drivers612/power
CL=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SHIPDIR=${1:-$P/drivers612/realboot/out/rbou5d/work/vr/lib/modules}
if [ ! -d "$W/tree" ]; then
	mkdir -p "$W/tree"
	rsync -a --exclude='*.o' --exclude='*.cmd' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' --exclude='.*' "$PW/src" "$PW/include" "$W/tree/"
	sed -e "s|\$(src)/../../bsp612|$P/bsp612|; s|\$(src)/../../samsung612|$P/samsung612|" "$PW/Kbuild" > "$W/tree/Kbuild"
	( cd "$W/tree" && patch -p1 < "$W/0001-sec-battery-fuelgauge-lpcharge-from-bootargs.patch" )
fi
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -s -C "$P/bsp612/kernel" ARCH=arm64 LLVM="$CL/" \
	O="$P/bsp612/out/lahaina" M="$W/tree" \
	KBUILD_EXTRA_SYMBOLS="$P/samsung612/modules/sec_core/Module.symvers $P/bsp612/soc-repo-staging/build/Module.symvers" -j20 modules
mkdir -p "$W/out"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
{
for n in sec-battery sm5714_fuelgauge; do
	k=$(find "$W/tree" -name "$n.ko" | head -1); cp "$k" "$W/out/$n.ko"
	"$CL/llvm-strip" --strip-debug "$W/out/$n.ko"
	"$CL/llvm-objcopy" --remove-section=.BTF --remove-section=.BTF.base "$W/out/$n.ko"
	NEW=$W/out/$n.ko; SHIP=$SHIPDIR/$n.ko
	echo "new $n.ko $(stat -c %s "$NEW") bytes sha256 $(sha256sum < "$NEW" | cut -c1-16) vermagic $(modinfo -F vermagic "$NEW")"
	[ -f "$SHIP" ] || { echo "  no shipped $SHIP: CRC compare skipped"; continue; }
	echo "  shipped $SHIP sha256 $(sha256sum < "$SHIP" | cut -c1-16)"
	python3 -I "$W/../ko2symvers.py" "$T/s.symvers" "$SHIP" >/dev/null; python3 -I "$W/../ko2symvers.py" "$T/n.symvers" "$NEW" >/dev/null
	diff <(cut -f1,2 "$T/s.symvers" | sort -k2) <(cut -f1,2 "$T/n.symvers" | sort -k2) >/dev/null && echo "  export CRCs: $(grep -c . "$T/n.symvers" || true) identical" || echo "  EXPORT CRC MISMATCH"
	diff <(/sbin/modprobe --dump-modversions "$SHIP" | sort) <(/sbin/modprobe --dump-modversions "$NEW" | sort) > "$T/imp.diff" && echo "  import CRCs: $(/sbin/modprobe --dump-modversions "$NEW" | wc -l) identical" || { echo "  import list differs:"; sed 's/^/    /' "$T/imp.diff"; }
	diff <(modinfo "$SHIP" | grep -v '^filename') <(modinfo "$NEW" | grep -v '^filename') >/dev/null && echo "  modinfo identical (depends=$(modinfo -F depends "$NEW"))" || echo "  MODINFO DIFFERS"
done
} 2>&1 | tee "$W/CRC-CHECK.txt"
