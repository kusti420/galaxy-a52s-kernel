# stress / benchmark variants: thermal load, suspend, mixed soak, framework restart, DRM master handover
# device-side sample: "<max zone mC> <max cpu-zone mC> <p0 kHz> <p4 kHz> <p7 kHz> <cooling cur_state sum> <cpus online>"
_st_sample() { A 'm=0; c=0; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/temp 2>/dev/null); [ -z "$t" ] && continue; [ "$t" -gt 110000 ] && continue; [ "$t" -gt $m ] && m=$t; case "$(cat $z/type 2>/dev/null)" in cpu*) [ "$t" -gt $c ] && c=$t;; esac; done; s=0; for d in /sys/class/thermal/cooling_device*/cur_state; do v=$(cat $d 2>/dev/null); s=$((s+${v:-0})); done; P=/sys/devices/system/cpu/cpufreq; echo $m $c $(cat $P/policy0/scaling_cur_freq) $(cat $P/policy4/scaling_cur_freq) $(cat $P/policy7/scaling_cur_freq) $s $(cat /sys/devices/system/cpu/online)' | tail -1; }
_st_killburn() { A 'pkill -f "st-bur[n]"' >/dev/null 2>&1; return 0; }
# 2 s busy loop pinned to one CPU, prints the highest scaling_cur_freq seen
_st_pinned_max() { A "taskset $(printf %x $((1<<$1))) sh -c 'i=0; while [ \$i -lt 600000 ]; do i=\$((i+1)); done' & sleep 1; m=0; for k in 1 2 3 4 5; do f=\$(cat /sys/devices/system/cpu/cpufreq/policy$1/scaling_cur_freq); [ \$f -gt \$m ] && m=\$f; sleep 0.2; done; echo \$m; wait" | tail -1; }

