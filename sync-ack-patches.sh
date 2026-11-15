#!/bin/sh
# Copies our changes in the (untracked) ack/ kernel clone into patches/ack-6.18/ so they are
# versioned with the rest of the project. Run before every commit that touched ack/.
set -e
cd "$(dirname "$0")"
git -C ack diff > patches/ack-6.18/0001-a52sxq-tracked-changes.diff
cp ack/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dts ack/arch/arm64/configs/a52sxq_gki.fragment patches/ack-6.18/
