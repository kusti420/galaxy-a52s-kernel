#!/bin/bash
# run-m1.sh <name>: kernel-only modem test M1 on PHONE 1 (PHONE1) through the kexec chain.
# Same flow as drivers612/wifibt/run.sh (harness kexec9 on recovery, 6.12 GKI by kexec, pack on
# /cache/a52kx, busybox shell), with the modem tree and pack from ./build.sh.
# NOT run by the agent that wrote it (no phone access). Read README.md "Test plan" first.
# Env: KX_HOLD=1 keeps the 6.12 kernel up afterwards; M1_ARGS (default "100") = m1.sh arguments
# (M2-K: M1_ARGS="120 m2 therm", README section 10; radio/data: M1_ARGS="150 m2 nas" or
# "200 m2 nas data", README section 12). The dead-man (a52.deadman, from the ramdisk's "ready")
# and the telnet timeout of the extra command grow with the mode: 420/360 s, nas 900/840 s,
# data 1500/1440 s (M1_DEADMAN / KX_EXTRA_TIMEOUT override). M1_ARGS="200 m2 data probe" runs
# the data-probe (DPM/endpoint variants, README section 12) instead of the single data call.
set -eu
cd "$(dirname "$0")/../.."
M=drivers612/modem/out
[ -f $M/pack-modem.tgz ] && [ -f $M/android-modem-r02.dtb ] || { echo "run drivers612/modem/build.sh first"; exit 1; }
case " ${M1_ARGS:-100} " in *" data "*) DM=1500 XT=1440;; *" nas "*) DM=900 XT=840;; *) DM=420 XT=360;; esac
DM=${M1_DEADMAN:-$DM}; XT=${KX_EXTRA_TIMEOUT:-$XT}
[ "$XT" -lt "$DM" ] || { echo "KX_EXTRA_TIMEOUT ($XT) must be below the dead-man ($DM)"; exit 1; }
echo "run-m1: M1_ARGS='${M1_ARGS:-100}' a52.deadman=$DM extra-timeout=$XT"
CMD='loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused a52.deadman='$DM' a52.net=42 '"$(cat bsp612/qcom-bootargs.txt)"
PHONE=1 HARNESS_IMG=images/a52sxq-ack618-kexec9-recovery.img KEXEC_BASE=$M/android-modem-r02.dtb KEXEC_OVERLAY=none \
 KX_PACK=$M/pack-modem.tgz KX_EXTRA_TIMEOUT=$XT \
 KX_EXTRA="mkdir -p /mnt /p; mount -t ext4 -o ro /dev/sda29 /mnt; cd /p; /bin/busybox tar xzf /mnt/a52kx/pack.tgz; sh /p/all.sh ${M1_ARGS:-100}" \
 kexec/kx-cycle.sh "${1:?name}" bsp612/out/dist/Image bsp612/out/bringup/ramdisk-612.cpio.gz gen "$CMD"
