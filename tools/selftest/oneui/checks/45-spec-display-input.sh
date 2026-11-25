#!/system/bin/sh
# SPEC rows for drivers612/SPEC/01-display-touch-fingerprint-sensors.md (display, touch, fingerprint, sensors,
# keys, haptics, LEDs). The older files (30-hw, 40-display-touch, 50-usb-storage-power) prove that the nodes
# exist; these rows compare what userspace DEPENDS on: who owns each node (init chowns it once: a node that
# appears after that stays root:root and the feature silently does nothing), the SELinux label, the event codes of
# every input device, wakeup capability, key layouts, and state that must agree between the framework and the kernel.
# READ-ONLY and SILENT: nothing is written anywhere (no sec touch command, no panel node, no vibrator, no setting);
# no attribute whose read handler talks to hardware is opened (panel self tests, touch raw data, adsp_factory
# selftest/raw_data, fingerprint type_check): fixed lists of plain state attributes only, the rest by name.
. "${0%/*}/../dev-lib.sh"
SKIPN='^(power|subsystem|uevent|device|waiting_for_supplier)$'
# perm <id> <dir>...: stable = every node that is NOT root:root (name:mode:owner:group) = the list init/vendor rc
# files hand to userspace; detail = distinct SELinux labels. An entry missing on 6.12 = a consumer lost its node.
perm() { local id=$1 d o n lab; shift; o=; lab=; n=0
	for d in "$@"; do [ -d "$d" ] || continue; n=$((n+1))
		o="$o $(ls -lZ "$d/" 2>/dev/null | awk -v p="${d##*/}" '$1 ~ /^-/ { if ($3 != "root" || $4 != "root") printf "%s/%s:%s:%s:%s ", p, $NF, substr($1, 2), $3, $4 }')"
		lab="$lab $(ls -lZ "$d/" 2>/dev/null | awk '$1 ~ /^-/ && $5 ~ /^u:/ { split($5, a, ":"); print a[3] }' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
	done
	if [ $n = 0 ]; then C "$id" FAIL kernel "absent" "$*"; return; fi
	o=$(printf '%s\n' $o | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
	C "$id" PASS kernel+ROM "set: $o" "$(printf '%s\n' $o | grep -c .) nodes handed to userspace; labels:$lab"; }
# kerr <id> <match> : kernel error lines of one driver family since the log began (root). stable none/present.
kerr() { local id=$1 l n; [ "$ROOT" = 1 ] || { C "$id" SKIP kernel "needs root"; return; }
	l=$(dmesg 2>/dev/null | grep -iE "$2" | grep -iE 'fail|error|timeout|timed out|not handled|recover|abnormal|i2c.*(err|nack)' | grep -vE 'avc: |audit|init: |type=14' )
	n=$(printf '%s\n' "$l" | grep -c .)
	M "$(printf '%s' "$id" | tr '.' '_')_lines" "$n"
	if [ "$n" = 0 ]; then C "$id" PASS kernel "none" "0 lines"; else C "$id" FAIL kernel "present" "$n lines; top: $(printf '%s\n' "$l" | sed -e 's/^[^]]*\] *//' -e 's/[0-9][0-9]*/N/g' | sort | uniq -c | sort -rn | head -4 | tr -s ' ' | tr '\n' ';' | cut -c1-560)"; fi; }
WAKE=$(D power | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)
dd=$(DT=30 D display)
DSTATE=$(printf '%s\n' "$dd" | grep -m1 -oE 'mState=[A-Z_]+' | cut -d= -f2)

# ---------------------------------------------------------------- display
L=/sys/class/lcd/panel; Mn=/sys/class/mdnie/mdnie
perm display.perm.panel $L
perm display.perm.mdnie $Mn
perm display.perm.backlight /sys/class/backlight/panel /sys/class/backlight/panel0-backlight
# DRM connector of the internal panel: mode list and link state as the kernel reports them
for c in /sys/class/drm/card*-DSI-1; do [ -d "$c" ] || continue
	C display.drm_connector "$([ "$(rd $c/status)" = connected ] && echo PASS || echo FAIL)" kernel "status=$(rd $c/status) modes=[$(sort -u $c/modes 2>/dev/null | tr '\n' ' ' | sed 's/ $//')]" "enabled=$(rd $c/enabled) dpms=$(rd $c/dpms) ${c##*/}"; break; done
[ -d "$c" ] || C display.drm_connector FAIL kernel "no card*-DSI-1 connector" "$(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"
# finger mask must be OFF while nobody touches the sensor (2026-11-22: stuck at 331 = 547 nit after every boot)
am=$(rd $L/actual_mask_brightness)
if [ ! -e $L/actual_mask_brightness ]; then C fingerprint.mask_idle FAIL kernel "node absent"
elif [ -z "$am" ] || [ "$(num "$am")" = 0 ]; then C fingerprint.mask_idle PASS kernel "mask off while idle" "actual_mask_brightness=[$am] display=$DSTATE"
else C fingerprint.mask_idle FAIL kernel "mask ON with no finger" "actual_mask_brightness=[$am] display=$DSTATE (finger mask HBM stuck: drivers612/display/FINGERMASK-ONEUI.md; a finger on the sensor during the sweep also gives this)"; fi
# panel refresh rate as the panel driver sees it vs the mode the framework believes is active (screen on only)
pv=$(rd $L/vrr | awk '{print $1}')
fw=$(printf '%s\n' "$dd" | grep -m1 -oE '(mActiveRenderFrameRate|activeRenderFrameRate|renderFrameRate)[ =:]+[0-9]+' | grep -oE '[0-9]+$')
[ -z "$fw" ] && fw=$(DT=25 D SurfaceFlinger | grep -m1 -oE 'refresh-rate *: *[0-9]+' | grep -oE '[0-9]+$')
if [ "$DSTATE" != ON ]; then C display.vrr_agrees SKIP kernel+ROM "screen not on ($DSTATE)" "panel vrr=[$(rd $L/vrr)] framework=${fw:-?}"
elif [ -z "$pv" ] || [ -z "$fw" ]; then C display.vrr_agrees SKIP kernel+ROM "not readable" "panel vrr=[$(rd $L/vrr)] framework=[${fw:-}]"
elif [ "$pv" = "$fw" ] || [ $((pv - fw)) = 1 ] || [ $((fw - pv)) = 1 ]; then C display.vrr_agrees PASS kernel+ROM "panel and framework agree" "panel ${pv} Hz, framework ${fw} Hz, refresh_rate_mode=$(settings get secure refresh_rate_mode 2>/dev/null)"
else C display.vrr_agrees FAIL kernel+ROM "panel ${pv} Hz, framework ${fw} Hz" "vrr=[$(rd $L/vrr)] refresh_rate_mode=$(settings get secure refresh_rate_mode 2>/dev/null)"; fi
# doze: the panel LPM state must follow the display state (alpm node: last mode the framework asked for)
al=$(rd $L/alpm)
case "$DSTATE" in
	DOZE|DOZE_SUSPEND) C display.doze_state "$([ -n "$al" ] && echo PASS || echo FAIL)" kernel+ROM "doze: alpm readable" "display=$DSTATE wakefulness=$WAKE alpm=[$al] aod_mode=$(settings get system aod_mode 2>/dev/null) aod_tap_to_show_mode=$(settings get system aod_tap_to_show_mode 2>/dev/null)";;
	*) C display.doze_state SKIP kernel+ROM "screen not dozing ($DSTATE)" "wakefulness=$WAKE alpm=[$al] (run the sweep with the screen off and AOD enabled to cover the LPM path)";;
