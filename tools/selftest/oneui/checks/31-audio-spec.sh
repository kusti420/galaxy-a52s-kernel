#!/system/bin/sh
# Audio rows of drivers612/SPEC/02-audio-connectivity-telephony.md (AUD-*) beyond 30-hw.sh. Read-only and SILENT: nothing
# is played or recorded, no tinymix, no calibration attribute is read (only names under /sys/class/tas25xx are listed).
. "${0%/*}/../dev-lib.sh"
# ---- audio, part 2 (read-only; nothing is played, no calibration attribute is read)
# front-end PCM numbers the closed HAL opens by index: direction per id must equal 5.4 (24 and 43 were compress nodes once)
fe=; for i in 00 02 03 05 06 09 12 13 15 23 24 29 43; do l=$(grep -m1 "^00-$i:" /proc/asound/pcm 2>/dev/null); d=; case "$l" in *playback*) d=p;; esac; case "$l" in *capture*) d=${d}c;; esac; fe="$fe $i=${d:-none}"; done
C audio.fe_pcm_ids "$(case "$fe" in *=none*) echo FAIL;; *) echo PASS;; esac)" kernel "${fe# }" "hw:24 primary, hw:3 VoIP, hw:2/15 voice, hw:13/29 MMAP, hw:43 Compress3"
# listen (voice wake-up) PCMs 10, 16..22: capture-only front ends
ls_=; for i in 10 16 17 18 19 20 21 22; do grep -q "^00-$i:.*capture" /proc/asound/pcm 2>/dev/null && ls_="$ls_ $i"; done
C audio.lsm_pcms "$([ "$(printf '%s\n' $ls_ | grep -c .)" = 8 ] && echo PASS || echo FAIL)" kernel "listen pcms:${ls_:- none}" "msm_lsm_cdev=$([ -e /dev/msm_lsm_cdev ] && echo y || echo n) (6.12 only; the HAL blob uses PCM ioctls)"
setl audio.compress_nodes kernel 7 "$(ls /dev/snd 2>/dev/null | grep '^comprC0D' | tr '\n' ' ')"
setl audio.hwdep_nodes kernel 2 "$(ls /dev/snd 2>/dev/null | grep '^hwC0D' | tr '\n' ' ')"
M audio_snd_nodes "$(ls /dev/snd 2>/dev/null | grep -c .)"
# card state the HAL's sndmonitor polls (ONLINE; OFFLINE during an ADSP restart)
val audio.card_state kernel /proc/asound/card0/state
val audio.codec_variant kernel /proc/asound/card0/codecs/wcd938x/variant
# calibration + amp device nodes (existence and label only)
nodes audio.cal_nodes kernel /dev/msm_audio_cal /dev/msm_rtac /dev/tas256x /dev/tas_calib
C audio.tas_amp "$([ -e /sys/bus/i2c/devices/18-004c/driver ] && echo PASS || echo FAIL)" kernel "tas256x 18-004c bound=$([ -e /sys/bus/i2c/devices/18-004c/driver ] && echo y || echo n)" "driver $(basename "$(readlink /sys/bus/i2c/devices/18-004c/driver 2>/dev/null)")"
tc=; for d in /sys/class/tas25xx/*; do [ -d "$d" ] && tc="$tc ${d##*/}:$(ls $d 2>/dev/null | grep -vcE '^(power|subsystem|uevent|device)$')"; done
C audio.tas_class "$([ -n "$tc" ] && echo PASS || echo FAIL)" kernel "${tc# }" "attribute counts per directory, names only (reading calib/valid starts a measurement)"
# Samsung adaptation component (SoundAlive / SoundBooster / volume monitor controls live here)
ad=$(ls -d /sys/bus/platform/drivers/*/soc:samsung,q6audio-adaptation 2>/dev/null | head -1)
C audio.adaptation "$([ -n "$ad" ] && echo PASS || echo FAIL)" kernel "q6audio-adaptation bound=$([ -n "$ad" ] && echo y || echo n)" "${ad%/*}"
# amp statistics + codec id: values, not only names (fed by callbacks; an unfed node reads 0)
av=; for a in curr_temperature_0 curr_temperature_1 temperature_max_0 temperature_max_1 excursion_max_0 excursion_max_1; do av="$av $a=$(rd /sys/class/audio/amp/$a)"; done
C audio.amp_values PASS info "${av# }" "check_codec_id=$(rd /sys/class/audio/codec/check_codec_id)"
# earjack idle values as the stable value: 5.4 reads state=0 key_state=-1 with nothing plugged, an unfed 6.12 node reads 0 0
ej=; for a in state key_state headset_state mic_adc l_impedance r_impedance; do ej="$ej $a=$(rd /sys/class/audio/earjack/$a)"; done
C audio.earjack_values "$([ -e /sys/class/audio/earjack/state ] && echo PASS || echo FAIL)" kernel "${ej# }" "only comparable with the jack empty"
# what the jack input devices can report (switches + headset keys), names instead of a count
jc=$(getevent -pl 2>/dev/null | sed -n '/name: .*[Jj]ack/,/^add device/p' | grep -oE '(SW|KEY)_[A-Z_]+' | sort -u | tr '\n' ' ')
setl audio.jack_caps kernel 2 "$jc"
# USB audio offload: the HAL has no other USB route (5.4 builtin, 6.12 a module that must be loaded)
ub=$(ls -d /sys/bus/platform/drivers/uaudio-qmi/soc:usb_audio_qmi_dev 2>/dev/null)
C audio.usb_offload "$([ -n "$ub" ] && echo PASS || echo FAIL)" kernel "uaudio-qmi bound=$([ -n "$ub" ] && echo y || echo n)" "module=$([ -d /sys/module/snd_usb_audio_qmi ] && echo loaded || echo builtin-or-absent) usb_notify cards node=$([ -e /sys/class/usb_notify/usb_control/cards ] && echo y || echo n) usb cards now=$(grep -c 'USB-Audio' /proc/asound/cards 2>/dev/null)"
# audio output threads by type (no stream is opened)
ot=$(D media.audio_flinger | grep -oE 'Output thread 0x[0-9a-f]+, name [A-Za-z0-9_]+, tid [0-9]+, type [0-9]+ \([A-Z_]+\)' | grep -oE '\([A-Z_]+\)' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
C audio.output_threads PASS kernel+ROM "${ot:-not parsed}" "MIXER/DIRECT/OFFLOAD/MMAP_PLAYBACK thread counts at idle"
# kernel-side audio error signatures since boot (root: dmesg); the OneUI 6.12 ring wraps fast, so 0 only means "not in the ring"
if needroot audio.kmsg_errors kernel; then
	ke=; for p in 'afe_tas_smartamp.*(fail|err)' 'voice_get_cal.*fail' 'adm_open.*failed' 'q6asm.*ADSP_E' 'Could not get copp idx' 'msm_compr_new: Could not add' 'swr.*clsh' 'msm_audio_ion.*(fail|err)' 'audio_cal.*(fail|err)'; do n=$(dmesg 2>/dev/null | grep -ciE "$p"); [ "$n" -gt 0 ] && ke="$ke [$p]=$n"; done
	C audio.kmsg_errors "$([ -z "$ke" ] && echo PASS || echo FAIL)" kernel "${ke:-none}" "patterns: smartamp, voice cal, adm open, asm, copp idx, compr new, swr clash, audio ion, audio cal"
fi
