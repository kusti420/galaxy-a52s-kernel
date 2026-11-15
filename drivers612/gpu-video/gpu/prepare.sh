#!/bin/bash
# Recreate src/ from the read-only donor clone (donors/graphics-kernel, tag
# GRAPHICS.LA.16.1.r2-04700-LAHAINA.0, commit 1418e58) and apply patches/ in order.
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd); D=$G/../../../donors/graphics-kernel
rsync -a --delete --exclude=.git/ "$D/" "$G/src/"
for p in "$G"/patches/*.patch; do patch -d "$G/src" -p1 --batch -s < "$p"; echo "applied $(basename "$p")"; done