esac
# mDNIe must agree with the user's settings: eye comfort off -> night_mode off; colour inversion <-> NEGATIVE
nm=$(rd $Mn/night_mode | awk '{print $1}'); blf=$(settings get system blue_light_filter 2>/dev/null); acc=$(rd $Mn/accessibility); inv=$(settings get secure accessibility_display_inversion_enabled 2>/dev/null)
if [ ! -d $Mn ]; then C display.mdnie_agrees FAIL kernel "no mdnie class"
else bad=
	[ "$blf" = 0 ] && [ "$nm" = 1 ] && bad="$bad night_mode on with eye comfort off;"
	case "$inv:$acc" in 1:*NEGATIVE*|0:*NEGATIVE*) [ "$inv" = 0 ] && bad="$bad NEGATIVE with inversion off;";; 1:*) bad="$bad inversion on but accessibility is not NEGATIVE;";; esac
	C display.mdnie_agrees "$([ -z "$bad" ] && echo PASS || echo FAIL)" kernel+ROM "${bad:-settings and mdnie agree}" "night_mode=[$(rd $Mn/night_mode)] blue_light_filter=$blf accessibility=[$(printf '%s' "$acc" | cut -c1-50)] inversion=$inv mode=[$(rd $Mn/mode | cut -c1-40)] screen_mode_setting=$(settings get system screen_mode_setting 2>/dev/null) sensorRGB=[$(rd $Mn/sensorRGB | cut -c1-30)] whiteRGB=[$(rd $Mn/whiteRGB | cut -c1-30)]"
