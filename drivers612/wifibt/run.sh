#!/bin/bash
# run.sh <name> <pack.tgz> <dtb-base> '<commands in the test kernel>'   (env KX_HOLD, KX_EXTRA_TIMEOUT)
# Copy of drivers612/hwbringup/run.sh without (fixed in bsp612 2026-11-12 21:12).
cd "$(dirname "$0")/../.."
CMD='loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused a52.deadman=300 a52.net=42 '"$(cat bsp612/qcom-bootargs.txt)"
PHONE=1 HARNESS_IMG=images/a52sxq-ack618-kexec9-recovery.img KEXEC_BASE=$3 KEXEC_OVERLAY=none KX_PACK=$2 \
 KX_EXTRA_TIMEOUT=${KX_EXTRA_TIMEOUT:-150} KX_EXTRA="mkdir -p /mnt /p; mount -t ext4 -o ro /dev/sda29 /mnt; cd /p; /bin/busybox tar xzf /mnt/a52kx/pack.tgz; $4" \
 kexec/kx-cycle.sh $1 bsp612/out/dist/Image bsp612/out/bringup/ramdisk-612.cpio.gz gen "$CMD"
