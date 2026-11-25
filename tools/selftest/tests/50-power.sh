# power: charge logger with the phone's own safety limits as FAIL rules (drivers612/SPEC/03-power-thermal-usb-storage.md, T-C1).
# READ-ONLY and SILENT: writes nothing on the phone, changes no charger state. A person plugs the charger under test
# (PC port, 5 V/2 A, 15 W AFC, PD, 25 W PPS) BEFORE the run; the test only watches. CHARGELOG_S=<seconds> (default 600,
# quick 60), sample every 30 s (quick 10 s). Limits = downstream-dt/a52sxq-r02.dts (drivers612/power/DT-VALUES.md).
_cl_sample() { X 'B=/sys/class/power_supply/battery; C=/sys/class/power_supply/sm5714-charger; r() { head -c 200 "$1" 2>/dev/null | tr "\n\t" "  " | sed "s/ *$//"; }
	n() { r "$1" | grep -oE -- "-?[0-9]+" | head -1; }
	echo "$(r $B/status | tr " " _)|$(r $B/health | tr " " _)|$(n $B/capacity)|$(n $B/voltage_now)|$(n $B/current_now)|$(n $B/temp)|$(n $B/chg_temp)|$(n $B/dchg_temp)|$(n $B/batt_charging_source)|$(n $B/hv_charger_status)|$(r $B/direct_charging_status | tr " " _)|$(n $B/direct_charging_step)|$(n $C/current_max)|$(n $C/current_now)|$(n $C/constant_charge_voltage)|$(r $B/safety_timer_info | tr " " _)|$(n $B/time_to_full_now)|$(n $B/siop_level)|$(n $B/batt_full_capacity)"'; }
reg chargelog - 0 "charging safety log: float <= 4380 mV, input <= 3000 mA, charge <= 2700 mA (direct: step table), cell <= 4420 mV, JEITA current per zone, health Good"
t_chargelog() {
	local dur=${CHARGELOG_S:-600} step=30; [ "$QUICK" = 1 ] && { dur=${CHARGELOG_S:-60}; step=10; }
	A 'dumpsys battery' | grep -qE '(USB|AC) powered: true' || { skip "no charger attached (plug the charger under test first)"; hands "Charging: run --only chargelog once per charger type: PC port, 5 V/2 A, Samsung 15 W AFC, a PD charger, Samsung 25 W PPS (with a USB-C power meter the first time), from below 50 %"; return; }
	printf 'sec\tstatus\thealth\tcap\tmv\tma\ttemp\tchg_temp\tdchg_temp\tsrc\thv\tdc_status\tdc_step\ticl\tfcc\tfloat\ttimer\tttf\tsiop\tfullcap\n' > "$L.samples.tsv"
	local el=0 start=$(date +%s) s n=0 bad= vmax=0 imax=-99999 tmax=-999 fmax=0 iclmax=0 src0= srcs= w0 w1 dcseen=0 hot=0
	w0=$(klog | grep -c 'wdt kick')
	while [ $el -le $dur ]; do s=$(_cl_sample | tail -1); el=$(( $(date +%s) - start ))
		local IFS='|'; set -- $s; unset IFS
		local st=$1 he=$2 cap=$3 mv=$4 ma=$5 t=$6 ct=$7 dt=$8 src=$9 hv=${10} dcs=${11} dstep=${12} icl=${13} fcc=${14} fl=${15} tm=${16} ttf=${17} siop=${18} fullcap=${19}
		[ -n "$mv" ] || { fail "battery nodes unreadable at t+${el}s: '$s'"; return; }
		[ "$mv" -gt 100000 ] && mv=$((mv/1000)); [ "${fl:-0}" -gt 100000 ] && fl=$((fl/1000)); [ "${ma#-}" -gt 20000 ] && ma=$((ma/1000))
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$el" "$st" "$he" "$cap" "$mv" "$ma" "$t" "$ct" "$dt" "$src" "$hv" "$dcs" "$dstep" "$icl" "$fcc" "$fl" "$tm" "$ttf" "$siop" "$fullcap" >> "$L.samples.tsv"
		echo "  t+${el}s: $st/$he ${cap}% ${mv} mV ${ma} mA batt $t chg $ct src $src hv $hv dc '$dcs' step $dstep icl $icl fcc $fcc float $fl"
		n=$((n+1)); [ -z "$src0" ] && src0=$src; case " $srcs " in *" $src "*) ;; *) srcs="$srcs $src";; esac
		[ "$mv" -gt $vmax ] && vmax=$mv; [ "$ma" -gt $imax ] && imax=$ma; [ "${t:-0}" -gt $tmax ] && tmax=$t; [ "${fl:-0}" -gt $fmax ] && fmax=$fl; [ "${icl:-0}" -gt $iclmax ] && iclmax=$icl
		local dc=0; [ "$dcs" = 1 ] && { dc=1; dcseen=1; }   # direct_charging_status = 1 while the PD contract is a PPS APDO
		# hard limits (any single sample)
		[ "${fl:-0}" -gt 4380 ] && bad="$bad; t+${el}s float ${fl} mV > 4380"
		[ "$mv" -gt 4420 ] && bad="$bad; t+${el}s cell ${mv} mV > 4420"
		[ "${icl:-0}" -gt 3000 ] && bad="$bad; t+${el}s input limit ${icl} mA > 3000"
		if [ $dc = 1 ]; then [ "$ma" -gt 5100 ] && bad="$bad; t+${el}s direct charge ${ma} mA > 4900 (+4 %)"; [ "$mv" -ge 4220 ] && [ "$ma" -gt 3800 ] && bad="$bad; t+${el}s ${ma} mA at ${mv} mV (step 3 allows 3650)"
		else [ "$ma" -gt 2850 ] && bad="$bad; t+${el}s battery current ${ma} mA > 2700 (+5 %) on the switching charger"; fi
		case "$he" in Good|"") ;; *) bad="$bad; t+${el}s health $he";; esac
		# JEITA zones (0.1 C): the current must respect the zone, with 8 % measurement margin, after the first sample
		if [ $n -gt 2 ] && [ -n "$t" ]; then
			[ "$t" -gt 500 ] && [ "$ma" -gt 50 ] && bad="$bad; t+${el}s charging ${ma} mA at ${t} (>50.0 C: must stop)"
			[ "$t" -lt 0 ] && [ "$ma" -gt 50 ] && bad="$bad; t+${el}s charging ${ma} mA at ${t} (<0 C: must stop)"
			[ "$t" -gt 430 ] && [ "$t" -le 500 ] && { hot=1; [ "$ma" -gt 1690 ] && bad="$bad; t+${el}s ${ma} mA in the warm zone (1563)"; [ "${fl:-0}" -gt 4160 ] && bad="$bad; t+${el}s float ${fl} in the warm zone (4150)"; }
			[ "$t" -lt 140 ] && [ "$t" -ge 50 ] && [ "$ma" -gt 1130 ] && bad="$bad; t+${el}s ${ma} mA in cool2 (1047)"
			[ "$t" -lt 40 ] && [ "$t" -ge 0 ] && [ "$ma" -gt 475 ] && bad="$bad; t+${el}s ${ma} mA in cool3 (437)"
		fi
		[ -n "$ct" ] && [ "$ct" -gt 570 ] && [ "${icl:-0}" -gt 1000 ] && [ $n -gt 4 ] && bad="$bad; t+${el}s charger IC ${ct} (>55.0 C) but input limit still ${icl} mA (1000)"
		[ $el -ge $dur ] && break; sleep $step
	done
	w1=$(klog | grep -c 'wdt kick')
	metric chg_vmax_mv $vmax; metric chg_imax_ma $imax; metric chg_tmax_dc $tmax; metric chg_float_max_mv $fmax; metric chg_icl_max_ma $iclmax
	note "cable types seen (Samsung numbers):$srcs; direct charging seen: $dcseen; samples $n in ${el}s: $L.samples.tsv"
	if [ -z "$bad" ]; then ok "no limit crossed in $n samples (max ${vmax} mV, ${imax} mA, ${tmax} batt temp, float ${fmax} mV, input limit ${iclmax} mA)"; else fail "limits crossed:${bad#;}"; fi
	if [ "$KLOG" = none ]; then skip "charger watchdog kicks (no kernel log access)"; elif [ $imax -gt 50 ] && [ $el -ge 120 ]; then
		if [ $((w1-w0)) -gt 0 ]; then ok "charger IC watchdog kicked $((w1-w0)) times while charging"; else note "no 'wdt kick' lines in the kernel log during ${el}s of charging (log level or ring buffer wrap? check by hand once)"; fi; fi
	[ $hot = 1 ] && note "warm zone (>43 C) was reached during this run: the warm rules above were really exercised"
	[ $imax -le 50 ] && skip "current never above 50 mA (battery full or charging paused): rerun below 80 %"
	return 0
}
