#!/bin/busybox sh
# QEMU virt smoke test of a52sxq_msm_subsys.ko (no remoteprocs in QEMU; the test dtb adds /soc and a
# qcom,yupik-modem-pas node without a driver so the lazy rproc lookup runs and finds nothing).
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys
$B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
D=/sys/bus/msm_subsys/devices
dump() {
	for d in $D/subsys*; do
		[ -e "$d" ] || continue
		n=${d##*/}
		r "$1 $n path=$($B readlink -f $d) name=$($B cat $d/name) state=$($B cat $d/state) crash=$($B cat $d/crash_count) level=$($B cat $d/restart_level) fw=$($B cat $d/firmware_name) dbg=$($B cat $d/system_debug)"
	done
}
$B insmod /a52sxq_msm_subsys.ko yield_to=msub_fakeowner; r "load rc=$?"
r "devices: $($B ls $D | $B tr '\n' ' ')"
dump A
$B ls -l $D/subsys3/ | $B sed 's/^/SMK: ls3 /'
S=$D/subsys3
echo RELATED > $S/restart_level; r "level RELATED rc=$? -> $($B cat $S/restart_level)"
echo sys > $S/restart_level; r "level sys rc=$? -> $($B cat $S/restart_level)"
echo bogus > $S/restart_level; r "level bogus rc=$? -> $($B cat $S/restart_level)"
echo set > $S/system_debug; r "debug set rc=$? -> $($B cat $S/system_debug)"
echo nope > $S/system_debug; r "debug nope rc=$? -> $($B cat $S/system_debug)"
echo reset > $S/system_debug; r "debug reset rc=$? -> $($B cat $S/system_debug)"
echo modem2 > $S/firmware_name; r "fw modem2 rc=$? -> $($B cat $S/firmware_name)"
echo modem > $S/firmware_name
for i in 1 2 3 4 5 6 7 8 9 10; do $B cat $D/subsys2/state $D/subsys3/state $D/subsys4/state $D/subsys5/state >/dev/null; done
r "state x40 reads done: $($B cat $S/state)"
# hand-over to the stand-in owner (yield_to=msub_fakeowner) and back
$B insmod /msub_fakeowner.ko; r "owner load rc=$?"
r "devices with owner: $($B ls $D | $B tr '\n' ' ') parents=$($B ls /sys/devices/platform/soc | $B grep -c qcom,)"
$B rmmod msub_fakeowner; r "owner rmmod rc=$?"
$B sleep 1
r "devices after owner left: $($B ls $D | $B tr '\n' ' ')"
dump B
$B rmmod a52sxq_msm_subsys; r "rmmod rc=$?"
r "after rmmod: bus=$([ -e /sys/bus/msm_subsys ] && echo yes || echo no) parents=$($B ls /sys/devices/platform/soc | $B grep -c qcom,)"
# owner loaded first: fallback must stay idle and still load with rc 0
$B insmod /msub_fakeowner.ko; r "owner first rc=$?"
$B insmod /a52sxq_msm_subsys.ko yield_to=msub_fakeowner; r "load behind owner rc=$?"
r "devices behind owner: $($B ls $D | $B tr '\n' ' ')"
$B rmmod a52sxq_msm_subsys; r "rmmod idle rc=$?"
$B rmmod msub_fakeowner; r "owner rmmod2 rc=$?"
# no /soc at all: devices without parent
$B insmod /a52sxq_msm_subsys.ko yield_to=msub_fakeowner soc_path=/nonexistent; r "load nosoc rc=$?"
r "nosoc subsys3 path=$($B readlink -f $D/subsys3) name=$($B cat $D/subsys3/name)"
$B rmmod a52sxq_msm_subsys; r "rmmod nosoc rc=$?"
$B dmesg | $B grep -iE "msm_subsys|msub_fakeowner|WARN|BUG|Oops|Call trace|duplicate" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
