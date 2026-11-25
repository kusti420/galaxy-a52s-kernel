#!/system/bin/sh
# SSRM / thermal / HYPER consumers: Samsung cpufreq_limit, input_booster, schedtune/uclamp, GPU sysfs, thermistors,
# thermal HAL. One brief write: with ONEUI_WRITE=1 (default) /sys/power/cpufreq_max_limit is set for about half a
# second and put back, to prove the limit reaches the cpufreq policies.
. "${0%/*}/../dev-lib.sh"
P=/sys/power
nodes perf.cpufreq_limit.nodes kernel $P/cpufreq_table $P/cpufreq_min_limit $P/cpufreq_max_limit $P/over_limit $P/limit_stat
val perf.cpufreq_limit.table kernel $P/cpufreq_table
if [ -e $P/cpufreq_max_limit ]; then C perf.cpufreq_limit.idle PASS kernel+ROM "readable" "min=$(rd $P/cpufreq_min_limit) max=$(rd $P/cpufreq_max_limit) over=$(rd $P/over_limit) labels $(lz $P/cpufreq_max_limit) $(lz $P/limit_stat)"; fi
val perf.cflm_info kernel /sys/devices/system/cpu/cflm/info
pol=; for p in /sys/devices/system/cpu/cpufreq/policy*; do pol="$pol ${p##*/}:$(rd $p/cpuinfo_min_freq)-$(rd $p/cpuinfo_max_freq):$(rd $p/scaling_governor)"; done
C perf.cpufreq_policies PASS kernel "$pol"
if needroot perf.cpufreq_limit.react kernel; then
	if [ "${ONEUI_WRITE:-1}" != 1 ]; then C perf.cpufreq_limit.react SKIP kernel "read-only run"
	elif [ ! -w $P/cpufreq_max_limit ]; then C perf.cpufreq_limit.react FAIL kernel "absent" "$P/cpufreq_max_limit"
	else
		last=$(ls -d /sys/devices/system/cpu/cpufreq/policy* | tail -1); prev=$(rd $P/cpufreq_max_limit); b=$(rd $last/scaling_max_freq)
		lim=1324800; grep -qw $lim $P/cpufreq_table 2>/dev/null || lim=$(tr ' ' '\n' < $P/cpufreq_table | grep . | sed -n 8p)
		trap 'echo ${prev:--1} > $P/cpufreq_max_limit 2>/dev/null' EXIT INT TERM
		echo "$lim" > $P/cpufreq_max_limit 2>/dev/null; sleep 0.4; m=$(rd $last/scaling_max_freq); seen=$(rd $P/cpufreq_max_limit)
		echo "${prev:--1}" > $P/cpufreq_max_limit 2>/dev/null; sleep 0.4; a=$(rd $last/scaling_max_freq); trap - EXIT INT TERM
		if [ "${m:-0}" -le "$lim" ] 2>/dev/null && [ "${m:-0}" -lt "${b:-0}" ] && [ "$a" = "$b" ]; then C perf.cpufreq_limit.react PASS kernel "limit applied and released" "${last##*/} scaling_max_freq $b -> $m (limit $lim, node read $seen) -> $a"
		elif [ "${b:-0}" -le "$lim" ] 2>/dev/null; then C perf.cpufreq_limit.react SKIP kernel "policy already limited" "${last##*/} max $b <= $lim before the test (thermal or SSRM limit active)"
		else C perf.cpufreq_limit.react FAIL kernel "limit not applied" "${last##*/} scaling_max_freq $b -> $m (limit $lim) -> $a, restored to '$prev'"; fi
	fi
