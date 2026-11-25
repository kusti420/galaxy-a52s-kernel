#!/bin/bash
# a52sxq_usb_moisture.ko -> out-p1/ + SHA256SUMS. Scratch-copy build (W=, default /tmp/a52sxq-p1-build: the .ko bytes depend on the build path); imports GKI vmlinux + pdic_notifier_module
# (get_pdic_device, pdic_notifier_register/unregister: CRCs in pdic.symvers, a snapshot of drivers612/power/Module.symvers).
# Headers: drivers612/power/include (read only).
#   drivers612/samsung-oneui/usb_moisture/mk.sh
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$D/../../.." && pwd); W=${W:-/tmp/a52sxq-p1-build}/usb_moisture; mkdir -p "$W"
cp "$D/a52sxq_usb_moisture.c" "$D/Kbuild" "$W/"
A52_POWER=$TOP/drivers612/power EXTRA_SYMVERS="$D/pdic.symvers" "$D/../build.sh" "$W"
mkdir -p "$D/out-p1"; cp "$W/out/a52sxq_usb_moisture.ko" "$D/out-p1/"
( cd "$D/out-p1" && sha256sum a52sxq_usb_moisture.ko > SHA256SUMS ); cat "$D/out-p1/SHA256SUMS"
