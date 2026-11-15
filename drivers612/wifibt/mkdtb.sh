#!/bin/bash
# mkdtb.sh: wifibt-r02.dtb = drivers612/hwbringup/hw-audio-full-r02.dtb + the Wi-Fi part of the
# conn fragment (our copy a52sxq-conn-wifibt.dtsi: clock-header fix + guards), applied as an
# overlay the way drivers612/hwbringup/mkdtb.sh applies fragments. Writes only into this directory.
#   - check: the copy (modem, IPA, icnss2, glinkpkt, hsuart; not BT/aliases: overlays cannot
#     resolve labels in /aliases) must compile as an overlay
#     (proves the clock-header fix); it is NOT applied.
#   - applied: icnss2 node + soc-wake smp2p entries + &wpss_pas firmware-name "wpss.mdt" only.
#     Not applied on purpose: &modem_pas (the modem must not start), IPA, glinkpkt smd4, the SE5
#     hsuart (the board tree already has it, with the same labels), the BT node (the board tree
#     already has bt_wcn6750 with the phone's values; overlays cannot delete properties).
#   - fdtput: BT UART RX (gpio31) default state pull-DOWN as on the phone (bt-node.dtsi).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); P=$(cd "$H/../.." && pwd); BSP=$P/bsp612; O=$H/dt; mkdir -p $O
BASE=${BASE:-$P/drivers612/hwbringup/hw-audio-full-r02.dtb}
INC="-I$P/drivers612/conn -I$BSP/devicetree/qcom -I$BSP/devicetree -I$BSP/soc-repo/include -I$BSP/kernel/include -I$BSP/kernel/scripts/dtc/include-prefixes"
mk() { # name defines...
  local n=$1; shift
  printf '/dts-v1/; /plugin/;\n#include "%s/a52sxq-conn-wifibt.dtsi"\n' $H > $O/$n.wrap.dts
  cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P "$@" $INC $O/$n.wrap.dts > $O/$n.pp.dtso
  dtc -@ -q -I dts -O dtb -o $O/$n.dtbo $O/$n.pp.dtso; }
mk conn-full -DA52SXQ_CONN_NO_ALIASES -DA52SXQ_CONN_NO_BT && echo "check: conn copy (all but BT, which has an alias) compiles as overlay ($(stat -c %s $O/conn-full.dtbo) bytes)"
mk wlan -DA52SXQ_CONN_NO_MODEM -DA52SXQ_CONN_NO_IPA -DA52SXQ_CONN_NO_GLINKPKT -DA52SXQ_CONN_NO_HSUART -DA52SXQ_CONN_NO_BT
fdtoverlay -i $BASE -o $H/wifibt-r02.dtb $O/wlan.dtbo
R=/soc/pinctrl@f000000/qupv3_se7_4uart_pins/qupv3_se7_default_rx/config
fdtput -d $H/wifibt-r02.dtb $R bias-pull-up
fdtput $H/wifibt-r02.dtb $R bias-pull-down   # no value = empty (boolean) property
dtc -q -I dtb -O dts -o $O/wifibt-r02.dts $H/wifibt-r02.dtb
ls -la $H/wifibt-r02.dtb
