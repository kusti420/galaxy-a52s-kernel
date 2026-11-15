#!/bin/sh
# /extra/m2check.sh: read-only M1/M2 report of a running mainline 7.3 session (runs /extra/m2up.sh
# first). Used as KX_EXTRA=/extra/m2check.sh by kx-cycle; output = logs/<run>/kexeced-extra.txt.
# Writes only: cpufreq governors (restored to schedutil), one 300 ms vibrator pulse, the watchdog.
uname -r; cat /proc/cmdline; echo CPUS $(grep -c processor /proc/cpuinfo); grep MemTotal /proc/meminfo; echo IDLE $(cat /sys/devices/system/cpu/cpuidle/current_driver) $(ls /sys/devices/system/cpu/cpu0/cpuidle | tr '\n' ' ');
/extra/m2up.sh;
echo == regulators; grep -E "^ +vreg" /sys/kernel/debug/regulator/regulator_summary | tr -s ' ' | cut -d' ' -f2,6-7 | tr '\n' ';'; echo;
echo == adc; for f in /sys/bus/iio/devices/iio:device0/in_*_input; do echo "${f##*/} $(cat $f)"; done | tr '\n' ';'; echo;
echo == thermal; for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type)=$(cat $z/temp)"; done | tr '\n' ' '; echo;
echo == input; grep -E "Name" /proc/bus/input/devices | tr '\n' ' '; echo; grep -E "gpio(62|91|101) " /sys/kernel/debug/gpio;
echo == vibrator; E=$(grep -l gpio-vibrator /sys/class/input/event*/device/name | sed 's|/sys/class/input/\(event[0-9]*\)/.*|\1|'); (/extra/ffbuzz /dev/input/$E 300; echo ffbuzz rc=$?) & sleep 0.15; grep "gpio62 " /sys/kernel/debug/gpio; wait; grep "gpio62 " /sys/kernel/debug/gpio;
echo == sd; ls /sys/class/mmc_host; grep -E "power mode|vdd" /sys/kernel/debug/mmc*/ios;
echo == display; insmod /extra/mdpdump.ko 2>/dev/null; dmesg | grep -E "mdpdump: (VIG0|INTF1)" | tail -2;
echo == cpufreq; for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "${p##*/} $(cat $p/scaling_governor) $(cat $p/scaling_cur_freq) [$(cat $p/cpuinfo_min_freq)-$(cat $p/cpuinfo_max_freq)]"; done;
echo == l3; insmod /extra/epssdump.ko samples=1 sram=0 >/dev/null 2>&1; G=/sys/devices/system/cpu/cpufreq; s() { grep -E "d0\(L3\) running|d0 VOTE0" /proc/epssdump | tr -s ' ' | tr '\n' ' '; echo; };
sleep 3; echo -n "schedutil: "; s; for p in 0 4 7; do echo powersave > $G/policy$p/scaling_governor; done; sleep 3; echo -n "powersave: "; s; for p in 0 4 7; do echo performance > $G/policy$p/scaling_governor; done; sleep 3; echo -n "performance: "; s; for p in 0 4 7; do echo schedutil > $G/policy$p/scaling_governor; done;
echo == remoteproc; for r in /sys/class/remoteproc/*; do echo "$(cat $r/name) $(cat $r/state)"; done; ls /dev/fastrpc*;
echo == wdt; cat /sys/module/hhwdt/parameters/status; killall watchdog; sleep 1; cat /sys/module/hhwdt/parameters/status;
echo == problems; dmesg | grep -E "WARNING|BUG|Oops|Internal error|SError|smmu.*fault|Unhandled" | head; cat /sys/kernel/debug/devices_deferred
