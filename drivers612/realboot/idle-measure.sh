#!/bin/bash
# Idle snapshot of a real 6.12 boot on white cable for A/B of kernel words (clk/pd/regulator_ignore_unused):
# screen off, waits until uptime >= SETTLE (default 180 s), then samples 60 s: battery current/temp, tsens zones,
# and counts enabled clocks / regulators / power domains. Usage: idle-measure.sh <label> -> logs/idle-<label>.txt
set -u; cd "$(dirname "$0")/../.."; S=PHONE2; L=logs/idle-$1.txt; SETTLE=${SETTLE:-180}
A() { adb -s $S shell "$@" 2>/dev/null | tr -d '\r'; }
adb -s $S root >/dev/null 2>&1; sleep 2
A 'input keyevent KEYCODE_SLEEP'
UP=$(A 'cut -d. -f1 /proc/uptime'); [ "$UP" -lt "$SETTLE" ] && sleep $((SETTLE - UP))
{
echo "idle $1: $(A 'cat /proc/device-tree/soc/a52sxq,realboot' | tr -d '\0') uptime $(A 'cut -d. -f1 /proc/uptime') s, $(A 'grep -oE "[a-z]+_ignore_unused" /proc/cmdline' | tr '\n' ' ')"
A 'i=0; cs=0; ts=0; cp=0; while [ $i -lt 30 ]; do c=$(cat /sys/class/power_supply/battery/current_now); t=$(cat /sys/class/power_supply/battery/temp); z=0; n=0; for f in /sys/class/thermal/thermal_zone*; do case $(cat $f/type) in cpu-*) z=$((z + $(cat $f/temp))); n=$((n+1));; esac; done; cs=$((cs + c)); ts=$((ts + t)); cp=$((cp + z / n)); i=$((i+1)); sleep 2; done; echo "battery current_now avg $((cs/30)) (unit of the driver, mA; + = charging), battery temp avg $((ts/30)) (0.1 C), cpu tsens avg $((cp/30)) mC, capacity $(cat /sys/class/power_supply/battery/capacity) status $(cat /sys/class/power_supply/battery/status)"'
A 'echo "usb input: $(cat /sys/class/power_supply/usb/current_now 2>/dev/null) voltage_now $(cat /sys/class/power_supply/battery/voltage_now)"; echo "clocks enabled: $(awk "NR>3 && \$2>0" /sys/kernel/debug/clk/clk_summary | wc -l) of $(awk "NR>3" /sys/kernel/debug/clk/clk_summary | wc -l)"; echo "regulators with use_count>0: $(awk "NR>2 && \$2>0" /sys/kernel/debug/regulator/regulator_summary | wc -l)"; echo "power domains on: $(grep -c " on " /sys/kernel/debug/pm_genpd/pm_genpd_summary) off: $(grep -cE " off(-[0-9]+)? " /sys/kernel/debug/pm_genpd/pm_genpd_summary)"; echo "cpuidle cluster/deep usage: $(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/usage | tr "\n" " ")"; echo "wakeup sources active: $(awk "NR>1 && \$6>0 {print \$1}" /sys/kernel/debug/wakeup_sources | tr "\n" " ")"'
} | tee "$L"
A 'awk "NR>3 && \$2>0 {print \$1}" /sys/kernel/debug/clk/clk_summary' | sort > "logs/idle-$1-clocks.txt"
A 'grep -E " on |^domain" /sys/kernel/debug/pm_genpd/pm_genpd_summary | awk "{print \$1}"' | sort > "logs/idle-$1-genpd.txt"
A 'awk "NR>2 && \$2>0 {print \$1}" /sys/kernel/debug/regulator/regulator_summary' | sort -u > "logs/idle-$1-regulators.txt"
