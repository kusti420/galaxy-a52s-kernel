#!/bin/sh
# Compile check of ../../a52sxq-conn.dtsi on top of the 6.12 yupik base.
# Reads bsp612 (devicetree, soc-repo/include, kernel/include); writes only here.
# usage: ./check.sh [-DA52SXQ_CONN_NO_WLAN] [-DA52SXQ_CONN_NO_BT]
P=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)
D=$(cd "$(dirname "$0")" && pwd)
C=$P/drivers612/conn
cat > $D/test.dts <<EOT
/dts-v1/;
#include "yupik.dtsi"
#include "yupik-idp.dtsi"
/ { model = "a52sxq conn fragment compile check"; compatible = "qcom,yupik"; qcom,board-id = <0 0>; };
#include "a52sxq-conn.dtsi"
EOT
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp "$@" \
  -I $C -I $P/bsp612/devicetree/qcom -I $P/bsp612/devicetree \
  -I $P/bsp612/soc-repo/include -I $P/bsp612/kernel/include \
  -I $P/bsp612/kernel/scripts/dtc/include-prefixes \
  $D/test.dts -o $D/test.pp.dts || exit 1
dtc -@ -q -I dts -O dtb -o $D/test.dtb $D/test.pp.dts || exit 1
dtc -q -I dtb -O dts -o $D/test.out.dts $D/test.dtb
echo "OK: $(stat -c %s $D/test.dtb) bytes"
