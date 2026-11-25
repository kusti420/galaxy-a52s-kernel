#!/bin/bash
# sdfat.ko (file system type "sdfat" forwarded to the built-in exfat / vfat) -> out-p1/sdfat.ko + SHA256SUMS.
# Built in a scratch copy (W=, default /tmp/a52sxq-p1-build: the .ko bytes depend on the build path) so the source dir stays clean; GKI vmlinux symbols only.
#   drivers612/samsung-oneui/sdfat-alias/mk.sh
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); W=${W:-/tmp/a52sxq-p1-build}/sdfat-alias; mkdir -p "$W"
cp "$D/sdfat.c" "$D/Kbuild" "$W/"
"$D/../build.sh" "$W"
mkdir -p "$D/out-p1"; cp "$W/out/sdfat.ko" "$D/out-p1/"
( cd "$D/out-p1" && sha256sum sdfat.ko > SHA256SUMS ); cat "$D/out-p1/SHA256SUMS"
