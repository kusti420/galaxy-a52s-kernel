#!/system/bin/sh
# READ-ONLY reference dump of the Samsung OneUI kernel interfaces (run as root on 5.4 and on 6.12, same phone;
# diff the two outputs). Writes nothing. The UFS UN is printed only as length + sha256.
echo "== $(uname -r) $(getprop ro.build.display.id)"
echo "== modules: $(grep -E '^(cpufreq_limit|ufs_sec_sysfs|usb_f_ss_mon_gadget|usb_f_ss_conn_gadget|input_booster) ' /proc/modules | cut -d' ' -f1 | tr '\n' ' ')"
echo "== /sys/power"; ls -lZ /sys/power/cpufreq_table /sys/power/cpufreq_min_limit /sys/power/cpufreq_max_limit /sys/power/over_limit /sys/power/limit_stat 2>&1
echo "table: $(cat /sys/power/cpufreq_table 2>&1)"
echo "min=$(cat /sys/power/cpufreq_min_limit 2>&1) max=$(cat /sys/power/cpufreq_max_limit 2>&1) over=$(cat /sys/power/over_limit 2>&1)"
echo "limit_stat:"; cat /sys/power/limit_stat 2>&1
echo "== cflm"; ls -lZ /sys/devices/system/cpu/cflm/ 2>&1; cat /sys/devices/system/cpu/cflm/info 2>&1
for c in 0 4 7; do echo "policy$c: $(cat /sys/devices/system/cpu/cpufreq/policy$c/scaling_available_frequencies 2>&1) | min $(cat /sys/devices/system/cpu/cpufreq/policy$c/scaling_min_freq) max $(cat /sys/devices/system/cpu/cpufreq/policy$c/scaling_max_freq)"; done
echo "== sec/ufs"; ls -lZ /sys/class/sec/ufs/ 2>&1 | grep -v -e ' power$' -e ' subsystem ->'
un=$(cat /sys/class/sec/ufs/un 2>&1); echo "un: len=${#un} bytes=$(cat /sys/class/sec/ufs/un 2>/dev/null | wc -c) prefix=$(echo "$un" | cut -c1-6) sha256=$(printf '%s\n' "$un" | sha256sum | cut -d' ' -f1)"
for n in lt lc man_id transferred_cnt sec_wb_enable; do echo "$n: $(cat /sys/class/sec/ufs/$n 2>&1)"; done
H=/sys/class/scsi_host/host0; ls -lZ $H/ 2>&1 | grep -iE "unique|SEC_|sense|lt|lc|man_" ; [ -e $H/unique_number ] && echo "host0/unique_number present" || echo "host0/unique_number absent"
for n in SEC_UFS_op_cnt SEC_UFS_err_sum sense_err_count; do echo "$n: $(cat $H/$n 2>&1)"; done
echo "== input_booster"; ls -lZ /sys/class/input_booster/ 2>&1; ls -lZ /sys/devices/virtual/input_booster/touch/ 2>&1
for d in key touchkey touch multitouch keyboard MOUSE mouse_wheel pen_hover pen; do echo "$d: head=[$(cat /sys/class/input_booster/$d/head 2>&1)] tail=[$(cat /sys/class/input_booster/$d/tail 2>&1)] level=$(cat /sys/class/input_booster/$d/level 2>&1)"; done
for f in enable_event debug_level sendevent ib_mode_state; do echo "$f=$(cat /sys/class/input_booster/$f 2>&1)"; done
echo "== usb"; ls -lZ /dev/usb_mtp_gadget /dev/android_ssusbcon 2>&1; ls /config/usb_gadget/g1/functions/ 2>&1 | tr '\n' ' '; echo
ls -l /config/usb_gadget/g1/configs/b.1/ 2>&1; echo "usb.config=$(getprop sys.usb.config) state=$(getprop sys.usb.state)"
ls -lZ /sys/class/misc/usb_mtp_gadget/ /sys/class/misc/android_ssusbcon/ 2>&1 | head -20
echo "== avc for these paths"; dmesg 2>/dev/null | grep 'avc:' | grep -E 'cpufreq_|over_limit|limit_stat|cflm|input_booster|ib_mode|name="un"|unique_number|usb_mtp_gadget|ssusbcon|ss_mon|conn_gadget' | tail -20
echo "== END"
