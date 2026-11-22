#!/system/bin/sh
# HW vsync timeline in doze (root): vsync-timeline.sh [loop_secs=10] [samples=24] [step=5]
# Screen off (KEYCODE_SLEEP) first, then per step: msm_drm IRQ/s, SF hwVsyncState, mMoreSamplesNeeded, tracker period.
# A vsyncloop runs for <loop_secs> starting at the 4th sample (0 = no loop).
LS=${1:-10}; N=${2:-24}; ST=${3:-5}
d() { awk '/msm_drm/{s=0; for(i=2;i<=9;i++) s+=$i; print s}' /proc/interrupts; }
i=0; p=$(d)
while [ $i -lt $N ]; do
  [ $i = 3 ] && [ $LS -gt 0 ] && { CLASSPATH=/data/local/tmp/vsyncloop.dex app_process / Vsyncloop $LS 100 >/dev/null 2>&1 & }
  sleep $ST; c=$(d); v=$(dumpsys SurfaceFlinger --vsync 2>/dev/null)
  echo "t=$((i*ST+ST))s msm_drm/s=$(( (c-p)/ST )) $(echo "$v" | grep -m1 -o 'hwVsyncState=[A-Za-z]*') $(echo "$v" | grep -m1 -o 'mMoreSamplesNeeded=[0-9]') $(echo "$v" | grep -m1 -o 'period = [0-9.]*ms') $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1)"
  p=$c; i=$((i+1))
done
wait
