# on-phone (root): xkv.sh <set>... : cold-read verify of xk sets; on 6.x also counts blk_crypto_fallback_bio_prep calls
T=/sys/kernel/tracing; K=0
if [ -d $T ] && grep -q blk_crypto_fallback_bio_prep /proc/kallsyms 2>/dev/null; then
  echo > $T/kprobe_events; echo "p:k_fb blk_crypto_fallback_bio_prep" >> $T/kprobe_events && echo 1 > $T/events/kprobes/enable && echo > $T/trace && echo 1 > $T/tracing_on && K=1
fi
sync; echo 3 > /proc/sys/vm/drop_caches
for s in "$@"; do sh /data/local/tmp/xk.sh verify $s; done
if [ $K = 1 ]; then echo 0 > $T/tracing_on; echo "fallback_bio_prep calls during the reads: $(grep -c k_fb $T/trace)"; echo 0 > $T/events/kprobes/enable; echo > $T/kprobe_events; fi
echo "kernel $(uname -r) up $(cut -d. -f1 /proc/uptime)s; fsck: $(logcat -d -b main,system 2>/dev/null | grep -E ' vold .*(fsck.f2fs|fsck on /data)' | tail -1 | cut -c1-120)"
echo "fscrypt/f2fs/vold errors: $(dmesg | grep -ciE 'fscrypt.*(error|fail)|F2FS-fs.*(error|inconsistent|corrupt)|error (programming|evicting) key') kernel, $(logcat -d -b main,system 2>/dev/null | grep -E ' E vold' | grep -vc 'bootctrl')  vold E lines"
