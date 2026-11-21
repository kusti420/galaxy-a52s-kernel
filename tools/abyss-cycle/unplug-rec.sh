#!/system/bin/sh
# Off-the-cable recorder. Runs as root ON the phone, detached; the user unplugs USB for ~10 minutes.
#   setsid nohup sh unplug-rec.sh [doze_s=300] [abyss_s=240] >/dev/null 2>&1 &
# Phase A (AOD doze, screen off, panel in LP1): real suspends, what aborts them, what wakes, panel lines.
# Phase B (Abyss with persist.abyss.suspend=1): abyssd's own suspend loop, an injected power-key tap, leave.
# The script only runs while the phone is awake (it is frozen in suspend), so every wait is on the wall clock.
# Ends when USB is back (or after the phases). Report: /data/local/tmp/unplug/report.txt. Silent, no vibration.
# Key mode (wake from REAL suspend by a real key):  setsid nohup sh unplug-rec.sh key [after_s=150] ... &
#   the user unplugs, waits 1 minute, presses the power key ONCE, then touches nothing; the script records the
#   suspend before the press, the wake reason, the key's IRQ count, the screen coming on, the screen timing out
#   again and the next suspends, until USB is back (or after_s seconds after the press).
MODE=phases; [ "${1:-}" = key ] && { MODE=key; AFTER_S=${2:-150}; }
DOZE_S=${1:-300}; ABYSS_S=${2:-240}
O=/data/local/tmp/unplug; rm -rf $O; mkdir -p $O; R=$O/report.txt
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
now() { date +%s; }
usb() { cat /sys/class/power_supply/usb/online 2>/dev/null; }
stats() { echo "suspend_stats: success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail) last_failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null) last_failed_errno=$(cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null) total_s2idle_us=$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null)"; }
ws() { awk 'NR>1 && $6>0 {printf "%s(active %s ms) ", $1, $6}' /sys/kernel/debug/wakeup_sources 2>/dev/null | cut -c1-600; echo; }
batt() { echo "battery: $(cat /sys/class/power_supply/battery/capacity)% $(cat /sys/class/power_supply/battery/current_now) $(cat /sys/class/power_supply/battery/status)"; }
tfd() { for f in $(grep -lE "^clockid: [89]$" /proc/[0-9]*/fdinfo/* 2>/dev/null); do p=${f#/proc/}; p=${p%%/*}; v=$(grep "^it_value" $f 2>/dev/null | tr -d '(),' | awk '{print $2}'); [ "${v:-0}" != 0 ] && echo -n "$(cat /proc/$p/comm 2>/dev/null):${v}s "; done; echo; }
summary() { # $1 = dmesg file, $2 = label
  echo "[$2] PM: suspend entry=$(grep -c 'PM: suspend entry' $1) exit=$(grep -c 'PM: suspend exit' $1) aborts=$(grep -ciE 'Abort: |failed to suspend|Some devices failed' $1) freezing-failed=$(grep -c 'Freezing.*failed' $1)"
  echo "[$2] abort reasons:"; grep -iE "Abort: |failed to suspend|not prepared for power transition|Some devices failed" $1 | cut -c16-150 | sed 's/[0-9]\{3,\}/N/g' | sort | uniq -c | sort -rn | head -8
  echo "[$2] wake reasons:"; grep -iE "Resume caused by|wakeup from IRQ|pm_system_irq_wakeup|PM: Triggering wakeup|PM: Wakeup pending|gic_show_resume_irq|hwirq" $1 | cut -c16-140 | sed 's/[0-9]\{5,\}/N/g' | sort | uniq -c | sort -rn | head -10
  echo "[$2] panel: LP1++=$(grep -c 'set_power : LP1 ++' $1) LP2++=$(grep -c 'set_power : LP2 ++' $1) ON++=$(grep -cE 'set_power : (ON|NO_LP) \+\+' $1) OFF++=$(grep -c 'set_power : OFF ++' $1) panel_on=$(grep -c 'ss_panel_on_post : -' $1) panel_off=$(grep -c 'ss_panel_off_post : -' $1) lpm_brightness=$(grep -c 'Panel LPM\]: set brightness' $1) sde_errors=$(grep -cE 'sde error|\[drm:sde_.*(fail|error)' $1) WARN/oops=$(grep -cE 'WARNING: |Oops|Unable to handle' $1)"
}
irqn() { awk -v n="$1" '$NF==n {c=0; for (i=2;i<=9;i++) c+=$i; print c}' /proc/interrupts; }
irqs() { echo "irq counts: pwrkey=$(irqn pmic_pwrkey) resin=$(irqn pmic_resin) volume_up=$(irqn volume_up) stm_ts=$(irqn stm_ts) rtc=$(irqn pm8xxx_rtc_alarm)"; }
wake() { dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2; }
if [ $MODE = key ]; then
{
echo "unplug-rec KEY start $(date '+%F %T') $(uname -r) uptime $(cut -d' ' -f1 /proc/uptime) doze_always_on=$(settings get secure doze_always_on) screen_off_timeout=$(settings get system screen_off_timeout)"
input keyevent SLEEP; sleep 6
echo "wakefulness $(wake) usb=$(usb) volkey_wakeup=$(cat /sys/power/volkey_wakeup 2>/dev/null)"; stats; batt; irqs
for d in /sys/class/input/event*; do n=$(cat $d/device/name 2>/dev/null); case "$n" in pmic_pwrkey|pmic_resin|gpio-keys|sec_touchscreen) echo "wakeup capable: $n $(cat $d/device/device/power/wakeup 2>/dev/null)";; esac; done
echo "active wakeup sources: $(ws)"
echo "waiting for the unplug (max 30 min)"
} > $R 2>&1
t=$(now); while [ "$(usb)" = 1 ] && [ $(( $(now) - t )) -lt 1800 ]; do sleep 1; done
[ "$(usb)" = 1 ] && { echo "never unplugged: end" >> $R; exit 0; }
T0=$(now); dmesg -c > $O/dmesg-before.txt; logcat -c
{
echo "=== K: unplugged at $(date +%T)"; stats; irqs
P0=$(irqn pmic_pwrkey); last=""; lastp=0; TP=0
while [ "$(usb)" != 1 ]; do
  w=$(wake); el=$(( $(now) - T0 ))
  if [ $TP = 0 ] && [ "$(irqn pmic_pwrkey)" != "$P0" ]; then TP=$(now)
    echo "K +${el}s POWER KEY IRQ seen (wakefulness $w) up=$(cut -d' ' -f1 /proc/uptime) last_resume_reason: $(cat /sys/kernel/wakeup_reasons/last_resume_reason 2>/dev/null | tr '\n' ' ')"; stats; irqs; fi
  if [ "$w" != "$last" ] || [ $(( el - lastp )) -ge 30 ]; then
    echo "K +${el}s $(date +%T) up=$(cut -d' ' -f1 /proc/uptime) $w $(batt) last_resume: $(cat /sys/kernel/wakeup_reasons/last_resume_reason 2>/dev/null | head -1)"; last=$w; lastp=$el; fi
  [ $TP != 0 ] && [ $(( $(now) - TP )) -ge $AFTER_S ] && break
  [ $el -ge 1800 ] && break
  sleep 2
done
dmesg -c > $O/dmesg-key.txt; logcat -d -b main -b system > $O/logcat-key.txt 2>/dev/null
echo "K end +$(( $(now) - T0 ))s wall, usb=$(usb)"; stats; batt; irqs
summary $O/dmesg-key.txt K
echo "[K] key / screen lines (kernel):"
grep -nE "PM: suspend (entry|exit)|Resume caused by|pmic_pwrkey|KEY_POWER|qpnp_pon|pon_kpdpwr|set_power : (ON|NO_LP|LP1|LP2|OFF) \+\+|ss_panel_on_post : -" $O/dmesg-key.txt | cut -c1-150 | tail -40
echo "[K] framework:"
grep -E "Waking up from|Going to sleep|WAKE_REASON|PowerManagerService: (Waking|Nap|Sleep)|DisplayPowerController.*state=(ON|OFF|DOZE)" $O/logcat-key.txt | cut -c1-170 | tail -12
[ $TP = 0 ] && echo "[K] NO power-key IRQ was counted while unplugged"
echo "waiting for USB (max 20 min)"; t=$(now); while [ "$(usb)" != 1 ] && [ $(( $(now) - t )) -lt 1200 ]; do sleep 2; done
dmesg > $O/dmesg-after.txt
echo "=== end $(date '+%F %T') usb=$(usb)"; stats; batt; irqs; summary $O/dmesg-after.txt after
echo DONE
} >> $R 2>&1
exit 0
fi
{
echo "unplug-rec start $(date '+%F %T') $(uname -r) uptime $(cut -d' ' -f1 /proc/uptime) doze_always_on=$(settings get secure doze_always_on)"
input keyevent SLEEP; sleep 6
echo "wakefulness $(dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+') alpm=$(cat /sys/class/lcd/panel/alpm) usb=$(usb)"; stats; batt; echo "active wakeup sources: $(ws)"
echo "waiting for the unplug (max 30 min)"
} > $R 2>&1
t=$(now); while [ "$(usb)" = 1 ] && [ $(( $(now) - t )) -lt 1800 ]; do sleep 1; done
[ "$(usb)" = 1 ] && { echo "never unplugged: end" >> $R; exit 0; }
T0=$(now); dmesg -c > $O/dmesg-before.txt
{
echo "=== A: doze, unplugged at $(date +%T)"; stats
while [ $(( $(now) - T0 )) -lt $DOZE_S ] && [ "$(usb)" != 1 ]; do
  echo "A +$(( $(now) - T0 ))s up=$(cut -d' ' -f1 /proc/uptime) $(dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+') $(batt) alarms: $(tfd)"
  sleep 5
done
dmesg -c > $O/dmesg-doze.txt
echo "A end +$(( $(now) - T0 ))s wall; uptime now $(cut -d' ' -f1 /proc/uptime) (CLOCK_MONOTONIC stands still in suspend)"; stats; batt; echo "active wakeup sources: $(ws)"
summary $O/dmesg-doze.txt A
if [ "$(usb)" = 1 ]; then echo "USB came back during A: no Abyss phase"; else
  echo "=== B: Abyss with persist.abyss.suspend=1 at $(date +%T)"
  OLD=$(getprop persist.abyss.suspend); setprop persist.abyss.suspend 1; logcat -c
  setprop sys.abyss.request enter; sleep 6
  echo "state=$(getprop sys.abyss.state) abyssd=$(pidof abyssd) volkey=$(cat /sys/power/volkey_wakeup)"; stats
  T1=$(now); tapped=0
  while [ $(( $(now) - T1 )) -lt $ABYSS_S ] && [ "$(usb)" != 1 ]; do
    echo "B +$(( $(now) - T1 ))s up=$(cut -d' ' -f1 /proc/uptime) abyssd=$(pidof abyssd) $(batt)"
    if [ $tapped = 0 ] && [ $(( $(now) - T1 )) -ge 100 ]; then
      e=""; for d in /sys/class/input/event*; do case "$(cat $d/device/name 2>/dev/null)" in pmic_pwrkey|qpnp_pon) e=/dev/input/${d##*/};; esac; done
      b=$(dmesg | grep -c 'ss_panel_on_post : -'); sendevent $e 1 116 1; sendevent $e 0 0 0; sleep 0.12; sendevent $e 1 116 0; sendevent $e 0 0 0; sleep 2
      echo "B injected power-key tap: panel_on $b -> $(dmesg | grep -c 'ss_panel_on_post : -') (the script was awake, so this is not a wake-from-suspend test)"; tapped=1
    fi
    sleep 5
  done
  dmesg -c > $O/dmesg-abyss.txt; logcat -d -s abyssd > $O/logcat-abyssd.txt 2>/dev/null
  echo "B end +$(( $(now) - T1 ))s wall"; stats; batt
  echo "abyssd: suspend woke=$(grep -c 'suspend: woke' $O/logcat-abyssd.txt) aborted=$(grep -c 'suspend: aborted' $O/logcat-abyssd.txt) entering=$(grep -c 'suspend: entering' $O/logcat-abyssd.txt)"
  grep -E "suspend: (woke|aborted)" $O/logcat-abyssd.txt | sed 's/.*suspend: //' | sed 's/[0-9]\{2,\} ms/N ms/' | sort | uniq -c | head -5
  grep -E "suspend: (woke|aborted)" $O/logcat-abyssd.txt | tail -4 | cut -c1-140
  summary $O/dmesg-abyss.txt B
  setprop sys.abyss.request leave; setprop persist.abyss.suspend "$OLD"
  i=0; while [ $i -lt 90 ]; do [ -n "$(pidof system_server)" ] && [ "$(getprop init.svc.bootanim)" = stopped ] && dumpsys window 2>/dev/null | grep -q mCurrentFocus && break; sleep 1; i=$((i+1)); done
  echo "leave: android up after ${i}s; state=$(getprop sys.abyss.state) ss=$(pidof system_server) sf=$(pidof surfaceflinger)"
  cp /data/misc/abyss/out/session.log $O/session.log 2>/dev/null
fi
echo "waiting for USB (max 20 min)"; t=$(now); while [ "$(usb)" != 1 ] && [ $(( $(now) - t )) -lt 1200 ]; do sleep 2; done
dmesg > $O/dmesg-after.txt
echo "=== end $(date '+%F %T') usb=$(usb)"; stats; batt; summary $O/dmesg-after.txt after
echo DONE
} >> $R 2>&1
