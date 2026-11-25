#!/system/bin/sh
# USB gadget (Samsung ss_mon / conn_gadget), storage (Samsung UFS sysfs, encryption, ICE), battery/charger class,
# suspend + wakeup sources. Read-only. The UFS unique number is reported as length + short hash only.
. "${0%/*}/../dev-lib.sh"
# ---- USB
G=/config/usb_gadget/g1
cfg=$(getprop sys.usb.config); stt=$(getprop sys.usb.state)
C usb.state "$([ "$cfg" = "$stt" ] && [ "$(getprop sys.usb.configured)" != "" ] && echo PASS || echo FAIL)" kernel+ROM "config=$cfg state=$stt" "UDC=$(rd $G/UDC) controller=$(getprop sys.usb.controller) persist=$(getprop persist.sys.usb.config)"
C usb.adb PASS kernel "adbd=$(svc adbd)" "this check ran over adb"
fn=$(ls $G/functions 2>/dev/null | tr '\n' ' ')
setl usb.functions kernel 3 "$fn"
for f in ss_mon.mtp ss_mon.ptp conn_gadget.0 ffs.mtp ffs.adb; do
	if [ -d "$G/functions/$f" ]; then C "usb.fn.$f" PASS kernel present; else C "usb.fn.$f" FAIL kernel absent "not in $G/functions"; fi
done
uv=$(printf '%s\n' $fn | grep -m1 '^uvc\.'); uc=$(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_USB_CONFIGFS_F_UVC=')
if [ -n "$uv" ] || [ -n "$uc" ]; then C usb.fn.uvc PASS kernel "available" "function dir '${uv:-none}' config '${uc:-config.gz not readable}'"; else C usb.fn.uvc FAIL kernel "not available" "no uvc.* function, CONFIG_USB_CONFIGFS_F_UVC not =y"; fi
links=$(ls $G/configs/b.1 2>/dev/null | grep -vE '^(MaxPower|bmAttributes|strings)$' | tr '\n' ' ')
bound=$(for l in $G/configs/b.1/*; do [ -L "$l" ] && readlink "$l" | sed 's|.*/||'; done 2>/dev/null | tr '\n' ' ')
C usb.config_links PASS kernel+ROM "bound: $bound" "links: $links"
case ",$cfg," in *,mtp,*|*,ptp,*) if printf '%s' "$bound" | grep -q 'ss_mon\.'; then C usb.ss_mon_bound PASS kernel "ss_mon bound in $cfg mode"; else C usb.ss_mon_bound FAIL kernel "ss_mon not bound in $cfg mode" "$bound"; fi;;
	*) C usb.ss_mon_bound SKIP kernel "not in MTP mode" "sys.usb.config=$cfg (the selftest usb test switches to MTP and checks from the PC side)";; esac