fi
# plain state attributes SSRM / the light HAL / the framework read back (5.4 values are the reference)
C display.panel_readback PASS kernel "temperature=[$(rd $L/temperature | cut -c1-60)] night_dim=[$(rd $L/night_dim)] irc_mode=[$(rd $L/irc_mode | cut -c1-30)] dynamic_hlpm=[$(rd $L/dynamic_hlpm | cut -c1-30)]" "volatile: lux=[$(rd $L/lux)] brt_avg=[$(rd $L/brt_avg | cut -c1-30)] adaptive_control=[$(rd $L/adaptive_control)] conn_det=[$(rd $L/conn_det | cut -c1-30)] alpm=[$al] vrr=[$(rd $L/vrr)]"
C display.brightness_settings PASS info "auto=$(settings get system screen_brightness_mode 2>/dev/null)" "brightness=$(settings get system screen_brightness 2>/dev/null) extra_brightness=$(settings get secure screen_extra_brightness 2>/dev/null) extra_dim=$(settings get secure reduce_bright_colors_activated 2>/dev/null) refresh_rate_mode=$(settings get secure refresh_rate_mode 2>/dev/null) screen_mode=$(settings get system screen_mode_setting 2>/dev/null) vision_booster/outdoor=$(settings get system display_outdoor_mode 2>/dev/null)"
# character devices the AOD / burn-in / dumpstate services open (presence + owner; never opened here)
md=; for n in self_display sec_display_debug mafpc poc act_clk; do [ -e /dev/$n ] && md="$md $n:$(ls -l /dev/$n 2>/dev/null | awk '{ print substr($1, 2) ":" $3 ":" $4 }')"; done
C display.misc_devs "$([ -n "$md" ] && echo PASS || echo FAIL)" kernel "set:$md" "5.4 has self_display + sec_display_debug only (no mafpc/poc on this panel)"
kerr klog.display 'dsi|sde|panel|ss_|mdnie|FINGER_MASK|drm'

# ---------------------------------------------------------------- touch
T=/sys/class/sec/tsp
setl touch.sysfs_attrs kernel 10 "$(ls $T/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ')"
perm touch.perm $T
if [ -d $T ]; then
	C touch.features PASS kernel "support_feature=[$(rd $T/support_feature)] fod_info=[$(rd $T/fod_info)] aod_active_area=[$(rd $T/aod_active_area)]" "prox_power_off=[$(rd $T/prox_power_off)] ear_detect_enable=[$(rd $T/ear_detect_enable)] virtual_prox=[$(rd $T/virtual_prox)]"
	# power state the driver is in vs the screen: off screen with a low-power gesture armed must be LPM, not OFF
	ps=$(rd $T/enabled); ie=$(rd $T/input/enabled)
	C touch.power_state "$([ -n "$ps$ie" ] && echo PASS || echo FAIL)" kernel+ROM "readable" "tsp/enabled(power_state 0 off 1 lpm 2 on)=[$ps] input/enabled=[$ie] display=$DSTATE; armed by settings: double_tab_to_wake_up=$(settings get system double_tab_to_wake_up 2>/dev/null) double_tap_to_sleep=$(settings get system double_tab_to_sleep 2>/dev/null) aod_tap_to_show_mode=$(settings get system aod_tap_to_show_mode 2>/dev/null) lift_to_wake=$(settings get system lift_to_wake 2>/dev/null) auto_adjust_touch(glove)=$(settings get system auto_adjust_touch 2>/dev/null) fingerprint_screen_off=$(settings get secure fingerprint_always_on_enable 2>/dev/null)"
	if [ "$ROOT" = 1 ]; then lp=$(dmesg 2>/dev/null | grep -E 'stm_ts|fts|sec_input' | grep -E 'lowpower_flag|lowpower_mode|LP mode|lpmode|aot_enable|aod_enable|fod_enable|singletap|glove|ear_detect|pocket_mode|set_grip|sip_mode|game_mode|scan_rate' | tail -6 | sed -e 's/^[^]]*\] *//' | tr '\n' ';')
		C touch.mode_log "$([ -n "$lp" ] && echo PASS || echo SKIP)" kernel+ROM "$([ -n "$lp" ] && echo "mode commands reach the driver" || echo "no mode line in the kernel log")" "${lp:-the log rolled or no mode was set since boot}"; fi
