#!/bin/bash
# Ends a held kexec session (KX_HOLD=1) or cleans up after the held kernel died: tells whatever
# answers on the phone to leave, collects the previous kernel's console when the harness is
# back, exits Download mode and waits for Android. Usage: PHONE=1 kexec/kx-finish.sh [label]
cd "$(dirname "$0")/.."
case "${PHONE:-1}" in 1) S=PHONE1; export TSH_IP=172.16.42.1; PORTDEF=1-5.3;; 2) S=PHONE2; export TSH_IP=172.16.43.1; PORTDEF=1-5.4.4.2;; *) exit 1;; esac
PORT=/sys/bus/usb/devices/${KX_PORT:-$PORTDEF}; T=tools/tsh.py
# cables get moved: prefer the port that shows this phone's Android serial; else, if the default
# port has no test kernel, the single test-kernel device (1209:a528) not on the other phone's port
for d in /sys/bus/usb/devices/*; do [ "$(cat $d/serial 2>/dev/null)" = "$S" ] && { PORT=$d; break; }; done
if [ "$(cat $PORT/idVendor 2>/dev/null)" != 1209 ] && [ "$(cat $PORT/serial 2>/dev/null)" != "$S" ]; then
	OTHER=$([ "$S" = PHONE1 ] && echo 1-5.4.4.2 || echo 1-5.3)
	C=$(for d in /sys/bus/usb/devices/*; do [ "$(cat $d/idVendor 2>/dev/null):$(cat $d/idProduct 2>/dev/null)" = 1209:a528 ] && [ "$(basename $d)" != "$OTHER" ] && echo $d; done)
	[ "$(echo "$C" | grep -c .)" = 1 ] && PORT=$C
fi
L=logs/kxfin-${1:-held}-p${PHONE:-1}-$(date +%H%M%S); mkdir -p $L
# home = the phone's installed Android: 5.4, or a real 6.x boot (flashed rb; /data is the real
# encrypted f2fs, not the zram of a kexec test Android). Rebooting a real boot here looped phone 2.
is_home() { adb -s $S shell 'case $(uname -r) in 5.4.*) echo HOME;; *) awk '"'"'$2=="/data"{print $1}'"'"' /proc/mounts | grep -q zram || echo HOME;; esac' 2>/dev/null | grep -q HOME; }
say() { echo "[$(date +%T)] $*"; }
T0=$(date +%s); GOT=0
while [ $(( $(date +%s) - T0 )) -lt 420 ]; do
  # 6.12 with sec_core loaded restarts with PON reason 0x14, and the bootloader then boots
  # Android directly (seen 2026-11-12): no harness, no Download mode in between.
  # back home = adb answers AND it is the installed 5.4 Android, not the 6.12 test Android
  if [ "$(adb -s $S get-state 2>/dev/null)" = device ]; then
    if is_home; then say "back in Android (direct restart, $(adb -s $S shell uname -r | tr -d '\r')); logs in $L"; exit 0
    else adb -s $S shell 'reboot' >/dev/null 2>&1; fi   # kexec test Android: restart it
  fi
  if [ "$(cat $PORT/idProduct 2>/dev/null)" = 685d ] && tools/dlexit.sh $PORT; then
    timeout 180 adb -s $S wait-for-device && { adb -s $S shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'; say "back in Android; logs in $L"; exit 0; }
  fi
  if O=$(python3 $T -t 4 'uname -r; [ -e /tmp/crashed ] && echo A52_SAFE_MODE; [ -e /tmp/prev-console.txt ] && echo A52_HAS_PREV' 2>/dev/null); then
    if echo "$O" | grep -q "^6\.18\." && [ $GOT = 0 ] && echo "$O" | grep -q A52_HAS_PREV; then
      python3 $T -t 25 'cat /tmp/prev-console.txt' > $L/prev-console.txt 2>&1; GOT=1
      say "harness is back ($(echo "$O" | grep -c A52_SAFE_MODE) = safe mode); previous kernel's console: $L/prev-console.txt ($(wc -l < $L/prev-console.txt) lines)"
      grep -a -E "Kernel panic|Internal error|Unable to handle|CFI failure|BUG:" $L/prev-console.txt | tail -4 | cut -c1-200
    fi
    python3 $T -t 3 /leave >/dev/null 2>&1
  fi
  python3 -c 'import time; time.sleep(2)'
done
say "did NOT get back to Android (needs the keys)"; exit 21
