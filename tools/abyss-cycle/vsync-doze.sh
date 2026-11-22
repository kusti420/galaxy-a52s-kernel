#!/system/bin/sh
# AOD vsync-drain A/B (root, on the phone; screen must already be off = Dozing with AOD):
#   sh vsync-doze.sh [secs=20]
# Two windows of <secs>: A = idle doze, B = /data/local/tmp/vsyncloop.dex running (a Choreographer
# loop = an app that requests every vsync, like com.instagram.android on the daily phone 11-21).
# Per window: frames the loop got, timerfd arms per task (surfaceflinger 'app' EventThread),
# msm_drm (MDSS: vsync/TE/rd_ptr) + arch_timer + all IRQs, CPU non-idle %, [timerfd]/total wakeup
# events, and SurfaceFlinger's power mode / hw vsync state / active mode / doze screen state.
# Needs timerfd-rank.sh and vsyncloop.dex in /data/local/tmp. Read-only apart from the trace buffer.
SECS=${1:-20}; T=/data/local/tmp
irqs() { awk '/^ *[0-9]+:/{s=0; for(i=2;i<=9;i++) s+=$i; if ($0 ~ /msm_drm/) d+=s; if ($0 ~ /arch_timer/) a+=s; t+=s} /^ *IPI/{s=0; for(i=2;i<=9;i++) s+=$i; ipi+=s} END{print d+0, a+0, t+0, ipi+0}' /proc/interrupts; }
cpu() { awk '/^cpu /{print $2+$3+$4+$7+$8, $5+$6}' /proc/stat; }
ws() { awk '$1=="[timerfd]"{tf+=$4} NR>1{ev+=$4} END{print tf+0, ev+0}' /sys/kernel/debug/wakeup_sources 2>/dev/null; }
state() {
  echo "  wakefulness: $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1) dozeScreenState(dream): $(dumpsys dreams | grep -o 'dozeScreenState=[0-9]*' | head -1)"
  dumpsys SurfaceFlinger > $T/sf.txt 2>/dev/null
  echo "  SF: $(grep -m1 -o 'powerMode=[A-Za-z]*' $T/sf.txt) $(grep -m1 -o 'hwVsyncState=[A-Za-z]*' $T/sf.txt) $(grep -m1 'activeMode=' $T/sf.txt | grep -o 'vsyncRate=[0-9.]* Hz')"
  echo "  panel (last LP/ON line): $(dmesg | grep -E 'LP1|LP2|NO_LP|Panel LPM' | tail -1 | cut -c1-140)"
}
win() { # $1 = label, $2 = 1 to run the loop
  L=$2; echo "== window $1 ($SECS s)"; state
  [ "$L" = 1 ] && { CLASSPATH=$T/vsyncloop.dex app_process / Vsyncloop $((SECS+4)) $((SECS+4)) > $T/vl.out 2>&1 & sleep 2; }
  set -- $(irqs) $(cpu) $(ws); i0="$*"
  sh $T/timerfd-rank.sh $SECS > $T/tfr.out 2>&1
  set -- $(irqs) $(cpu) $(ws); i1="$*"
  echo "$i0 $i1" | awk -v s=$SECS '{n=NF/2; printf "  msm_drm %.1f/s  arch_timer %.1f/s  all IRQ %.1f/s  IPI %.1f/s  CPU busy %.1f %% (of all cores)  [timerfd] events %d  all wakeup events %d\n", ($(n+1)-$1)/s, ($(n+2)-$2)/s, ($(n+3)-$3)/s, ($(n+4)-$4)/s, 100*($(n+5)-$5)/(($(n+5)-$5)+($(n+6)-$6)), $(n+7)-$7, $(n+8)-$8}'
  sed -n '/timerfd arms/,/alarmtimer starts/p' $T/tfr.out | grep -v alarmtimer | head -6 | sed 's/^/  /'
  [ "$L" = 1 ] && { wait; echo "  vsyncloop: $(tail -2 $T/vl.out | tr '\n' ' ')"; }
  state | tail -2
}
echo "kernel $(uname -r) uptime $(cut -d' ' -f1 /proc/uptime) battery $(dumpsys battery | grep -m1 -o 'level: [0-9]*') plugged $(dumpsys battery | grep -E 'USB powered|AC powered' | tr -d ' \n')"
win A-idle 0
win B-vsyncloop 1
echo "== vblank trace, idle (5 s)"; sh $T/vbltrace.sh 5 0 | head -14
echo "== vblank trace, vsyncloop (5 s)"; sh $T/vbltrace.sh 5 1 | head -14
