#!/bin/bash
# a52sxq_sd_ioerror.ko -> out-p1/ + SHA256SUMS. Scratch-copy build (W=, default /tmp/a52sxq-p1-build: the .ko bytes depend on the build path); imports GKI vmlinux + sec_core (sec_dev_get_by_name).
#   drivers612/samsung-oneui/sd_ioerror/mk.sh
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); W=${W:-/tmp/a52sxq-p1-build}/sd_ioerror; mkdir -p "$W"
cp "$D/a52sxq_sd_ioerror.c" "$D/Kbuild" "$W/"
EXTRA_SYMVERS="$D/sec_core.symvers" "$D/../build.sh" "$W"
mkdir -p "$D/out-p1"; cp "$W/out/a52sxq_sd_ioerror.ko" "$D/out-p1/"
( cd "$D/out-p1" && sha256sum a52sxq_sd_ioerror.ko > SHA256SUMS ); cat "$D/out-p1/SHA256SUMS"
