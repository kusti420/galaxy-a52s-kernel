#!/system/bin/sh
# Who owns the "[timerfd]" wakeup source? (root, on the phone; read-only apart from a trace instance)
#   sh tfdwake.sh start      # arm a ring-buffer trace (keeps running on/off the cable, across suspends)
#   sh tfdwake.sh report     # attribute every "[timerfd]" activation to the task that armed that timer
#   sh tfdwake.sh stop       # remove the instance
#   sh tfdwake.sh now [secs] # start + sleep + report + stop in one go (default 60 s)
# An EPOLLWAKEUP epoll item on a timerfd holds its own wakeup source named "[timerfd]"; it is activated
# from the timer's expiry (timerfd_tmrproc for CLOCK_MONOTONIC/REALTIME/BOOTTIME, alarm timers for the
# *_ALARM clocks) -> ep_poll_callback -> __pm_stay_awake. Trace: timer:hrtimer_start/hrtimer_expire_entry
# filtered on timerfd_tmrproc (hrtimer pointer links arm -> expiry; the arming task is the user),
# alarmtimer:alarmtimer_start/_fired, power:wakeup_source_activate (*timerfd*), power:suspend_resume
# (machine_suspend), kprobes on s2idle_wake (+stack), pm_system_irq_wakeup (irq) and timerfd_clock_was_set. Report: per arming task: [timerfd] activations caused, how many came right out of a
# suspend or INSIDE s2idle (an expiry inside s2idle after timekeeping froze = a non-ALARM timer firing in
# suspend: kernel bug), the arm->expiry time (trace clock; stops in suspend), then the user's EPOLLWAKEUP timerfds.
T=/sys/kernel/tracing; [ -d $T/events ] || T=/sys/kernel/debug/tracing; I=$T/instances/tfdwake
KP="p:a52tfd/s2wake s2idle_wake|p:a52tfd/irqwake pm_system_irq_wakeup irq=%x0:u32|p:a52tfd/tfdcws timerfd_clock_was_set|p:a52tfd/hard pm_wakeup_ws_event hard=%x2:u8|p:a52tfd/svcin qrtr_get_service_id node=%x0:u32 port=%x1:u32|r:a52tfd/svc qrtr_get_service_id svc=\$retval:s32"
kp_add() { echo "$KP" | tr '|' '\n' | while read l; do n=${l%% *}; n=${n#?:}; [ -d $T/events/$n ] || echo "$l" >> $T/kprobe_events; done; }
kp_del() { for n in s2wake irqwake tfdcws hard svcin svc; do echo "-:a52tfd/$n" >> $T/kprobe_events 2>/dev/null; done; }
ev() { for e in a52tfd/s2wake a52tfd/irqwake a52tfd/tfdcws a52tfd/hard a52tfd/svcin a52tfd/svc timer/hrtimer_start timer/hrtimer_expire_entry power/wakeup_source_activate power/suspend_resume alarmtimer/alarmtimer_start alarmtimer/alarmtimer_fired; do [ -d $I/events/$e ] && echo $1 > $I/events/$e/enable; done; }
start() {
  kp_add 2>/dev/null; mkdir -p $I || exit 1; echo 0 > $I/tracing_on; echo > $I/trace; echo ${KB:-4096} > $I/buffer_size_kb
  echo 'function.function == timerfd_tmrproc' > $I/events/timer/hrtimer_start/filter
  echo 'function.function == timerfd_tmrproc' > $I/events/timer/hrtimer_expire_entry/filter
  echo 'name ~ "*timerfd*"' > $I/events/power/wakeup_source_activate/filter
  echo 'action ~ "machine_suspend" || action ~ "timekeeping_freeze"' > $I/events/power/suspend_resume/filter
  [ -d $I/events/a52tfd/s2wake ] && echo stacktrace > $I/events/a52tfd/s2wake/trigger
  [ -d $I/events/a52tfd/hard ] && { echo 'hard == 1' > $I/events/a52tfd/hard/filter; echo stacktrace > $I/events/a52tfd/hard/trigger; }
  ev 1; echo 1 > $I/tracing_on; echo "tfdwake: tracing since uptime $(cut -d' ' -f1 /proc/uptime)"
}
report() {
  [ -d $I ] || { echo "no trace instance (run start first)"; exit 1; }
  echo 0 > $I/tracing_on; cat $I/trace > /data/local/tmp/tfdwake.trace; echo 1 > $I/tracing_on
  F=/data/local/tmp/tfdwake.trace
  echo "== trace $(grep -vc '^#' $F) lines, [timerfd] activations: $(grep -c 'wakeup_source_activate: \[timerfd\]' $F), s2idle entries (machine_suspend begin): $(grep -c 'machine_suspend\[1\] begin' $F), timekeeping frozen: $(grep -c 'timekeeping_freeze\[[0-9]*\] begin' $F), first $(grep -v '^#' $F | head -1 | awk '{print $4}') last $(tail -1 $F | awk '{print $4}')"
  awk '
    !/^#/ { i=index($0," ["); task=substr($0,1,i-1); sub(/^ +/,"",task); sub(/ +$/,"",task); r=substr($0,i+2); cpu=substr(r,1,index(r,"]")-1)+0
            if (match($0,/ [0-9]+\.[0-9]+: /)) { ts=substr($0,RSTART+1,RLENGTH-3)+0 } }
    / hrtimer_start:/ { match($0,/hrtimer=[^ ]*/); p=substr($0,RSTART+8,RLENGTH-8); owner[p]=task; armts[p]=ts }
    / hrtimer_expire_entry:/ { match($0,/hrtimer=[^ ]*/); p=substr($0,RSTART+8,RLENGTH-8); lastexp[cpu]=p; lastts[cpu]=ts }
    / alarmtimer_start:/ { match($0,/alarmtimer:[^ ]*/); p=substr($0,RSTART,RLENGTH); owner[p]=task " (ALARM)"; armts[p]=ts }
    / alarmtimer_fired:/ { match($0,/alarmtimer:[^ ]*/); p=substr($0,RSTART,RLENGTH); lastexp[cpu]=p; lastts[cpu]=ts }
    / machine_suspend\[1\] begin/ { insusp=1; tkf=0 }
    / timekeeping_freeze\[[0-9]*\] begin/ { tkf=1 }
    / machine_suspend\[1\] end/ { insusp=0; resumets=ts }
    / wakeup_source_activate: \[timerfd\]/ {
      # from a timer expiry (irq context, right after hrtimer_expire_entry/alarmtimer_fired on this cpu)
      # or from the user itself (epoll_wait re-activates the item while it collects the event)
      p=lastexp[cpu]
      if (task !~ /^<idle>/ && !(p != "" && ts-lastts[cpu] < 0.002)) { reown[task]++; next }
      o="?"; d=-1
      if (p != "" && ts-lastts[cpu] < 0.005) { o=(p in owner)?owner[p]:"armed before trace"; if (p in armts) d=lastts[cpu]-armts[p] }
      n[o]++; if (resumets != "" && ts-resumets < 0.2) rs[o]++; if (insusp) { ins[o]++; if (tkf) inf[o]++ }
      if (d >= 0) { sum[o]+=d; if (!(o in mn) || d<mn[o]) mn[o]=d; if (d>mx[o]) mx[o]=d }
    }
    END { for (o in n) printf "%7d activations at expiry (%d within 0.2 s after a resume, %d inside s2idle of which %d after timekeeping froze)  armed by %s  arm->fire %.3f..%.3f s (mean %.3f)\n", n[o], rs[o]+0, ins[o]+0, inf[o]+0, o, mn[o]+0, mx[o]+0, (n[o]?sum[o]/n[o]:0)
          for (t in reown) printf "%7d epoll-collect activations in task %s\n", reown[t], t }' $F | sort -rn | head -12 | tee /data/local/tmp/tfdwake.top
  echo "== what ended each s2idle: s2idle_wake callers (first stack frames under s2idle_wake) and wake IRQs"
  awk '/ s2wake:/ {st=1; c=""; k=0; next}
       st && /^ *=> / { f=$2; if (f ~ /^s2idle_wake/) { c=""; k=0; next } if (k<4) { c=(c=="")?f:c" <- "f; k++ } next }
       st && /<stack trace>/ { next }
       st { if (c!="") w[c]++; st=0 }
       END { if (st && c!="") w[c]++; for (k2 in w) printf "%7d  %s\n", w[k2], k2 }' $F | sort -rn | head -6
  grep -o 'irqwake: ([^)]*) irq=[0-9]*' $F | sed 's/.*irq=//' | sort | uniq -c | sort -rn | head -6 | while read c q; do echo "  $c wake IRQ $q: $(grep -E "^ *$q:" /proc/interrupts | awk '{$1=""; for(i=2;i<=9;i++) $i=""; print}' | tr -s ' ')"; done
  echo "  hard wakeup events (pm_wakeup_ws_event hard=1) by chain, and how many fell inside s2idle (machine_suspend begin..end):"
  awk '/ machine_suspend\[1\] begin/ {ins=1} / machine_suspend\[1\] end/ {ins=0}
       / hard: / {st=1; c=""; k=0; hin=ins; next}
       st && /^ *=> / { f=$2; if (f ~ /^pm_wakeup_ws_event/) { c=""; k=0; next } if (k<3) { c=(c=="")?f:c" <- "f; k++ } next }
       st && /<stack trace>/ { next }
       st { if (c!="") { w[c]++; if (hin) wi[c]++ } st=0 }
       END { for (x in w) printf "%7d (%d in s2idle)  %s\n", w[x], wi[x]+0, x }' $F | sort -rn | head -6
  echo "  QRTR packets received by node:service (node 0 modem, 5 adsp; all / inside s2idle):"
  awk '/ machine_suspend\[1\] begin/ {ins=1} / machine_suspend\[1\] end/ {ins=0}
       / svcin: / { match($0,/node=[0-9]+/); nd=substr($0,RSTART+5,RLENGTH-5); next }
       / svc: / { match($0,/svc=-?[0-9]+/); sv=substr($0,RSTART+4,RLENGTH-4); c[nd":"sv]++; if (ins) ci[nd":"sv]++ }
       END { for (x in c) printf "%7d / %d  node:svc %s\n", c[x], ci[x]+0, x }' $F | sort -rn | head -8
  echo "  timerfd_clock_was_set calls (clock-set/resume -> CANCEL_ON_SET timerfds woken): $(grep -c 'tfdcws:' $F), by: $(grep 'tfdcws:' $F | awk '{print $1}' | sed 's/-[0-9]*$//' | sort | uniq -c | sort -rn | head -3 | tr '\n' ' ')"
  echo "== owners (tid -> process) and their EPOLLWAKEUP timerfds (fd clockid it_value it_interval)"
  sed -n 's/.*armed by \(.*\)  arm->.*/\1/p; s/.*activations in task \(.*\)$/\1/p' /data/local/tmp/tfdwake.top | sed 's/ (ALARM)//' | awk '{n=split($0,a,"-"); if (a[n] ~ /^[0-9]+$/) print a[n]}' | sort -u | while read tid; do
    pid=$(awk '/^Tgid:/{print $2}' /proc/$tid/status 2>/dev/null); [ -n "$pid" ] || { echo "  tid $tid: gone"; continue; }
    echo "  tid $tid = pid $pid $(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-80) uid $(awk '/^Uid:/{print $2}' /proc/$pid/status)"
    grep -H -E "^(clockid|it_value|it_interval):|^tfd:" /proc/$pid/fdinfo/* 2>/dev/null | awk '
      { n=split($1,a,"/"); fd=a[n]; sub(/:.*/,"",fd); l=$0; sub(/^[^:]*:/,"",l) }
      l ~ /^clockid:/ { ck[fd]=$2 } l ~ /^it_value:/ { v=l; gsub(/[^0-9,]/,"",v); val[fd]=v } l ~ /^it_interval:/ { v=l; gsub(/[^0-9,]/,"",v); iv[fd]=v }
      l ~ /^tfd:/ { t=l; sub(/^tfd: */,"",t); split(t,b," "); e=""; if (match(l,/events: *[0-9a-f]+/)) { e=substr(l,RSTART,RLENGTH); sub(/events: */,"",e) }
                    d=(length(e)>=8)?substr(e,length(e)-7,1):"0"; if (index("2367abef",d)>0) wk[b[1]]=1 }
      END { for (f in ck) if (f in wk) print "    fd", f, "clockid", ck[f], "value", val[f], "interval", iv[f], "EPOLLWAKEUP" }'
  done
}
case "$1" in
  start) start ;;
  report) report ;;
  stop) ev 0; echo '!stacktrace' > $I/events/a52tfd/s2wake/trigger 2>/dev/null; echo '!stacktrace' > $I/events/a52tfd/hard/trigger 2>/dev/null; rmdir $I && echo "tfdwake: stopped"; kp_del ;;
  now) start; sleep ${2:-60}; report; ev 0; echo '!stacktrace' > $I/events/a52tfd/s2wake/trigger 2>/dev/null; echo '!stacktrace' > $I/events/a52tfd/hard/trigger 2>/dev/null; rmdir $I; kp_del ;;
  *) sed -n 2,6p $0 ;;
esac
