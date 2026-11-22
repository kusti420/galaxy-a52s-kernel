#!/system/bin/sh
# Who does storage I/O right now? (root, read-only apart from a trace instance): ioattr.sh [secs=20]
# block:block_rq_issue per issuing task + rwbs + device, f2fs/ext4-free; then /proc/<pid>/io
# read_bytes/write_bytes/syscw deltas per process over the same window (the real owner when the
# issuing task is a kworker / f2fs flusher).
SECS=${1:-20}; T=/sys/kernel/tracing; I=$T/instances/ioattr
mkdir -p $I || exit 1; echo 0 > $I/tracing_on; echo > $I/trace; echo 4096 > $I/buffer_size_kb
echo 1 > $I/events/block/block_rq_issue/enable
snap() { for p in /proc/[0-9]*; do [ -r $p/io ] && echo "${p#/proc/} $(awk '/^(read_bytes|write_bytes|syscw|cancelled_write_bytes):/{printf "%s ", $2}' $p/io) $(cat $p/comm 2>/dev/null)"; done; }
snap > /data/local/tmp/io0; echo 1 > $I/tracing_on; sleep $SECS; echo 0 > $I/tracing_on; snap > /data/local/tmp/io1
echo 0 > $I/events/block/block_rq_issue/enable
echo "== block requests issued in $SECS s: $(grep -c block_rq_issue $I/trace); by task, rwbs, device:"
grep block_rq_issue $I/trace | awk '{i=index($0," ["); t=substr($0,1,i-1); sub(/^ +/,"",t); sub(/-[0-9]+ *$/,"",t); match($0,/block_rq_issue: [0-9]+,[0-9]+ [A-Z]+/); x=substr($0,RSTART+16,RLENGTH-16); c[t"  "x]++} END{for(k in c) printf "%7d  %s\n", c[k], k}' | sort -rn | head -12
echo "== per-process deltas (write_bytes read_bytes syscw), top 12 by write_bytes:"
awk 'NR==FNR{w[$1]=$4; r[$1]=$3; s[$1]=$2; next} ($1 in w){dw=$4-w[$1]; dr=$3-r[$1]; ds=$2-s[$1]; if (dw>0||dr>0||ds>0) printf "%10d %10d %7d  pid %s %s\n", dw, dr, ds, $1, $6}' /data/local/tmp/io0 /data/local/tmp/io1 | sort -rn | head -12
rmdir $I