reg thermal - 1 "thermal: all cores + GPU loaded, temperatures sampled, throttling observed and released"
t_thermal() {
	local dur=120; [ "$QUICK" = 1 ] && dur=25; [ -n "${THERMAL_S:-}" ] && dur=$THERMAL_S
	local max4 max7; max4=$(rd /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq); max7=$(rd /sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq)
	local s0; s0=$(_st_sample); set -- $s0; local t0=${1:-0} cd0=${6:-0}
	[ "$t0" -gt 0 ] 2>/dev/null || { fail "cannot read thermal zones: '$s0'"; return; }
	echo "  start: max ${t0} mC, cooling state sum $cd0, policy4/7 max ${max4}/${max7} kHz"
	printf 'sec\tmax_mC\tcpu_mC\tp0_khz\tp4_khz\tp7_khz\tcdev_sum\tonline\tstatus\n' > "$L.samples.tsv"
	# burners end by themselves after dur s; 'st-burn' in the command line lets pkill -f find them
	( TMO=$((dur+40)) A "e=\$((\$(date +%s)+$dur)); for n in 1 2 3 4 5 6 7 8; do (while :; do i=0; while [ \$i -lt 150000 ]; do i=\$((i+1)); done; [ \$(date +%s) -ge \$e ] && break; done; : st-burn) & done; wait" >/dev/null 2>&1 & )
	( TMO=$((dur+60)) st gl $dur > "$L.gl.out" 2>&1 & )
	local el=0 tmax=$t0 cdmax=$cd0 min4=99999999 min7=99999999 lost=0 s st0 hot=0 start=$(date +%s)
	while [ $el -lt $dur ]; do sleep 5; el=$(( $(date +%s) - start ))
		s=$(_st_sample); set -- $s
		[ "${1:-0}" -gt 0 ] 2>/dev/null || { lost=$((lost+1)); echo "  t+${el}s: no sample ('$s')"; [ $lost -ge 4 ] && break; continue; }
		st0=$(A 'dumpsys thermalservice 2>/dev/null' | awk -F': ' '/^Thermal Status/{print $2; exit}')
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$el" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${st0:-?}" >> "$L.samples.tsv"
		echo "  t+${el}s: max $(( $1/1000 )) C cpu $(( $2/1000 )) C freq $3/$4/$5 kHz cooling $6 online $7 status ${st0:-?}"
		[ "$1" -gt $tmax ] && tmax=$1; [ "$6" -gt $cdmax ] && cdmax=$6
		if [ $el -ge 10 ]; then [ "$4" -lt $min4 ] && min4=$4; [ "$5" -lt $min7 ] && min7=$5; fi
		[ "$1" -ge 100000 ] && { hot=1; echo "  >= 100 C: stopping the load"; break; }
	done
	_st_killburn; A 'pkill -f "st/st[.]dex"' >/dev/null 2>&1
	[ $min4 = 99999999 ] && min4=0; [ $min7 = 99999999 ] && min7=0
	metric thermal_start_c $((t0/1000)); metric thermal_max_c $((tmax/1000)); metric thermal_min_loaded_khz_p4 $min4; metric thermal_min_loaded_khz_p7 $min7; metric cdev_state_max $cdmax
	if [ $lost -ge 4 ]; then adb -s "$S" get-state 2>/dev/null | grep -q device || { fail "phone lost during the thermal load (last max $((tmax/1000)) C)"; return; }; fi
	[ $hot = 1 ] && fail "max temperature reached $((tmax/1000)) C (>= 100 C) under load: $L.samples.tsv"
	local rise=$(( (tmax-t0)/1000 ))
	if [ $rise -ge 5 ]; then ok "load raised temps by $rise C ($((t0/1000)) -> $((tmax/1000)) C in ${el}s)"; else skip "load raised temps by only $rise C in ${el}s ($((t0/1000)) -> $((tmax/1000)) C)"; fi
	local thr=0; [ $cdmax -gt $cd0 ] && thr=1
	[ "${max4:-0}" -gt 0 ] && [ $min4 -gt 0 ] && [ $min4 -lt $((max4*95/100)) ] && thr=1
	[ "${max7:-0}" -gt 0 ] && [ $min7 -gt 0 ] && [ $min7 -lt $((max7*95/100)) ] && thr=1
	if [ $thr = 1 ]; then
		sleep 20; local r4 r7 cd1; r4=$(_st_pinned_max 4); r7=$(_st_pinned_max 7); s=$(_st_sample); set -- $s; cd1=${6:-999999}
		metric thermal_release_khz_p4 "${r4:-0}"; metric thermal_release_khz_p7 "${r7:-0}"
		echo "  release after 20 s: pinned policy4 ${r4} / ${max4}, policy7 ${r7} / ${max7}, cooling $cd1 (start $cd0)"
		if [ "${r4:-0}" -ge $((max4*9/10)) ] && [ "${r7:-0}" -ge $((max7*9/10)) ] && [ "$cd1" -le "$cd0" ]; then ok "throttling observed (cooling sum $cd0 -> $cdmax, loaded min ${min4}/${min7} kHz) and released (${r4}/${r7} kHz 20 s later)"
		else fail "throttling not released 20 s after the load: policy4 ${r4}/${max4} kHz, policy7 ${r7}/${max7} kHz, cooling sum $cd1 (start $cd0): $L.samples.tsv"; fi
	else skip "no throttling reached in ${el}s (max $((tmax/1000)) C; needs a longer or hotter load)"; fi
	local on; on=$(rd /sys/devices/system/cpu/online); if [ "$on" = 0-7 ]; then ok "all CPUs online after the load"; else fail "CPUs online after the load: '$on' (expected 0-7)"; fi
	_st_killburn
}

