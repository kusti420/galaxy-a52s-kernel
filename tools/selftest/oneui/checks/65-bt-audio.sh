#!/system/bin/sh
# Bluetooth audio over SLIMbus + A2DP offload (drivers612/SPEC/02-audio-connectivity-telephony.md, rows BTA-*), and
# the HAL's mixer control names against the card. SILENT: nothing is played, recorded or connected; no BT address is
# printed. One write, only with ONEUI_WRITE=1, root and NO Bluetooth/hearing-aid output device connected: actl encfmt
# stores <format, zero config> in "SLIM_7_RX Encoder Config" per format and resets it (the put only fills the back
# end's private data; nothing reaches the DSP because SLIMBUS_7_RX is not opened).
. "${0%/*}/../dev-lib.sh"
ACTL="${0%/*}/../actl"
# ---- SLIMbus transport of BT audio (SCO + A2DP offload): controller bound, BT slave device, codec char device
slimdev=$(ls /sys/bus/slimbus/devices 2>/dev/null | tr '\n' ' ')
C bta.slimbus "$([ -e /sys/bus/platform/devices/3ac0000.slim/driver ] && echo PASS || echo FAIL)" kernel "ngd bound=$([ -e /sys/bus/platform/devices/3ac0000.slim/driver ] && echo y || echo n) btfmslim node=$([ -e /dev/btfmslim ] && echo y || echo n)" "slimbus devices: ${slimdev:-none}; driver $(basename "$(readlink /sys/bus/platform/devices/3ac0000.slim/driver 2>/dev/null)")"
C bta.pcm_abr_feedback "$(grep -q 'SLIMBUS_7 Hostless' /proc/asound/pcm 2>/dev/null && echo PASS || echo FAIL)" kernel "SLIMBUS_7 Hostless pcm=$(grep -c 'SLIMBUS_7 Hostless' /proc/asound/pcm 2>/dev/null)" "$(grep -m1 'SLIMBUS_7 Hostless' /proc/asound/pcm 2>/dev/null) (ABR feedback capture, HAL usecase id 36)"
C bta.offload_props PASS info "supported=$(getprop ro.bluetooth.a2dp_offload.supported) disabled=$(getprop persist.bluetooth.a2dp_offload.disabled) feature=$(getprop vendor.audio.feature.a2dp_offload.enable)" "cap=$(getprop persist.bluetooth.a2dp_offload.cap) vendor cap=$(getprop persist.vendor.bt.a2dp_offload_cap) soc=$(getprop vendor.qcom.bluetooth.soc)"
ls /vendor/lib/liba2dpoffload.so /vendor/lib64/liba2dpoffload.so >/dev/null 2>&1 && hal=y || hal=n
C bta.offload_hal PASS ROM "liba2dpoffload=$hal sehA2dp=$(ls /vendor/lib*/hw/vendor.samsung.hardware.bluetooth.a2dp@1.0-impl.so >/dev/null 2>&1 && echo y || echo n)" "ssc in the HAL: $(grep -c configure_ssc_enc_format /vendor/lib/liba2dpoffload.so 2>/dev/null) (1 = the HAL sends the Samsung Scalable / SBC_SS formats)"
# ---- control set the stock HAL (liba2dpoffload.so + mixer_paths bt-a2dp / bt-sco paths) sets for BT audio
if needroot bta.controls kernel; then
	if [ -x "$ACTL" ]; then
		want='SLIM_7_RX Encoder Config
