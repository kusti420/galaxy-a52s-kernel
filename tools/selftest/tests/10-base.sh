# boot health, display, touch, GPU, CPU, memory, storage
reg boot - 1 "boot health: boot_completed, enforcing, kernel errors since boot, restarting services, tombstones"
t_boot() {
	chk "boot_completed=1" [ "$(A getprop sys.boot_completed)" = 1 ]
	chk "SELinux enforcing" [ "$(A getenforce)" = Enforcing ]
	local bt; bt=$(A 'logcat -b events -d 2>/dev/null | grep -m1 boot_progress_enable_screen' | awk '{print $NF}')
	if [ -n "$bt" ]; then metric boot_enable_screen_ms "$bt"; if [ "$bt" -lt 90000 ]; then ok "UI up ${bt} ms after kernel start"; else fail "slow boot: ${bt} ms to enable_screen"; fi; else note "boot time: events buffer rolled over"; fi
	if [ "$KLOG" != none ]; then
		local first n; first=$(head -1 "$RUN/kmsg-before.txt" | grep -oE '[0-9]+\.[0-9]+' | head -1)
		n=$(grep -cE "$KBAD" "$RUN/kmsg-before.txt"); metric kernel_bad_lines_at_start "$n"; grep -E "$KBAD" "$RUN/kmsg-before.txt" | head -20
		if [ "$n" = 0 ]; then ok "0 kernel WARN/BUG/oops lines in the log from ${first}s"; else fail "$n kernel WARN/BUG/error lines before the run: $(grep -m1 -E "$KBAD" "$RUN/kmsg-before.txt" | cut -c1-140)"; fi
		[ "${first%.*}" -gt 5 ] 2>/dev/null && skip "kernel log only reaches back to ${first}s (boot-time WARNs not visible: needs root dmesg right after boot or log_buf_len)"
	else skip "kernel log (needs root or an a52kmsg kernel)"; fi
	if have_root; then local d; d=$(R 'cat /sys/kernel/debug/devices_deferred'); echo "$d"; if [ -z "$d" ]; then ok "no deferred probes"; else fail "deferred probes: $(echo "$d" | awk '{print $1}' | tr '\n' ' ' | cut -c1-200)"; fi; else skip "deferred probe list (needs root)"; fi
	local rs; rs=$(A getprop | grep -E '^\[init\.svc\.' | grep -E '\[restarting\]'); A getprop | grep -E '^\[init\.svc\.' | grep -vE 'running|stopped' 
	if [ -z "$rs" ]; then ok "no init service in restart loop"; else fail "services restarting: $(echo "$rs" | tr '\n' ' ' | cut -c1-200)"; fi
	local tb; tb=$(A 'dumpsys dropbox 2>/dev/null | grep -cE "SYSTEM_TOMBSTONE|system_server_crash|system_server_watchdog|SYSTEM_LAST_KMSG"'); metric dropbox_crash_entries "$(num "$tb")"
	local fc; fc=$(A 'logcat -b crash -d 2>/dev/null | grep -cE "Fatal signal|AndroidRuntime: Process: "')   # app_process tools (no Process: line) do not count; metric crash_buffer_fatals "$(num "$fc")"
	A 'logcat -b crash -d 2>/dev/null | grep -E -A3 "Fatal signal|FATAL EXCEPTION" | head -30'
	# a daemon spinning at rest (seen: a HAL in a busy loop keeps a core at max frequency and out of idle)
	local spin; spin=$(A 'top -b -n 2 -d 3 -m 5 2>/dev/null' | awk '/PID +USER/{blk++} blk==2 && $9+0 >= 70 && $0 !~ /top -b/ {print $NF " " $9 "% (pid " $1 ", cpu time " $11 ")"}'); A 'top -b -n 1 -m 5 | tail -6'
	if [ -z "$spin" ]; then ok "no process above 70 % CPU at rest"; else fail "process spinning at rest: $(echo "$spin" | tr '\n' ' ' | cut -c1-200)"; fi
	if [ "$(num "$fc")" = 0 ]; then ok "0 fatal crashes in the crash buffer"; else fail "$fc fatal crash(es) since boot: $(A 'logcat -b crash -d | grep -m1 -A2 -E "Fatal signal|FATAL EXCEPTION|Process:"' | tr '\n' ' ' | cut -c1-200)"; fi
}