fi
ti=$(grep -iE 'stm_ts|fts|sec_ts|tsp' /proc/interrupts 2>/dev/null | head -2 | awk '{ s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; printf "%s=%s ", $NF, s }')
C touch.irq "$([ -n "$ti" ] && echo PASS || echo FAIL)" kernel "$([ -n "$ti" ] && echo "touch interrupt registered" || echo "no touch interrupt line")" "name=count: $ti"
# command history the driver keeps (/proc/tsp_cmd_hist: every mode command the framework sent, with its result)
if [ -r /proc/tsp_cmd_hist ]; then h=$(tail -c 3000 /proc/tsp_cmd_hist 2>/dev/null | tr -d '\000'); ng=$(printf '%s\n' "$h" | grep -cE 'NG|FAIL|NOT_APPLICABLE')
	C touch.cmd_hist "$([ "$ng" = 0 ] && echo PASS || echo FAIL)" kernel+ROM "$([ "$ng" = 0 ] && echo "no failed mode command" || echo "failed mode commands")" "$ng NG of $(printf '%s\n' "$h" | grep -c .) lines; last: $(printf '%s\n' "$h" | tail -5 | sed -e 's/^[^]]*\] *//' | tr '\n' ';' | cut -c1-420)"
else C touch.cmd_hist SKIP kernel+ROM "no /proc/tsp_cmd_hist" "absent on the OneUI 5.4 kernel (sec_tsp_log off there)"; fi
kerr klog.touch 'stm_ts|fts_|sec_ts|sec_input|sec_cmd|tsp'

# ---------------------------------------------------------------- input devices, keys
ge=$(getevent -pl 2>/dev/null)
# caps <device name>: every KEY_/BTN_/ABS_/SW_/REL_/MSC_/INPUT_PROP_ code the device advertises; codes getevent has no
# name for come out as <TYPE>_0x<code> (Samsung SW_FLIP 0x15, KEY_BLACK_UI_GESTURE 0x1c7, BTN_PALM, ABS_MT_CUSTOM 0x3e)
caps() { printf '%s\n' "$ge" | awk -v want="$1" '/^add device/ { on = 0 } /^ *name:/ { n = $0; sub(/^ *name: *"/, "", n); sub(/".*/, "", n); on = (n == want) } on && /^ +[A-Z]+ +\([0-9a-f]+\):/ { ty = $1 } on { for (i = 1; i <= NF; i++) { if ($i ~ /^(KEY|BTN|ABS|SW|REL|MSC|LED|FF|INPUT_PROP)_[A-Z0-9_]+$/) print $i; else if ($i ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/ && ty != "") print ty "_0x" $i } }' | sort -u | tr '\n' ' '; }
for dv in sec_touchscreen sec_touchproximity sec_touchpad hall grip_sensor grip_notifier meta_event gpio-keys; do
	cp=$(caps "$dv"); id=input.caps.$(printf '%s' "$dv" | tr '-' '_')
	if [ -n "$cp" ]; then C "$id" PASS kernel "set: $cp" "$(printf '%s\n' $cp | grep -c .) codes"; else C "$id" FAIL kernel "set: " "device absent or no event codes"; fi
