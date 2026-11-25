#!/system/bin/sh
# Suspend / CPU power / boot / watchdog state (drivers612/SPEC/03-power-thermal-usb-storage.md sections 6-8). READ-ONLY, SILENT.
. "${0%/*}/../dev-lib.sh"
ms=$(rd /sys/power/mem_sleep)
C pm.mem_sleep "$(printf '%s' "$ms" | grep -q '\[s2idle\]' && echo PASS || echo FAIL)" kernel+ROM "$ms" "every ROM's post_boot selects s2idle; r70 drivers treat 'deep' as hibernation-like"
# hardware watchdog: 5.4 arms the Gunyah virtual watchdog at 0.4 s; a 6.12 build with wdt=0 has none
wd=n; ls /sys/devices/platform/soc/*wdt*/driver >/dev/null 2>&1 && wd=y; [ -e /sys/devices/platform/soc/soc:qcom,gh-watchdog/driver ] && wd=y
dw=$(dmesg 2>/dev/null | grep -c -E 'Apps Watchdog Initialized|hh-watchdog|gh-watchdog')
bi=$(rd /proc/device-tree/a52sxq,realboot-base); kc=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -m1 -E '^a52bc\.wdt=')
C pm.watchdog "$([ $wd = y ] || [ "${dw:-0}" -gt 0 ] && echo PASS || echo FAIL)" kernel "hardware watchdog armed: $([ $wd = y ] || [ "${dw:-0}" -gt 0 ] && echo y || echo n)" "driver bound=$wd, kernel log lines=$dw (log may have wrapped), build=$bi $kc, hung_task_panic=$(rd /proc/sys/kernel/hung_task_panic) softlockup_panic=$(rd /proc/sys/kernel/softlockup_panic)"
# SoC sleep statistics: the only proof that AOSD / CXSD are reached
st=; for f in /sys/power/soc_sleep/stats /sys/kernel/debug/qcom_stats/aosd /sys/kernel/debug/qcom_stats/cxsd /sys/kernel/debug/qcom_stats/ddr; do [ -r $f ] && st="$st ${f##*/}:$(grep -m1 -i count $f 2>/dev/null | tr -s ' \t' ' ')"; done
C pm.soc_sleep_stats "$([ -n "$st" ] && echo PASS || echo FAIL)" kernel "stats readable: $([ -n "$st" ] && echo y || echo n)" "${st:-neither /sys/power/soc_sleep/stats (5.4) nor debugfs qcom_stats (6.12: qcom_stats.ko not loaded, or debugfs unmounted)}"
aosd=$(grep -m1 -i -A3 aosd /sys/power/soc_sleep/stats 2>/dev/null | grep -m1 -i count | grep -oE '[0-9]+' | head -1); [ -z "$aosd" ] && aosd=$(grep -m1 -i count /sys/kernel/debug/qcom_stats/aosd 2>/dev/null | grep -oE '[0-9]+' | head -1); [ -n "$aosd" ] && M soc_aosd_count "$aosd"
C pm.wakeup_reason "$([ -r /sys/kernel/wakeup_reasons/last_resume_reason ] && echo PASS || echo FAIL)" kernel "node readable: $([ -r /sys/kernel/wakeup_reasons/last_resume_reason ] && echo y || echo n)" "last: $(rd /sys/kernel/wakeup_reasons/last_resume_reason) | suspend time: $(rd /sys/kernel/wakeup_reasons/last_suspend_time)"
C pm.volkey_node PASS kernel "volkey_wakeup=$([ -e /sys/power/volkey_wakeup ] && echo y || echo n)" "value $(rd /sys/power/volkey_wakeup) (5.4 SEC_PM node; 6.12: VOLKEY=1 builds)"
C pm.cpuidle_gov PASS kernel "$(rd /sys/devices/system/cpu/cpuidle/current_governor)" "driver $(rd /sys/devices/system/cpu/cpuidle/current_driver) qcom_lpm sleep_disabled=$(rd /sys/devices/system/cpu/qcom_lpm/parameters/sleep_disabled) lpm_levels=$(rd /sys/module/lpm_levels/parameters/sleep_disabled)"
sb=$(rd /proc/sys/walt/sched_boost); [ -z "$sb" ] && sb=$(rd /proc/sys/kernel/sched_boost)
up=$(num "$(cut -d' ' -f1 /proc/uptime)")
if [ "${up:-0}" -lt 90 ]; then C pm.walt_boost SKIP kernel "uptime < 90 s" "boot boost is released ~45 s after dsp_boot"; else C pm.walt_boost "$([ "${sb:-0}" = 0 ] && echo PASS || echo FAIL)" kernel "sched_boost=${sb:-absent}" "a stuck boot boost pins every cluster at max (alpha1 bug)"; fi
C pm.gpu_gov "$([ "$(rd /sys/class/kgsl/kgsl-3d0/devfreq/governor)" = msm-adreno-tz ] && echo PASS || echo FAIL)" kernel "$(rd /sys/class/kgsl/kgsl-3d0/devfreq/governor)" "freqs $(rd /sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies) cur $(rd /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq)"
C pm.dma_latency "$([ -c /dev/cpu_dma_latency ] && echo PASS || echo FAIL)" kernel "/dev/cpu_dma_latency=$([ -c /dev/cpu_dma_latency ] && echo y || echo n)" "$(lz /dev/cpu_dma_latency)"
pe=$(logcat -d -s libperfmgr 2>/dev/null | grep -c 'Failed to write'); [ -n "$(getprop ro.lineage.version)$(getprop ro.ichthys.version)" ] || pe=
if [ -z "$pe" ]; then C pm.perfmgr_errors SKIP ROM "no libperfmgr power HAL on this ROM"; else C pm.perfmgr_errors "$([ "$pe" = 0 ] && echo PASS || echo FAIL)" kernel "failed powerhint writes: $([ "$pe" = 0 ] && echo 0 || echo some)" "$pe 'Failed to write' lines; nodes: $(logcat -d -s libperfmgr 2>/dev/null | grep 'Failed to write' | grep -oE '/[^ :]+' | sort -u | head -6 | tr '\n' ' ')"; fi
l3=; for f in /sys/devices/system/cpu/bus_dcvs/L3/cur_freq /sys/devices/system/cpu/bus_dcvs/DDR/cur_freq /sys/devices/system/cpu/bus_dcvs/LLCC/cur_freq; do [ -r $f ] && l3="$l3 $(echo $f | cut -d/ -f7)=$(rd $f)"; done
C pm.bus_dcvs PASS kernel "bus_dcvs nodes: $([ -n "$l3" ] && echo y || echo n)" "${l3:-none (5.4 uses devfreq + RIMPS)} | devfreq: $(ls /sys/class/devfreq 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
C pm.pstore "$([ -d /sys/fs/pstore ] && echo PASS || echo FAIL)" kernel "pstore mounted: $(grep -c ' /sys/fs/pstore ' /proc/mounts)" "$(ls /sys/fs/pstore 2>/dev/null | tr '\n' ' ') | panic=$(rd /proc/sys/kernel/panic) panic_on_oops=$(rd /proc/sys/kernel/panic_on_oops)"
C pm.boot_reason PASS kernel+ROM "bootreason node=$([ -e /proc/sys/kernel/boot_reason ] && echo y || echo n)" "ro.boot.bootreason=$(getprop ro.boot.bootreason) sys.boot.reason=$(getprop sys.boot.reason) last=$(getprop sys.boot.reason.last) mode=$(getprop ro.boot.mode) alarm_boot=$(getprop ro.vendor.alarm_boot)"
C pm.samsung_reset_nodes PASS kernel "reset_reason=$([ -e /proc/reset_reason ] && echo y || echo n) last_kmsg=$([ -e /proc/last_kmsg ] && echo y || echo n) extra=$([ -e /proc/extra ] && echo y || echo n) sec_hw_param=$([ -d /sys/class/sec/sec_hw_param ] && echo y || echo n)" "SEC_DEBUG nodes: on in the LineageOS/IchthysOS 5.4, off in the One UI port's 5.4 and on 6.12"
