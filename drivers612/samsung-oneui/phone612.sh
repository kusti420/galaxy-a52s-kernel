#!/system/bin/sh
# 6.12 runtime check of the Samsung OneUI compat modules (root; OneUI 9 on rbou/s99q+). Read-only except:
# cpufreq_{min,max}_limit (restored to -1), mem_boost_mode (auto-resets), pios_enable (restored). Never touches
# /sys/class/lcd/panel (read only). Silent (no vibration, no audio, no input injection).
P=/sys/devices/system/cpu/cpufreq
pol() { for c in 0 4 7; do printf 'p%s %s-%s ' $c "$(cat $P/policy$c/scaling_min_freq)" "$(cat $P/policy$c/scaling_max_freq)"; done; }
echo "== $(uname -r) $(getprop ro.build.display.id) up $(cut -d' ' -f1 /proc/uptime)"
for m in cpufreq_limit ufs_sec_sysfs usb_f_ss_mon_gadget usb_f_ss_conn_gadget input_booster a52sxq_vrr_state a52sxq_mm_boost blk_sec_stats sec_argos subsys_compat; do
	printf '%-22s %s\n' $m "$(grep "^$m " /proc/modules | cut -d' ' -f3- || echo MISSING)"; done
echo "== cpufreq_limit"; ls -lZ /sys/power/cpufreq_* /sys/power/over_limit /sys/power/limit_stat
echo "table: $(cat /sys/power/cpufreq_table)"
echo "base:              $(pol)"
for v in 1056000 902400; do echo $v > /sys/power/cpufreq_max_limit; sleep 0.3; echo "max_limit $v: $(pol)"; done
echo -1 > /sys/power/cpufreq_max_limit; sleep 0.3; echo "max_limit -1:      $(pol)"
echo 1324800 > /sys/power/cpufreq_min_limit; sleep 0.3; echo "min_limit 1324800: $(pol) sched_boost=$(cat /proc/sys/walt/sched_boost)"
echo -1 > /sys/power/cpufreq_min_limit; sleep 0.3; echo "min_limit -1:      $(pol) sched_boost=$(cat /proc/sys/walt/sched_boost)"
cat /sys/devices/system/cpu/cflm/info | tail -4; echo "limit_stat:"; cat /sys/power/limit_stat
echo "== input_booster"; ls -lZ /sys/class/input_booster/ | grep -v '^l'; for d in touch multitouch key; do echo "$d head=[$(cat /sys/class/input_booster/$d/head)] tail=[$(cat /sys/class/input_booster/$d/tail)]"; done
grep -A3 input_booster /proc/bus/input/handlers 2>/dev/null | head -4
echo "== ufs"; ls -lZ /sys/class/sec/ufs/ | grep -v -e ' power$' -e ' subsystem'; un=$(cat /sys/class/sec/ufs/un); echo "un len=${#un} sha256=$(printf '%s\n' "$un" | sha256sum | cut -d' ' -f1)"
echo "lt=$(cat /sys/class/sec/ufs/lt) man_id=$(cat /sys/class/sec/ufs/man_id)"
echo "== usb"; ls -lZ /dev/usb_mtp_gadget /dev/android_ssusbcon 2>&1; ls /config/usb_gadget/g1/functions/ | tr '\n' ' '; echo; ls -l /config/usb_gadget/g1/configs/b.1/ | grep -- '->'
echo "usb.config=$(getprop sys.usb.config) state=$(getprop sys.usb.state)"
echo "== vrr_state"; ls -lZ /sys/class/lcd/panel/vrr_state 2>&1; echo "bytes=$(cat /sys/class/lcd/panel/vrr_state 2>/dev/null | wc -c)"
echo "== mm_boost"; ls -lZ /sys/kernel/mm/vmscan/ 2>&1; echo 2 > /sys/kernel/mm/vmscan/mem_boost_mode; echo "after write 2: $(cat /sys/kernel/mm/vmscan/mem_boost_mode)"
echo "== blk_sec_stats"; ls -lZ /sys/kernel/blk_sec_stats/; echo "diskios: $(cat /sys/kernel/blk_sec_stats/diskios)"
OLD=$(cat /sys/kernel/blk_sec_stats/pios_enable); echo 1 > /sys/kernel/blk_sec_stats/pios_enable; dd if=/system/bin/toybox of=/dev/null bs=64k 2>/dev/null; sync; sleep 1
echo "pios:"; cat /sys/kernel/blk_sec_stats/pios | head -5; echo $OLD > /sys/kernel/blk_sec_stats/pios_enable
echo "== argos"; ls -lZ /dev/network_throughput 2>&1; ls /proc/device-tree/soc/argos 2>&1 | head -3; echo "argosd: $(pidof argosd || echo not running) restarts=$(getprop init.svc_debug_pid.argos-daemon)"
echo "nt=$(cat /dev/network_throughput 2>&1 | head -c 40)"; cat /sys/devices/system/cpu/cflm/info | grep '\[3\]'
echo "== msm_subsys"; ls /sys/bus/msm_subsys/devices/ 2>&1 | tr '\n' ' '; echo; for n in 2 3 4 5; do echo "subsys$n $(cat /sys/bus/msm_subsys/devices/subsys$n/name 2>&1) $(cat /sys/bus/msm_subsys/devices/subsys$n/state 2>&1)"; done
echo "== kernel log: WARN/BUG + avc on these paths"
dmesg | grep -cE "WARNING:|BUG:|Oops" | sed 's/^/warn+bug+oops lines: /'
dmesg | grep -E "WARNING:|BUG:" | head -5
dmesg | grep 'avc:' | grep -E 'cpufreq_|over_limit|limit_stat|cflm|input_booster|ib_mode|name="un"|"lt"|"lc"|man_id|sec_wb|usb_mtp_gadget|ssusbcon|vrr_state|mem_boost|am_app_launch|blk_sec|diskios|pios|network_throughput|argos|msm_subsys|subsys' | tail -20
echo "== END"
