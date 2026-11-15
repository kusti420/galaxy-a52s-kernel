# Before wlan.ko: boot the WPSS through icnss2 with the phone's own firmware. GKI 6.12 does not
# fall back to ueventd for firmware by itself; with force_sysfs_fallback every request goes to
# Android's ueventd, which searches /vendor/firmware, /vendor/firmware_mnt/image, ... (the ADSP
# is already up at this point, it was loaded directly through firmware_class.path).
F=/proc/sys/kernel/firmware_config/force_sysfs_fallback
[ -e $F ] && echo 1 > $F && echo "force_sysfs_fallback=1"
W=$(find /sys/devices/platform -name wpss_boot 2>/dev/null | head -1)
echo "wpss_boot: ${W:-none}"
[ -n "$W" ] && echo 1 > $W
i=0; while [ $i -lt 40 ]; do dmesg | grep -q -iE "WLAN FW is ready|FW Ready" && break; sleep 1; i=$((i + 1)); done
echo "fw ready after ${i}s: $(dmesg | grep -iE 'WLAN FW is ready' | tail -1)"
