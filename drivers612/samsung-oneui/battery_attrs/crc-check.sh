#!/bin/bash
# crc-check.sh: proof that out/sec-battery.ko can replace the shipped one (writes crc/CRC-CHECK.txt)
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); T=${A52SXQ_ROOT:?set A52SXQ_ROOT to the repo root}/; F=$T/drivers612/realboot/out/rbou3/work/vr/lib/modules
SHIP=$F/sec-battery.ko; NEW=$H/out/sec-battery.ko; C=$H/crc; mkdir -p "$C"
{
echo "shipped: $SHIP sha256 $(sha256sum < "$SHIP" | cut -c1-16) (the BTF-stripped copy in the vendor ramdisk of rbou3 + rbich45; = drivers612/power/sec-battery.ko --strip-debug + .BTF removed; rbich45 plan/first copy = same + .BTF, same CRCs)"
echo "new:     $NEW $(stat -c %s "$NEW") bytes sha256 $(sha256sum < "$NEW" | cut -c1-16)"
python3 -I "$T/drivers612/samsung-oneui/ko2symvers.py" "$C/shipped.symvers" "$SHIP" >/dev/null
python3 -I "$T/drivers612/samsung-oneui/ko2symvers.py" "$C/new.symvers" "$NEW" >/dev/null
diff <(cut -f1,2 "$C/shipped.symvers" | sort -k2) <(cut -f1,2 "$C/new.symvers" | sort -k2) && echo "EXPORT CRCs: $(grep -c . "$C/new.symvers") of $(grep -c . "$C/shipped.symvers") identical"
diff <(/sbin/modprobe --dump-modversions "$SHIP" | sort) <(/sbin/modprobe --dump-modversions "$NEW" | sort) && echo "IMPORT CRCs (__versions): $(/sbin/modprobe --dump-modversions "$NEW" | wc -l) identical"
diff <(modinfo "$SHIP" | grep -v '^filename') <(modinfo "$NEW" | grep -v '^filename') && echo "modinfo identical: $(modinfo -F vermagic "$NEW") | depends=$(modinfo -F depends "$NEW")"
n=0; bad=0
for k in "$F"/*.ko; do
	[ "$(basename "$k")" = sec-battery.ko ] && continue
	while read -r crc sym; do
		e=$(awk -v s="$sym" '$2==s{print $1}' "$C/new.symvers"); [ -n "$e" ] || continue
		n=$((n+1)); [ "$(printf '0x%08x' "$crc")" = "$e" ] || { echo "MISMATCH $(basename "$k") $sym $crc vs $e"; bad=$((bad+1)); }
	done < <(/sbin/modprobe --dump-modversions "$k" 2>/dev/null)
done
echo "first-stage consumers of sec-battery exports: $n imported CRCs checked against the new module, $bad mismatches"
echo "sections: .BTF=$(llvm-readelf -SW "$NEW" 2>/dev/null | grep -c ' \.BTF' || true) .debug_*=$(llvm-readelf -SW "$NEW" 2>/dev/null | grep -c ' \.debug_' || true)"
python3 -I "$H/attrtable.py" "$NEW"
} 2>&1 | tee "$C/CRC-CHECK.txt"