done
# the three hardware keys, whatever the device is called (qpnp_pon on 5.4, pmic_pwrkey + pmic_resin on 6.12)
keys=$(for dv in gpio-keys qpnp_pon pmic_pwrkey pmic_resin; do caps "$dv"; done | tr ' ' '\n' | grep '^KEY_' | sort -u | tr '\n' ' ')
miss=; for k in KEY_POWER KEY_VOLUMEDOWN KEY_VOLUMEUP; do case " $keys " in *" $k "*) ;; *) miss="$miss $k";; esac; done
C input.hw_keys "$([ -z "$miss" ] && echo PASS || echo FAIL)" kernel "set: $keys" "${miss:+missing:$miss}"
# wakeup capability of the key / touch / hall / grip devices (power key and volume keys must wake; sysfs power/wakeup)
wk=; for i in /sys/class/input/input*; do [ -r $i/name ] || continue; n=$(rd $i/name | tr ' ' '_'); case "$n" in gpio-keys|qpnp_pon|pmic_pwrkey|pmic_resin|sec_touchscreen|hall|grip_sensor) w=$(rd $i/device/power/wakeup); wk="$wk $n=${w:-none}";; esac; done
C input.wakeup "$([ -n "$wk" ] && echo PASS || echo FAIL)" kernel "set:$wk" "power/wakeup of the parent device of each input (none = not wakeup capable)"
# /sys/class/sec/sec_key does not exist on the A52s 5.4 kernel either (the vendor rc write of wakeup_keys fails there
# too): reported so a kernel that grows or loses it shows up; volkey_wakeup is the Lineage/IchthysOS vol-down wake switch
C input.sec_key PASS kernel "sec_key=$([ -d /sys/class/sec/sec_key ] && echo present || echo absent) volkey_wakeup=$([ -e /sys/power/volkey_wakeup ] && echo present || echo absent)" "sec_key attrs: $(ls /sys/class/sec/sec_key/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ') volkey_wakeup=[$(rd /sys/power/volkey_wakeup)]"
setl input.hall_attrs kernel 1 "$(ls /sys/class/sec/hall_ic/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ')"
perm input.perm.hall /sys/class/sec/hall_ic
C input.hall_state "$([ -r /sys/class/sec/hall_ic/hall_detect ] && echo PASS || echo FAIL)" kernel "hall_detect readable" "hall_detect=[$(rd /sys/class/sec/hall_ic/hall_detect)] hall_count=[$(rd /sys/class/sec/hall_ic/hall_count)] (a cover on the phone reads CLOSE)"
# which key layout / device configuration the framework picked per device (a renamed device loses its .kl / .idc)
di=$(DT=25 D input)
kl=$(printf '%s\n' "$di" | awk '/^ +-?[0-9]+: / { n = $0; sub(/^ +-?[0-9]+: /, "", n); gsub(/ /, "_", n) } /KeyLayoutFile:/ { f = $2; sub(/.*\//, "", f); if (n != "" && f != "") print n "=" f } /ConfigurationFile:/ { f = $2; sub(/.*\//, "", f); if (n != "" && f != "") print n "=" f }' | grep -E '^(gpio-keys|qpnp_pon|pmic_pwrkey|pmic_resin|sec_touchscreen|sec_touchproximity|hall|grip|meta_event)' | sort -u | tr '\n' ' ')
C input.keylayouts "$([ -n "$kl" ] && echo PASS || echo SKIP)" kernel+ROM "set: $kl" "from dumpsys input (KeyLayoutFile / ConfigurationFile)"
ki=$(grep -iE 'pon|pwrkey|resin|gpio[-_]keys|vol|hall|certify' /proc/interrupts 2>/dev/null | awk '{ print $NF }' | sort -u | tr '\n' ' ')
C input.key_irqs "$([ -n "$ki" ] && echo PASS || echo FAIL)" kernel "set: $ki" "interrupt names of the key / hall sources"
kerr klog.keys 'gpio[-_]keys|pwrkey|resin|qpnp.pon|pon_|hall|sec_key'

# ---------------------------------------------------------------- sensors
for d in /sys/class/sensors/*; do [ -d "$d" ] || continue; n=${d##*/}
	setl "sensors.attrs.$n" kernel 0 "$(ls $d/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ')"; done
