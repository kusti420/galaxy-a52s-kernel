#!/system/bin/sh
# On-phone check of cpufreq_limit (run as root: adb shell /system/bin/su -c "sh /data/local/tmp/cflm-check.sh").
# Prints nodes, labels, and the effect of writes on the three cluster policies; restores -1 at the end.
P=/sys/devices/system/cpu/cpufreq
pol() { for c in 0 4 7; do printf 'p%s %s-%s ' $c "$(cat $P/policy$c/scaling_min_freq)" "$(cat $P/policy$c/scaling_max_freq)"; done; echo; }
ls -lZ /sys/power/cpufreq_table /sys/power/cpufreq_min_limit /sys/power/cpufreq_max_limit /sys/power/over_limit /sys/power/limit_stat /sys/devices/system/cpu/cflm/
echo "table: $(cat /sys/power/cpufreq_table)"
echo "min=$(cat /sys/power/cpufreq_min_limit) max=$(cat /sys/power/cpufreq_max_limit) over=$(cat /sys/power/over_limit)"
cat /sys/devices/system/cpu/cflm/info
echo "base:            $(pol)"
for v in 1056000 902400 1516800; do echo $v > /sys/power/cpufreq_max_limit; echo "max_limit $v: $(pol)"; done
echo -1 > /sys/power/cpufreq_max_limit; echo "max_limit -1:      $(pol)"
for v in 1324800 600000; do echo $v > /sys/power/cpufreq_min_limit; echo "min_limit $v: $(pol) boost=$(cat /proc/sys/walt/sched_boost 2>/dev/null)"; done
echo -1 > /sys/power/cpufreq_min_limit; echo "min_limit -1:      $(pol) boost=$(cat /proc/sys/walt/sched_boost 2>/dev/null)"
echo "limit_stat:"; cat /sys/power/limit_stat
cat /sys/devices/system/cpu/cflm/info | tail -4
