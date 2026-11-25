#!/system/bin/sh
# Charging + thermal SAFETY parity (drivers612/SPEC/03-power-thermal-usb-storage.md, section 2). READ-ONLY and SILENT:
# nothing is written anywhere, no charger state is changed, no load is started. Works on 5.4 and 6.12, on every ROM.
# Every "stable" value below must be identical on both kernels of one phone; the expected numbers are the phone's
# 5.4 device tree (drivers612/power/DT-VALUES.md, generated from downstream-dt/a52sxq-r02.dts).
. "${0%/*}/../dev-lib.sh"
PS=/sys/class/power_supply
B=$PS/battery
# ---- 1. the whole charger chain is bound (a missing member = the limits below are not enforced by anyone)
want="battery usb ac otg sm5714-charger sm5714-fuelgauge pca9468-charger sec-direct-charger"
miss=; for s in $want; do [ -d $PS/$s ] || miss="$miss $s"; done
C safety.chain "$([ -z "$miss" ] && echo PASS || echo FAIL)" kernel "missing:${miss:- none}" "expected: $want; present: $(ls $PS 2>/dev/null | tr '\n' ' ')"
# ---- 2. the limits the driver was given = the phone's 5.4 values (live device tree, big-endian cells)
DT=; for d in /proc/device-tree/samsung_mobile_device/battery /sys/firmware/devicetree/base/samsung_mobile_device/battery; do [ -d "$d" ] && { DT=$d; break; }; done
cells() { od -An -v -tu1 "$1" 2>/dev/null | tr -s ' \n' ' ' | awk '{ o=""; for (i=1; i+3<=NF; i+=4) { v=(($i*256+$(i+1))*256+$(i+2))*256+$(i+3); if (v>=2147483648) v-=4294967296; o=o (o==""?"":" ") v } print o }'; }
if [ -z "$DT" ]; then C safety.dt_limits FAIL kernel "no battery node" "/proc/device-tree/samsung_mobile_device/battery missing: sec-battery has no limits at all"
elif [ ! -r "$DT/battery,chg_float_voltage" ]; then C safety.dt_limits SKIP kernel "needs root" "$DT not readable"
else bad=; got=; n=0
	while read -r p exp; do [ -n "$p" ] || continue; n=$((n+1)); v=$(cells "$DT/battery,$p"); got="$got $p=$v"; [ "$v" = "$exp" ] || bad="$bad $p=${v:-absent}(want $exp)"; done <<EOF
chg_float_voltage 4380
high_temp_float 4150
low_temp_float 4380
wire_warm_overheat_thresh 500
wire_normal_warm_thresh 420
wire_cool1_normal_thresh 180
wire_cool2_cool1_thresh 150
wire_cool3_cool2_thresh 50
wire_cold_cool3_thresh 0
wire_warm_current 1563
wire_cool1_current 2700
wire_cool2_current 1047
wire_cool3_current 437
overheatlimit_threshold 700
overheatlimit_recovery 680
chg_high_temp 550
chg_high_temp_recovery 480
chg_input_limit_current 1000
chg_charging_limit_current 1400
dchg_high_temp 560
dchg_high_temp_recovery 400
dchg_input_limit_current 1000
dchg_charging_limit_current 2000
mix_high_temp 420
mix_high_chg_temp 500
mix_high_temp_recovery 390
max_input_voltage 9000
max_input_current 3000
max_charging_current 2700
max_charging_charge_power 25000
pd_charging_charge_power 15000
expired_time 9120
recharging_expired_time 5400
full_condition_soc 93
recharge_condition_vcell 4310
swelling_low_rechg_voltage 4230
swelling_high_rechg_voltage 4000
temp_check_type 2
thermal_source 2
chg_temp_check_type 2
dc_step_chg_val_vfloat 4055 4220 4380
dc_step_chg_val_iout 4900 3960 3650
EOF
	C safety.dt_limits "$([ -z "$bad" ] && echo PASS || echo FAIL)" kernel "${bad:-$n/$n limits = 5.4 values}" "$got"
