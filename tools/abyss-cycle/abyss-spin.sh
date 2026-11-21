#!/system/bin/sh
# What abyssd does with its screen on (root, on the phone): enter Abyss, sample abyssd's threads
# (CPU, current syscall, wchan), strace summary + simpleperf for a few seconds in two phases:
# (A) right after enter (abyssd lit the panel), (B) after its screen timeout + an injected short
# power-key press (screen on again). Then leave. Silent (no audio is started).
O=/data/local/tmp/abyss-spin; rm -rf $O; mkdir -p $O
android_up() { [ -n "$(pidof system_server)" ] && [ "$(getprop init.svc.bootanim)" = stopped ] && dumpsys window 2>/dev/null | grep -q mCurrentFocus; }
pwrdev() { for d in /sys/class/input/event*; do case "$(cat $d/device/name 2>/dev/null)" in pmic_pwrkey|qpnp_pon) echo /dev/input/${d##*/}; return;; esac; done; }
tap_power() { e=$(pwrdev); sendevent $e 1 116 1; sendevent $e 0 0 0; sleep 0.12; sendevent $e 1 116 0; sendevent $e 0 0 0; }
sample() { # $1 label
  P=$(pidof abyssd); echo "=== $1: abyssd $P"
  top -H -b -n 1 -p $P 2>/dev/null | head -20
  for i in 1 2 3 4 5 6 7 8 9 10; do for t in /proc/$P/task/*; do echo "$(cat $t/comm) $(cut -d' ' -f1 $t/syscall) $(cat $t/wchan 2>/dev/null) $(awk '{print $14+$15}' $t/stat)"; done; sleep 0.2; done | sort | uniq -c | sort -rn | head -20
  timeout 3 strace -f -c -p $P -o $O/strace-$1.txt >/dev/null 2>&1; echo "strace -c:"; head -25 $O/strace-$1.txt
  timeout 2 strace -f -tt -p $P -o $O/strace-raw-$1.txt >/dev/null 2>&1; echo "strace raw (first 40):"; head -40 $O/strace-raw-$1.txt | cut -c1-160
  simpleperf record -p $P --duration 3 -g -o $O/perf-$1.data >/dev/null 2>&1; simpleperf report -i $O/perf-$1.data --sort tid,comm,dso,symbol 2>/dev/null | head -40
}
OLD_TO=$(getprop persist.abyss.screen_timeout_s); setprop persist.abyss.screen_timeout_s 15
logcat -b all -c
setprop sys.abyss.request enter
i=0; while [ "$(getprop sys.abyss.state)" != active ] && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
sleep 3; sample A-after-enter
sleep 20; echo "screen should be off now"; sample C-screen-off
tap_power; sleep 2; sample B-after-key
logcat -d -s abyssd > $O/abyssd.txt
setprop sys.abyss.request leave; setprop persist.abyss.screen_timeout_s "$OLD_TO"
i=0; while ! android_up && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
echo "leave: android up after ${i}s"
