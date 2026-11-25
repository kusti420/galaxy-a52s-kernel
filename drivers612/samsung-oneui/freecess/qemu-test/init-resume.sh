#!/bin/busybox sh
# SPEC/07: a cgroup v1 frozen process across a system suspend/resume cycle (pm_test=freezer: freeze, 5 s, thaw)
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t tmpfs tmpfs /dev
$B mknod /dev/null c 1 3; $B mknod /dev/console c 5 1
r() { echo "RSM: $*"; }
$B mkdir /dev/freezer; $B mount -t cgroup -o freezer none /dev/freezer; r "v1 freezer mount rc=$?"
$B mkdir /dev/freezer/frozen; echo FROZEN > /dev/freezer/frozen/freezer.state
$B insmod /freecess.ko; r "insmod rc=$?"
P=/sys/module/freecess/parameters
st() { for t in /proc/$1/task/*; do $B printf "%s=%s " "$($B cat $t/comm)/${t##*/}" "$($B awk '{print $3}' $t/stat)"; done; }
cycle() { echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state; r "$1: suspend cycle rc=$?"; }
run() {	# $1 = name, $2 = refreeze
	echo $2 > $P/refreeze
	/halfthaw /$1.out & H=$!
	$B sleep 1; r "$1: running   [$(st $H)] count=$($B cat /$1.out)"
	echo $H > /dev/freezer/frozen/cgroup.procs; $B sleep 1
	a=$($B cat /$1.out); $B sleep 1; b=$($B cat /$1.out)
	r "$1: frozen    [$(st $H)] count=$a -> $b"
	[ "$a" = "$b" ] && r "$1: before suspend: frozen ok"
	cycle $1
	$B sleep 1; c=$($B cat /$1.out); $B sleep 2; d=$($B cat /$1.out)
	r "$1: resumed   [$(st $H)] count=$c -> $d escaped_total=$($B cat $P/stat_refreeze_escaped) queued_total=$($B cat $P/stat_refreeze_queued)"
	if [ "$c" = "$d" ]; then r "$1: after resume: STILL FROZEN"; else
		r "$1: after resume: HALF THAWED sleeper loops ${c% *} -> ${d% *}, spinner ${c#* } -> ${d#* }"; fi
	cycle $1-2
	$B sleep 1; e=$($B cat /$1.out); $B sleep 1; f=$($B cat /$1.out)
	if [ "$e" = "$f" ]; then r "$1: after 2nd resume: STILL FROZEN [$(st $H)]"; else r "$1: after 2nd resume: RUNS [$(st $H)]"; fi
	echo $H > /dev/freezer/cgroup.procs; $B sleep 1
	g=$($B cat /$1.out); $B sleep 1; h=$($B cat /$1.out)
	if [ "${g% *}" != "${h% *}" ] && [ "${g#* }" != "${h#* }" ]; then r "$1: after thaw: both threads run [$(st $H)]"; else r "$1: after thaw: NOT RUNNING $g -> $h"; fi
	$B kill -9 $H; $B sleep 1; $B kill -0 $H 2>/dev/null && r "$1: kill FAILED" || r "$1: killed"
}
run nofix 0
run fix 1
for f in refreeze stat_refreeze_runs stat_refreeze_escaped stat_refreeze_queued; do r "param $f=$($B cat $P/$f)"; done
$B rmmod freecess; r "rmmod rc=$?"
$B dmesg | $B grep -iE "freecess|WARN|BUG|Oops|Call trace|Freezing|Restarting" | $B sed 's/^/RSM: dmesg /'
echo "RSM: END"
$B poweroff -f
