#!/bin/bash
# Regenerate dts/*.dtsi from the phone's merged 5.4 tree, compile a52sxq-display.dtsi on top of
# the 6.12 yupik.dts (cpp + dtc -@), and compare every display node with the phone's tree.
# Reads the project, writes only dts/ and a temp dir. Usage: tools/check-dts.sh
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); P=$D/../..; T=$(mktemp -d)
dtc -q -I dts -O dtb "$P/downstream-dt/a52sxq-r02.dts" -o "$T/r02.dtb" 2>/dev/null
python3 "$D/tools/gen-dts.py" "$P/downstream-dt/a52sxq-r02.dts" "$T/r02.dtb" "$D/dts"
printf '#include "yupik.dts"\n#include "%s/a52sxq-display.dtsi"\n' "$D" > "$T/test.dts"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ -I "$P/bsp612/devicetree/qcom" \
  -I "$P/bsp612/soc-repo/include" -I "$P/bsp612/kernel/include" -I "$D" -o "$T/test.pp" "$T/test.dts"
dtc -@ -q -I dts -O dtb -o "$T/test.dtb" "$T/test.pp"
python3 "$D/tools/verify-dts.py" "$T/r02.dtb" "$T/test.dtb"
rm -rf "$T"
