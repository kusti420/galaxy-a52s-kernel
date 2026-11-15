#!/bin/bash
# Step 4 check: can the stock Samsung dtbo apply on the 6.12 yupik base? Writes out/dt-compare.txt.
# Reads only: the stock dtbo of the test phone, the 5.4 base dts, our yupik.dtb.
set -euo pipefail
BSP=$(cd "$(dirname "$0")/.." && pwd); P=$BSP/..
W=$BSP/out/dtcompare; mkdir -p "$W"
mkdtboimg dump "$P/testdev-PHONE1/dtbo.img" -b "$W/stock-dtbo" > "$W/stock-dtbo.info"
for i in 0 1 2; do dtc -q -I dtb -O dts -o "$W/stock-ovl$i.dts" "$W/stock-dtbo.$i"; done
dtc -q -I dtb -O dts -o "$W/yupik612.dts" "$BSP/out/dist/dtb/yupik.dtb"
( cd "$W" && python3 -I "$BSP/tools/dtcompare.py" "$P/downstream-dt/yupik-base.dts" yupik612.dts stock-ovl0.dts stock-ovl1.dts stock-ovl2.dts ) \
  | sed "s|$P/||" > "$BSP/out/dt-compare.txt"
grep -E '^==|MISSING in|different path|path /' "$BSP/out/dt-compare.txt"
