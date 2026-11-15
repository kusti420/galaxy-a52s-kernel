#!/bin/busybox sh
# stage 4: audio (ADSP must be running: s3.sh first)
cd "${0%/*}"; . ./common.sh
ld s4pre "$1"; ld s4 "$1"; sleep 5; sh /p/mkdevs
[ -e /sys/kernel/boot_adsp/boot ] && k "boot_adsp present"
k "cards"; cat /proc/asound/cards; cat /proc/asound/pcm 2>&1 | head -60; ls /dev/snd 2>&1 | wc -l
ls /dev/msm_audio_cal /dev/msm_rtac /dev/tas256x /sys/class/audio 2>&1 | tr '\n' ' '; echo
ls /proc/asound/card0 2>&1 | tr '\n' ' '; echo; ls /dev/snd 2>&1 | grep -c pcm
k "deferred"; cat /sys/kernel/debug/devices_deferred
k "s4 done"; dmesg | grep -iE 'apr|q6core|swr|wcd93|bolero|tas25|lahaina|asoc|snd|audio|lpi' | grep -v 'hw: insmod' | tail -90
