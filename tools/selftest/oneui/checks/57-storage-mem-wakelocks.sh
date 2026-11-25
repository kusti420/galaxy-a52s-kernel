#!/system/bin/sh
# Storage / memory additions + kernel wakelock table (drivers612/SPEC/03-power-thermal-usb-storage.md 6a, 9, 10).
# READ-ONLY and SILENT. Wakelock numbers are normalised to ms held per hour of uptime so a 5.4 run and a 6.12 run
# of different length compare directly (report.py compares METRIC lines).
. "${0%/*}/../dev-lib.sh"
# ---- kernel wakeup sources: top holders + the five named in the 2026-11-24 overnight report
up=$(num "$(cut -d. -f1 /proc/uptime)"); [ "${up:-0}" -lt 60 ] && up=60
tab=$(for w in /sys/class/wakeup/wakeup*; do [ -r "$w/total_time_ms" ] || continue; echo "$(cat $w/total_time_ms 2>/dev/null) $(cat $w/active_count 2>/dev/null) $(cat $w/name 2>/dev/null)"; done | sort -rn)
if [ -z "$tab" ]; then C pm.wakelock_top SKIP kernel "wakeup class unreadable" "needs root or the sysfs_wakeup label"
else C pm.wakelock_top PASS info "top: $(printf '%s\n' "$tab" | head -3 | awk '{print $3}' | tr '\n' ' ')" "ms/count/name: $(printf '%s\n' "$tab" | head -10 | awk '{printf "%s/%s/%s ", $1, $2, $3}') uptime ${up}s"
	for n in grip_wake_lock nfc_wake_lock tsp hal_bluetooth_lock qup_uart alarmtimer wlan; do
		l=$(printf '%s\n' "$tab" | grep -m1 -F "$n"); ms=$(printf '%s' "$l" | awk '{print $1+0}'); cnt=$(printf '%s' "$l" | awk '{print $2+0}')
		M "ws_${n}_ms_per_h" $(( ${ms:-0} * 3600 / up )); M "ws_${n}_count_per_h" $(( ${cnt:-0} * 3600 / up )); done
