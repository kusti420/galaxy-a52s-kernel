#!/system/bin/sh
# vblank timestamps (drm_vblank_event time=) for <secs> with the vsyncloop running (root): intervals in us
SECS=${1:-3}; TR=/sys/kernel/tracing; I=$TR/instances/vblts; mkdir -p $I || exit 1
echo 0 > $I/tracing_on; echo > $I/trace; echo 1 > $I/events/drm/drm_vblank_event/enable; echo 1 > $I/events/irq/irq_handler_entry/enable
CLASSPATH=/data/local/tmp/vsyncloop.dex app_process / Vsyncloop $((SECS+3)) 100 >/dev/null 2>&1 & sleep 2
echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on; echo 0 > $I/events/drm/drm_vblank_event/enable; echo 0 > $I/events/irq/irq_handler_entry/enable
grep ' drm_vblank_event:' $I/trace | sed 's/.*time=\([0-9]*\).*/\1/' | awk 'NR>1{printf "%d ", ($1-p)/1000} {p=$1} END{print ""}'
grep 'irq_handler_entry' $I/trace | grep msm_drm | awk '{t=$4; sub(":","",t); if (p) printf "%d ", (t-p)*1000000; p=t} END{print ""}'
wait; rmdir $I