reg display - 1 "display: pattern drawn + screencap compare, measured vsync at 60/120 Hz, 10 off/on cycles, brightness sweep, rotation"
t_display() {
	wake; home; sleep 1
	# 1. known pattern on top of everything, verified by screencap pixel compare
	local o; ( st disp 12 > "$L.disp.out" 2>&1 & ); local i; for i in $(seq 1 25); do grep -q 'disp shown' "$L.disp.out" 2>/dev/null && break; sleep 0.7; done
	if grep -q 'disp shown' "$L.disp.out"; then
		local exp got bad=4 q try; exp=$(grep -m1 'disp colours' "$L.disp.out" | awk '{print toupper($4), toupper($5), toupper($6), toupper($7)}')
		for try in 1 2 3 4 5; do sleep 1; adb -s "$S" exec-out screencap -p > "$L.pattern.png"; set -- $exp
			bad=$(python3 - "$L.pattern.png" "$@" <<'PY'
import subprocess, sys
png, exp = sys.argv[1], sys.argv[2:]
w, h = map(int, subprocess.run(["magick", png, "-format", "%w %h", "info:"], capture_output=True, text=True).stdout.split())
bad = 0
for (fx, fy), e in zip(((.25, .25), (.75, .25), (.25, .75), (.75, .75)), exp):
    g = subprocess.run(["magick", png, "-format", "%%[hex:u.p{%d,%d}]" % (w * fx, h * fy), "info:"], capture_output=True, text=True).stdout.strip()[:6].upper()
    okq = len(g) == 6 and all(abs(int(g[i:i+2], 16) - int(e[i:i+2], 16)) <= 6 for i in (0, 2, 4))
    sys.stderr.write("  quadrant %.2f,%.2f: expected %s got %s %s\n" % (fx, fy, e, g, "ok" if okq else "MISMATCH"))
    bad += 0 if okq else 1
print(bad)
PY
); [ "$bad" = 0 ] && break; done
		if [ "$bad" = 0 ]; then ok "4-colour pattern verified by screencap (attempt $try)"; elif [ "$bad" = 4 ]; then skip "pattern layer never appeared in 5 screencaps (todo: St disp layer is not composited above the launcher in a suite run although it was in a standalone run; evidence $L.pattern.png)"
		else fail "pattern mismatch in $bad of 4 quadrants in 5 screencaps over 5 s: $L.pattern.png"; fi
	else cat "$L.disp.out"; skip "pattern draw: $(grep -m1 RESULT "$L.disp.out" | cut -c1-120) (needs St disp)"; fi
	for i in $(seq 1 20); do grep -q '^RESULT' "$L.disp.out" 2>/dev/null && break; sleep 1; done
	# 2. real vsync rate at each refresh rate
	local hz m
	for hz in 60 120; do if [ "${ONEUI:-0}" = 1 ]; then ps secure refresh_rate_mode $([ $hz = 60 ] && echo 0 || echo 2); else ps system min_refresh_rate $hz.0; ps system peak_refresh_rate $hz.0; fi; sleep 1.5   # One UI: secure refresh_rate_mode 0 = Standard 60, 2 = High 120
		o=$(st vsync 3); echo "$o"; m=$(echo "$o" | awk '$1=="METRIC" && $2=="vsync_hz"{print int($3+0.5)}')
		if [ -z "$m" ]; then skip "vsync count at $hz Hz (needs St vsync)"; else metric vsync_hz_at_$hz "$m"; if [ "$m" -ge $((hz-3)) ] && [ "$m" -le $((hz+3)) ]; then ok "measured ${m} Hz vsync at ${hz} Hz mode"; else fail "asked ${hz} Hz, measured ${m} Hz vsync"; fi; fi
	done; restore_one system min_refresh_rate; restore_one system peak_refresh_rate; restore_one secure refresh_rate_mode
	# 3. off/on x10: measured by composition state + a non-black screencap after each wake
	local n=10 good=0 mean; [ "$QUICK" = 1 ] && n=3
	for i in $(seq 1 $n); do A 'input keyevent KEYCODE_SLEEP' >/dev/null; sleep 1.5; local off; off=$(A dumpsys power | grep -m1 -o 'mWakefulness=[A-Za-z]*')
		A 'input keyevent KEYCODE_WAKEUP' >/dev/null; sleep 1.2; locked && unlock >/dev/null; sleep 0.5; mean=$(shot_mean "$L.cyc.png"); echo "  cycle $i: $off -> mean/std/w/h $mean"
		[ "$off" != "mWakefulness=Awake" ] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>0.02 and float(sys.argv[2])>0.01 else 1)" $mean 2>/dev/null && good=$((good+1)); done
	metric screen_cycles_ok "$good"; if [ $good = $n ]; then ok "$n/$n off/on cycles came back with a picture"; else fail "only $good/$n off/on cycles produced a non-black frame ($L.cyc.png)"; fi
	# 4. brightness sweep (the panel takes it through the Samsung DCS path; measured value = what the kernel applied when readable)
	ps system screen_brightness_mode 0; local b cd cds=
	for b in 0.05 0.3 0.6 1.0 0.3; do A "cmd display set-brightness $b" >/dev/null; sleep 1.5; cd=$(klog | grep ss_brightness_dcs | tail -1 | grep -oE 'candela:[0-9]+' | cut -d: -f2); [ -z "$cd" ] && cd=$(rd /sys/class/backlight/panel/actual_brightness)   # root: actual_brightness exists but stays 0 on the Samsung DCS path, so the kernel log line comes first
		echo "  set $b -> panel: ${cd:-unreadable} cd (kernel ss_brightness_dcs)"; cds="$cds ${cd:-x}"; done
	set -- $cds; metric brightness_cd_min "${1:-0}"; metric brightness_cd_max "${4:-0}"
	if [ "$#" = 5 ] && [ "$1" -lt "$2" ] 2>/dev/null && [ "$2" -lt "$3" ] && [ "$3" -lt "$4" ] && [ "$5" -lt "$4" ] && [ $(( $5 - $2 )) -ge -3 ] && [ $(( $5 - $2 )) -le 3 ]; then ok "brightness sweep applied by the panel driver: $1 -> $2 -> $3 -> $4 -> $5 cd"
	elif echo "$cds" | grep -q x; then skip "brightness sweep sent, applied panel level not readable (needs root sysfs or a kernel log with ss_brightness_dcs)"
	else fail "brightness sweep 5%/30%/60%/100%/30% gave panel levels$cds cd (not monotonic)"; fi
	restore_one system screen_brightness_mode
	# 5. rotation: real composition size from a screencap of a rotatable stock activity
	A 'wm user-rotation lock 1; am start -a android.settings.SETTINGS' >/dev/null; sleep 2.5; mean=$(shot_mean "$L.rot.png"); echo "  rotated: $mean"
	A 'wm user-rotation free; wm user-rotation lock 0; input keyevent KEYCODE_HOME' >/dev/null; [ "$(gs system accelerometer_rotation)" = 1 ] && A 'wm user-rotation free' >/dev/null
	set -- $mean; if [ "${3:-0}" -gt "${4:-0}" ] 2>/dev/null; then ok "rotation: landscape frame ${3}x${4} captured"; else fail "rotation: frame stayed ${3:-?}x${4:-?} ($L.rot.png)"; fi
	skip "HBM / fingerprint mask (needs a finger: hands-on), AOD/doze (todo)"; hands "Fingerprint unlock (UDFPS mask/HBM path), also with Night Light on"; hands "Look at the panel: colours, flicker at low brightness, 120 Hz smoothness"
}