fi
# PCA9468 (25 W direct charger) limits: node name pca9468@57 on the SE3 bus, found by compatible name
P9=$(ls -d /proc/device-tree/soc/i2c@*/pca9468@57 2>/dev/null | head -1)
if [ -n "$P9" ] && [ -r "$P9/pca9468,input-current-limit" ]; then
	a=$(cells "$P9/pca9468,input-current-limit"); b=$(cells "$P9/pca9468,charging-current"); c=$(cells "$P9/pca9468,ta-max-vol")
	C safety.dt_pca9468 "$([ "$a $b $c" = "2550000 6000000 10500000" ] && echo PASS || echo FAIL)" kernel "iin=$a ichg=$b ta_max_vol=$c" "want 2550000 6000000 10500000 (uA, uA, uV)"
else C safety.dt_pca9468 SKIP kernel "node not readable" "${P9:-no /soc/i2c@*/pca9468@57}"; fi
# ---- 3. what the charger chip is programmed with right now
fv=$(num "$(rd $PS/sm5714-charger/constant_charge_voltage)"); [ "${fv:-0}" -gt 100000 ] && fv=$((fv/1000))
if [ -z "$fv" ]; then C safety.float_now SKIP kernel "unreadable" "$PS/sm5714-charger/constant_charge_voltage"
else # 4380 normal, 4360/4340/4320/4270 by battery age (battery,age_data), 4150 in the warm zone; never above 4380
	C safety.float_now "$([ "$fv" -ge 4000 ] && [ "$fv" -le 4380 ] && echo PASS || echo FAIL)" kernel "float<=4380: $([ "$fv" -le 4380 ] && echo y || echo n)" "sm5714 BATREG=$fv mV, battery_cycle=$(rd $B/battery_cycle) fg_asoc=$(rd $B/fg_asoc)"; M chg_float_mv "$fv"; fi
