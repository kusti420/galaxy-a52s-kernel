#!/bin/bash
# Measures when the hypervisor watchdog really bites. Boots the harness (already on recovery),
# arms the watchdog by the raw sequence with <bark> <bite> (decimal), pets once, then logs a
# tick to kmsg every 0.1 s. After the bite the harness comes back in safe mode with the dead
# boot's console: the last tick tells the time. Usage: PHONE=1 tools/wdtmeasure.sh <bark> <bite>
cd "$(dirname "$0")/.."
case "${PHONE:-1}" in 1) S=PHONE1; export TSH_IP=172.16.42.1;; 2) S=PHONE2; export TSH_IP=172.16.43.1;; esac
PORT=""; for d in /sys/bus/usb/devices/*; do [ "$(cat "$d/serial" 2>/dev/null)" = "$S" ] && PORT=$d; done
[ -n "$PORT" ] || { echo "$S is not on USB"; exit 1; }
BARK=$(printf %x "$1"); BITE=$(printf %x "$2"); T=tools/tsh.py
NOFLASH=1 HOLD=1 ./test-cycle.sh "${HARNESS_IMG:?}" 70 >/dev/null 2>&1 || { echo "harness did not come up"; exit 1; }
python3 $T -t 8 "setsid sh -c 'insmod /hhwdt.ko; R=/sys/module/hhwdt/parameters/raw; echo \"8 $BARK ffff\" > \$R; echo \"8 ffff $BITE\" > \$R; echo \"5 3 0\" > \$R; echo \"7 0 0\" > \$R; echo \"a52sxq-init: wdtm armed $1 $2\" > /dev/kmsg; i=0; while [ \$i -lt 900 ]; do /bin/busybox usleep 100000; i=\$((i+1)); echo \"a52sxq-init: wdtm tick \$i\" > /dev/kmsg; done; echo \"5 2 0\" > \$R; echo \"a52sxq-init: wdtm survived 90s\" > /dev/kmsg' >/dev/null 2>&1 & echo detached" >/dev/null 2>&1
T0=$(date +%s); RES=none
while [ $(( $(date +%s) - T0 )) -lt 130 ]; do
  O=$(python3 $T -t 4 '[ -e /tmp/crashed ] && echo A52_SAFE_MODE; dmesg | grep -c "wdtm survived"' 2>/dev/null)
  echo "$O" | grep -q A52_SAFE_MODE && { RES=bite; break; }
  [ "$(echo "$O" | tail -1)" = 1 ] && { RES=survived; break; }
  python3 -c 'import time; time.sleep(2)'
done
if [ $RES = bite ]; then
  python3 $T -t 25 'cat /tmp/prev-console.txt' > logs/wdtm-last.txt 2>&1
  A=$(grep -a "wdtm armed" logs/wdtm-last.txt | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'); Z=$(grep -a "wdtm tick" logs/wdtm-last.txt | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
  echo "bark=$1 bite=$2: BITE $(python3 -c "print(round($Z-$A,1))") s after arming (armed at $A, last tick at $Z)"
else echo "bark=$1 bite=$2: $RES"; fi | tee -a logs/wdtm-summary.txt
python3 $T -t 3 /leave >/dev/null 2>&1
T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt 300 ]; do
  if [ "$(cat $PORT/idProduct 2>/dev/null)" = 685d ] && tools/dlexit.sh $PORT; then
    timeout 180 adb -s $S wait-for-device && { adb -s $S shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'; exit 0; }
  fi
  python3 $T -t 3 /leave >/dev/null 2>&1; python3 -c 'import time; time.sleep(2)'
done
echo "did NOT get back to Android"; exit 21