reg touch - 1 "touch: controller present with multitouch axes (real touches need a finger)"
t_touch() {
	local g; g=$(A 'getevent -pl 2>/dev/null'); echo "$g" | grep -E 'add device|name:' | paste - - | cut -c1-150
	if echo "$g" | grep -q ABS_MT_POSITION_X; then note "multitouch device registered: $(echo "$g" | grep -B12 ABS_MT_POSITION_X | grep -m1 'name:' | tr -s ' ')"; else fail "no input device with ABS_MT_POSITION_X"; fi
	have_root && { R 'cat /sys/class/sec/tsp/cmd_list >/dev/null 2>&1; echo get_fw_ver_ic > /sys/class/sec/tsp/cmd; cat /sys/class/sec/tsp/cmd_result'; }
	skip "real touch events (needs a finger: hands-on; synthetic input cannot prove the controller)"; hands "Touch: draw across the whole screen, edges and corners; multi-touch pinch"
}

reg gpu - 1 "GPU: GLES render loop with pixel readback, allocation/fragmentation torture that keeps rendering, UI frames"
t_gpu() {
	local s=6 mb=768; [ "$QUICK" = 1 ] && { s=3; mb=256; }
	local f0 f1; have_root && f0=$(rd /sys/class/kgsl/kgsl-3d0/gpuclk)
	strun gl $s
	have_root && { st gl 4 >/dev/null 2>&1 & local sp=$!; sleep 2; f1=$(rd /sys/class/kgsl/kgsl-3d0/gpuclk); wait $sp; local f2 i s0 s1 top; for i in $(seq 20); do sleep 1; f2=$(rd /sys/class/kgsl/kgsl-3d0/gpuclk); [ "${f2:-0}" -lt "${f1:-0}" ] && break; done
		# the level index can stay up while the GPU slumbers (clocks off): then judge by the active time at the top
		# level (gpu_clock_stats, us per level) over 5 s of idle
		if [ "${f2:-0}" -ge "${f1:-0}" ]; then s0=$(rd /sys/class/kgsl/kgsl-3d0/gpu_clock_stats | awk '{print $1}'); sleep 5; s1=$(rd /sys/class/kgsl/kgsl-3d0/gpu_clock_stats | awk '{print $1}'); top=$(( (${s1:-0} - ${s0:-0}) / 1000 )); echo "  level index stays $f2 after the load; active at the top level: $top ms in 5 s"; [ "$top" -lt 250 ] && f2="$f2-slumber"; fi; metric gpu_clk_loaded "$f1"; metric gpu_clk_idle "$f2"; echo "  gpuclk idle-before $f0 loaded $f1 idle-after $f2"
		if [ "${f2%-slumber}" != "$f2" ]; then ok "GPU clock scaled up under load ($f1 Hz); idle: index kept but ${top} ms active at it in 5 s (slumber)"; f2=${f2%-slumber}; elif [ "${f1:-0}" -gt "${f2:-0}" ]; then ok "GPU clock scaled up under load ($f1 Hz) and back down ($f2 Hz)"; elif [ "${f1:-0}" = "$(rd /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies | tr ' ' '\n' | grep . | sort -n | head -1)" ]; then skip "GPU frequency scaling: the vsync-limited GL loop (about 60-120 fps of a small scene) runs at the lowest OPP ($f1 Hz) on this governor; needs a heavier load (bench gpu.torture) to prove scaling"
		else fail "GPU clock did not scale: loaded $f1, idle $f2"; fi; } || skip "GPU frequency scaling (needs root: kgsl sysfs)"
	strun glalloc $mb
	# real UI frames through HWUI/SurfaceFlinger
	wake; A 'am start -a android.settings.SETTINGS >/dev/null; sleep 1.5; dumpsys gfxinfo com.android.settings reset >/dev/null; for i in 1 2 3 4 5 6; do input swipe 540 1700 540 600 150; input swipe 540 600 540 1700 150; done' >/dev/null
	local g tot jank; g=$(A dumpsys gfxinfo com.android.settings); tot=$(echo "$g" | awk -F: '/Total frames rendered/{print $2+0}'); jank=$(echo "$g" | awk -F'[:(]' '/Janky frames:/{print $2+0; exit}'); echo "$g" | grep -E 'Total frames|Janky|percentile' | head -8; home
	metric ui_frames "${tot:-0}"; metric ui_janky "${jank:-0}"; mean=$(shot_mean "$L.ui.png")
	if [ "${tot:-0}" -ge 30 ]; then ok "Settings scroll: $tot frames rendered, $jank janky"; else fail "Settings scroll rendered only ${tot:-0} frames"; fi
}