reg suspend - 1 "suspend: screen off, kernel time in suspend measured (clock delta; root: suspend_stats, stuck wakeup sources)"
t_suspend() {
	local dur=120; [ "$QUICK" = 1 ] && dur=30
	local wifi0=0; A 'cmd wifi status' | grep -q 'Wifi is connected' && wifi0=1
	local usb=0; A 'dumpsys battery' | grep -qE '(USB|AC) powered: true' && usb=1
	local s0 s1 ok0 ok1 f0 f1; s0=$(suspended_ms)
	[ -n "$s0" ] || { skip "suspend time measurement (needs clk.dex: tools/selftest/clk)"; return; }
	if have_root; then ok0=$(num "$(rd /sys/power/suspend_stats/success)"); f0=$(num "$(rd /sys/power/suspend_stats/fail)"); fi
	A 'input keyevent KEYCODE_SLEEP' >/dev/null; echo "  screen off for ${dur}s (usb attached: $usb, wifi connected: $wifi0, suspended so far ${s0} ms)"
	sleep $dur
	adb -s "$S" get-state 2>/dev/null | grep -q device || { sleep 15; adb -s "$S" get-state 2>/dev/null | grep -q device || adb -s "$S" wait-for-device; }
	s1=$(suspended_ms); local d=$(( ${s1:-$s0} - s0 )); metric suspend_ms $d
	if have_root; then ok1=$(num "$(rd /sys/power/suspend_stats/success)"); f1=$(num "$(rd /sys/power/suspend_stats/fail)")
		metric suspend_success $(( ${ok1:-0} - ${ok0:-0} )); metric suspend_fail $(( ${f1:-0} - ${f0:-0} ))
		echo "  suspend_stats: success +$(( ${ok1:-0} - ${ok0:-0} )) fail +$(( ${f1:-0} - ${f0:-0} )) last_failed_dev '$(rd /sys/power/suspend_stats/last_failed_dev)' last_failed_step '$(rd /sys/power/suspend_stats/last_failed_step)'"
		echo "  wakeup sources active now (name, active_since ms):"; R 'cat /sys/kernel/debug/wakeup_sources' | awk 'NR>1 && $6+0 > 0 {print $6, $1}' | sort -rn | head -5 | sed 's/^/    /'
		[ $(( ${f1:-0} - ${f0:-0} )) -gt 0 ] && fail "suspend_stats fail +$(( f1 - f0 )) (last_failed_dev '$(rd /sys/power/suspend_stats/last_failed_dev)')"
	fi
	if [ $d -gt 0 ]; then ok "kernel suspended ${d} ms of ${dur} s screen-off${ok1:+ (suspend_stats success +$(( ok1 - ok0 )))}"
	elif [ $usb = 1 ]; then skip "kernel did not suspend in ${dur} s with USB attached (usb_notify holds a wakelock on a data cable by design; needs USB unplugged or the root a52susp harness)"; hands "Suspend: unplug USB, screen off 10 min, replug; then compare battery drop and run the suspend test again (suspended time must be > 0)"
	else fail "kernel never suspended in ${dur} s of screen-off without USB power (suspended time +0 ms)"; fi
	wake; sleep 1
	if [ $wifi0 = 1 ]; then local i c=0; for i in 1 2 3 4 5 6 7 8 9 10; do A 'cmd wifi status' | grep -q 'Wifi is connected' && { c=1; break; }; sleep 2; done
		if [ $c = 1 ]; then if [ $d -gt 0 ]; then ok "Wi-Fi still connected after suspend"; else note "Wi-Fi still connected after the screen-off period (no suspend happened: not a pass)"; fi; else fail "Wi-Fi connection lost over the screen-off period (not back after 20 s): $(A 'cmd wifi status' | head -3 | tr '\n' ' ' | cut -c1-160)"; fi; fi
}

