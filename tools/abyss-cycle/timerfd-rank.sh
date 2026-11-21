#!/system/bin/sh
# Who arms timerfds how often, and which of them sit in an EPOLLWAKEUP epoll set? (root, on the phone)
#   sh timerfd-rank.sh [secs=10]
# tracefs timer:hrtimer_start (function timerfd_tmrproc = a timerfd armed/re-armed by that task) and
# alarmtimer:alarmtimer_start (ALARM clockids) for <secs>, counted per task; then, for the top
# processes, their timerfds (fdinfo clockid / it_value / it_interval) and whether an epoll set of the
# process watches them with EPOLLWAKEUP (events bit 0x20000000: an expiry then holds a wakeup source,
# "Pending Wakeup Sources: [timerfd]"). Read-only apart from the trace buffer.
SECS=${1:-10}; TR=/sys/kernel/tracing; [ -d $TR/events ] || TR=/sys/kernel/debug/tracing
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
I=$TR/instances/tfdrank; mkdir -p $I || exit 1
echo 0 > $I/tracing_on; echo > $I/trace; echo 4096 > $I/buffer_size_kb
echo 1 > $I/events/timer/hrtimer_start/enable; [ -d $I/events/alarmtimer ] && echo 1 > $I/events/alarmtimer/alarmtimer_start/enable
echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on
echo "== timerfd arms in $SECS s (task-pid count):"
grep "function=timerfd_tmrproc" $I/trace | awk '{print $1}' | sort | uniq -c | sort -rn | head -15 | tee /data/local/tmp/tfd-top.txt
echo "== alarmtimer starts (task-pid count):"
grep "alarmtimer_start" $I/trace | awk '{print $1}' | sort | uniq -c | sort -rn | head -8
echo 0 > $I/events/timer/hrtimer_start/enable; [ -d $I/events/alarmtimer ] && echo 0 > $I/events/alarmtimer/alarmtimer_start/enable
rmdir $I 2>/dev/null
echo "== timerfds of the top processes (tgid comm fd clockid it_value it_interval epoll):"
awk '{n=split($2,a,"-"); print a[n]}' /data/local/tmp/tfd-top.txt | while read tid; do awk '/^Tgid:/{print $2}' /proc/$tid/status 2>/dev/null; done | sort -u | while read p; do
  # one grep per process; EPOLLWAKEUP = bit 29 of the epoll entry's events (hex digit 8 from the right has bit 1)
  grep -H -E "^(clockid|it_value|it_interval):|^tfd:" /proc/$p/fdinfo/* 2>/dev/null | awk -v p=$p -v comm="$(cat /proc/$p/comm 2>/dev/null)" '
    { n=split($1,a,"/"); fd=a[n]; sub(/:.*/,"",fd); l=$0; sub(/^[^:]*:/,"",l) }
    l ~ /^clockid:/ { ck[fd]=$2 }
    l ~ /^it_value:/ { v=l; gsub(/[^0-9,]/,"",v); val[fd]=v }
    l ~ /^it_interval:/ { v=l; gsub(/[^0-9,]/,"",v); iv[fd]=v }
    l ~ /^tfd:/ { t=l; sub(/^tfd: */,"",t); split(t,b," "); e=""; if (match(l,/events: *[0-9a-f]+/)) { e=substr(l,RSTART,RLENGTH); sub(/events: */,"",e) }
                  d=(length(e)>=8)?substr(e,length(e)-7,1):"0"; w=(index("2367abef",d)>0); if (w) wk[b[1]]="EPOLLWAKEUP"; else if (!(b[1] in wk)) wk[b[1]]="epoll" }
    END { for (f in ck) print p, comm, "fd", f, "clockid", ck[f], "value", val[f], "interval", iv[f], ((f in wk)?wk[f]:"no-epoll") }'
done | head -40
