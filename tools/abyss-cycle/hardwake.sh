#!/system/bin/sh
# Hard wakeup events per source for <secs> (root, read-only apart from kprobes + a trace instance):
#   sh hardwake.sh [secs=60]
# A "hard" wakeup (pm_wakeup_ws_event(..., hard=true), pm_wakeup_hard_event, pm_system_wakeup) ends an
# s2idle at once without a wake IRQ (pm_wakeup_irq stays empty) and is invisible in the wake reasons
# when its wakeup source has a 0 ms timeout (qrtr: CONFIG_QRTR_WAKEUP_MS=0). Counts them by call chain,
# plus the QRTR services (node:svc) of every received packet (qrtr_get_service_id), which is what hard-
# wakes for modem/ADSP QMI traffic unless the service is in the edge's qcom,no-wake-svc list.
SECS=${1:-60}; T=/sys/kernel/tracing; I=$T/instances/hardwake
for l in "p:a52hw/hard pm_wakeup_ws_event hard=%x2:u8" "p:a52hw/sysw pm_system_wakeup" "p:a52hw/svcin qrtr_get_service_id node=%x0:u32 port=%x1:u32" "r:a52hw/svc qrtr_get_service_id svc=\$retval:s32"; do
  n=${l%% *}; n=${n#?:}; [ -d $T/events/$n ] || echo "$l" >> $T/kprobe_events; done
mkdir -p $I || exit 1; echo 0 > $I/tracing_on; echo > $I/trace; echo 4096 > $I/buffer_size_kb
echo 'hard == 1' > $I/events/a52hw/hard/filter
echo stacktrace > $I/events/a52hw/hard/trigger; echo stacktrace > $I/events/a52hw/sysw/trigger
for e in hard sysw svcin svc; do echo 1 > $I/events/a52hw/$e/enable; done
echo "hardwake: $SECS s, $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1), uptime $(cut -d' ' -f1 /proc/uptime)"
echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on
for e in hard sysw svcin svc; do echo 0 > $I/events/a52hw/$e/enable; done
echo '!stacktrace' > $I/events/a52hw/hard/trigger; echo '!stacktrace' > $I/events/a52hw/sysw/trigger
F=/data/local/tmp/hardwake.trace; cat $I/trace > $F; rmdir $I
for n in hard sysw svcin svc; do echo "-:a52hw/$n" >> $T/kprobe_events; done
echo "== hard wakeup events: $(grep -c ' hard: ' $F) pm_wakeup_ws_event(hard), $(grep -c ' sysw: ' $F) pm_system_wakeup; by call chain:"
awk '/ (hard|sysw): / {st=1; c=""; k=0; next}
     st && /^ *=> / { f=$2; if (f ~ /^(pm_wakeup_ws_event|pm_system_wakeup)/) { c=""; k=0; next } if (k<4) { c=(c=="")?f:c" <- "f; k++ } next }
     st && /<stack trace>/ { next }
     st { if (c!="") w[c]++; st=0 }
     END { if (st && c!="") w[c]++; for (x in w) printf "%7d  %s\n", w[x], x }' $F | sort -rn | head -10
echo "== received QRTR packets by node:service (svc -1 = control/unknown port)"
awk '/ svcin: / { match($0,/node=[0-9]+/); nd=substr($0,RSTART+5,RLENGTH-5); next } / svc: / { match($0,/svc=-?[0-9]+/); s=substr($0,RSTART+4,RLENGTH-4); c[nd":"s]++ } END { for (k in c) printf "%7d  node:svc %s\n", c[k], k }' $F | sort -rn | head -15