icl=$(num "$(rd $PS/sm5714-charger/current_max)"); fcc=$(num "$(rd $PS/sm5714-charger/current_now)")
C safety.limits_now "$([ "${icl:-0}" -le 3000 ] && [ "${fcc:-0}" -le 2700 ] && echo PASS || echo FAIL)" kernel "input<=3000 charge<=2700: $([ "${icl:-0}" -le 3000 ] && [ "${fcc:-0}" -le 2700 ] && echo y || echo n)" "sm5714 input ${icl:-?} mA, charge ${fcc:-?} mA, type $(rd $B/batt_charging_source) hv=$(rd $B/hv_charger_status) dc_status=$(rd $B/direct_charging_status)"
vn=$(num "$(rd $B/voltage_now)"); [ "${vn:-0}" -gt 100000 ] && vn=$((vn/1000))
C safety.vcell "$([ "${vn:-0}" -ge 3000 ] && [ "${vn:-0}" -le 4420 ] && echo PASS || echo FAIL)" kernel "cell<=4420mV: $([ "${vn:-9999}" -le 4420 ] && echo y || echo n)" "voltage_now=$vn mV status=$(rd $B/status) health=$(rd $B/health)"
# ---- 4. every temperature the protections read is alive and plausible (a dead NTC channel = no JEITA protection)
bt=$(num "$(rd $B/temp)"); ct=$(num "$(rd $B/chg_temp)"); dt=$(num "$(rd $B/dchg_temp)")
ap=$(num "$(rd /sys/class/sec/sec-ap-thermistor/temperature)"); pa=$(num "$(rd /sys/class/sec/sec-pa-thermistor/temperature)"); wf=$(num "$(rd /sys/class/sec/sec-wf-thermistor/temperature)")
tb=; for kv in "batt=$bt" "chg=$ct" "ap=$ap" "pa=$pa" "wf=$wf"; do v=${kv#*=}; if [ -z "$v" ]; then tb="$tb ${kv%%=*}:absent"; elif [ "$v" -le -100 ] || [ "$v" -ge 650 ] || [ "$v" = 900 ] || [ "$v" = -200 ]; then tb="$tb ${kv%%=*}:$v"; fi; done
C safety.ntc_alive "$([ -z "$tb" ] && echo PASS || echo FAIL)" kernel "out of -10..65 C or absent:${tb:- none}" "0.1 C: batt=$bt chg=$ct dchg=$dt ap=$ap pa=$pa wf=$wf batt_temp_adc=$(rd $B/batt_temp_adc) chg_temp_adc=$(rd $B/chg_temp_adc)"
if [ -n "$bt" ] && [ -n "$ap" ]; then sp=$((bt-ap)); [ $sp -lt 0 ] && sp=$((-sp)); sp2=0; [ -n "$pa" ] && { sp2=$((pa-ap)); [ $sp2 -lt 0 ] && sp2=$((-sp2)); }
	# idle phone: all NTCs sit within ~15 C; pa/wf 30+ C above ap = PM7325 gpio1/gpio4 not high-Z (drivers612/power/THERMISTOR-ADC.md)
	C safety.ntc_spread "$([ $sp -le 200 ] && [ $sp2 -le 250 ] && echo PASS || echo FAIL)" kernel "spread ok: $([ $sp -le 200 ] && [ $sp2 -le 250 ] && echo y || echo n)" "|batt-ap|=$sp |pa-ap|=$sp2 (0.1 C); modem: $(getprop gsm.version.baseband | cut -c1-20)"
else C safety.ntc_spread SKIP kernel "thermistor missing" "batt=$bt ap=$ap"; fi
# ---- 5. charge-control nodes the ROMs use to stop charging
nodes safety.ctrl_nodes kernel $B/batt_slate_mode $B/batt_full_capacity $B/siop_level $B/batt_swelling_control $B/safety_timer_info $B/batt_misc_event $B/batt_current_event /sys/class/sec/switch/afc_disable
C safety.protect_battery PASS kernel+ROM "batt_full_capacity node=$([ -e $B/batt_full_capacity ] && echo y || echo n)" "value '$(rd $B/batt_full_capacity)' (100 = off, '85' / '80 OPTION' = Protect battery), slate=$(rd $B/batt_slate_mode) siop=$(rd $B/siop_level) pass_through=$(rd $B/pass_through)"
C safety.lpm_param PASS kernel "batt_lp_charging=$(rd $B/batt_lp_charging)" "must be 0 in a normal boot and 1 in power-off charging (6.12: needs samsung-oneui/lpm patch 0001); androidboot.mode=$(getprop ro.boot.mode) bootmode=$(getprop ro.bootmode)"
# ---- 6. water / hiccup plumbing on the USB-C port
H=/sys/class/sec/switch
C safety.water_nodes "$([ -e $H/hiccup ] && echo PASS || echo FAIL)" kernel "hiccup=$([ -e $H/hiccup ] && echo y || echo n) ccic_water=$([ -e /sys/class/sec/ccic/water ] && echo y || echo n)" "switch: $(ls $H 2>/dev/null | tr '\n' ' ') | ccic water='$(rd /sys/class/sec/ccic/water)' typec water: $(rd /sys/class/typec/port0/device/water 2>/dev/null)"
# ---- 7. SoC thermal protection: zones with trips, cooling devices bound, nothing stuck throttled at idle
nz=0; ntr=0; hot=; for z in /sys/class/thermal/thermal_zone*; do [ -d "$z" ] || continue; nz=$((nz+1)); t=$(num "$(rd $z/temp)"); [ -n "$t" ] && [ "$t" -ge 95000 ] && hot="$hot $(rd $z/type)=$((t/1000))"; ls $z/trip_point_0_temp >/dev/null 2>&1 && ntr=$((ntr+1)); done
ncd=0; bound=0; act=; for c in /sys/class/thermal/cooling_device*; do [ -d "$c" ] || continue; ncd=$((ncd+1)); s=$(num "$(rd $c/cur_state)"); [ "${s:-0}" -gt 0 ] && act="$act $(rd $c/type)=$s"; done
for z in /sys/class/thermal/thermal_zone*; do ls -d $z/cdev[0-9]* >/dev/null 2>&1 && bound=$((bound+1)); done
cpub=0; for z in /sys/class/thermal/thermal_zone*; do case "$(rd $z/type)" in cpu-[01]-[0-9]*) ls -d $z/cdev[0-9]* >/dev/null 2>&1 && cpub=$((cpub+1));; esac; done
C safety.thermal_zones "$([ $nz -ge 30 ] && [ $ntr -ge 20 ] && echo PASS || echo FAIL)" kernel "zones>=30 with trips>=20: $([ $nz -ge 30 ] && [ $ntr -ge 20 ] && echo y || echo n)" "$nz zones, $ntr with trips, >= 95 C now:${hot:- none}"
C safety.cooling_bound "$([ $ncd -ge 10 ] && [ $cpub -ge 8 ] && echo PASS || echo FAIL)" kernel "cpu zones with a cooling device >= 8: $([ $cpub -ge 8 ] && echo y || echo n)" "$ncd cooling devices, $bound zones bound ($cpub CPU zones; 5.4 counts the cpu-*-step zones), active now:${act:- none}"
M thermal_zones_n $nz; M cooling_devices_n $ncd; M cpu_zones_bound $cpub
pm=; for z in /sys/class/thermal/thermal_zone*; do case "$(rd $z/type)" in pm7325_tz|pm8350c_tz|pmr735a_tz) pm="$pm $(rd $z/type):$(for i in 0 1 2; do printf '%s/' "$(rd $z/trip_point_${i}_temp)"; done)";; esac; done
C safety.pmic_alarm "$(printf '%s' "$pm" | grep -q 'pm7325_tz:95000/115000/145000/' && printf '%s' "$pm" | grep -q 'pm8350c_tz:95000/115000/145000/' && echo PASS || echo FAIL)" kernel "$(printf '%s' "$pm" | sed 's/^ //')" "PMIC die temperature alarms: 95 C passive, 115 + 145 C critical (kernel orderly shutdown)"
C safety.bcl "$(ls -d /sys/class/thermal/thermal_zone* 2>/dev/null | while read z; do rd $z/type; echo; done | grep -c 'bcl-lvl' | { read n; [ "$n" -ge 3 ] && echo PASS || echo FAIL; })" kernel "pm8350c-bcl-lvl0..2 zones" "battery current/voltage limit (BCL) zones: cpu4-7 pause, modem/cdsp/gpu limits on a sagging battery"
sk=$(D thermalservice | grep -m3 -iE 'mType=3|SKIN' | tr -s ' ' | tr '\n' ';')
C safety.skin_temp "$(printf '%s' "$sk" | grep -qE 'mValue=[0-9]' && ! printf '%s' "$sk" | grep -qi nan && echo PASS || echo FAIL)" kernel+ROM "framework has a SKIN temperature" "$(printf '%s' "$sk" | cut -c1-300) headroom: $(D thermalservice | grep -m1 -i headroom | cut -c1-120)"
# ---- 8. shutdown paths the framework relies on
C safety.batt_shutdown_inputs PASS kernel+ROM "temp+capacity+voltage readable: $([ -r $B/temp ] && [ -r $B/capacity ] && [ -r $B/voltage_now ] && echo y || echo n)" "BatteryService shuts down at battery temp > config_shutdownBatteryTemperature (default 68.0 C) and at level 0 off charger; kernel: fuelgauge sw_v_empty 3200 mV"
C safety.poweroff_delay PASS kernel "emergency poweroff delay node=$([ -e /sys/module/thermal_sys/parameters/emergency_poweroff_delay_ms ] && echo y || echo n)" "$(rd /proc/sys/kernel/poweroff_cmd) panic=$(rd /proc/sys/kernel/panic) panic_on_oops=$(rd /proc/sys/kernel/panic_on_oops)"