reg soak - 1 "soak: mixed loop (stock app launches, swipes, screen cycles, Wi-Fi toggles, GPU allocations) watching for black frames and restarts"
t_soak() {
	local dur=900; [ "$QUICK" = 1 ] && dur=60; [ -n "${SOAK_S:-}" ] && dur=$SOAK_S   # SOAK_S=<seconds> overrides
	local allow="com.android.settings com.android.calculator2 com.android.contacts com.android.documentsui com.android.dialer org.lineageos.etar org.lineageos.jelly org.lineageos.aperture com.android.gallery3d org.lineageos.glimpse"
	local inst pkgs= p; inst=$(A 'pm list packages' | sed 's/^package://'); for p in $allow; do echo "$inst" | grep -qx "$p" && pkgs="$pkgs $p"; done
	local -a PK=($pkgs); local np=${#PK[@]}; [ $np -ge 1 ] || { skip "soak (none of the allow-listed stock apps is installed)"; return; }
	echo "  apps: $pkgs"
	local wifi0=0 wen0=0; A 'cmd wifi status' | grep -q 'Wifi is enabled' && wen0=1; A 'cmd wifi status' | grep -q 'Wifi is connected' && wifi0=1
	local ss0 sf0 ss sf; ss0=$(A pidof system_server); sf0=$(A pidof surfaceflinger)
	printf 'sec\tmemavail_mb\tsystem_server\tsurfaceflinger\tmax_mC\tpkg\tmean\n' > "$L.samples.tsv"
	local it=0 black=0 wfail=0 gfail=0 ssr=0 sfr=0 minmem=999999 start=$(date +%s) el=0 mean mem tmax pk o i c
	wake
	while [ $el -lt $dur ]; do it=$((it+1)); pk=${PK[$(( (it-1) % np ))]}
		adb -s "$S" get-state 2>/dev/null | grep -q device || { fail "phone lost during the soak at iteration $it (t+${el}s)"; break; }
		A "monkey -p $pk -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1; sleep 1.5
		A 'input swipe 540 1700 540 700 150; input swipe 540 700 540 1700 150; input swipe 540 1700 540 700 150; input swipe 540 700 540 1700 150' >/dev/null
		mean=$(shot_mean "$L.shot.png"); set -- $mean
		if A dumpsys power | grep -q 'mWakefulness=Awake' && ! locked; then
			if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 0.02 else 1)" "${1:-1}" 2>/dev/null; then black=$((black+1)); cp "$L.shot.png" "$L.black-$black.png"; echo "  iteration $it: BLACK frame in $pk (mean $1) -> $L.black-$black.png"; fi
		else wake; fi
		mem=$(A "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo"); ss=$(A pidof system_server); sf=$(A pidof surfaceflinger)
		tmax=$(A 'm=0; for z in /sys/class/thermal/thermal_zone*/temp; do t=$(cat $z 2>/dev/null); [ -z "$t" ] && continue; [ "$t" -gt 110000 ] && continue; [ "$t" -gt $m ] && m=$t; done; echo $m' | tail -1)
		el=$(( $(date +%s) - start ))
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$el" "$mem" "$ss" "$sf" "$tmax" "$pk" "${mean%% *}" >> "$L.samples.tsv"
		[ -n "$mem" ] && [ "$mem" -lt $minmem ] 2>/dev/null && minmem=$mem
		[ -n "$ss" ] && [ "$ss" != "$ss0" ] && { ssr=$((ssr+1)); echo "  iteration $it: system_server pid $ss0 -> $ss"; ss0=$ss; }
		[ -n "$sf" ] && [ "$sf" != "$sf0" ] && { sfr=$((sfr+1)); echo "  iteration $it: surfaceflinger pid $sf0 -> $sf"; sf0=$sf; }
		if [ $((it % 4)) = 0 ]; then A 'input keyevent KEYCODE_SLEEP' >/dev/null; sleep 2; wake; sleep 1; fi
		if [ $((it % 5)) = 0 ]; then o=$(TMO=180 st glalloc 256); echo "$o" | grep -E '^(RESULT|METRIC)' | sed 's/^/    /'; echo "$o" | grep -q '^RESULT glalloc PASS' || { gfail=$((gfail+1)); echo "$o" > "$L.glalloc-fail-$gfail.out"; echo "  iteration $it: glalloc did not pass -> $L.glalloc-fail-$gfail.out"; }; fi
		if [ $((it % 6)) = 0 ] && [ $wifi0 = 1 ]; then A 'svc wifi disable' >/dev/null; sleep 3; A 'svc wifi enable' >/dev/null; c=0
			for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; A 'cmd wifi status' | grep -q 'Wifi is connected' && { c=1; break; }; done
			[ $c = 1 ] || { wfail=$((wfail+1)); echo "  iteration $it: Wi-Fi did not reconnect within 20 s"; }; fi
		A 'input keyevent KEYCODE_HOME' >/dev/null
		el=$(( $(date +%s) - start ))
	done
	home
	if [ $wen0 = 1 ]; then A 'svc wifi enable' >/dev/null; else A 'svc wifi disable' >/dev/null; fi
	[ $minmem = 999999 ] && minmem=0
	metric soak_iterations $it; metric soak_black_frames $black; metric soak_wifi_reconnect_fail $wfail; metric soak_glalloc_fail $gfail; metric soak_ss_restarts $ssr; metric soak_sf_restarts $sfr; metric soak_min_memavail_mb $minmem
	[ $black -gt 0 ] && fail "$black black frame(s) while awake and unlocked: $L.black-1.png"
	[ $ssr -gt 0 ] && fail "system_server restarted $ssr time(s)"
	[ $sfr -gt 0 ] && fail "surfaceflinger restarted $sfr time(s)"
	[ $gfail -gt 0 ] && fail "GPU allocation torture failed $gfail time(s): $L.glalloc-fail-1.out"
	[ $wfail -gt 0 ] && fail "Wi-Fi did not reconnect after $wfail toggle(s)"
	[ $((black+ssr+sfr+gfail+wfail)) = 0 ] && [ $it -ge 3 ] && ok "$it iterations in ${el}s over $np apps: 0 black frames, 0 restarts, 0 GPU allocation failures, 0 Wi-Fi reconnect failures, min MemAvailable ${minmem} MB"
	return 0
}