reg cpu - 1 "CPU: every cpufreq policy reaches max under load and drops when idle, idle-state residency grows, thermal zones sane, hotplug (root)"
t_cpu() {
	local p cpu max min hi lo
	for p in $(A 'ls -d /sys/devices/system/cpu/cpufreq/policy*'); do cpu=${p##*policy}; max=$(rd $p/cpuinfo_max_freq); min=$(rd $p/cpuinfo_min_freq)
		hi=$(A "taskset $(printf %x $((1<<cpu))) sh -c 'i=0; while [ \$i -lt 400000 ]; do i=\$((i+1)); done' & sleep 1.2; m=0; for k in 1 2 3 4 5; do f=\$(cat $p/scaling_cur_freq); [ \$f -gt \$m ] && m=\$f; sleep 0.2; done; echo \$m; wait")
		sleep 2; lo=$(A "m=99999999; for k in 1 2 3 4 5 6 7 8; do f=\$(cat $p/scaling_cur_freq); [ \$f -lt \$m ] && m=\$f; sleep 0.25; done; echo \$m")
		echo "  policy$cpu: min $min max $max loaded $hi idle $lo gov $(rd $p/scaling_governor)"; metric cpu${cpu}_loaded_khz "$hi"; metric cpu${cpu}_idle_khz "$lo"
		if [ "${hi:-0}" -ge $((max*9/10)) ]; then ok "policy$cpu loaded ${hi}/${max} kHz"; else fail "policy$cpu reached only ${hi} of ${max} kHz under a pinned busy loop"; fi
		if [ "${lo:-99999999}" -le $((max*6/10)) ]; then ok "policy$cpu idle ${lo} kHz"; else fail "policy$cpu never dropped below ${lo} kHz when idle (max $max)"; fi
	done
	chk "WALT sysctls present (/proc/sys/walt)" [ -n "$(A 'ls /proc/sys/walt 2>/dev/null | head -1')" ]
	# cpuidle residency delta per CPU over 4 idle seconds
	local a b; a=$(A 'for c in 0 1 2 3 4 5 6 7; do t=0; for s in /sys/devices/system/cpu/cpu$c/cpuidle/state[1-9]; do t=$((t+$(cat $s/time))); done; echo $t; done' | tr '\n' ' '); sleep 4
	b=$(A 'for c in 0 1 2 3 4 5 6 7; do t=0; for s in /sys/devices/system/cpu/cpu$c/cpuidle/state[1-9]; do t=$((t+$(cat $s/time))); done; echo $t; done' | tr '\n' ' ')
	local dead=; set -- $b; local i=0 x; for x in $a; do local y; eval "y=\${$((i+1))}"; local d=$(( (y-x)/1000 )); echo "  cpu$i deep idle (state>=1) +${d} ms in 4 s"; metric cpu${i}_deepidle_ms_per_4s "$d"; [ $d -lt 200 ] && dead="$dead cpu$i(${d}ms)"; i=$((i+1)); done
	[ -n "$dead" ] && { echo "  busiest processes:"; A 'top -b -n 1 -m 4 | tail -5'; dead="$dead; busiest: $(A 'top -b -n 1 -m 3 2>/dev/null' | awk '$9+0 >= 50 && $0 !~ /top -b/ {print $NF " " $9 "%"}' | head -2 | tr '\n' ' ')"; }
	if [ -z "$dead" ]; then ok "all 8 CPUs entered power-collapse idle states (>=200 ms in 4 s)"; else fail "CPUs with almost no deep idle in 4 idle seconds:$dead"; fi
	if have_root; then local cl; cl=$(R 'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -40; cat /sys/power/soc_sleep/stats /sys/kernel/debug/qcom_stats/* 2>/dev/null | head -40'); echo "$cl"; note "cluster idle stats logged (root)"; else skip "cluster/SoC idle residency (needs root)"; fi
	# thermal zones
	local z bad=0 n=0 t; for t in $(A 'cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null'); do n=$((n+1)); { [ "$t" -lt -30000 ] || [ "$t" -gt 110000 ]; } 2>/dev/null && bad=$((bad+1)); done; metric thermal_zones "$n"
	A 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp 2>/dev/null)"; done' | column -c 200 | head -40
	if [ $n -ge 20 ] && [ $bad -le 3 ]; then ok "$n thermal zones read, $bad out of range"; else fail "thermal zones: $n readable, $bad out of range (-30..110 C)"; fi
	if have_root; then local on=0 off=0 c
		for c in 1 2 3 4 5 6 7; do R "echo 0 > /sys/devices/system/cpu/cpu$c/online"; [ "$(rd /sys/devices/system/cpu/cpu$c/online)" = 0 ] && off=$((off+1)); R "echo 1 > /sys/devices/system/cpu/cpu$c/online"; [ "$(rd /sys/devices/system/cpu/cpu$c/online)" = 1 ] && on=$((on+1)); done
		if [ $on = 7 ] && [ $off = 7 ]; then ok "hotplug: cpu1-7 each went offline and back"; else fail "hotplug: $off/7 went offline, $on/7 came back; online now $(rd /sys/devices/system/cpu/online)"; fi
	else skip "CPU hotplug (needs root)"; fi
	chk "all 8 CPUs online" [ "$(rd /sys/devices/system/cpu/online)" = 0-7 ]
}

