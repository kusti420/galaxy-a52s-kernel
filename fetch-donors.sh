#!/bin/sh
# Shallow clones of the donor trees named in research/source-scout.md. Reference source only:
# nothing in donors/ is built or run from here.
cd "$(dirname "$0")/donors" || exit 1
C=https://git.codelinaro.org/clo/la
V=$C/platform/vendor
get() {
  [ -d "$1" ] || git clone -q --depth 1 --branch "$3" "$2" "$1" 2>&1 | tail -2
  echo "$1: $(git -C "$1" log --oneline -1 2>&1 | cut -c1-70) [$(du -sh "$1" 2>/dev/null | cut -f1)]"
}
get redwood-6.12 https://github.com/suvojeet-sengupta/redwood-6.12 main
get clo-kernel-6.12 $C/kernel/qcom.git kernel.lnx.6.12.r70-rel
get clo-devicetree-6.12 $V/qcom-opensource/devicetree.git kernel.lnx.6.12.r70-rel
get camera-kernel $V/opensource/camera-kernel.git camera-kernel.lnx.4.4.r1-rel
get display-drivers $V/opensource/display-drivers.git display-kernel.lnx.1.11.r7-rel
get mm-drivers $V/opensource/mm-drivers.git display-kernel.lnx.1.11.r7-rel
get graphics-kernel $V/qcom/opensource/graphics-kernel.git GRAPHICS.LA.16.1.r2-04700-LAHAINA.0
get audio-kernel $V/opensource/audio-kernel.git audio-kernel-legacy.lnx.6.12.r1-rel
get securemsm-kernel $V/qcom/opensource/securemsm-kernel.git sec-kernel.lnx.14.16.r27-rel
get dataipa $V/opensource/dataipa.git data-kernel.lnx.5.0.r30-rel
get datarmnet $V/qcom/opensource/datarmnet.git data-kernel.lnx.5.0.r30-rel
get datarmnet-ext $V/qcom/opensource/datarmnet-ext.git data-kernel.lnx.5.0.r30-rel
get qcom-linux-6.18 https://github.com/qualcomm-linux/kernel qcom-6.18.y
