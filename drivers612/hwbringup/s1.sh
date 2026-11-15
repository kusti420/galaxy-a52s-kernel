#!/bin/busybox sh
# stage 1: secure (ioncompat, qseecom, smcinvoke, qce). Args: skip-regex (optional)
cd "${0%/*}"; . ./common.sh; chmod 755 iontest* qseetest*
mount -t debugfs none /sys/kernel/debug 2>/dev/null
ld s1a "$1"; sleep 1; sh /p/mkdevs
k "ioncompat heaps"; cat /sys/kernel/debug/ioncompat/heaps 2>&1; ls -l /dev/ion /dev/dma_heap 2>&1
# iontest -s RESETS THE PHONE in "secure_heap, CP_NON_PIXEL" (hw3, hw5): only on request, last in a session
if [ "$2" = ion ]; then sh ./ion.sh 64 -v -s; sh ./ion.sh 32 -s; fi
ld s1b "$1"; sleep 2; sh /p/mkdevs; ls -l /dev/qseecom 2>&1; dmesg | grep -i qseecom | tail -20
ld s1c "$1"; sleep 1; sh /p/mkdevs; ls -l /dev/smcinvoke 2>&1
ld s1d "$1"; sleep 1; sh /p/mkdevs; ls -l /dev/qce 2>&1
k "qseetest64"; ./qseetest64 2>&1 | tail -40
k "qseetest32"; ./qseetest32 2>&1 | tail -25
k "qseetest64 TA query"; ./qseetest64 -a keymaster64 -a skeymast 2>&1 | tail -12
k "s1 done"; cat /sys/kernel/debug/devices_deferred 2>/dev/null