fi
ss=/sys/power/suspend_stats; ok=$(num "$(rd $ss/success)"); fl=$(num "$(rd $ss/fail)")
C pm.suspend_ratio PASS info "suspend attempts readable: $([ -n "$ok" ] && echo y || echo n)" "success=$ok fail=$fl last_failed_dev=$(rd $ss/last_failed_dev) last_failed_errno=$(rd $ss/last_failed_errno)"
[ -n "$ok" ] && [ -n "$fl" ] && [ $((ok+fl)) -gt 0 ] && M suspend_fail_pct $(( fl * 100 / (ok+fl) ))
# ---- zram: the algorithm in use and RAM Plus writeback state
Z=/sys/block/zram0
alg=$(rd $Z/comp_algorithm | grep -oE '\[[a-z0-9-]+\]')
C mem.zram_algo "$([ -n "$alg" ] && echo PASS || echo FAIL)" kernel+ROM "$alg" "all: $(rd $Z/comp_algorithm); 5.4 and 6.12 default = lzo-rle, One UI asks for lz4 (6.12 falls back to the default on every zram reset)"
C mem.zram_writeback PASS kernel+ROM "backing_dev=$(rd $Z/backing_dev)" "bd_stat=$(rd $Z/bd_stat) writeback_limit_enable=$(rd $Z/writeback_limit_enable) balance_ratio node=$([ -e /sys/module/zram/parameters/zram_balance_ratio ] && echo y || echo n) reclaim node=$([ -e /proc/self/reclaim ] && echo y || echo n)"
M mem_total_kb "$(awk '/^MemTotal/{print $2}' /proc/meminfo)"; M cma_total_kb "$(awk '/^CmaTotal/{print $2}' /proc/meminfo)"; M swap_total_kb "$(awk '/^SwapTotal/{print $2}' /proc/meminfo)"
C mem.thp PASS kernel "$(rd /sys/kernel/mm/transparent_hugepage/enabled)" "ksm run=$(rd /sys/kernel/mm/ksm/run) lmkd_debug=$([ -d /proc/lmkd_debug ] && echo y || echo n) meminfo_extra=$([ -e /proc/meminfo_extra ] && echo y || echo n)"
# ---- storage
U=$(ls -d /sys/devices/platform/soc/*.ufshc 2>/dev/null | head -1)
C storage.ufs_link PASS kernel "gear=$(rd $U/power_info/gear) lane=$(rd $U/power_info/lane) rate=$(rd $U/power_info/rate)" "power_mode: $(rd $U/power_mode | cut -c1-160) wb_on=$(rd $U/wb_on) lt=$(rd /sys/class/sec/ufs/lt)"
lt=$(num "$(rd /sys/class/sec/ufs/lt)"); wb=$(num "$(rd $U/wb_on)")
C storage.wb_lifetime "$([ "${lt:-0}" -ge 9 ] && [ "${wb:-0}" = 1 ] && echo FAIL || echo PASS)" kernel "write booster on a worn device: $([ "${lt:-0}" -ge 9 ] && [ "${wb:-0}" = 1 ] && echo y || echo n)" "5.4 turns the write booster off at life time >= 9; lt=$lt wb_on=$wb"
C storage.f2fs_features PASS kernel "set: $(ls /sys/fs/f2fs/features 2>/dev/null | tr '\n' ' ')" "on-disk: $(cat /sys/fs/f2fs/dm-*/features 2>/dev/null | head -1 | cut -c1-200) sec nodes: $(ls /sys/fs/f2fs/dm-* 2>/dev/null | grep -c '^sec_')"
dq=$(grep -E ' /data f2fs ' /proc/mounts | head -1 | cut -d' ' -f4)
C storage.data_quota "$(printf '%s' "$dq" | grep -qE 'usrquota|prjquota|grpquota' && echo PASS || echo FAIL)" kernel+ROM "quota: $(printf '%s' "$dq" | tr ',' '\n' | grep -E 'quota' | tr '\n' ' ')" "Settings > Storage per-app sizes come from quota"
C storage.ntfs "$(grep -qwE 'ntfs3|ntfs' /proc/filesystems && echo PASS || echo FAIL)" kernel "ntfs driver: $(grep -owE 'ntfs3|ntfs' /proc/filesystems | tr '\n' ' ')" "5.4: read-only ntfs built in; 6.12: ntfs3.ko must be in the vendor_boot load list"
C storage.removable_fs PASS kernel "exfat=$(grep -cw exfat /proc/filesystems) sdfat=$(grep -cw sdfat /proc/filesystems) vfat=$(grep -cw vfat /proc/filesystems)" "public volumes: $(sm list-volumes public 2>/dev/null | tr '\n' ';') mounts: $(grep -E ' /mnt/media_rw/' /proc/mounts | awk '{print $2":"$3}' | tr '\n' ' ')"
C storage.fuse_bpf PASS kernel+ROM "ro.fuse.bpf.is_running=$(getprop ro.fuse.bpf.is_running) enabled=$(getprop ro.fuse.bpf.enabled) persist=$(getprop persist.sys.fuse.bpf.override)" "emulated storage path under test in SPEC 03 D12"
SD=/sys/class/sec/sdcard
C storage.sd_nodes PASS kernel "status=$(rd $SD/status)" "max_mode=$(rd $SD/max_mode) current_mode=$(rd $SD/current_mode) cd_cnt=$(rd $SD/cd_cnt) summary=$(rd $SD/sdcard_summary | cut -c1-120)"
C storage.blk_sec_stats "$([ ! -e /sys/kernel/blk_sec_stats/diskios ] || grep -q ReadC /sys/kernel/blk_sec_stats/diskios 2>/dev/null && echo PASS || echo FAIL)" kernel "diskios=$([ -e /sys/kernel/blk_sec_stats/diskios ] && echo y || echo n)" "$(rd /sys/kernel/blk_sec_stats/diskios | cut -c1-160)"
C storage.discard PASS kernel "discard_max_bytes=$(rd /sys/block/sda/queue/discard_max_bytes)" "read_ahead_kb dm-0..2: $(rd /sys/block/dm-0/queue/read_ahead_kb) $(rd /sys/block/dm-1/queue/read_ahead_kb) $(rd /sys/block/dm-2/queue/read_ahead_kb)"
