#!/bin/bash
# SPEC/05 P1 (power): build sec-battery.ko + common_muic.ko + muic_sm5714.ko from a COPY of drivers612/power (./tree, not
# committed; nothing is written into drivers612/power or the shared bsp612 output), strip like
# drivers612/samsung-oneui/build.sh, then prove both can replace the shipped modules -> CRC-CHECK.txt.
#   drivers612/power/out-p1/build.sh [SHIPPED_MODULE_DIR]     (default: rb108 vendor ramdisk; rbou9 ships the same three files)
set -euo pipefail
W=$(cd "$(dirname "$0")" && pwd); P=$(cd "$W/../../.." && pwd); PW=$P/drivers612/power
CL=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SHIPDIR=${1:-$P/drivers612/realboot/out/rb108/work/vr/lib/modules}
mkdir -p "$W/tree"
rsync -a --delete --exclude='*.o' --exclude='*.cmd' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' --exclude='.*' "$PW/src" "$PW/include" "$W/tree/"
sed -e "s|\$(src)/../../bsp612|$P/bsp612|; s|\$(src)/../../samsung612|$P/samsung612|" "$PW/Kbuild" > "$W/tree/Kbuild"
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -s -C "$P/bsp612/kernel" ARCH=arm64 LLVM="$CL/" \
	O="$P/bsp612/out/lahaina" M="$W/tree" \
	KBUILD_EXTRA_SYMBOLS="$P/samsung612/modules/sec_core/Module.symvers $P/bsp612/soc-repo-staging/build/Module.symvers" -j20 modules
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
VM="6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64"
{
# whole power stack: the tree's Module.symvers against the one of the shipped build (drivers612/power)
if [ -f "$PW/Module.symvers" ]; then
	diff <(cut -f1,2,3 "$PW/Module.symvers" | sed "s|$PW/||" | sort -k2) <(cut -f1,2,3 "$W/tree/Module.symvers" | sed "s|$W/tree/||" | sort -k2) > "$T/sv.diff" \
		&& echo "Module.symvers (all power modules): $(grep -c . "$W/tree/Module.symvers") exports, CRC + name + module identical to drivers612/power/Module.symvers" \
		|| { echo "Module.symvers DIFFERS from drivers612/power/Module.symvers:"; sed 's/^/    /' "$T/sv.diff"; }
fi
for n in sec-battery common_muic muic_sm5714; do
	k=$(find "$W/tree" -name "$n.ko" | head -1); cp "$k" "$W/$n.ko"
	"$CL/llvm-strip" --strip-debug "$W/$n.ko"
	"$CL/llvm-objcopy" --remove-section=.BTF --remove-section=.BTF.base "$W/$n.ko"
	NEW=$W/$n.ko; SHIP=$SHIPDIR/$n.ko
	[ "$(modinfo -F vermagic "$NEW")" = "$VM" ] || { echo "bad vermagic"; exit 1; }
	echo "new $n.ko $(stat -c %s "$NEW") bytes sha256 $(sha256sum < "$NEW" | cut -d' ' -f1)"
	echo "  shipped $SHIP sha256 $(sha256sum < "$SHIP" | cut -d' ' -f1)"
	python3 -I "$P/drivers612/samsung-oneui/ko2symvers.py" "$T/s.symvers" "$SHIP" >/dev/null; python3 -I "$P/drivers612/samsung-oneui/ko2symvers.py" "$T/n.symvers" "$NEW" >/dev/null
	diff <(cut -f1,2 "$T/s.symvers" | sort -k2) <(cut -f1,2 "$T/n.symvers" | sort -k2) >/dev/null && echo "  export CRCs: $(grep -c . "$T/n.symvers" || true) of $(grep -c . "$T/s.symvers" || true) identical" || echo "  EXPORT CRC MISMATCH"
	diff <(/sbin/modprobe --dump-modversions "$SHIP" | sort) <(/sbin/modprobe --dump-modversions "$NEW" | sort) > "$T/imp.diff" && echo "  import CRCs: $(/sbin/modprobe --dump-modversions "$NEW" | wc -l) identical" || { echo "  import list: $(/sbin/modprobe --dump-modversions "$SHIP" | wc -l) shipped, $(/sbin/modprobe --dump-modversions "$NEW" | wc -l) new; differences:"; sed 's/^/    /' "$T/imp.diff"; }
	# every new import must be a vmlinux (GKI) export with the same CRC, or an export of a module already in depends
	while read -r crc sym; do
		grep -q "^$(printf '0x%08x' "$crc")	$sym	vmlinux" "$P/bsp612/out/lahaina/Module.symvers" || echo "    NOT a vmlinux export with this CRC: $sym"
	done < <(grep '^>' "$T/imp.diff" | sed 's/^> //')
	diff <(modinfo "$SHIP" | grep -v '^filename') <(modinfo "$NEW" | grep -v '^filename') >/dev/null && echo "  modinfo identical (depends=$(modinfo -F depends "$NEW"))" || echo "  MODINFO DIFFERS"
	# consumers in the shipped first-stage set: their imported CRCs against the new module's exports
	c=0; bad=0
	for o in "$SHIPDIR"/*.ko; do
		[ "$(basename "$o")" = "$n.ko" ] && continue
		while read -r crc sym; do
			e=$(awk -v s="$sym" '$2==s{print $1}' "$T/n.symvers"); [ -n "$e" ] || continue
			c=$((c+1)); [ "$(printf '0x%08x' "$crc")" = "$e" ] || { echo "    MISMATCH $(basename "$o") $sym"; bad=$((bad+1)); }
		done < <(/sbin/modprobe --dump-modversions "$o" 2>/dev/null)
	done
	echo "  consumers in $(basename "$(dirname "$(dirname "$(dirname "$(dirname "$SHIPDIR")")")")"): $c imported CRCs checked against the new $n.ko, $bad mismatches"
done
} 2>&1 | tee "$W/CRC-CHECK.txt"
( cd "$W" && sha256sum sec-battery.ko common_muic.ko muic_sm5714.ko > SHA256SUMS )
