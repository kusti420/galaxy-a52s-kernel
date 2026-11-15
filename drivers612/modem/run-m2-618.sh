#!/bin/bash
# run-m2-618.sh <name>: kernel-only modem test M2-K on the 6.18 kernel, PHONE 1 (PHONE1),
# through the kexec chain. The 6.18 counterpart of run-m1.sh (README section 11): 6.18 dist Image
# (= the a8 package's), 6.18 bring-up ramdisk (bsp612/ramdisk/init + the 6.18 first stage), the
# 6.18 pack and modem tree from ./build-618.sh, the 6.18 kernel-only cmdline. Same harness, same
# pack layout and the same m1.sh as the passing 6.12 run kx-m2k-p1-p1-192337.
# NOT run by the agent that wrote it (no phone access).
# Env: M1_ARGS (default "120 m2 therm" = the 6.12 M2-K run; radio/data: "150 m2 nas",
# "200 m2 nas data", "200 m2 data probe", README section 12: dead-man 900/1500 s via
# cmdline-m2{nas,data}-618.txt, extra timeout 840/1440 s), KX_HOLD=1 keeps 6.18 up afterwards.
set -eu
cd "$(dirname "$0")/../.."
M=drivers612/modem/out-618
[ -f $M/inputs.sha256 ] || { echo "run drivers612/modem/build-618.sh first"; exit 1; }
sha256sum --quiet -c $M/inputs.sha256 || { echo "inputs changed since build-618.sh checked them: run it again"; exit 1; }
A="${M1_ARGS:-120 m2 therm}"
case " $A " in *" data "*) CL=cmdline-m2data-618.txt XT=1440;; *" nas "*) CL=cmdline-m2nas-618.txt XT=840;; *) CL=cmdline-m2-618.txt XT=360;; esac
XT=${KX_EXTRA_TIMEOUT:-$XT}
echo "run-m2-618: M1_ARGS='$A' cmdline $CL ($(grep -o 'a52\.deadman=[0-9]*' $M/$CL)) extra-timeout=$XT"
PHONE=1 HARNESS_IMG=images/a52sxq-ack618-kexec9-recovery.img KEXEC_BASE=$M/android-modem-r02-618.dtb KEXEC_OVERLAY=none \
 KX_PACK=$M/pack-modem-618.tgz KX_EXTRA_TIMEOUT=$XT \
 KX_EXTRA="mkdir -p /mnt /p; mount -t ext4 -o ro /dev/sda29 /mnt; cd /p; /bin/busybox tar xzf /mnt/a52kx/pack.tgz; sh /p/all.sh $A" \
 kexec/kx-cycle.sh "${1:?name}" bsp618/android/out/dist/Image bsp618/android/out/bringup/ramdisk-618.cpio.gz gen "$(cat $M/$CL)"
