#!/bin/busybox sh
# W1: WPSS through icnss2 (wpss_boot), firmware = the phone's own set, copied into /lib/firmware.
# Never the modem (no modem.mdt anywhere in the firmware path), no ADSP/CDSP firmware either.
# usage: sh /p/w1.sh [skip-regex] [noboot]
cd "${0%/*}"; . ./lib.sh; chmod 755 qrtrls
mount -t debugfs none /sys/kernel/debug 2>/dev/null
k "w1 firmware"; fwsetup
ld w1 "$1"; sleep 2; sh /p/mkdevs
k "w1 remoteprocs after load"; rp
k "w1 icnss2 probe"; dmesg | grep -iE 'icnss|wcn6750|cnss' | grep -v 'hw: insmod' | tail -30
cat /sys/kernel/debug/devices_deferred 2>/dev/null
W=$(find /sys/devices/platform -name wpss_boot 2>/dev/null | head -1); k "wpss_boot node: ${W:-none}"
ls /sys/wifi 2>&1 | tr '\n' ' '; echo
[ "$2" = noboot ] && exit 0
[ -n "$W" ] || exit 1
k "w1 echo 1 > wpss_boot"; echo 1 > $W
for i in 1 2 3 4 5 6 7 8; do sleep 4; dmesg | grep -q -iE 'WLAN FW is ready|FW Ready|fw_ready' && break; done
k "w1 after boot"; rp
dmesg | grep -iE 'icnss|wpss|remoteproc|q6v5|wlfw|fw.ready|soc.wake|smp2p|sysmon|qmi' | grep -v 'hw: insmod' | tail -70
k "w1 qrtrls"; ./qrtrls 2>&1 | head -40
k "w1 done"
