#!/bin/sh
# Builds a52sxq-nfc.dtsi as an overlay, applies it with fdtoverlay onto the Android-on-6.12
# board tree (default out-ack/kx/android-r02.dtb; BASE=<dtb> to use another) and checks
# (dt-compare.py):
#   1. sec-nfc@27, the PVDD fixed regulator and the NFC/LDO pin states equal the phone's
#      (downstream-dt/a52sxq-r02.dts), property by property (phandles compared by target path);
#   2. i2c@a84000 okay with the phone's sleep pins, spi@a84000 disabled, no other live child;
#   3. TLMM 36..42 not TZ-reserved and claimed by no other enabled node.
# Output in dt-work/ (overlay .dtbo, merged .dtb). Read-only on everything outside this directory.
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
H=$P/drivers612/nfc
W=$H/dt-work
BASE=${BASE:-$P/out-ack/kx/android-r02.dtb}
DTC=$P/bsp612/out/lahaina/scripts/dtc/dtc
mkdir -p "$W"
printf '/dts-v1/;\n/plugin/;\n#include "a52sxq-nfc.dtsi"\n' > "$W/nfc-overlay.dts"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I "$H" \
    -I "$P/bsp612/kernel/include" -I "$P/bsp612/kernel/scripts/dtc/include-prefixes" \
    "$W/nfc-overlay.dts" > "$W/nfc-overlay.pp.dts"
$DTC -@ -q -I dts -O dtb -o "$W/a52sxq-nfc.dtbo" "$W/nfc-overlay.pp.dts"
fdtoverlay -i "$BASE" -o "$W/merged.dtb" "$W/a52sxq-nfc.dtbo"
echo "overlay OK: $(stat -c %s "$W/a52sxq-nfc.dtbo") bytes -> $W/merged.dtb"
# the phone's tree as a dtb (decompiled source; phandles are numeric there)
[ "$W/phone-r02.dtb" -nt "$P/downstream-dt/a52sxq-r02.dts" ] ||
	$DTC -q -I dts -O dtb -o "$W/phone-r02.dtb" "$P/downstream-dt/a52sxq-r02.dts"
exec python3 -I "$H/dt-compare.py" "$W/phone-r02.dtb" "$W/merged.dtb"