fi
# input booster (HYPER HAL + framework boosts)
IB=/sys/class/input_booster
nodes perf.input_booster.nodes kernel $IB/enable_event $IB/debug_level $IB/sendevent $IB/touch/head $IB/touch/tail $IB/touch/level
[ -d $IB ] && setl perf.input_booster.devices kernel 5 "$(ls $IB 2>/dev/null | tr '\n' ' ')"
[ -d $IB ] && C perf.input_booster.tables PASS kernel+ROM "$(for d in key touchkey multitouch keyboard MOUSE mouse_wheel pen_hover pen; do echo "$d=[$(rd $IB/$d/head)|$(rd $IB/$d/tail)]"; done | tr '\n' ' ')" "touch (HYPER rewrites it at runtime): head [$(rd $IB/touch/head)] tail [$(rd $IB/touch/tail)] level $(rd $IB/touch/level)"
# scheduler boost surface the Samsung power HAL writes
st=absent; [ -e /dev/stune/top-app/schedtune.boost ] && st="schedtune(boost=$(rd /dev/stune/top-app/schedtune.boost))"
uc=absent; [ -e /dev/cpuctl/top-app/cpu.uclamp.min ] && uc="uclamp(min=$(rd /dev/cpuctl/top-app/cpu.uclamp.min))"
if [ "$st" = absent ] && [ "$uc" = absent ]; then C perf.boost_surface FAIL kernel+ROM "no schedtune, no uclamp"; else C perf.boost_surface PASS kernel+ROM "stune=${st%%\(*} uclamp=${uc%%\(*}" "$st $uc"; fi
w=absent; [ -d /proc/sys/walt ] && w=/proc/sys/walt; [ -e /proc/sys/kernel/sched_boost ] && w="$w /proc/sys/kernel/sched_boost"
C perf.walt_sysctl "$([ "$w" = absent ] && echo FAIL || echo PASS)" kernel+ROM "$w" "sched_boost=$(rd /proc/sys/kernel/sched_boost)$(rd /proc/sys/walt/sched_boost)"
nodes perf.gpu_sysfs kernel /sys/kernel/gpu/gpu_freq_table /sys/kernel/gpu/gpu_max_clock /sys/kernel/gpu/gpu_min_clock /sys/kernel/gpu/gpu_busy /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage /sys/class/kgsl/kgsl-3d0/gpuclk
val perf.gpu_freq_table kernel /sys/kernel/gpu/gpu_freq_table
nodes perf.measured_fps kernel /sys/class/drm/sde-crtc-0/measured_fps
nodes perf.core_ctl kernel /sys/devices/system/cpu/cpu7/core_ctl/max_cpus /sys/devices/system/cpu/cpu4/core_ctl/min_cpus
lat=$(ls -d /sys/class/devfreq/*latfloor* /sys/class/devfreq/*cpu-llcc* /sys/class/devfreq/*cpu-ddr* /sys/devices/system/cpu/bus_dcvs/*/* 2>/dev/null | sed 's|.*/devfreq/||; s|/sys/devices/system/cpu/||' | tr '\n' ' ')
C perf.bus_dcvs PASS kernel+ROM "$([ -n "$lat" ] && echo present || echo none)" "$lat"
C perf.hyper_misc PASS kernel+ROM "kswapd_perftune=$([ -e /proc/sys/vm/kswapd_perftune_cpumask ] && echo y || echo n) pcie_l1ss=$([ -e /sys/devices/virtual/sec/pcie-wifi/pcie_l1ss_ctrl ] && echo y || echo n) ufs_clkscale=$(ls /sys/devices/platform/soc/*ufshc/clkscale_enable 2>/dev/null | grep -c .)"
# thermal
ok=0; t=; for n in ap pa wf; do v=$(rd /sys/class/sec/sec-$n-thermistor/temperature); t="$t $n=$v"; x=$(num "$v"); [ -n "$x" ] && [ "$x" -gt -200 ] && [ "$x" -lt 900 ] && ok=$((ok+1)); done
C thermal.sec_thermistor "$([ $ok = 3 ] && echo PASS || echo FAIL)" kernel "$ok/3 readable and sane" "$t (0.1 C)"
n=0; bad=0; for z in /sys/class/thermal/thermal_zone*; do n=$((n+1)); v=$(cat $z/temp 2>/dev/null); [ -z "$v" ] && bad=$((bad+1)); done
M thermal_zones $n; C thermal.zones "$([ $n -ge 20 ] && echo PASS || echo FAIL)" kernel "zones readable" "$n zones, $bad unreadable"
setl thermal.zone_types kernel 20 "$(cat /sys/class/thermal/thermal_zone*/type 2>/dev/null | tr '\n' ' ')"
setl thermal.cooling_types kernel 3 "$(cat /sys/class/thermal/cooling_device*/type 2>/dev/null | tr '\n' ' ')"
th=$(D thermalservice); hr=$(printf '%s\n' "$th" | grep -m1 -oE 'HAL Ready: *[a-z]+'); sk=$(printf '%s\n' "$th" | grep -cE 'mType=3|SKIN')
if printf '%s' "$hr" | grep -q true && [ "$sk" -gt 0 ]; then C thermal.hal PASS kernel+ROM "HAL ready, skin temperature reported" "$(printf '%s\n' "$th" | grep -m2 -E 'mType=3|SKIN' | tr -s ' ')"; else C thermal.hal FAIL kernel+ROM "hal='$hr' skin_entries=$sk" "$(printf '%s\n' "$th" | head -5)"; fi
C thermal.ssrm "$([ "$(getprop dev.ssrm.init)" = 1 ] && echo PASS || echo FAIL)" kernel+ROM "dev.ssrm.init=$(getprop dev.ssrm.init) version=$(getprop dev.ssrm.version)" "sdhms pid $(pidof com.sec.android.sdhms) siop_level=$(rd /sys/class/power_supply/battery/siop_level)"
