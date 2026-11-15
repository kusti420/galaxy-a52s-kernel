#!/bin/bash
# Everything the 6.18 Android kexec test needs, offline, in order:
#   [build]  bsp618/port/build618.sh (only with BUILD=1; PORT_ARGS=--fresh for a clean tree)
#   dist     mkdist-618.sh       out/dist: Image + modules + modules.dep + first-stage list
#   rd       mkramdisk-618.sh    out/bringup/ramdisk-618.cpio.gz (first stage, 6.12 order)
#   stages   mkstages-618.py     stage-618/<name>/ (every 6.12 stage, 6.18 .ko, same load.list)
#   dtb      mkdtb-618.sh        out/android-r02-618.dtb (6.12 android tree + a52ram reservation)
#   pack     pack-kexec-rd-618.sh <name>   out/<name>-rd.cpio.gz (+ insmod simulation)
# Usage: bsp618/android/build-android-618.sh <name>      e.g. a1
# Prints the kx-cycle line for the main session at the end. Nothing is flashed or run on a phone.
set -euo pipefail
A=$(cd "$(dirname "$0")" && pwd); B=$(dirname "$A"); TOP=$(dirname "$B")
NAME=${1:?name}
[ "${BUILD:-0}" = 1 ] && "$B/port/build618.sh"
"$A/mkdist-618.sh"
"$A/mkramdisk-618.sh"
python3 -I "$A/mkstages-618.py"
"$A/mkdtb-618.sh"
"$A/pack-kexec-rd-618.sh" "$NAME"
cat <<EOF

kx-cycle (PHONE=2 = PHONE2, the cmdline file carries its serial/bootloader):
cd $TOP && R=bsp618/android; PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img \\
  KEXEC_BASE=\$R/out/android-r02-618.dtb KEXEC_OVERLAY=none KX_HOLD=1 kexec/kx-cycle.sh ab618-$NAME \\
  \$R/out/dist/Image \$R/out/$NAME-rd.cpio.gz gen "\$(cat \$R/android-cmdline-618.txt) log_buf_len=4M \\
  a52.mods=debug,secure,display,kgsl,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,audio@adsp,wlan@adsp"
EOF
