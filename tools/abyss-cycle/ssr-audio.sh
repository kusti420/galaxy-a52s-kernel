#!/bin/bash
# ADSP subsystem restart (SSR) / Abyss robustness check, SILENT (tones are hz=0 digital silence). PC side:
#   tools/abyss-cycle/ssr-audio.sh <serial> idle    SSR with no audio stream
#   tools/abyss-cycle/ssr-audio.sh <serial> voip    SSR during a silent VoIP stream (BtSco: MODE_IN_COMMUNICATION
#                                                    + SCO; Tone voice hz=0 + Rec vc), the msm-pcm-voip FE
#   tools/abyss-cycle/ssr-audio.sh <serial> abyss   Abyss enter + leave during the same silent VoIP stream
# The SSR is a remoteproc "watchdog" crash report via debugfs: the kernel's recovery stops and boots the ADSP
# again, as after a real ADSP watchdog bite. Needs root over adb (KernelSU) and btsco/tone/rec.dex in
# /data/local/tmp. Logs: logs/ssr-<mode>-<time>/.
set -u; S=${1:?serial}; M=${2:-idle}; cd "$(dirname "$0")/../.." || exit 1
L=logs/ssr-$M-$(date +%H%M%S); mkdir -p "$L"; T=/data/local/tmp
a() { adb -s "$S" "$@"; }
# root: KernelSU su (IchthysOS) or a root adbd (white cable: LineageOS userdebug, adb root)
if [ "$(a shell id -u | tr -d '\r')" = 0 ]; then SU() { a shell "$1"; }; else SU() { a shell "/system/bin/su -c '$1'"; }; fi
R=$(SU 'for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name)" in *adsp*) echo ${r##*/};; esac; done' | tr -d '\r')
[ -n "$R" ] || { echo "FAIL: no adsp remoteproc"; exit 1; }
card() { SU 'grep -q lahaina /proc/asound/cards && [ -e /dev/snd/controlC0 ] && echo up || echo DOWN' | tr -d '\r'; }
hal() { a shell 'pidof android.hardware.audio.service || pidof android.hardware.audio.service_64 || pidof vendor.audio-hal-aidl || echo none' | tr -d '\r'; }
SU "mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug; dmesg -C"
echo "adsp $R: $(SU "cat /sys/class/remoteproc/$R/name /sys/class/remoteproc/$R/state /sys/class/remoteproc/$R/recovery" | tr '\r\n' '  ')" | tee "$L/summary.txt"
echo "before: card $(card), audio HAL pid $(hal)" | tee -a "$L/summary.txt"
stream() {   # $1 = seconds of tone/rec
	a shell "CLASSPATH=$T/btsco.dex app_process / BtSco $(($1 + 8)) 30" > "$L/btsco.txt" 2>&1 &
	sleep 3
	a shell "CLASSPATH=$T/tone.dex app_process / Tone $1 voice hz=0" > "$L/tone.txt" 2>&1 &
	a shell "CLASSPATH=$T/rec.dex app_process / Rec vc $1" > "$L/rec.txt" 2>&1 &
	sleep 6
	echo "stream up: $(SU 'dmesg | grep -o "msm_pcm_hw_params: periods = [0-9]*" | sort | uniq -c' | tr '\r\n' '  ')" | tee -a "$L/summary.txt"
}
crash() {
	local t0=$(date +%s)
	echo "SSR (adsp watchdog report) at $(date +%T)" | tee -a "$L/summary.txt"
	SU "echo 1 > /sys/kernel/debug/remoteproc/$R/crash"   # 1 = RPROC_WATCHDOG (6.12 GKI takes the number)
	for i in $(seq 1 45); do sleep 1; [ "$(SU "cat /sys/class/remoteproc/$R/state" | tr -d '\r')" = running ] && [ $i -ge 3 ] && break; done
	echo "adsp state $(SU "cat /sys/class/remoteproc/$R/state" | tr -d '\r') after $(( $(date +%s) - t0 )) s" | tee -a "$L/summary.txt"
}
case $M in
idle) crash; sleep 15;;
voip) stream 30; crash; wait;;
abyss) stream 60; SU 'setprop sys.abyss.request enter'; sleep 20; echo "abyss state: $(a shell getprop sys.abyss.state | tr -d '\r')" | tee -a "$L/summary.txt"
	SU 'setprop sys.abyss.request leave'; wait; sleep 15;;
esac
sleep 5
echo "after: card $(card), audio HAL pid $(hal), adsp $(SU "cat /sys/class/remoteproc/$R/state" | tr -d '\r')" | tee -a "$L/summary.txt"
for f in tone rec btsco; do [ -s "$L/$f.txt" ] && echo "$f: $(tr -d '\r' < "$L/$f.txt" | tail -2 | tr '\n' ' ' | cut -c1-220)" | tee -a "$L/summary.txt"; done
SU 'dmesg' > "$L/dmesg.txt"
echo "kernel: $(grep -ciE 'BUG:|Oops|WARNING:|Unable to handle|list_del corruption|refcount_t:|use-after-free|Kernel panic' "$L/dmesg.txt") bug/warn, $(grep -ciE 'msm_pcm|voip' "$L/dmesg.txt") voip, $(grep -ciE 'q6core|apr_|q6afe|q6asm' "$L/dmesg.txt") q6/apr lines" | tee -a "$L/summary.txt"
grep -iE 'BUG:|Oops|WARNING:|Unable to handle|list_del corruption|refcount_t:' "$L/dmesg.txt" | head -5 | tee -a "$L/summary.txt"
grep -oiE 'msm_pcm_[a-z_]+: [A-Za-z ]+|No free DL buffs|No UL data available' "$L/dmesg.txt" | sort | uniq -c | sort -rn | head -6 | tee -a "$L/summary.txt"
# audio usable again: 1 s silent media tone + 1 s mic capture through the normal paths
echo "tone after: $(a shell "CLASSPATH=$T/tone.dex app_process / Tone 1 hz=0" 2>&1 | tr -d '\r' | tail -1 | cut -c1-140)" | tee -a "$L/summary.txt"
echo "rec after: $(a shell "CLASSPATH=$T/rec.dex app_process / Rec 1" 2>&1 | tr -d '\r' | tail -1 | cut -c1-140)" | tee -a "$L/summary.txt"
echo "logs: $L"
