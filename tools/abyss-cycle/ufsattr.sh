#!/system/bin/sh
# What makes the UFS host interrupt? (root, read-only apart from a trace instance): ufsattr.sh [secs=10]
# Enables all ufs:* and ufsqcom:* tracepoints; counts events by name (+ the command/UIC/gating string
# and the task), and lists the UFS IRQ rate in the same window.
SECS=${1:-10}; T=/sys/kernel/tracing; I=$T/instances/ufsattr
mkdir -p $I || exit 1; echo 0 > $I/tracing_on; echo > $I/trace; echo 4096 > $I/buffer_size_kb
echo 1 > $I/events/ufs/enable; [ -d $I/events/ufsqcom ] && echo 1 > $I/events/ufsqcom/enable
u() { awk '/ufshcd/{s=0; for(i=2;i<=9;i++) s+=$i; print s}' /proc/interrupts | head -1; }
a=$(u); echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on; b=$(u)
echo 0 > $I/events/ufs/enable; [ -d $I/events/ufsqcom ] && echo 0 > $I/events/ufsqcom/enable
echo "ufsattr: $SECS s, $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1), ufshcd IRQs $((b-a)) ($(( (b-a)/SECS ))/s), trace events $(grep -vc '^#' $I/trace)"
echo "== events by name:"; grep -v '^#' $I/trace | sed 's/.*: \(ufs[a-z_0-9]*\): .*/\1/' | sort | uniq -c | sort -rn | head -15
echo "== top event detail (name + first fields, task):"
grep -v '^#' $I/trace | awk '{i=index($0," ["); t=substr($0,1,i-1); sub(/^ +/,"",t); sub(/-[0-9]+ *$/,"",t); m=$0; sub(/.*: ufs/,"ufs",m); n=split(m,f," "); d=f[1]" "f[2]" "f[3]" "f[4]; gsub(/tag: *[0-9]+|lba: *[0-9]+|[0-9a-f]{8,}/,"",d); c[d"  ["t"]"]++} END{for(k in c) printf "%7d  %s\n", c[k], k}' | sort -rn | head -15
grep -v '^#' $I/trace | head -6 | cut -c1-220
rmdir $I
