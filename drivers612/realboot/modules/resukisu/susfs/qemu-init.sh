#!/bin/busybox sh
# init of the SUSFS QEMU smoke test (qemu-susfs-test.sh): QSUS: lines are the result
B=/bin/busybox
$B mount -t proc proc /proc 2>/dev/null; $B mount -t sysfs sysfs /sys
echo "QSUS: init up pid=$$ uname=$($B uname -r) uptime=$($B cat /proc/uptime)"
$B dmesg | $B grep -i -E 'KernelSU|ksu|susfs' | $B head -40 | while read -r l; do echo "QSUS: dmesg: $l"; done
echo "QSUS: /sys/module/kernelsu: $([ -d /sys/module/kernelsu ] && echo present || echo absent); /proc/modules lines: $($B wc -l < /proc/modules)"
/susfsq | while read -r l; do echo "QSUS: $l"; done
echo "QSUS: kallsyms visible to root: susfs $($B grep -c -i susfs /proc/kallsyms), ksu_ $($B grep -c ' ksu_' /proc/kallsyms) (HIDE_KSU_SUSFS_SYMBOLS hides them)"
echo "QSUS: uname spoof default: $($B uname -r) | $($B uname -v)"
echo "QSUS: WARN/BUG/Oops lines this boot: $($B dmesg | $B grep -c -E 'WARNING:|BUG:|Oops|Call trace')"
echo "QSUS: done"
$B poweroff -f