reg fwrestart root 0 "framework restart (stop/start): phone must stay up, UI + audio + GPU must come back"
t_fwrestart() {
	SVC_ALLOW=.; CRASH_OK=1   # the test stops the framework itself
	local up0 up1 ss0 as0 t0 i back=0; up0=$(num "$(A 'cut -d. -f1 /proc/uptime')"); ss0=$(A pidof system_server); as0=$(A pidof audioserver)
	klog | tail -30 > "$L.pre-stop.kmsg"; t0=$(date +%s)
	echo "  before: uptime ${up0}s system_server $ss0 audioserver $as0"
	TMO=30 R 'stop; sleep 3; start' >/dev/null
	for i in $(seq 1 45); do sleep 2
		if ! adb -s "$S" get-state 2>/dev/null | grep -q device; then echo "  t+$(( $(date +%s) - t0 ))s: adb lost"; continue; fi
		up1=$(num "$(A 'cut -d. -f1 /proc/uptime')"); [ -n "$up1" ] && [ "$up1" -lt "$up0" ] && break
		A 'service check activity' | grep -q ': found' && A 'dumpsys window 2>/dev/null' | grep -qE 'mCurrentFocus=Window\{' && { back=1; break; }
	done
	local el=$(( $(date +%s) - t0 )); metric fwrestart_s $el
	adb -s "$S" get-state 2>/dev/null | grep -q device || { fail "SoC reset during framework stop: phone not back on adb after ${el}s (kernel log before the stop: $L.pre-stop.kmsg)"; return; }
	up1=$(num "$(A 'cut -d. -f1 /proc/uptime')")
	if [ "${up1:-0}" -lt "$up0" ]; then fail "SoC reset during framework stop: uptime went ${up0}s -> ${up1}s (kernel log before the stop: $L.pre-stop.kmsg)"; A 'start' >/dev/null 2>&1; return; fi
	if [ $back = 1 ]; then ok "framework back with a focused window ${el}s after stop/start, no reset (uptime ${up0} -> ${up1}s)"; else fail "framework not back ${el}s after stop/start: activity service $(A 'service check activity' | tr -d '\n'), focus '$(A 'dumpsys window 2>/dev/null' | grep -m1 mCurrentFocus | cut -c1-100)'"; R 'start' >/dev/null 2>&1; fi
	sleep 5; mute; wake
	local ss1 as1; ss1=$(A pidof system_server); as1=$(A pidof audioserver); echo "  after: system_server $ss1 audioserver $as1"
	if [ -n "$ss1" ] && [ "$ss1" != "$ss0" ]; then ok "system_server restarted ($ss0 -> $ss1)"; else fail "system_server pid unchanged or missing after stop/start ('$ss1')"; fi
	local hal; hal=$(A 'dumpsys media.audio_flinger 2>/dev/null' | grep -cE 'Output thread|Hal stream|Standby')
	if [ -n "$as1" ] && [ "${hal:-0}" -gt 0 ]; then ok "audioserver up with $hal output thread line(s) from the audio HAL"; else fail "audio did not come back: audioserver '$as1', audio_flinger output threads $hal"; fi
	strun gl 2
}

