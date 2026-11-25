#!/bin/bash
# s99u = s99tb (rbou5d's ramdisk) + lpm: sec-battery.ko and sm5714_fuelgauge.ko swapped for the ones with
# lpm/0001 (lpcharge from /chosen/bootargs) + a52sxq_lpm_nodes.ko appended to stage vibrator.
# Usage: drivers612/samsung-oneui/lpm/mk-s99u.sh   -> drivers612/androidboot/out/s99u-rd.cpio.gz
set -euo pipefail
TOP=$(cd "$(dirname "$0")/../../.." && pwd); O=$TOP/drivers612/samsung-oneui; R=$TOP/drivers612/androidboot/out
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I "$TOP/drivers612/realboot/tools/rd-swap-ko.py" "$R/s99tb-rd.cpio.gz" "$T/a.cpio.gz" "$O/lpm/out/sec-battery.ko" "$O/lpm/out/sm5714_fuelgauge.ko"
python3 -I "$O/rd-add-ko.py" "$T/a.cpio.gz" "${OUT:-$R/s99u-rd.cpio.gz}" vibrator "$O/lpm/out/a52sxq_lpm_nodes.ko"
sha256sum "${OUT:-$R/s99u-rd.cpio.gz}"
