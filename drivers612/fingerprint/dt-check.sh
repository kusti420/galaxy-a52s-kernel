#!/bin/sh
# Builds a52sxq-fingerprint.dtsi as an overlay, applies it with fdtoverlay onto the Android-on-6.12
# board tree (default out-ack/kx/android-r02.dtb; BASE=<dtb> to use another) and checks:
#   1. the merged /soc/etspi,et7xx node equals the phone's (downstream-dt/a52sxq-r02.dts),
#      property by property (phandles compared by target path), plus the one new property;
#   2. the et7xx_rst pin state and L3C equal the phone's;
#   3. the TrustZone-owned SPI engine is left alone: spi@a98000 / i2c@a98000 disabled,
#      TLMM 56..59 in qcom,gpios-reserved.
# Output in dt-work/ (overlay .dtbo, merged .dtb). Read-only on everything outside this directory.
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
H=$P/drivers612/fingerprint
W=$H/dt-work
BASE=${BASE:-$P/out-ack/kx/android-r02.dtb}
DTC=$P/bsp612/out/lahaina/scripts/dtc/dtc
mkdir -p "$W"
printf '/dts-v1/;\n/plugin/;\n#include "a52sxq-fingerprint.dtsi"\n' > "$W/fp-overlay.dts"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I "$H" \
    -I "$P/bsp612/kernel/include" -I "$P/bsp612/kernel/scripts/dtc/include-prefixes" \
    "$W/fp-overlay.dts" > "$W/fp-overlay.pp.dts"
$DTC -@ -q -I dts -O dtb -o "$W/a52sxq-fingerprint.dtbo" "$W/fp-overlay.pp.dts"
fdtoverlay -i "$BASE" -o "$W/merged.dtb" "$W/a52sxq-fingerprint.dtbo"
echo "overlay OK: $(stat -c %s "$W/a52sxq-fingerprint.dtbo") bytes -> $W/merged.dtb"
# the phone's tree as a dtb (decompiled source; phandles are numeric there)
[ "$W/phone-r02.dtb" -nt "$P/downstream-dt/a52sxq-r02.dts" ] ||
	$DTC -q -I dts -O dtb -o "$W/phone-r02.dtb" "$P/downstream-dt/a52sxq-r02.dts"
exec python3 -I "$H/dt-compare.py" "$W/phone-r02.dtb" "$W/merged.dtb"
