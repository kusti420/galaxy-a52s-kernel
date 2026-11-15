#!/bin/bash
# Compile a52sxq-gpu.dtsi as an overlay, apply it on the 6.12 yupik base and compare the result
# with the device tree the phone boots on 5.4 (downstream-dt/a52sxq-r02.dts). Reads only.
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd); P=$(cd "$G/../../.." && pwd); BSP=$P/bsp612; O=$G/out; mkdir -p "$O"
{ echo '/dts-v1/; /plugin/;'
  for h in clock/qcom,gcc-sc7280.h clock/qcom,gpucc-sc7280.h interconnect/qcom,yupik.h \
           interrupt-controller/arm-gic.h regulator/qcom,rpmh-regulator-levels.h; do echo "#include <dt-bindings/$h>"; done
  echo "#include \"$G/a52sxq-gpu.dtsi\""; } > "$O/wrap.dts"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I"$BSP/soc-repo/include" -I"$BSP/kernel/include" \
    "$O/wrap.dts" > "$O/a52sxq-gpu.pp.dtso"
dtc -@ -q -I dts -O dtb -o "$O/a52sxq-gpu.dtbo" "$O/a52sxq-gpu.pp.dtso"
fdtoverlay -i "$BSP/out/dist/dtb/yupik.dtb" -o "$O/yupik+gpu.dtb" "$O/a52sxq-gpu.dtbo"
dtc -q -I dts -O dtb -o "$O/phone-r02.dtb" "$P/downstream-dt/a52sxq-r02.dts"
python3 "$G/../tools/dtcmp.py" "$O/yupik+gpu.dtb" "$O/phone-r02.dtb" \
  /soc/qcom,kgsl-3d0@3d00000 /soc/qcom,kgsl-iommu@3da0000 /soc/qcom,gmu@3d69000 \
  /soc/kgsl-smmu@3da0000 /reserved-memory/gpu_micro_code@8b71a000 | tee "$O/dt-compare.txt"
