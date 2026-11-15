#!/bin/bash
# DT compile check of a52sxq-audio.dtsi on the 6.12 yupik base. Output: dtcheck/out.dtb + dtcheck.log
H=$(cd "$(dirname "$0")" && pwd); P=$(cd "$H/../../.." && pwd); B=$P/bsp612
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I"$H/inc" -I"$B/devicetree/qcom" -I"$B/devicetree" \
  -I"$B/soc-repo/include" -I"$B/devicetree/bindings" -I"$B/kernel/include" -I"$B/kernel/scripts/dtc/include-prefixes" "$H/a52sxq-audio-check.dts" -o "$H/pp.dts" 2> "$H/dtcheck.log" \
 && dtc -@ -I dts -O dtb -o "$H/out.dtb" "$H/pp.dts" >> "$H/dtcheck.log" 2>&1
echo "rc=$?"; grep -v 'Warning' "$H/dtcheck.log" | head -20
