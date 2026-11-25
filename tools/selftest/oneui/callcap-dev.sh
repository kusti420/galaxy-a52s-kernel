#!/system/bin/sh
# Phone side of tools/selftest/oneui/callcap.sh: one read-only snapshot of the voice-call audio path.
# SILENT and read-only: nothing is played, recorded, dialled, routed or written. PRIVACY: no number, IMEI, IMSI,
# operator name or address is printed: enum fields are cut out inside the pipe, the radio log buffer is never read,
# and every run of 7+ digits is masked on output.
HERE=${0%/*}; ACTL=$HERE/actl
mask() { sed -E 's/[0-9]{7,}/<digits>/g'; }
sec() { echo; echo "=== $1"; }
sec identity
echo "kernel $(uname -r)"; echo "rom $(getprop ro.build.display.id | mask)"; echo "uptime $(cut -d' ' -f1 /proc/uptime) s"; echo "root $(id -u)"
sec call_state
# enum fields only (TelephonyRegistry): call state 0 idle / 1 ringing / 2 offhook; precise states; disconnect causes
T=$(timeout 25 dumpsys telephony.registry 2>/dev/null)
printf '%s\n' "$T" | grep -oE 'm(CallState|RingingCallState|ForegroundCallState|BackgroundCallState|CallDisconnectCause|CallPreciseDisconnectCause|VoiceRegState|DataRegState)=-?[0-9]+(\([A-Z_]+\))?' | sort | uniq -c | mask
printf '%s\n' "$T" | grep -oE 'getRil(Voice|Data)RadioTechnology=[0-9]+\([A-Za-z_0-9]+\)' | sort | uniq -c
printf '%s\n' "$T" | grep -oE 'mImsCallDisconnectCause=ImsReasonInfo :: \{[0-9]+ : [0-9]+' | sort | uniq -c
echo "ims: $(timeout 25 dumpsys phone 2>/dev/null | grep -oE '(isImsRegistered\(\)|mImsRegistered|isVolteEnabled\(\)|isWifiCallingEnabled\(\))=(true|false)' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
echo "sim: $(getprop gsm.sim.state) net: $(getprop gsm.network.type)"
sec audio_mode
timeout 20 dumpsys audio 2>/dev/null | grep -m6 -E '^ *(mMode|Mode|- mode|Audio mode|mCommunicationDevice|Communication route)' | mask
timeout 20 dumpsys media.audio_flinger 2>/dev/null | grep -E 'Output thread|Input thread|Standby: |HAL stream|Thread name' | head -60 | mask
timeout 20 dumpsys media.audio_policy 2>/dev/null | sed -n '/Available output devices/,/Available input devices/p' | grep -oE 'AUDIO_DEVICE_[A-Z_0-9]+' | sort -u | tr '\n' ' '; echo
echo "phone state (policy): $(timeout 20 dumpsys media.audio_policy 2>/dev/null | grep -m1 -iE 'phone state|Phone state' | mask)"
sec sound_card
echo "card state: $(cat /proc/asound/card0/state 2>/dev/null)"; cat /proc/asound/cards 2>/dev/null | head -4
for r in /sys/class/remoteproc/remoteproc*; do echo "$(cat $r/name 2>/dev/null)=$(cat $r/state 2>/dev/null)"; done | tr '\n' ' '; echo
sec open_pcms
# every PCM substream that is not closed: voice calls use hw:0,2 (VoiceMMode1) / hw:0,15 (VoiceMMode2) hostless front ends
for st in /proc/asound/card0/pcm*/sub*/status; do s=$(cat $st 2>/dev/null); [ "$s" = closed ] && continue; [ -z "$s" ] && continue
	d=${st%/status}; echo "$d: $(grep -m1 '^ *name' ${d%/sub*}/info 2>/dev/null | tr -s ' ') | $(printf '%s' "$s" | tr '\n' ' ' | tr -s ' ') | $(cat $d/hw_params 2>/dev/null | tr '\n' ' ' | tr -s ' ')"; done
grep -E '^00-(02|15|03|12|23):' /proc/asound/pcm 2>/dev/null
sec voice_controls
if [ -x "$ACTL" ] && [ "$(id -u)" = 0 ]; then "$ACTL" get 0 <<'EOF'
Voc VSID
Voice Rx Device Mute
Voice Tx Device Mute
Voice Tx Mute
Voice Rx Gain
Voice Topology Disable
Voice Sidetone Enable
TTY Mode
CVD Version
QUIN_MI2S_RX_Voice Mixer VoiceMMode1
QUIN_MI2S_RX_Voice Mixer VoiceMMode2
RX_CDC_DMA_RX_0_Voice Mixer VoiceMMode1
RX_CDC_DMA_RX_0_Voice Mixer VoiceMMode2
SLIM_7_RX_Voice Mixer VoiceMMode1
SLIM_7_RX_Voice Mixer VoiceMMode2
USB_AUDIO_RX_Voice Mixer VoiceMMode1
PROXY_RX_Voice Mixer VoiceMMode1
VoiceMMode1_Tx Mixer TX_CDC_DMA_TX_3_MMode1
VoiceMMode2_Tx Mixer TX_CDC_DMA_TX_3_MMode2
VoiceMMode1_Tx Mixer SLIM_7_TX_MMode1
VoiceMMode1_Tx Mixer USB_AUDIO_TX_MMode1
QUIN_MI2S_RX_Voice Mixer Voip
Voip_Tx Mixer TX_CDC_DMA_TX_3_Voip
TX_CDC_DMA_TX_3 Channels
TX DEC0 MUX
TX DEC1 MUX
TX SMIC MUX0
TX SMIC MUX1
TX_AIF1_CAP Mixer DEC0
TX_AIF1_CAP Mixer DEC1
ADC1_MIXER Switch
ADC3_MIXER Switch
ADC3 MUX
TX_DEC0 Volume
TX_DEC1 Volume
TAS256X RECEIVER ENABLE LEFT
TAS256X ASI Left Switch
TAS256X ASI Right Switch
TAS256X ASI1 SEL LEFT
TAS256X ASI1 SEL RIGHT
TAS256X PLAYBACK VOLUME LEFT
TAS256X PLAYBACK VOLUME RIGHT
TAS256X AMP OUTPUT LVL LEFT
TAS256X DAC Mute
AUDIO_REF_EC_UL1 MUX
EC Reference Channels
Voice Device Info
NB Mode
Receiver Sensor Mode
Speaker Sensor Mode
DSP AEC Effect
Echo Ref Mute
REF LCH MUTE
Loopback Enable
Voice Isolation Mode
BT SCO Rx Volume
App Type Config
Device PP Params
EOF
else echo "actl not available or not root: control values not read"; fi
sec kernel_log
if [ "$(id -u)" = 0 ]; then dmesg 2>/dev/null | grep -iE 'voice|voc_|q6voice|cvp|cvs|mvm|afe_|q6afe|adm_|q6adm|tas25|msm-pcm-voice|msm_pcm_routing|apr_|rx_macro|tx_macro|wcd938|swr|audio_cal|cal_utils|sec_voice|adaptation' | tail -250 | mask
else echo "no root: dmesg not read"; fi
sec audio_hal_log
# main + system buffers only, audio tags only (the radio buffer and Telecom lines are never read)
logcat -d -b main,system -t 6000 2>/dev/null | grep -aE ' (audio_hw_primary|audio_hw_sec|sec_audio_hw|msm8974_platform|voice|voice_extn|audio_route|ACDB-LOADER|audio_hw_extn|audio_hw_utils|audio_hw_acdb|hardware_info|soundtrigger|sound_trigger_hw|AudioFlinger|APM_AudioPolicyManager|AudioPolicyManager|AHAL[A-Za-z:_ ]*|SecAudio[A-Za-z]*) *:' | tail -400 | mask
