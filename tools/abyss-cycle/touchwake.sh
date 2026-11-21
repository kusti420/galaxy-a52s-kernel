#!/system/bin/sh
# Touch IC (stm_ts) as a wakeup source while Abyss sleeps: same script on 5.4 and 6.12. Runs as root ON the phone.
#   sh touchwake.sh [dark_s=30]      FROM=doze: screen off (AOD doze, touch driver in LPM) before the enter
# Enters Abyss, waits until abyssd has blanked its screen (15 s timeout) and the touch driver went to its low-power
# mode, reads whether the touch IRQ is armed as a wakeup IRQ (/sys/kernel/irq/N/wakeup = enable_irq_wake taken) and
# the device-level wakeup flag, then leaves. Also prints crashrecovery.rescue_boot_count before and after (each
# leave = a new system_server = noteBoot). RESET=1: set it to 0 right before the leave, as the proposed abyss.rc
# line does before `start zygote` (ICHTHYS-ROM-NOTES.md 1). Silent, no vibration, no key injection.
DARK=${1:-30}
irqn() { awk '/stm_ts|fts_ts|sec_touch/ {sub(":","",$1); print $1; exit}' /proc/interrupts; }
irqc() { awk -v n="$1" '$1==n":" {c=0; for (i=2;i<=9;i++) c+=$i; print c}' /proc/interrupts; }
tnode() { for d in /sys/class/input/event*; do [ "$(cat $d/device/name 2>/dev/null)" = sec_touchscreen ] && { echo /dev/input/${d##*/}; return; }; done; }
holders() { N=$(tnode); ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v n="$N" '/^\/proc\/[0-9]+\/fd:$/ {split($0,a,"/"); p=a[3]} $NF==n {print p}' | sort -u | while read p; do echo -n "$(cat /proc/$p/comm 2>/dev/null)($p) "; done; }
tdev() { for d in /sys/class/input/event*; do [ "$(cat $d/device/name 2>/dev/null)" = sec_touchscreen ] && { readlink -f $d/device/device; return; }; done; }
st() { I=$(irqn); D=$(tdev); echo "$1: irq=$I count=$(irqc $I) irq_wakeup=$(cat /sys/kernel/irq/$I/wakeup 2>/dev/null || echo n/a) dev_wakeup=$(cat $D/power/wakeup 2>/dev/null) dev_wakeup_count=$(cat $D/power/wakeup_count 2>/dev/null) pwrkey_irq_wakeup=$(cat /sys/kernel/irq/$(awk '/pmic_pwrkey|qpnp_kpdpwr|pon_kpdpwr/ {sub(":","",$1); print $1; exit}' /proc/interrupts)/wakeup 2>/dev/null) rescue_boot_count=$(getprop crashrecovery.rescue_boot_count) state=$(getprop sys.abyss.state) touch_open_by=[$(holders)]"; }
android_up() { [ -n "$(pidof system_server)" ] && [ "$(getprop init.svc.bootanim)" = stopped ] && dumpsys window 2>/dev/null | grep -q mCurrentFocus; }
echo "touchwake FROM=${FROM:-awake} RESET=${RESET:-0} $(uname -r) $(date '+%F %T') uptime $(cut -d' ' -f1 /proc/uptime) touch dev $(tdev)"
st "android, screen $(dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+')"
dmesg -c >/dev/null
[ "${FROM:-awake}" = doze ] && { input keyevent SLEEP; sleep 8; st "android dozing $(dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+')"; }
setprop sys.abyss.request enter
i=0; while [ "$(getprop sys.abyss.state)" != active ] && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
sleep 3; st "abyss +3s (screen lit by abyssd)"
sleep $DARK; st "abyss +$((DARK+3))s (abyssd screen off after its 15 s timeout)"
echo "touch driver lines while in Abyss:"; dmesg | grep -iE "stm_ts|\[sec_input\]|tsp|lowpower|LPM|irq_wake" | grep -vE "set_power|ss_panel|Panel LPM|irq_thread: +event|mode:0000" | cut -c1-160 | tail -15
[ "${RESET:-0}" = 1 ] && { setprop crashrecovery.rescue_boot_count 0; echo "RESET: crashrecovery.rescue_boot_count set to $(getprop crashrecovery.rescue_boot_count) before the leave"; }
setprop sys.abyss.request leave
i=0; while ! android_up && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
echo "leave: android up after ${i}s"
st "android after leave"
