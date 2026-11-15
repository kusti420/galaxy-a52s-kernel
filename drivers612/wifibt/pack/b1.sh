#!/bin/busybox sh
# B1: btpower + msm_geni_serial (ttyHS0). Probe only; "on" (arg 1) = rfkill power on/off as in conn/bt/STATUS.md.
cd "${0%/*}"; . ./lib.sh
mount -t debugfs none /sys/kernel/debug 2>/dev/null
ld b1 ""; sleep 2; sh /p/mkdevs
k "b1 nodes"; ls -l /dev/btpower /dev/ttyHS* 2>&1
for r in /sys/class/rfkill/rfkill*; do echo "$r: $(cat $r/name) $(cat $r/type) state=$(cat $r/state) extldo=$(cat $r/device/extldo 2>/dev/null)"; done
grep -E 'gpio-?(84|85|86)\b' /sys/kernel/debug/gpio 2>/dev/null
dmesg | grep -iE 'bt_power|btpower|bluetooth|geni.*serial|ttyHS|99c000|uart' | grep -v 'hw: insmod' | tail -40
if [ "$1" = on ]; then
  R=$(for r in /sys/class/rfkill/rfkill*; do [ "$(cat $r/type)" = bluetooth ] && echo $r; done | head -1)
  k "b1 rfkill $R state 1"; echo 1 > $R/state; sleep 2
  echo "state=$(cat $R/state)"; grep -E 'gpio-?(84|85|86)\b' /sys/kernel/debug/gpio 2>/dev/null
  dmesg | grep -iE 'bt_power|btpower|bluetooth|regulator' | grep -v 'hw: insmod' | tail -25
  k "b1 rfkill state 0"; echo 0 > $R/state; sleep 1; echo "state=$(cat $R/state)"
  grep -E 'gpio-?(84|85|86)\b' /sys/kernel/debug/gpio 2>/dev/null
  dmesg | grep -iE 'bt_power|btpower' | tail -8
fi
k "b1 done"
