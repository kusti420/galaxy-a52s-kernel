#!/system/bin/sh
# Display + touch: Samsung panel class, mDNIe, brightness path, AOD nodes, refresh modes; sec touch command
# interface with read-only commands. NOTHING is written under /sys/class/lcd/panel, and panel attributes whose
# read handler talks to the panel (self tests, CRC, gct, ccd, mafpc/self-mask checks, flash gamma) are not opened:
# only the fixed list below is read; the rest of the directory is listed by name.
. "${0%/*}/../dev-lib.sh"
L=/sys/class/lcd/panel
setl display.panel_attrs kernel 30 "$(ls $L 2>/dev/null | grep -vE '^(power|subsystem|uevent|device)$' | tr '\n' ' ')"
if [ -d $L ]; then
	C display.panel_id PASS kernel "lcd_type=[$(rd $L/lcd_type)] window_type=[$(rd $L/window_type)] manufacture_date=[$(rd $L/manufacture_date)]" "cell_id sha $(h12 "$(rd $L/cell_id)") len $(rd $L/cell_id | wc -c); octa_id sha $(h12 "$(rd $L/octa_id)")"
	C display.panel_state PASS kernel "readable" "alpm=[$(rd $L/alpm)] vrr=[$(rd $L/vrr)] vrr_lfd=[$(rd $L/vrr_lfd | cut -c1-80)] adaptive_control=[$(rd $L/adaptive_control)] temperature=[$(rd $L/temperature)] lux=[$(rd $L/lux)] mask_brightness=[$(rd $L/mask_brightness)] hmt_on=[$(rd $L/hmt_on)]"
else C display.panel_id FAIL kernel "no /sys/class/lcd/panel"; fi
nodes display.aod_nodes kernel $L/alpm $L/vrr $L/vrr_lfd $L/mask_brightness $L/actual_mask_brightness $L/fp_green_circle $L/adaptive_control $L/lux $L/hmt_on $L/hmt_bright $L/brt_avg $L/cell_id $L/window_type
Mn=/sys/class/mdnie/mdnie
setl display.mdnie_attrs kernel 5 "$(ls $Mn 2>/dev/null | grep -vE '^(power|subsystem|uevent|device)$' | tr '\n' ' ')"
[ -d $Mn ] && C display.mdnie_state PASS kernel+ROM "mode_max=[$(rd $Mn/mode_max)]" "mode=[$(rd $Mn/mode | cut -c1-60)] scenario=[$(rd $Mn/scenario | cut -c1-60)] accessibility=[$(rd $Mn/accessibility | cut -c1-60)] night_mode=[$(rd $Mn/night_mode | cut -c1-40)] bypass=[$(rd $Mn/bypass | cut -c1-40)]"
B=/sys/class/backlight/panel
nodes display.backlight kernel $B/brightness $B/max_brightness
dd=$(DT=30 D display)
C display.brightness_path "$([ -r $B/brightness ] && echo PASS || echo FAIL)" kernel+ROM "max_brightness=$(rd $B/max_brightness)" "brightness=$(rd $B/brightness) actual=$(rd $B/actual_brightness) labels $(lz $B/brightness); framework: $(printf '%s\n' "$dd" | grep -m1 -oE 'mScreenBrightness(Setting)?=[0-9.]+')"
modes=$(printf '%s\n' "$dd" | grep -oE '(fps|refreshRate)=[0-9]+(\.[0-9])?' | grep -oE '[0-9]+(\.[0-9])?$' | cut -d. -f1 | sort -un | tr '\n' ' ')
C display.refresh_modes "$(printf '%s' "$modes" | grep -q 120 && echo PASS || echo FAIL)" kernel+ROM "modes: $modes" "state $(printf '%s\n' "$dd" | grep -m1 -oE 'mState=[A-Z_]+|mGlobalDisplayState=[A-Z_]+')"
C display.composer "$([ "$(svc vendor.qti.hardware.display.composer)" = running ] && [ "$(svc surfaceflinger)" = running ] && echo PASS || echo FAIL)" kernel+ROM "composer=$(svc vendor.qti.hardware.display.composer) sf=$(svc surfaceflinger) color=$(svc display-color-hal-1-0)" "drm cards $(ls /sys/class/drm 2>/dev/null | grep -c '^card') measured_fps=$(rd /sys/class/drm/sde-crtc-0/measured_fps | cut -c1-60)"
C display.aod_setting PASS info "aod_mode=$(settings get system aod_mode 2>/dev/null) doze_always_on=$(settings get secure doze_always_on 2>/dev/null)" "user settings (AOD on-panel behaviour is a hands-on item)"
# ---- touch (sec_cmd): read-only commands
T=/sys/class/sec/tsp
nodes touch.sec_cmd_nodes kernel $T/cmd $T/cmd_status $T/cmd_result $T/cmd_list $T/input/enabled
C touch.aux_nodes PASS kernel "ss_touch=$([ -d /sys/class/sec/ss_touch ] && echo y || echo n) tsp_msg=$([ -e /proc/tsp_msg ] && echo y || echo n) tsp_cmoffset=$(ls /proc/tsp_cmoffset* 2>/dev/null | grep -c .)" "enabled=$(rd $T/input/enabled) fod_pressed=$([ -e $T/fod_pressed ] && echo present || echo absent)"
if needroot touch.cmds kernel; then
	if [ -w $T/cmd ]; then r=
		for c in get_fw_ver_ic get_fw_ver_bin get_chip_vendor get_chip_name get_x_num get_y_num; do echo $c > $T/cmd 2>/dev/null; sleep 0.15; r="$r $(rd $T/cmd_result)"; done
		case "$r" in *NG*|*"NOT_APPLICABLE"*) C touch.cmds FAIL kernel "$r" "status $(rd $T/cmd_status)";; *) C touch.cmds PASS kernel "$r" "cmd_list $(grep -c . $T/cmd_list 2>/dev/null) commands";; esac
		M touch_cmd_list "$(grep -c . $T/cmd_list 2>/dev/null)"
		setl touch.cmd_list kernel 20 "$(grep -v '^++' $T/cmd_list 2>/dev/null | tr '\n' ' ')"
	else C touch.cmds FAIL kernel "cmd node absent or not writable" "$T/cmd"; fi
fi
ge=$(getevent -pl 2>/dev/null)
C touch.input_dev "$(printf '%s' "$ge" | grep -q ABS_MT_POSITION_X && echo PASS || echo FAIL)" kernel "multitouch device $(printf '%s' "$ge" | grep -q ABS_MT_POSITION_X && echo present || echo absent)" "$(printf '%s\n' "$ge" | grep -B14 ABS_MT_POSITION_X | grep -m1 'name:' | tr -s ' ')"
setl input.devices kernel 3 "$(printf '%s\n' "$ge" | sed -n 's/^ *name: *"\(.*\)"/\1/p' | tr ' ' '_' | tr '\n' ' ')"