reg drmhandover root 0 "DRM master handover (Abyss-like): stop SurfaceFlinger + composer, lastclose must run clean, restart must draw"
t_drmhandover() {
	SVC_ALLOW=.; CRASH_OK=1   # stops the display stack and, at the end, restarts the framework
	local comp; comp=$(A getprop | grep -E '^\[init\.svc\.[^]]*(composer|hwcomposer)[^]]*\]: \[running\]' | sed -E 's/^\[init\.svc\.([^]]+)\].*/\1/' | head -1)
	[ -n "$comp" ] || { skip "no running composer init service found (getprop init.svc.*composer*)"; return; }
	local k0 sf0; k0=$(klog_last); sf0=$(A pidof surfaceflinger); echo "  composer service: $comp, surfaceflinger pid $sf0"
	TMO=30 R "stop surfaceflinger; stop $comp" >/dev/null; sleep 4
	local st1 st2; st1=$(A getprop init.svc.surfaceflinger); st2=$(A getprop "init.svc.$comp")
	klog_since "${k0:-0}" > "$L.handover.kmsg"
	# always bring the display stack back, whatever happened above
	TMO=30 R "start $comp; sleep 1; start surfaceflinger" >/dev/null
	if [ "$st1" = stopped ] && [ "$st2" = stopped ]; then ok "SurfaceFlinger and $comp stopped (last DRM file closed)"; else fail "could not stop the display stack: surfaceflinger=$st1 $comp=$st2"; fi
	grep -iE 'lastclose|_sde_plane_validate|failed|error' "$L.handover.kmsg" | grep -iE 'drm|sde|msm|dsi|mdss' > "$L.handover.drm"; sed 's/^/    /' "$L.handover.drm" | cut -c1-220 | head -40
	local nlc nerr; nlc=$(grep -ci 'lastclose' "$L.handover.drm"); nerr=$(grep -ciE '_sde_plane_validate|failed|error' "$L.handover.drm"); metric drm_handover_errors "${nerr:-0}"; metric drm_lastclose_lines "${nlc:-0}"
	if [ "${nerr:-0}" -gt 0 ]; then fail "$nerr drm/sde error line(s) at the handover: $(grep -m1 -iE '_sde_plane_validate|failed|error' "$L.handover.drm" | cut -c1-160) ($L.handover.drm)"
	elif [ "${nlc:-0}" -gt 0 ]; then ok "msm_lastclose ran ($nlc log line(s)), 0 drm/sde errors"
	else skip "lastclose leaves no log line on this kernel (0 drm/sde errors seen; needs the lastclose marker build to prove it ran)"; fi
	local i sf1=; for i in $(seq 1 30); do sleep 2; sf1=$(A pidof surfaceflinger); [ -n "$sf1" ] && A 'service check SurfaceFlinger' | grep -q ': found' && break; done
	if [ -z "$sf1" ]; then R "start $comp; start surfaceflinger" >/dev/null 2>&1; sleep 10; sf1=$(A pidof surfaceflinger); fi
	[ -n "$sf1" ] || { fail "SurfaceFlinger did not come back after the handover"; return; }
	sleep 8; mute; wake; home; sleep 2
	local mean; mean=$(shot_mean "$L.after.png"); echo "  after restart: surfaceflinger pid $sf1, screencap mean/std/w/h $mean"; set -- $mean
	if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>0.02 and float(sys.argv[2])>0.01 else 1)" "${1:-0}" "${2:-0}" 2>/dev/null; then ok "picture back after the handover (mean $1)"; else fail "black/uniform frame after the handover (mean ${1:-?} std ${2:-?}): $L.after.png"; fi
	local o hz; o=$(st vsync 2); echo "$o" | tail -5; hz=$(echo "$o" | awk '$1=="METRIC" && $2=="vsync_hz"{print int($3+0.5)}')
	if [ -n "$hz" ] && [ "$hz" -ge 30 ]; then metric drm_handover_vsync_hz "$hz"; ok "vsync running at ${hz} Hz after the handover"; elif [ -n "$hz" ]; then fail "vsync only ${hz} Hz after the handover"; else skip "vsync rate after the handover (needs St vsync)"; fi
	# system_server keeps its connection to the SurfaceFlinger that was stopped: every later activity start fails with
	# DEAD_OBJECT (SurfaceControl.nativeCreate), e.g. the bench app right after this test (2026-11-19). init would have
	# restarted zygote with SurfaceFlinger; do the same so the phone is usable after the test.
	TMO=30 R 'stop; sleep 2; start' >/dev/null; local j; for j in $(seq 1 40); do sleep 2; A 'dumpsys window 2>/dev/null' | grep -qE 'mCurrentFocus=Window\{' && break; done; sleep 4; mute; wake
}
