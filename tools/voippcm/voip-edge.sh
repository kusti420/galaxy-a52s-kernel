#!/system/bin/sh
# msm-pcm-voip-v2 edge cases + ADSP SSR mid-stream, silent (zero frames, VoIP routed to the AFE proxy ports
# AFE_PCM_RX/TX, which drive no output). Root. Prints each case and the kernel lines it caused.
V=/data/local/tmp/voippcm
route() { tinymix "AFE_PCM_RX_Voice Mixer Voip" $1 >/dev/null; tinymix "Voip_Tx Mixer AFE_PCM_TX_Voip" $1 >/dev/null; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
R=""; for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name)" in *adsp*) R=${r##*/};; esac; done
klog() { dmesg | grep -iE "voip|msm_pcm_(hw|playback|capture|close|prepare)|BUG:|Oops|WARNING:|list_del|refcount|Unable to handle|dma_free|bad page|corrupt" | grep -v fps_et7xx | cut -c16-160 | sort | uniq -c | sort -rn | head -8; dmesg -C; }
route 1; dmesg -C
echo "== 1. early: 4 playback writes before capture is prepared (state VOIP_STOPPED, 2-node queue)"; $V early; klog
echo "== 2. periods differ per direction (2 playback / 4 capture), then close (free sizes)"; $V run 3 8000 2 4; klog
echo "== 3. hw_params twice on both directions, then run"; $V hw2 3; klog
echo "== 4. ADSP SSR during a running VoIP stream"
$V run 25 > /data/local/tmp/voip-ssr.txt 2>&1 &
sleep 6; echo "SSR $(cut -d' ' -f1 /proc/uptime)"; echo 1 > /sys/kernel/debug/remoteproc/$R/crash
wait; cat /data/local/tmp/voip-ssr.txt; echo "adsp: $(cat /sys/class/remoteproc/$R/state)"; klog
echo "== 5. stream again after the SSR"; sleep 3; $V run 3; klog
route 0
echo "card: $(head -1 /proc/asound/cards)"
