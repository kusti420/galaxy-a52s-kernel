#!/bin/sh
# syntax/compile check of a52sxq-camera.dtsi as an overlay (unresolved external labels become __fixups__)
set -e
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
W=$P/drivers612/camera/dt-work
DTC=$P/bsp612/out/lahaina/scripts/dtc/dtc
printf '/dts-v1/;\n/plugin/;\n#include "a52sxq-camera.dtsi"\n' > $W/check-overlay.dts
cpp -nostdinc -undef -x assembler-with-cpp -P -I $P/drivers612/camera \
    -I $P/bsp612/soc-repo/include -I $P/bsp612/kernel/include $W/check-overlay.dts > $W/check-overlay.pp.dts
$DTC -@ -I dts -O dtb -o $W/check-overlay.dtbo $W/check-overlay.pp.dts
$DTC -I dtb -O dts -o $W/check-overlay.decomp.dts $W/check-overlay.dtbo 2>/dev/null
echo "dtc OK: $(stat -c %s $W/check-overlay.dtbo) bytes"