perm sensors.perm /sys/class/sensors/*
ss=$(DT=30 D sensorservice)
setl sensors.types kernel+ROM 10 "$(printf '%s\n' "$ss" | grep -oE 'type: [A-Za-z0-9_.]+\([0-9]+\)' | sed -e 's/^type: //' | sort -u | tr '\n' ' ')"
wu=$(printf '%s\n' "$ss" | grep -cE '\| wakeUp \|'); nw=$(printf '%s\n' "$ss" | grep -cE '\| non-wakeUp \|')
C sensors.wake_split "$([ "$wu" -ge 1 ] && echo PASS || echo FAIL)" kernel+ROM "wakeUp=$wu non-wakeUp=$nw" "$(printf '%s\n' "$ss" | grep -m1 -E '^Total [0-9]+ h/w sensors')"
M sensors_wakeup "$wu"
# who is listening now and which sensors delivered recently (volatile: evidence that events flow at all)
ac=$(printf '%s\n' "$ss" | grep -m1 -oE '^[0-9]+ active connections' | grep -oE '^[0-9]+'); re=$(printf '%s\n' "$ss" | awk '/^Recent Sensor events:/ { on = 1; next } /^Active sensors:/ { on = 0 } on && /: last [0-9]+ events/ { sub(/: last.*/, ""); gsub(/ /, "_"); printf "%s ", $0 }')
C sensors.event_flow "$([ -n "$re" ] && echo PASS || echo SKIP)" kernel+ROM "$([ -n "$re" ] && echo "sensor events were delivered" || echo "no recent events recorded")" "active connections ${ac:-?}; recent: $(printf '%s' "$re" | cut -c1-500)"
rg=$(ls /mnt/vendor/persist/sensors/registry/registry 2>/dev/null | grep -c .)
C sensors.registry "$([ "${rg:-0}" -gt 0 ] && echo PASS || { [ "$ROOT" = 1 ] && echo FAIL || echo SKIP; })" kernel+ROM "$([ "${rg:-0}" -gt 0 ] && echo "registry populated" || echo "registry empty or unreadable")" "${rg:-0} files in /mnt/vendor/persist/sensors/registry/registry; sns_reg_config $(ls /vendor/etc/sensors/sns_reg_config 2>/dev/null | grep -c .)"
G=/sys/class/sensors/grip_sensor
[ -d $G ] && C sensors.grip_identity PASS kernel "name=$(rd $G/name) vendor=$(rd $G/vendor)" "input device $(printf '%s\n' "$ge" | grep -c '"grip_sensor"'); irq $(grep -ciE 'sx93|grip' /proc/interrupts 2>/dev/null)"
kerr klog.sensors 'adsp_factory|\[FACTORY\]|ssc_core|sx93|grip|flip_cover|sensors_core|sns_|slpi'

# ---------------------------------------------------------------- fingerprint
F=/sys/class/fingerprint/fingerprint
setl fingerprint.attrs kernel 4 "$(ls $F/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ')"
perm fingerprint.perm $F
C fingerprint.dev_node "$([ -c /dev/esfp0 ] && echo PASS || echo FAIL)" kernel "$(ls -l /dev/esfp0 2>/dev/null | awk '{ print substr($1, 2) ":" $3 ":" $4 }')" "label $(lz /dev/esfp0); fod_info=[$(rd $T/fod_info)] fp_green_circle $([ -e $L/fp_green_circle ] && echo present || echo absent)"
fpd=$(D fingerprint | head -60)
C fingerprint.framework "$(printf '%s' "$fpd" | grep -q . && echo PASS || echo FAIL)" kernel+ROM "service answers" "$(printf '%s\n' "$fpd" | grep -oE '(sensorType|mSensorType|sensorStrength|sensorLocation[A-Za-z]*|"count"|enrollments?)[^,;}]{0,40}' | head -6 | tr '\n' ';' | cut -c1-300) udfps=$(getprop ro.vendor.fingerprint.sensor_type 2>/dev/null)"
kerr klog.fingerprint 'et7xx|etspi|esfp|fps_|fingerprint'

# ---------------------------------------------------------------- vibrator, LEDs
V=/sys/class/timed_output/vibrator
setl vibrator.attrs kernel 2 "$(ls $V/ 2>/dev/null | grep -vE "$SKIPN" | tr '\n' ' ')"
perm vibrator.perm $V
[ -d $V ] && C vibrator.identity PASS kernel "motor_type=[$(rd $V/motor_type)]" "COINDC = on/off GPIO motor: no intensity/haptic_engine node on 5.4 either; intensity node $([ -e $V/intensity ] && echo present || echo absent) (read only; the sweep never vibrates)"
vm=$(D vibrator_manager | head -80)
C vibrator.hal_caps "$(printf '%s' "$vm" | grep -qiE 'capabilities|vibratorIds' && echo PASS || echo FAIL)" kernel+ROM "$(printf '%s\n' "$vm" | grep -m1 -oiE 'm?capabilities ?= ?[^}]{0,200}' | cut -c1-240)" "ids $(printf '%s\n' "$vm" | grep -m1 -oiE 'm?vibratorIds ?= ?\[[^]]*\]'); haptic settings: haptic_feedback_enabled=$(settings get system haptic_feedback_enabled 2>/dev/null) vibrate_on=$(settings get system vibrate_on 2>/dev/null)"
setl leds.class kernel 0 "$(ls /sys/class/leds/ 2>/dev/null | tr '\n' ' ')"
kerr klog.vibrator 'sec_vib|vibrator|haptic|motor'

