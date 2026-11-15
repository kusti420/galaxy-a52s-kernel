#!/bin/bash
# Watchdog unit experiments on test phone 2 (a52.wdt=0 image `wdtexp-p2` must exist).
# Usage: tools/wdtexp.sh "<bark> <bite>" ...   (decimal, raw SET_TIME units). Arms the hypervisor
# watchdog by hand, pets once, then logs a line to kmsg every 0.2 s so that the last timestamp in
# the crash log tells when the reset came. Results: logs/wdtexp-summary.txt
cd "$(dirname "$0")/.."
for pair in "$@"; do
  timeout 240 adb -s PHONE2 wait-for-device; adb -s PHONE2 shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
  set -- $pair; BARK=$(printf %x "$1"); BITE=$(printf %x "$2")
  PHONE=2 EXTRA_TIMEOUT=75 EXTRA='insmod /hhwdt.ko; R=/sys/module/hhwdt/parameters/raw; echo "8 '$BARK' ffff" > $R; echo "8 ffff '$BITE'" > $R; echo "5 3 0" > $R; echo "7 0 0" > $R; echo "a52sxq-init: wdtexp armed" > /dev/kmsg; i=0; while [ $i -lt 300 ]; do /bin/busybox usleep 200000; i=$((i+1)); echo "a52sxq-init: wdtexp tick $i" > /dev/kmsg; done; echo "5 2 0" > $R; echo SURVIVED_60s' \
    ./test-cycle.sh images/a52sxq-ack618-wdtexp-p2-recovery.img 70 > logs/wdtexp-run.out 2>&1
  L=$(ls -dt logs/*wdtexp-p2-recovery-p2-* | head -1)
  if grep -qx SURVIVED_60s $L/extra.txt 2>/dev/null; then R="survived 60 s"
  else A=$(grep -a "wdtexp armed" $L/crash-console.txt | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'); Z=$(grep -a "wdtexp tick" $L/crash-console.txt | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'); R="reset; armed at ${A}s, last tick at ${Z}s"; fi
  echo "$(date +%T) bark=$1 bite=$2: $R" >> logs/wdtexp-summary.txt
done
