#!/bin/busybox sh
# Kexec test stage "dcvs" post script (drivers612/busdcvs/README.md). helper2.sh runs it in the
# background right after the stage's modules (bwmon, memlat) are loaded. It waits for Android's
# sys.boot_completed + 30 s (fw_devlink's deferred-probe timeout has passed by then), then
# applies busdcvs.conf in three steps and logs the bus state after each, then samples idle,
# under a memory load (4x dd /dev/zero -> /dev/null for 12 s) and idle again.
# Every line goes to the kernel log as "a52sxq-busdcvs: ..." (ramoops keeps it) and to
# /tmp/busdcvs.log in the helper's tmpfs.
# Cmdline: a52.busdcvs=0 -> only observe (no writes); a52.busdcvs=noicc -> tunables + boost
# reset, but no interconnect state_synced (to see the two effects separately).
C=/a52/mods/dcvs/busdcvs.conf; O=/tmp/busdcvs.log; B=/sys/devices/system/cpu/bus_dcvs
MODE=all
for w in $(cat /proc/cmdline); do case "$w" in a52.busdcvs=*) MODE=${w#a52.busdcvs=};; esac; done
log() { echo "a52sxq-busdcvs: $*" > /dev/kmsg; echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $O; }
rd() { cat "$1" 2>/dev/null || echo -; }
snap() {
	s="$1: hw"
	for h in DDR LLCC L3 DDRQOS; do s="$s $h=$(rd $B/$h/cur_freq)"; done
	s="$s | bwmon"
	for v in $B/*/*.qcom,bwmon-*; do [ -d "$v" ] && s="$s ${v##*bwmon-}=$(rd $v/cur_freq)"; done
	s="$s | memlat"
	n=0
	for v in $B/*/soc:qcom,memlat:*; do
		[ -d "$v" ] || continue; n=$((n + 1)); m=${v##*/}; m=${m#soc:qcom,memlat:}
		s="$s $m=$(rd $v/cur_freq)"
	done
	[ $n = 0 ] && s="$s none"
	# what the interconnect really asks for (incl. the keepalive INT_MAX floor before sync_state)
	S=/sys/kernel/debug/interconnect/interconnect_summary
	if [ -r $S ]; then
		s="$s | icc(avg/peak kBps)"
		# (no awk in the helper's busybox links)
		for nd in ebi qns_llcc; do set -- $(grep -E "^ *$nd " $S | head -1); s="$s $nd=${2:-?}/${3:-?}"; done
	fi
	bl=$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1)
	s="$s | cpu0 $(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) cpu7 $(rd /sys/devices/system/cpu/cpufreq/policy7/scaling_cur_freq) bl=${bl:--}"
	log "$s"
}
apply() {	# <label> <egrep pattern on the path>
	ok=0; bad=0
	grep -vE '^[[:space:]]*(#|$)' $C | grep -E "$2" > /tmp/busdcvs.step
	while read -r p v; do
		if [ ! -e "/sys/$p" ]; then log "$1: MISSING /sys/$p"; bad=$((bad + 1)); continue; fi
		if echo "$v" > "/sys/$p" 2>/tmp/busdcvs.err; then ok=$((ok + 1))
		else
			e=$(cat /tmp/busdcvs.err)
			case "$p" in */state_synced) log "$1: /sys/$p already synced (${e##*: })";;
			*) log "$1: write FAILED /sys/$p = $v: $e"; bad=$((bad + 1));; esac
		fi
	done < /tmp/busdcvs.step
	log "$1: $ok written, $bad failed"
}
log "post script started (mode=$MODE)"
i=0
while [ $i -lt 400 ]; do
	[ "$(an 'getprop sys.boot_completed' 2>/dev/null)" = 1 ] && break
	sleep 2; i=$((i + 2))
done
log "boot_completed after ${i}s of waiting; settling 30 s"
sleep 30
snap boot
log "memlat: $(ls -d $B/memlat_settings 2>/dev/null || echo 'no memlat_settings (memlat not probed)'); pmu_lib: $(ls -d /sys/devices/system/cpu/pmu_lib 2>/dev/null || echo none)"
D=/sys/kernel/debug/devices_deferred
[ -r $D ] && log "deferred: $(cut -c1-60 $D | tr '\n' ';' | cut -c1-400)"
for d in /sys/bus/platform/drivers/qnoc-yupik/*/; do
	[ -e "$d/state_synced" ] && log "icc $(basename $d) state_synced=$(cat $d/state_synced)"
done
if [ "$MODE" != 0 ]; then
	apply tunables 'bwmon|memlat'; sleep 5; snap tuned
	apply boost '/boost_freq$'; sleep 5; snap noboost
	if [ "$MODE" != noicc ]; then apply icc '/state_synced$'; sleep 5; snap synced; fi
fi
for k in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 10; snap idle$k; done
log "load: 4x dd /dev/zero -> /dev/null, 12 s"
for k in 1 2 3 4; do timeout 12 dd if=/dev/zero of=/dev/null bs=4M count=1000000 2>/dev/null & done
for k in 1 2 3 4 5; do sleep 2; snap load$k; done
wait
sleep 5; snap after-load
for k in 1 2 3 4 5 6; do sleep 10; snap idle-b$k; done
# final tunables for the record
for f in $B/*/*.qcom,bwmon-*/io_percent $B/*/*.qcom,bwmon-*/mbps_zones $B/*/boost_freq $B/*/soc:qcom,memlat:*/ipm_ceil; do
	[ -e "$f" ] && echo "${f#$B/} $(cat $f)"
done > /tmp/busdcvs-final.txt 2>/dev/null
log "done ($(wc -l < /tmp/busdcvs-final.txt) settings in /tmp/busdcvs-final.txt)"