# ---------------------------------------------------------------- cross-driver hooks (compiled-out notifiers)
# 5.4 has these callbacks built in; a 6.12 module built without its optional notifier still loads and looks fine,
# the feature behind it is silently gone. The symbol table is the proof that the hook exists in this kernel.
if [ "$ROOT" = 1 ] && [ -r /proc/kallsyms ]; then ks=$(grep -E ' (stm_ts_vbus_notification|stm_hall_ic_notify|ssc_motor_notify|ss_rf_info_notify_callback|ss_esd_touch_notifier_cb|sx9360_ccic_handle_notification|sx9360_hall_notifier|sec_input_notify)([.$ 	]|$)' /proc/kallsyms | awk '{ sub(/[.$].*/, "", $3); print $3 }' | sort -u | tr '\n' ' ')
	hook() { case " $ks " in *" $3 "*) C "$1" PASS kernel "hook present" "$3: $2";; *) C "$1" FAIL kernel "hook absent" "$3 not in /proc/kallsyms: $2";; esac; }
	hook touch.hook.charger "charger (VBUS) state -> touch IC charger noise mode (ghost touches on a noisy charger without it)" stm_ts_vbus_notification
	hook touch.hook.hall "hall notifier -> touch cover mode (5.4 reacts to flip* halls only: informational)" stm_hall_ic_notify
	hook sensors.hook.vibrator "vibrator on/off -> SSC accelerometer motor masking (false pick-up/tilt while vibrating without it)" ssc_motor_notify
	hook display.hook.rf_band "RIL band -> panel dynamic MIPI clock / FFC (radio desense avoidance)" ss_rf_info_notify_callback
	hook display.hook.touch_esd "sec_input notifier -> panel (5.4: CONFIG_INPUT_SEC_NOTIFIER=y; the STM touch driver never sends the ESD event, so informational on this phone)" ss_esd_touch_notifier_cb
	hook sensors.hook.grip_usb "USB attach -> SX9360 grip recalibration" sx9360_ccic_handle_notification
else C touch.hook.charger SKIP kernel "needs root (kallsyms)"; fi

# ---------------------------------------------------------------- wakeup sources of this domain
# 2026-11-24: the SX9360 grip driver held grip_wake_lock 27 min in 395 events overnight on the daily phone (3 s per
# interrupt). Time held per hour of uptime is the number to compare with 5.4; above 1 % of uptime the row fails.
up=$(cut -d. -f1 /proc/uptime); wsl=; gms=0; gcnt=0
for w in /sys/class/wakeup/wakeup*; do [ -r "$w/name" ] || continue; n=$(rd $w/name)
	case "$n" in grip_wake_lock|et7xx_wake_lock|*stm_ts*|*25-0049*|*sec_touch*|*hall*|*gpio-keys*|*gpio_keys*|*pwrkey*|*resin*|*pon*|*vib*|*ssc*|*adsp_factory*)
		wsl="$wsl $n:$(rd $w/active_count):$(rd $w/total_time_ms)ms"
		[ "$n" = grip_wake_lock ] && { gms=$(num "$(rd $w/total_time_ms)"); gcnt=$(num "$(rd $w/active_count)"); };; esac; done
if [ "$ROOT" != 1 ] && [ -z "$wsl" ]; then C power.wakeup_domain SKIP kernel "needs root"
else M grip_wake_ms "${gms:-0}"; M grip_wake_count "${gcnt:-0}"; M grip_wake_ms_per_h "$(( ${gms:-0} * 3600 / (${up:-1} > 0 ? ${up:-1} : 1) ))"
	if [ $(( ${gms:-0} / 10 )) -gt "${up:-0}" ]; then C power.wakeup_domain FAIL kernel "grip_wake_lock held more than 1 % of uptime" "grip ${gms} ms in ${gcnt} events over ${up} s;$wsl"
	else C power.wakeup_domain PASS kernel "no domain wakeup source above 1 % of uptime" "uptime ${up} s; name:count:held$wsl"; fi; fi
