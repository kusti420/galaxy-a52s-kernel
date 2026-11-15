#!/bin/busybox sh
# stage 5: video (msm-vidc). Needs the dtb with the video fragment (hw-full-r02.dtb)
cd "${0%/*}"; . ./common.sh; . ./fw.sh
mount -t debugfs none /sys/kernel/debug 2>/dev/null
fwmount; fwlink 'vpu20_1v.*'; ls /lib/firmware | grep -c vpu20
ld s5 "$1"; sleep 3; sh /p/mkdevs
ls -l /dev/video32 /dev/video33 2>&1; cat /sys/devices/platform/soc/aa00000.qcom,vidc/sku_version 2>&1; cat /sys/kernel/debug/msm_vidc/core0/info 2>&1 | head -20
k "deferred"; cat /sys/kernel/debug/devices_deferred
if [ "$2" = open ] && [ -e /dev/video32 ]; then k "open /dev/video32 (firmware boot)"; exec 3<>/dev/video32; sleep 2; exec 3>&-; fi
k "s5 done"; dmesg | grep -iE 'vidc|venus|videocc|video_cc|vpu' | grep -v 'hw: insmod' | tail -50
