# on-phone (root): kat.sh <keyhex128> <iv_offset_sectors> <tag>: dm-default-key known-answer test on testparti (sda32, 4 MB of zeros)
K=$1; IV=$2; TAG=$3; P=/dev/block/sda32; W=/data/local/tmp/kat; T=/sys/kernel/tracing
cmp -s -n 4194304 $P /dev/zero || { echo "KAT: $P is not all zero, refusing"; exit 1; }
echo > $T/kprobe_events; echo "p:k_fb blk_crypto_fallback_bio_prep" >> $T/kprobe_events; echo "p:k_ice qcom_ice_program_key" >> $T/kprobe_events 2>/dev/null
echo 1 > $T/events/kprobes/enable; echo > $T/trace; echo 1 > $T/tracing_on
d=$($W/dmkat create a52kat 0 2048 default-key aes-xts-plain64 $K $IV $P 0 3 allow_discards sector_size:4096 iv_large_sectors) || exit 1
N=/dev/block/dm-${d#*:}; sleep 1
[ "$(cat /sys/block/dm-${d#*:}/dm/name 2>/dev/null)" = a52kat ] && [ "$(cat /sys/block/dm-${d#*:}/dev)" = "$d" ] && [ "$(stat -c %t:%T $N)" = "$(printf %x:%x ${d%:*} ${d#*:})" ] || { echo "KAT: $N is not the new a52kat device, refusing"; $W/dmkat remove a52kat; exit 1; }
dd if=$W/pat.bin of=$N bs=4096 conv=fsync 2>/dev/null; sync; blockdev --flushbufs $N; blockdev --flushbufs $P; echo 3 > /proc/sys/vm/drop_caches
dd if=$P of=$W/ct-$TAG.bin bs=4096 count=256 2>/dev/null; dd if=$N of=$W/rt-$TAG.bin bs=4096 count=256 2>/dev/null
echo 0 > $T/tracing_on; fb=$(grep -c k_fb $T/trace); ice=$(grep -c k_ice $T/trace)
blockdev --flushbufs $N; $W/dmkat remove a52kat
dd if=/dev/zero of=$P bs=1M count=4 conv=fsync 2>/dev/null; sync; blockdev --flushbufs $P
echo 0 > $T/events/kprobes/enable; echo > $T/kprobe_events
cmp -s -n 4194304 $P /dev/zero && z=yes || z=NO
echo "KAT $TAG: fallback_bio_prep calls $fb, qcom_ice_program_key calls $ice, testparti zero again: $z"
