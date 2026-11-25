#!/system/bin/sh
# Sensors, camera, fingerprint, NFC/eSE, audio: HAL-level device lists + the Samsung sysfs classes. Read-only.
# Samsung factory nodes that start a self-test when READ (adsp_factory selftest/raw_data, OIS selftest, amp
# calibration) are never opened: only name/vendor/firmware-version style attributes from fixed lists.
. "${0%/*}/../dev-lib.sh"
# ---- sensors
sl=$(D sensorservice | grep -E '^0x[0-9a-f]+\) ' | sed -e 's/^0x[0-9a-f]*) //' -e 's/ *|.*//' -e 's/ /_/g' | tr '\n' ' ')
setl sensors.hal_list kernel+ROM 10 "$sl"
M sensors_count "$(printf '%s\n' $sl | grep -c .)"
setl sensors.sysfs_class kernel 5 "$(ls /sys/class/sensors 2>/dev/null | tr '\n' ' ')"
sv=; for d in /sys/class/sensors/*_sensor /sys/class/sensors/ssc_core; do [ -d "$d" ] || continue; sv="$sv ${d##*/}=$(rd $d/vendor)/$(rd $d/name)"; done
C sensors.sysfs_names "$([ -n "$sv" ] && echo PASS || echo FAIL)" kernel "$sv"
nodes sensors.hub_nodes kernel /sys/class/sensors/ssc_core /sys/class/sensors/light_sensor/name /sys/class/sensors/accelerometer_sensor/name
C sensors.dsp PASS kernel "adsp=$(pidof adsprpcd >/dev/null 2>&1 && echo up || echo down) sscrpcd=$(pidof sscrpcd >/dev/null 2>&1 && echo up || echo down) sensors_hal=$(svc vendor.sensors-hal-2-0-multihal)" "remoteproc/subsys: $(cat /sys/class/remoteproc/*/name /sys/bus/msm_subsys/devices/*/name 2>/dev/null | tr '\n' ' ')"
C sensors.hall PASS kernel "hall_ic=$([ -d /sys/class/sec/hall_ic ] && echo y || echo n)" "hall_detect=$(rd /sys/class/sec/hall_ic/hall_detect)"
# ---- camera
cs=$(DT=30 D media.camera | head -300); n=$(printf '%s\n' "$cs" | grep -m1 -oE 'Number of camera devices: [0-9]+' | grep -oE '[0-9]+$')
ids=$(printf '%s\n' "$cs" | grep -oE '^ *Device [0-9]+ maps to "[^"]*"' | sed 's/^ *//' | tr '\n' ';')
[ -z "$ids" ] && ids=$(printf '%s\n' "$cs" | grep -oE '== Camera (HAL )?device (device@[0-9.]+/[a-z]+/)?[0-9]+' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')
if [ "${n:-0}" -ge 2 ]; then C camera.provider_devices PASS kernel+ROM "$n devices" "$ids"; else C camera.provider_devices FAIL kernel+ROM "${n:-0} devices" "provider $(svc sec-camera-provider-4-0); $(printf '%s\n' "$cs" | head -3)"; fi
M camera_devices "${n:-0}"
setl camera.sysfs_class kernel 2 "$(ls /sys/class/camera 2>/dev/null | tr '\n' ' ')"
setl camera.sysfs_rear kernel 3 "$(ls /sys/class/camera/rear 2>/dev/null | tr '\n' ' ')"
setl camera.sysfs_front kernel 2 "$(ls /sys/class/camera/front 2>/dev/null | tr '\n' ' ')"
cf=; for a in rear/rear_camfw rear/rear2_camfw rear/rear3_camfw rear/rear4_camfw front/front_camfw rear/rear_camtype rear/rear2_camtype rear/rear3_camtype rear/rear4_camtype front/front_camtype; do [ -e /sys/class/camera/$a ] && cf="$cf ${a#*/}=[$(rd /sys/class/camera/$a)]"; done
C camera.sysfs_fw "$([ -n "$cf" ] && echo PASS || echo FAIL)" kernel "$cf"
C camera.flash_node "$([ -e /sys/class/camera/flash/rear_flash ] && echo PASS || echo FAIL)" kernel "rear_flash $([ -e /sys/class/camera/flash/rear_flash ] && echo present || echo absent)" "$(lz /sys/class/camera/flash/rear_flash) (never written by the sweep)"
C camera.dev_nodes PASS kernel "video=$(ls /dev/video* 2>/dev/null | grep -c .) v4l-subdev=$(ls /dev/v4l-subdev* 2>/dev/null | grep -c .) media=$(ls /dev/media* 2>/dev/null | grep -c .)"
# ---- fingerprint
F=/sys/class/fingerprint/fingerprint
nodes fingerprint.sysfs kernel $F/name $F/vendor $F/adm $F/position /dev/esfp0
[ -d $F ] && C fingerprint.identity PASS kernel "name=$(rd $F/name) vendor=$(rd $F/vendor) adm=$(rd $F/adm) position=[$(rd $F/position)]" "esfp0 $(lz /dev/esfp0); attrs: $(ls $F 2>/dev/null | tr '\n' ' ')"
fd=$(D fingerprint | head -40); hd=$(printf '%s\n' "$fd" | grep -m1 -oE 'HAL deaths since last reboot: [0-9]+' | grep -oE '[0-9]+$')
fs=$(svc vendor.fps_hal)
if [ "$fs" = running ] && [ "${hd:-0}" = 0 ]; then C fingerprint.hal PASS kernel+ROM "HAL running, 0 deaths" "$(D fingerprint | grep -m1 -oE '"count":[0-9]+')"; else C fingerprint.hal FAIL kernel+ROM "hal=$fs deaths=${hd:-?}"; fi
nodes fingerprint.mask_nodes kernel /sys/class/lcd/panel/mask_brightness /sys/class/lcd/panel/actual_mask_brightness
# ---- NFC + eSE
nodes nfc.dev kernel /dev/sec-nfc
ns=$(D nfc | grep -m1 -E '^ *mState=' | tr -d ' ')
C nfc.service "$([ -n "$ns" ] && echo PASS || echo FAIL)" kernel+ROM "hal=$(svc nfc_hal_service) service=$([ -n "$ns" ] && echo up || echo down)" "$ns (on/off is the user's setting) label $(lz /dev/sec-nfc)"
ese=$(ls /dev 2>/dev/null | grep -iE '^(ese|p61|p73|p3|k250a?|sec_ese|spi.*ese|sec-ese)' | tr '\n' ' ')
se=$(D secure_element | grep -iE 'terminal|eSE|SIM[0-9]' | head -6 | tr -s ' ' | tr '\n' ';')
C nfc.ese PASS kernel+ROM "dev nodes: ${ese:-none}; esepmdaemon=$(svc esepmdaemon)" "secure_element: ${se:-no dump}; nfc.product.support.esim=$(getprop nfc.product.support.esim)"
# ---- audio (nothing is played)
cards=$(sed -n 's/^ *[0-9]* \[\([^]]*\)\].*/\1/p' /proc/asound/cards 2>/dev/null | tr -d ' ' | tr '\n' ' ')
if [ -n "$cards" ]; then C audio.cards PASS kernel "$cards" "pcm devices $(grep -c . /proc/asound/pcm 2>/dev/null)"; else C audio.cards FAIL kernel "no sound card" "$(head -2 /proc/asound/cards 2>&1)"; fi
M audio_pcm_devices "$(grep -c . /proc/asound/pcm 2>/dev/null)"
setl audio.sysfs_class kernel 1 "$(ls /sys/class/audio 2>/dev/null | tr '\n' ' ')"
for d in /sys/class/audio/*; do [ -d "$d" ] && setl "audio.sysfs.${d##*/}" kernel 0 "$(ls $d 2>/dev/null | grep -vE '^(power|subsystem|uevent|device)$' | tr '\n' ' ')"; done
C audio.earjack PASS kernel "state node $([ -e /sys/class/audio/earjack/state ] && echo present || echo absent)" "state=$(rd /sys/class/audio/earjack/state) key_state=$(rd /sys/class/audio/earjack/key_state)"
af=$(D media.audio_flinger | grep -cE '^Output thread|Output thread 0x')
C audio.hal "$([ "$(svc vendor.audio-hal)" = running ] && [ "$af" -ge 1 ] && echo PASS || echo FAIL)" kernel+ROM "hal=$(svc vendor.audio-hal) audioserver=$(svc audioserver)" "$af output threads; adsp audio pd $(svc vendor.audioadsprpcd_audiopd)"
jk=$(getevent -pl 2>/dev/null | grep -ciE 'name:.*(jack|headset|button)')
C audio.jack_input PASS kernel "$jk jack/headset input devices"
