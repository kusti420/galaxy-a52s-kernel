#!/system/bin/sh
# IRQ deltas over <secs> (root, read-only): irqdelta.sh [secs=60]; marks wake-armed IRQs with [WAKE]
SECS=${1:-60}; T=/data/local/tmp
echo "irqdelta: $SECS s, $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1), uptime $(cut -d' ' -f1 /proc/uptime)"
W=""; for d in /sys/kernel/irq/*; do [ "$(cat $d/wakeup 2>/dev/null)" = enabled ] && W="$W ${d##*/}"; done
cat /proc/interrupts > $T/irq0; sleep $SECS; cat /proc/interrupts > $T/irq1
awk -v w="$W" -v s=$SECS 'BEGIN{n=split(w,a," "); for(i=1;i<=n;i++) wk[a[i]":"]=1}
  NR==FNR { t=0; for(i=2;i<=9;i++) t+=$i; v[$1]=t; next }
  { t=0; for(i=2;i<=9;i++) t+=$i; d=t-v[$1]; if (d>0) { $2=$3=$4=$5=$6=$7=$8=$9=""; printf "%8d %6.2f/s %s %s\n", d, d/s, (($1 in wk)?"[WAKE]":"      "), $0 } }' $T/irq0 $T/irq1 | sort -rn | head -25
