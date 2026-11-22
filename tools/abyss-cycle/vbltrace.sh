#!/system/bin/sh
# DRM vblank requests/deliveries + sde_evtlog functions for <secs> (root): vbltrace.sh [secs=5] [loop=0|1]
SECS=${1:-5}; TR=/sys/kernel/tracing; I=$TR/instances/vbl; mkdir -p $I || exit 1
echo 0 > $I/tracing_on; echo > $I/trace; echo 8192 > $I/buffer_size_kb
for e in drm/drm_vblank_event drm/drm_vblank_event_queued drm/drm_vblank_event_delivered sde/sde_evtlog irq/irq_handler_entry; do echo 1 > $I/events/$e/enable; done
[ "$2" = 1 ] && { CLASSPATH=/data/local/tmp/vsyncloop.dex app_process / Vsyncloop $((SECS+3)) 100 >/dev/null 2>&1 & sleep 2; }
echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on
for e in drm/drm_vblank_event drm/drm_vblank_event_queued drm/drm_vblank_event_delivered sde/sde_evtlog irq/irq_handler_entry; do echo 0 > $I/events/$e/enable; done
echo "drm_vblank_event (vblank irq handled): $(grep -c ' drm_vblank_event:' $I/trace)  queued: $(grep -c drm_vblank_event_queued $I/trace)  delivered: $(grep -c drm_vblank_event_delivered $I/trace)"
echo "irq handlers by name:"; grep irq_handler_entry $I/trace | grep -o 'name=[^ ]*' | sort | uniq -c | sort -rn | head -8
echo "queued by task:"; grep drm_vblank_event_queued $I/trace | awk '{print $1}' | sort | uniq -c | head
echo "sde_evtlog top functions:"; grep sde_evtlog $I/trace | sed 's/.*sde_evtlog: *//' | awk '{print $1}' | sort | uniq -c | sort -rn | head -12
grep ' drm_vblank_event:' $I/trace | head -3; grep sde_evtlog $I/trace | head -5
wait; rmdir $I
