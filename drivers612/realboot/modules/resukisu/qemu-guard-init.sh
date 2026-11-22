#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc 2>/dev/null; $B mount -t sysfs sysfs /sys; $B mount -t pstore pstore /sys/fs/pstore 2>/dev/null
echo "QRSK: real init up pid=$$ $($B cat /proc/uptime)"
echo "QRSK: modules: $($B cut -d' ' -f1 /proc/modules | $B tr '\n' ' ')"
echo "QRSK: pstore: $($B ls /sys/fs/pstore | $B tr '\n' ' ')"
echo "QRSK: WARN/BUG/Oops lines this boot: $($B dmesg | $B grep -c -E 'WARNING:|BUG:|Oops')"
if $B grep -q '^kernelsu ' /proc/modules; then
  if $B grep -q 'kernelsu.ko NOT loaded this boot' /sys/fs/pstore/console-ramoops* 2>/dev/null; then
    echo "QRSK: boot 3: kernelsu loaded again after the guarded boot: GUARD PASS"; $B poweroff -f
  fi
  echo "QRSK: boot 1: kernelsu loaded, crashing on purpose"; $B sleep 1; echo c > /proc/sysrq-trigger
else
  echo "QRSK: boot 2: kernelsu NOT loaded (guard): $($B dmesg | $B grep 'a52:' | $B tr '\n' '|')"
  $B sleep 1; $B reboot -f
fi
$B sleep 5; $B poweroff -f
