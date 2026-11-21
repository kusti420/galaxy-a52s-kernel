#!/system/bin/sh
# Abyss enter/leave cycle. Runs as root ON the phone (push it, then run it through /system/bin/su):
#   sh cycle.sh <cycles> [seconds_active]
# Hands-free: enters through the ROM's own property trigger, watches, leaves, checks Android is back.
# Works on the ROM's 5.4 kernel and on 6.12 (same script = comparable output). Silent, no vibration.
N=${1:-1}; ACTIVE_S=${2:-40}; SUSP=${3:-}   # 3rd argument: value for persist.abyss.suspend during the run (restored after)
O=/data/local/tmp/abyss-cycle; mkdir -p $O
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
kerr() { dmesg | grep -cE "WARNING: |Oops| BUG:|BUG: |sde error|\[drm:sde_.*(fail|error)|Unable to handle"; }
drmmaster() { cat /sys/kernel/debug/dri/0/clients 2>/dev/null | awk 'NR>1 && $4=="y"{print $1"("$2")"}' | tr "\n" " "; }
panel() { echo "on=$(dmesg | grep -c 'ss_panel_on_post : -') off=$(dmesg | grep -c 'ss_panel_off_post : -') underrun=$(dmesg | grep 'mdp underrun' | grep -vc 'underrun: 0')"; }
pwrdev() { for d in /sys/class/input/event*; do case "$(cat $d/device/name 2>/dev/null)" in pmic_pwrkey|qpnp_pon) echo /dev/input/${d##*/}; return;; esac; done; }
tap_power() { e=$(pwrdev); [ -n "$e" ] || { echo "no power key device"; return; }; sendevent $e 1 116 1; sendevent $e 0 0 0; sleep 0.12; sendevent $e 1 116 0; sendevent $e 0 0 0; }
halpid() { pidof android.hardware.audio.service audiohalservice.qti 2>/dev/null | tr "\n" " "; }
wait_for() { # wait_for <seconds> <cmd...>: prints the seconds it took, or "timeout"
  n=$1; shift; i=0; while [ $i -lt $((n*2)) ]; do "$@" >/dev/null 2>&1 && { echo $((i/2)); return 0; }; sleep 0.5; i=$((i+1)); done; echo timeout; return 1; }
is_state() { [ "$(getprop sys.abyss.state)" = "$1" ]; }
android_up() { [ -n "$(pidof system_server)" ] && [ "$(getprop init.svc.bootanim)" = stopped ] && dumpsys window 2>/dev/null | grep -q mCurrentFocus; }
c=1
while [ $c -le $N ]; do
  L=$O/cycle-$(uname -r | cut -d. -f1-2)-$c.txt
  {
  echo "=== cycle $c $(uname -r) $(date +%T) uptime $(cut -d' ' -f1 /proc/uptime)"
  echo "before: state=$(getprop sys.abyss.state) ss=$(pidof system_server) sf=$(pidof surfaceflinger) hal=$(halpid) volkey=$(cat /sys/power/volkey_wakeup 2>&1) online=$(cat /sys/devices/system/cpu/online) kerr=$(kerr) master=$(drmmaster)"
  dmesg -c > $O/dmesg-pre-$c.txt
  logcat -c 2>/dev/null
  OLDSUSP=$(getprop persist.abyss.suspend); [ -n "$SUSP" ] && setprop persist.abyss.suspend "$SUSP"
  setprop sys.abyss.request enter
  echo "enter: active after $(wait_for 20 is_state active) s"
  sleep 4
  echo "+4s: abyssd=$(pidof abyssd) $(ps -AZ 2>/dev/null | grep -c 'u:r:abyssd:s0.*abyssd') in abyssd domain; ss=$(pidof system_server) sf=$(pidof surfaceflinger) audioserver=$(pidof audioserver) hal=$(halpid)"
  echo "+4s: master=$(drmmaster) volkey=$(cat /sys/power/volkey_wakeup 2>&1) online=$(cat /sys/devices/system/cpu/online) bl=$(cat /sys/class/backlight/panel0-backlight/brightness)"
  sleep 1; echo "+5s: panel $(panel) (abyssd lit the panel)"
  sleep 5
  echo "+10s: hal=$(halpid) sys.abyss.hal=$(getprop sys.abyss.hal) cards=$(cat /proc/asound/cards 2>/dev/null | grep -c '^ *[0-9]') kerr=$(kerr)"
  sleep 12; echo "+22s: panel $(panel) (after the 15 s screen timeout)"
  tap_power; sleep 2; echo "+24s: panel $(panel) (after an injected short power-key press: wakes the screen)"
  s=24; while [ $s -lt $ACTIVE_S ]; do sleep 4; s=$((s+4)); done
  echo "+${s}s: abyssd=$(pidof abyssd) state=$(getprop sys.abyss.state) panel $(panel) master=$(drmmaster) hal=$(halpid) kerr=$(kerr) persist.abyss.suspend=$(getprop persist.abyss.suspend)"
  echo "abyssd suspend log: $(logcat -d -s abyssd 2>/dev/null | grep -c 'suspend: woke') woke, $(logcat -d -s abyssd 2>/dev/null | grep -c 'suspend: aborted') aborted"
  echo "abyssd cpu: $(top -b -n1 -p $(pidof abyssd) 2>/dev/null | tail -1 | awk '{print $9"% "$12}')"
  echo "suspend lines: $(dmesg | grep -cE 'PM: suspend entry') entries, $(dmesg | grep -cE 'PM: suspend exit') exits, aborts $(dmesg | grep -ciE 'Abort|failed to suspend')"
  echo "--- kernel display/audio lines while active:"
  dmesg | grep -v "init: Command" | grep -E "dsi_display_set_power|sde error|bolero|lpass.*(fail|err)|volkey|WARNING: |Oops|msm_drm.*(fail|err)|lastclose|DRM master|ASoC.*(fail|err)|afe_.*(fail|err)|q6.*timeout" | cut -c16-170 | sort | uniq -c | sort -rn | head -25
  echo "--- init commands of abyss.rc that failed: $(dmesg | grep 'init: Command' | grep -c failed)"
  dmesg | grep 'init: Command' | grep failed | sed "s/.*Command '\([^']*\)'.*failed: \(.*\)/  \1 => \2/" | cut -c1-150
  echo "--- avc denials for abyss domains: $(dmesg | grep 'avc: *denied' | grep -c abyss) (logcat: $(logcat -d 2>/dev/null | grep 'avc: *denied' | grep -c abyss))"
  echo "--- abyssd log (warn/error + last lines):"
  logcat -d -s abyssd 2>/dev/null | grep -E " [WE] " | cut -c32-200 | sort | uniq -c | sort -rn | head -20
  logcat -d -s abyssd 2>/dev/null | tail -6 | cut -c32-200
  dmesg > $O/dmesg-active-$c.txt
  logcat -d -s abyssd > $O/logcat-abyssd-$c.txt 2>/dev/null
  setprop sys.abyss.request leave
  [ -n "$SUSP" ] && setprop persist.abyss.suspend "$OLDSUSP"
  echo "leave: state off after $(wait_for 20 is_state off) s; android up after $(wait_for 120 android_up) s"
  sleep 20
  echo "after +20s: ss=$(pidof system_server) sf=$(pidof surfaceflinger) audioserver=$(pidof audioserver) hal=$(halpid) abyssd=$(pidof abyssd) volkey=$(cat /sys/power/volkey_wakeup 2>&1) online=$(cat /sys/devices/system/cpu/online) master=$(drmmaster)"
  echo "wifi: $(ip -4 addr show wlan0 2>/dev/null | grep -c inet) addr, ping 1.1.1.1: $(ping -c2 -W3 1.1.1.1 2>/dev/null | grep -c 'bytes from')/2, $(dumpsys connectivity 2>/dev/null | grep -m1 -oE 'WIFI.*VALIDATED' | cut -c1-12)VALIDATED?"
  echo "ril: $(getprop init.svc.ril-daemon) baseband=$(getprop gsm.version.baseband) sim=$(getprop gsm.sim.state)"
  echo "svc: fp=$(getprop init.svc.vendor.fingerprint-default) sensors=$(getprop init.svc.vendor.sensors-hal-multihal) wv=$(getprop init.svc.vendor.drm-widevine-hal-1-3) power=$(getprop init.svc.vendor.power-hal-aidl) cam=$(getprop init.svc.vendor.camera.provider) netd=$(getprop init.svc.netd)"
  echo "sf: $(dumpsys SurfaceFlinger 2>/dev/null | grep -m1 -E 'refresh-rate|activeMode|fps')"
  echo "audio: $(dumpsys media.audio_flinger 2>/dev/null | grep -c 'Output thread') output threads, cards=$(grep -c '^ *[0-9]' /proc/asound/cards)"
  echo "top cpu: $(top -b -n1 -m5 2>/dev/null | tail -5 | awk '{printf "%s%%=%s ", $9, $12}')"
  echo "kerr=$(kerr); kernel lines after leave:"
  dmesg | grep -E "sde error|WARNING: |Oops|bolero.*(fail|err)|lastclose" | cut -c16-170 | sort | uniq -c | sort -rn | head -12
  dmesg > $O/dmesg-after-$c.txt
  cp /data/misc/abyss/out/session.log $O/session.log 2>/dev/null
  echo "session.log: $(wc -l < /data/misc/abyss/out/session.log 2>/dev/null) lines"
  } > $L 2>&1
  cat $L
  c=$((c+1))
done