SLIM_7_RX APTX_AD Enc Cfg
SLIM_7_TX Decoder Config
AFE Input Channels
AFE Input Bit Format
AFE Output Channels
AFE Output Bit Format
AFE Scrambler Mode
TWS Channel Mode
LC3 Channel Mode
AFE Dynamic Bitrate
SBM Delay
BT SampleRate
BT SampleRate RX
BT SampleRate TX
SLIM7_RX ADM Channels
SLIM7_TX ADM Channels
A2DP_SLIM7_UL_HL Switch
SLIMBUS_7_RX Audio Mixer MultiMedia1
SLIMBUS_7_RX Audio Mixer MultiMedia5
SLIMBUS_7_RX Audio Mixer MultiMedia4
MultiMedia1 Mixer SLIM_7_TX
SLIM_7_RX_Voice Mixer VoiceMMode1
VoiceMMode1_Tx Mixer SLIM_7_TX_MMode1
SLIM_7_RX_Voice Mixer Voip
Voip_Tx Mixer SLIM_7_TX_Voip'
		o=$(printf '%s\n' "$want" | "$ACTL" has 0 2>&1); miss=$(printf '%s\n' "$o" | sed -n 's/^HAS n //p' | tr ' ' '_' | tr '\n' ' ')
		n=$(printf '%s\n' "$o" | grep -c '^HAS y ')
		if printf '%s\n' "$o" | grep -q '^HAS '; then C bta.controls "$([ -z "$miss" ] && echo PASS || echo FAIL)" kernel "$n/26 present; missing: ${miss:-none}" "names the stock HAL sets for an A2DP offload / SCO session"
		else C bta.controls SKIP kernel "actl did not answer" "$o"; fi
		# every <ctl name> of the HAL's mixer path files that is not a control of the card (stale names are equal on 5.4)
		for x in mixer_paths sound_trigger_mixer_paths; do f=/vendor/etc/$x.xml; [ -r "$f" ] || { C "audio.$x.names" SKIP ROM "no $f"; continue; }
			o=$(grep -o '<ctl name="[^"]*"' "$f" | sed -e 's/^<ctl name="//' -e 's/"$//' | sort -u | "$ACTL" has 0 2>&1)
			tot=$(printf '%s\n' "$o" | grep -c '^HAS '); miss=$(printf '%s\n' "$o" | sed -n 's/^HAS n //p' | tr ' ' '_' | tr '\n' ' ')
			if [ "$tot" -gt 0 ]; then C "audio.$x.names" PASS kernel "set: $miss" "$tot distinct control names in $f, $(printf '%s\n' $miss | grep -c .) not on the card (compare with 5.4: a name missing only on 6.12 is a lost route)"
			else C "audio.$x.names" SKIP kernel "actl did not answer" "$o"; fi; done
		M audio_controls "$("$ACTL" list 0 2>/dev/null | sed -n 's/^ACTL controls //p')"
		# type and value count of the controls the HAL blobs write as ARRAYS: tinyalsa refuses an array longer than the
		# control reports, so a smaller count on 6.12 = the HAL's write fails silently (SPEC/02 section 11, fix C1)
		sh_=$(printf '%s\n' 'App Type Config' 'App Type Gain' 'Audio Effect' 'Device PP Params' 'Backend Device Channel Map' 'Playback Device Channel Map' 'Capture Device Channel Map' 'Listen App Type Config' 'Listen App Type Config V2' 'Voc VSID' 'Voice Rx Device Mute' 'Voice Tx Mute' 'Voice Rx Gain' 'IIR0 Band1' 'IIR1 Band1' 'MultiMedia1 EQ Band1' 'EC Reference ChMixer Weights Ch1' 'SLIM_7_RX Encoder Config' 'QUIN_MI2S_RX_Voice Mixer VoiceMMode1' 'Voip Tx Mute' | "$ACTL" get 0 2>&1 | sed -n 's/^VAL \([a-z0-9]*:[0-9]*\) \(.*\) = .*$/\2=\1/p; s/^VAL absent \(.*\)$/\1=absent/p' | tr ' ' '_' | tr '\n' ' ')
		if [ -n "$sh_" ]; then C audio.ctl_shapes PASS kernel "set: $sh_" "name=type:count; must equal 5.4 (5.4: App_Type_Config=int:128 Device_PP_Params=int:3 IIR0_Band1=int:5 Backend_Device_Channel_Map=int:33)"; else C audio.ctl_shapes SKIP kernel "actl did not answer"; fi
		# ---- which encoder formats the kernel accepts (the stock HAL fails the whole A2DP start when the put fails)
		pol=$(D media.audio_policy); ext=$(printf '%s\n' "$pol" | sed -n '/Available output devices/,/Available input devices/p')
		if [ "${ONEUI_WRITE:-1}" != 1 ]; then C bta.encfmt SKIP kernel "read-only run"
		elif [ -z "$ext" ]; then C bta.encfmt SKIP kernel "audio policy dump has no device list" "cannot prove that no BT audio device is connected"
		elif printf '%s\n' "$ext" | grep -qE 'BLUETOOTH|BLE_|HEARING_AID'; then C bta.encfmt SKIP kernel "a Bluetooth audio device is connected" "not touching the encoder config of a live link"
		else o=$("$ACTL" encfmt 0 2>&1); st=$(printf '%s\n' "$o" | sed -n 's/^ENCFMT \([a-z_]*\) 0x[0-9a-f]* \(.*\)$/\1=\2/p' | grep -v '^reset=' | tr '\n' ' ')
			if [ -z "$st" ]; then C bta.encfmt FAIL kernel "no answer" "$o"
			else C bta.encfmt "$(printf '%s' "$st" | grep -qE '=(E|errno)' && echo FAIL || echo PASS)" kernel "$st" "$(printf '%s\n' "$o" | grep -E 'control|reset' | tr '\n' ' '); ssc/sbc_ss = Samsung Scalable (Galaxy Buds) and Samsung SBC"; fi; fi
	else C bta.controls SKIP kernel "actl helper not pushed"; fi
fi