reg memory - 1 "memory: fill RAM with anonymous pages until zram swaps, system must survive (no OOM kill, system_server stays)"
t_memory() {
	local av sw ss0 so0 oom0 n per; av=$(A "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo"); sw=$(A "awk '/SwapTotal/{print int(\$2/1024)}' /proc/meminfo")
	chk "swap (zram) configured: ${sw} MB" [ "${sw:-0}" -gt 0 ]
	ss0=$(A pidof system_server); so0=$(A "awk '/^pswpout/{print \$2}' /proc/vmstat"); oom0=$(A "awk '/^oom_kill/{print \$2}' /proc/vmstat")
	per=200; n=$(( (av + sw/4) / per )); [ "$QUICK" = 1 ] && n=$(( av*6/10/per )); [ $n -gt 24 ] && n=24
	echo "  MemAvailable ${av} MB, swap ${sw} MB -> $n x ${per} MB of touched anonymous memory for 12 s"
	TMO=120 A "for i in \$(seq 1 $n); do (x=\$(head -c ${per}m /dev/zero | tr '\\0' 'a'); sleep 12; : st-burn) & done; sleep 9; awk '/MemAvailable|SwapFree|MemFree/{printf \"%s %d MB  \", \$1, \$2/1024}' /proc/meminfo; echo; wait" 
	local so1 oom1 ss1; so1=$(A "awk '/^pswpout/{print \$2}' /proc/vmstat"); oom1=$(A "awk '/^oom_kill/{print \$2}' /proc/vmstat"); ss1=$(A pidof system_server)
	metric mem_fill_mb $((n*per)); metric mem_swapout_pages $((so1-so0)); metric mem_oom_kills $((oom1-oom0))
	if [ $((so1-so0)) -gt 1000 ]; then ok "zram took $(( (so1-so0)*4/1024 )) MB of swap-out under a $((n*per)) MB fill"; else skip "fill of $((n*per)) MB did not push anything to swap (pswpout +$((so1-so0)))"; fi
	chk "kernel OOM kills during the fill: $((oom1-oom0))" [ $((oom1-oom0)) = 0 ]
	chk "system_server survived (pid $ss1)" [ "$ss0" = "$ss1" ]
	local cma; cma=$(A "awk '/CmaTotal/{t=\$2}/CmaFree/{f=\$2}END{print int(t/1024), int(f/1024)}' /proc/meminfo"); note "CMA total/free MB: $cma (exercised for real by the camera and video tests)"
	wake
}

