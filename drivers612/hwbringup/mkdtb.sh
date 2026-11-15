#!/bin/bash
# Builds hw-full-r02.dtb = out-ack/kx/full-r02-usb.dtb + the gpu and video fragments (not yet in
# the board tree: boarddt README "gpu-video: no fragment yet"). Writes only into this directory.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); P=$(cd "$H/../.." && pwd); BSP=$P/bsp612; O=$H/dt; mkdir -p $O
mk() { # name dtsi headers...
  local n=$1 d=$2; shift 2
  { echo '/dts-v1/; /plugin/;'; for h in "$@"; do echo "#include <dt-bindings/$h>"; done; echo "#include \"$d\""; } > $O/$n.wrap.dts
  cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I$BSP/soc-repo/include -I$BSP/kernel/include -I$BSP/kernel/scripts/dtc/include-prefixes $O/$n.wrap.dts > $O/$n.pp.dtso
  dtc -@ -q -I dts -O dtb -o $O/$n.dtbo $O/$n.pp.dtso; }
mk gpu $P/drivers612/gpu-video/gpu/a52sxq-gpu.dtsi clock/qcom,gcc-sc7280.h clock/qcom,gpucc-sc7280.h interconnect/qcom,yupik.h interrupt-controller/arm-gic.h regulator/qcom,rpmh-regulator-levels.h
mk video ${VIDEO_DTSI:-$P/drivers612/gpu-video/video/a52sxq-video.dtsi}
fdtoverlay -i $P/out-ack/kx/full-r02-usb.dtb -o $H/hw-full-r02.dtb $O/gpu.dtbo $O/video.dtbo
dtc -q -I dtb -O dts -o $O/hw-full-r02.dts $H/hw-full-r02.dtb; ls -la $H/hw-full-r02.dtb
# qcom_dma_heaps probe fails with -22 on the phone's map ("qcom,secure_cdsp: Failed to find reserved
# memory region", hw1b): the board tree disables the regions but not the two heap children
# (drivers612/secure/ioncompat/a52sxq-dma-heaps.dtsi has it; boarddt does not carry it).
for n in qcom,secure_cdsp qcom,display; do fdtput -t s $H/hw-full-r02.dtb /soc/qcom,dma-heaps/$n status disabled; done
dtc -q -I dtb -O dts -o $O/hw-full-r02.dts $H/hw-full-r02.dtb

# --- audio: the board tree only has the inert 5.4 placeholder (/soc/a52sxq-todo-audio): boarddt could not
# integrate drivers612/audio/a52sxq-audio.dtsi ("dt-bindings/clock/qcom,audio-ext-clk.h: No such file",
# the headers are in audio/dtcheck/inc). hw-audio-full-r02.dtb = hw-full-r02.dtb + the audio fragment.
A=$P/drivers612/audio
printf '/dts-v1/; /plugin/;\n#include "%s/dts/yupik-audio.dtsi"\n#include "%s/a52sxq-audio.dtsi"\n' $A $A > $O/audio.wrap.dts
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I$A/dtcheck/inc -I$A -I$BSP/devicetree/qcom -I$BSP/devicetree -I$BSP/soc-repo/include -I$BSP/devicetree/bindings -I$BSP/kernel/include -I$BSP/kernel/scripts/dtc/include-prefixes $O/audio.wrap.dts > $O/audio.pp.dtso
dtc -@ -q -I dts -O dtb -o $O/audio.dtbo $O/audio.pp.dtso
fdtoverlay -i $H/hw-full-r02.dtb -o $H/hw-audio-full-r02.dtb $O/audio.dtbo
# hw6: "swrm_probe: version specified in dtsi: 0x2000000 not match with HW read version 0x1060000": the 5.4
# driver's default was SWRM_VERSION_1_6, the 6.12 techpack's default is 2.0; say 1.6 in the DT.
B=/soc/qcom,msm-audio-apr/qcom,q6core-audio/bolero-cdc
for n in rx-macro@3200000/rx_swr_master tx-macro@3220000/tx_swr_master wsa-macro@3240000/wsa_swr_master; do
  fdtput -t x $H/hw-audio-full-r02.dtb $B/$n qcom,swr-master-version 0x01060000; done
dtc -q -I dtb -O dts -o $O/hw-audio.dts $H/hw-audio-full-r02.dtb