for n in /dev/usb_mtp_gadget /dev/android_ssusbcon; do if [ -e $n ]; then C "usb.dev.${n#/dev/}" PASS kernel "present $(lz $n)" "$(ls -l $n | cut -d' ' -f1,3,4)"; else C "usb.dev.${n#/dev/}" FAIL kernel absent; fi; done
C usb.typec PASS kernel "port0=$([ -d /sys/class/typec/port0 ] && echo y || echo n)" "power_role=$(rd /sys/class/typec/port0/power_role) data_role=$(rd /sys/class/typec/port0/data_role)"
nodes usb.notify kernel /sys/class/usb_notify/usb_control/usb_data_enabled /sys/class/usb_notify/usb_control/disable
setl sec.class_dirs kernel 8 "$(ls /sys/class/sec 2>/dev/null | tr '\n' ' ')"
# ---- storage
U=/sys/class/sec/ufs
nodes storage.sec_ufs kernel $U/un $U/lt $U/lc $U/man_id
if [ -r $U/un ]; then un=$(cat $U/un 2>/dev/null); C storage.ufs_un PASS kernel "len=${#un} sha=$(h12 "$un")" "must be identical on both kernels (Knox/Widevine device identity); value not printed"; else C storage.ufs_un FAIL kernel "unreadable"; fi
C storage.ufs_info PASS kernel "man_id=$(rd $U/man_id)" "lt=$(rd $U/lt) lc=$(rd $U/lc) host0/unique_number=$([ -e /sys/class/scsi_host/host0/unique_number ] && echo present || echo absent) SEC_UFS_err_sum=$(rd /sys/class/scsi_host/host0/SEC_UFS_err_sum | cut -c1-80)"
dm=$(grep -E ' /data (f2fs|ext4) ' /proc/mounts | head -1)
fs=$(printf '%s' "$dm" | cut -d' ' -f3); opt=$(printf '%s' "$dm" | cut -d' ' -f4)
C storage.data_fs "$([ -n "$fs" ] && echo PASS || echo FAIL)" kernel+ROM "fs=$fs dev=$(printf '%s' "$dm" | cut -d' ' -f1 | sed 's|.*/||') inlinecrypt=$(printf '%s' "$opt" | grep -c inlinecrypt)" "$opt"
C storage.encryption "$([ "$(getprop ro.crypto.state)" = encrypted ] && echo PASS || echo FAIL)" kernel+ROM "state=$(getprop ro.crypto.state) type=$(getprop ro.crypto.type) metadata=$(getprop ro.crypto.metadata.enabled) method=$(getprop ro.crypto.volume.metadata.method)" "dm devices: $(ls /sys/block 2>/dev/null | grep -c '^dm-'); userdata dm name: $(cat /sys/block/dm-*/dm/name 2>/dev/null | grep -m1 userdata)"
K=/sys/module/ufshcd_crypto_qti/parameters
if [ -e $K/a52_kat_state ]; then ks=$(rd $K/a52_kat_state); C storage.ice_kat "$([ "$ks" = 1 ] && [ "$(rd $K/a52_kat_fail)" = 0 ] && echo PASS || echo FAIL)" kernel "kat_state=$ks kat_fail=$(rd $K/a52_kat_fail)" "raw_keys=$(rd $K/a52_raw_keys) no_hwkm=$(rd /sys/module/qcom_ice/parameters/a52_no_hwkm)"
else C storage.ice_kat SKIP kernel "no kat_state node" "the boot-time ICE known-answer test exists only on the 6.12 line"; fi
C storage.ice_errors "$([ "$(dmesg 2>/dev/null | grep -ciE 'fscrypt.*(error|fail)|F2FS-fs.*(error|inconsistent|corrupt)|error (programming|evicting) key|blk-crypto.*(fail|error)')" = 0 ] && echo PASS || echo FAIL)" kernel "$(dmesg 2>/dev/null | grep -ciE 'fscrypt.*(error|fail)|F2FS-fs.*(error|inconsistent|corrupt)|error (programming|evicting) key|blk-crypto.*(fail|error)') fscrypt/f2fs/key error lines in dmesg" "I/O errors: $(dmesg 2>/dev/null | grep -ciE 'I/O error|critical medium error|ufshcd.*(abort|error handler)')"
C storage.sd_class PASS kernel "sdcard=$([ -d /sys/class/sec/sdcard ] && echo y || echo n) sdinfo=$([ -d /sys/class/sec/sdinfo ] && echo y || echo n) sddata=$([ -d /sys/class/sec/sddata ] && echo y || echo n)" "public volumes: $(sm list-volumes public 2>/dev/null | cut -d' ' -f2 | tr '\n' ' ')"
C storage.filesystems PASS kernel "$(for f in f2fs ext4 erofs exfat sdfat vfat fuse incremental-fs; do grep -qw "$f" /proc/filesystems && printf '%s ' $f; done)" "exfat driver for SD cards: $(grep -oE '\b(exfat|sdfat)\b' /proc/filesystems | tr '\n' ' ')"
setl storage.erofs_features kernel 0 "$(ls /sys/fs/erofs/features 2>/dev/null | tr '\n' ' ')"
C storage.io_sched PASS kernel "$(rd /sys/block/sda/queue/scheduler)" "wb: $(cat /sys/devices/platform/soc/*ufshc/wb_on $U/sec_wb_enable 2>/dev/null | tr '\n' ' ')"
C storage.zram "$([ -e /sys/block/zram0/disksize ] && [ "$(rd /sys/block/zram0/disksize | tr -d 0)" != "" ] && echo PASS || echo FAIL)" kernel+ROM "algo=$(rd /sys/block/zram0/comp_algorithm | grep -oE '\[[a-z0-9-]+\]')" "disksize=$(rd /sys/block/zram0/disksize) swap: $(grep -E 'SwapTotal' /proc/meminfo | tr -s ' ')"
# ---- battery / charger (same Samsung drivers on both kernels)
PS=/sys/class/power_supply
setl battery.supplies kernel 3 "$(ls $PS 2>/dev/null | tr '\n' ' ')"
setl battery.attrs kernel 50 "$(ls $PS/battery 2>/dev/null | grep -vE '^(power|subsystem|uevent|device|wakeup[0-9]*)$' | tr '\n' ' ')"
nodes battery.oneui_attrs kernel $PS/battery/status $PS/battery/capacity $PS/battery/voltage_now $PS/battery/current_now $PS/battery/temp $PS/battery/batt_slate_mode $PS/battery/siop_level $PS/battery/batt_full_capacity $PS/battery/pass_through $PS/battery/pd_disable $PS/battery/lcd $PS/battery/lrp $PS/battery/wc_param_info $PS/battery/cisd_wire_count $PS/battery/batt_type $PS/battery/hv_charger_status $PS/battery/online $PS/battery/batt_misc_event
v=$(num "$(rd $PS/battery/voltage_now)"); cap=$(num "$(rd $PS/battery/capacity)"); t=$(num "$(rd $PS/battery/temp)")
[ "${v:-0}" -gt 100000 ] && v=$((v/1000))
C battery.values "$([ "${v:-0}" -ge 3300 ] && [ "${v:-0}" -le 4500 ] && [ "${cap:-0}" -ge 1 ] && [ "${t:-0}" -ge 50 ] && [ "${t:-0}" -le 500 ] && echo PASS || echo FAIL)" kernel "sane" "status=$(rd $PS/battery/status) $cap % $v mV temp $t (0.1 C) current_now=$(rd $PS/battery/current_now) online=$(rd $PS/battery/online) batt_type=$(rd $PS/battery/batt_type) slate=$(rd $PS/battery/batt_slate_mode) full_capacity=$(rd $PS/battery/batt_full_capacity)"
bd=$(D battery); C battery.framework "$(printf '%s' "$bd" | grep -qE 'level: [0-9]+' && echo PASS || echo FAIL)" kernel+ROM "BatteryService reports" "$(printf '%s\n' "$bd" | grep -E '^ *(AC|USB|Wireless) powered: true|^ *status:|^ *health:|^ *level:|^ *voltage:|^ *temperature:' | tr -s ' ' | tr '\n' ';')"
C battery.switch_class PASS kernel "switch=$([ -d /sys/class/sec/switch ] && echo y || echo n) muic=$([ -d /sys/class/sec/muic ] && echo y || echo n) ccic=$([ -d /sys/class/sec/ccic ] && echo y || echo n) typec_manager=$([ -d /sys/class/sec/typec_manager ] && echo y || echo n)" "attached_dev=$(rd /sys/class/sec/switch/attached_dev) afc_disable=$(rd /sys/class/sec/switch/afc_disable) water=$(rd /sys/class/sec/ccic/water) usbpd_type=$(rd /sys/class/sec/ccic/usbpd_type)"
C battery.rtc_status PASS kernel "sec/rtc/rtc_status=$([ -e /sys/class/sec/rtc/rtc_status ] && echo y || echo n) power/rtc_status=$([ -e /sys/power/rtc_status ] && echo y || echo n)" "rtc0 $(rd /sys/class/rtc/rtc0/name) since_epoch $([ -r /sys/class/rtc/rtc0/since_epoch ] && echo readable || echo unreadable)"
C vibrator.nodes PASS kernel "timed_output=$([ -e /sys/class/timed_output/vibrator/enable ] && echo y || echo n) motor_type=$([ -e /sys/class/timed_output/vibrator/motor_type ] && echo y || echo n) leds_vibrator=$([ -d /sys/class/leds/vibrator ] && echo y || echo n)" "presence only: the sweep never drives the vibrator; HAL $(svc sec-vibrator-aidl)"
# ---- suspend / wakeup sources
C power.sleep_modes "$([ -r /sys/power/state ] && echo PASS || echo FAIL)" kernel "state=[$(rd /sys/power/state)] mem_sleep=[$(rd /sys/power/mem_sleep)]" "wakeup_count readable: $([ -r /sys/power/wakeup_count ] && echo y || echo n)"
ss=/sys/power/suspend_stats
C power.suspend_stats "$([ -r $ss/success ] || [ -r /sys/kernel/debug/suspend_stats ] && echo PASS || echo FAIL)" kernel "readable" "success=$(rd $ss/success) fail=$(rd $ss/fail) last_failed_dev=$(rd $ss/last_failed_dev) last_failed_step=$(rd $ss/last_failed_step)"
M suspend_success "$(num "$(rd $ss/success)")"; M suspend_fail "$(num "$(rd $ss/fail)")"
nw=$(ls -d /sys/class/wakeup/wakeup* 2>/dev/null | grep -c .)
C power.wakeup_class "$([ "$nw" -ge 10 ] && echo PASS || echo FAIL)" kernel "/sys/class/wakeup readable" "$nw sources; label $(lz /sys/class/wakeup/wakeup0)"
if needroot power.wakeup_active kernel; then
	act=$(for w in /sys/class/wakeup/wakeup*; do [ "$(cat $w/active_time_ms 2>/dev/null)" != 0 ] && cat $w/name 2>/dev/null; done | tr '\n' ' ')
	C power.wakeup_active PASS info "listed" "held right now: ${act:-none} (USB + adb keep the phone awake during the sweep)"
	if [ -r /sys/kernel/debug/wakeup_sources ]; then rx=$(grep -E '^qcom_rx_wakelock' /sys/kernel/debug/wakeup_sources | tr -s '\t ' ' ' | cut -d' ' -f2,4)
	else rx=$(for w in /sys/class/wakeup/wakeup*; do [ "$(cat $w/name 2>/dev/null)" = qcom_rx_wakelock ] && echo "$(cat $w/active_count) $(cat $w/wakeup_count)"; done); fi
	if [ -z "$rx" ]; then C wifi.rx_wakelock SKIP kernel "no qcom_rx_wakelock source" "source not registered (Wi-Fi off, or a driver without it)"
	else M wifi_rx_wakelock_active_count "$(num "$rx")"; case "$rx" in "0 "*) C wifi.rx_wakelock PASS kernel "active_count 0" "active_count wakeup_count = $rx";; *) C wifi.rx_wakelock FAIL kernel "active_count > 0" "active_count wakeup_count = $rx (a hard RX wakelock per packet keeps the phone out of suspend in AOD/Doze)";; esac; fi
fi
sc=$(D suspend_control_internal | grep -cE 'wake ?lock|Wakelock')
C power.suspend_service "$([ "$(svc system_suspend)" = running ] && echo PASS || echo FAIL)" kernel+ROM "system_suspend=$(svc system_suspend)" "autosuspend: $(D suspend_control_internal | grep -m1 -iE 'suspend (enabled|attempts)|Autosuspend' | tr -s ' '); $sc wakelock lines"