reg storage - 1 "storage: 256 MB write+fsync, direct read back with checksum, 4k sync writes, encryption state, microSD"
t_storage() {
	local mb=256; [ "$QUICK" = 1 ] && mb=64; local D=/data/local/tmp/st
	head -c $((mb*1024*1024)) /dev/urandom > "$RUN/blob.bin"; local h; h=$(sha256sum "$RUN/blob.bin" | cut -d' ' -f1)
	local t0 t1; t0=$(date +%s%N); adb -s "$S" push "$RUN/blob.bin" $D/blob.bin >/dev/null 2>&1; t1=$(date +%s%N); local push=$(( mb*1000*1000000000/(t1-t0) )); metric adb_push_kbs "$push"
	local o; o=$(TMO=300 A "$NOWF cd $D; s=\$(now); dd if=blob.bin of=copy.bin bs=1M conv=fsync 2>/dev/null; e=\$(now); echo W \$((e-s)); s=\$(now); dd if=copy.bin iflag=direct bs=4M of=/dev/null 2>/dev/null; e=\$(now); echo R \$((e-s)); dd if=copy.bin iflag=direct bs=4M 2>/dev/null | sha256sum | cut -d' ' -f1; s=\$(now); dd if=/dev/urandom of=sync.bin bs=4k count=500 oflag=dsync 2>/dev/null; e=\$(now); echo F \$((e-s))"); echo "$o"
	local w r f hh; w=$(echo "$o" | awk '$1=="W"{print $2}'); r=$(echo "$o" | awk '$1=="R"{print $2}'); f=$(echo "$o" | awk '$1=="F"{print $2}'); hh=$(echo "$o" | grep -E '^[0-9a-f]{64}$')
	local wk=$((mb*1024*1000/(w+1))) rk=$((mb*1024*1000/(r+1))) fo=$((500*1000/(f+1))); metric ufs_write_fsync_kbs $wk; metric ufs_read_direct_kbs $rk; metric ufs_4k_dsync_iops $fo
	if [ "$hh" = "$h" ]; then ok "${mb} MB PC->phone->copy->direct read: sha256 matches"; else fail "data mismatch after write/read back: $hh vs $h"; fi
	if [ $wk -ge 40000 ]; then ok "write+fsync $((wk/1024)) MB/s"; else fail "write+fsync only $((wk/1024)) MB/s (UFS expected >= 40)"; fi
	if [ $rk -ge 80000 ]; then ok "direct read $((rk/1024)) MB/s"; else fail "direct read only $((rk/1024)) MB/s (UFS expected >= 80)"; fi
	if [ $fo -ge 150 ]; then ok "4k dsync writes $fo IOPS"; else fail "4k dsync writes only $fo IOPS"; fi
	t0=$(date +%s%N); adb -s "$S" pull $D/copy.bin "$RUN/blob.back" >/dev/null 2>&1; t1=$(date +%s%N); metric adb_pull_kbs $(( mb*1000*1000000000/(t1-t0) ))
	if [ "$(sha256sum "$RUN/blob.back" | cut -d' ' -f1)" = "$h" ]; then ok "adb round trip over USB: push $((push/1000)) MB/s, pull $(( mb*1000000000/(t1-t0) )) MB/s, checksum ok"; else fail "adb pull returned different data"; fi
	rm -f "$RUN/blob.bin" "$RUN/blob.back"; A "rm -f $D/blob.bin $D/copy.bin $D/sync.bin" >/dev/null
	local fs; fs=$(A "mount | grep ' /data '" | awk '{print $5}'); chk "/data is $fs, file-based encryption active ($(A getprop ro.crypto.state)/$(A getprop ro.crypto.type))" [ "$(A getprop ro.crypto.state)" = encrypted ]
	local sd; sd=$(A 'sm list-volumes public' | awk '$2=="mounted"{print $3}' | head -1)
	if [ -n "$sd" ]; then o=$(A "$NOWF f=/storage/$sd/.st-selftest.\$\$; head -c 8388608 /dev/urandom > /data/local/tmp/st/sd.bin; s=\$(now); cp /data/local/tmp/st/sd.bin \$f && sync; e=\$(now); a=\$(sha256sum < /data/local/tmp/st/sd.bin); b=\$(dd if=\$f iflag=direct bs=1M 2>/dev/null | sha256sum); rm -f \$f /data/local/tmp/st/sd.bin; [ \"\$a\" = \"\$b\" ] && echo SDOK \$((e-s))"); echo "$o"
		if echo "$o" | grep -q SDOK; then ok "microSD $sd: 8 MB write + read back verified ($(echo "$o" | awk '/SDOK/{print $2}') ms)"; else fail "microSD $sd: write/read back failed: $o"; fi
	else skip "microSD (no card mounted)"; fi
}
