#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mknod /dev/null c 1 3
r() { echo "SMK: $*"; }
S=/sys/class/sec
rd() { $B cat "$1" 2>&1 | $B tr "\n" "|"; }
$B insmod /sec_core.ko; r "sec_core rc=$?"
$B insmod /fakehall.ko; r "fakehall rc=$?"
echo 1 > /sys/module/fakehall/parameters/lid; echo 0 > /sys/module/fakehall/parameters/lid
$B insmod /a52sxq_sec_class.ko; r "secclass rc=$?"
# uevent check: tracefs kprobe on kobject_uevent_env (kobj->name, envp[0]); mdev here ignores "change"
$B mount -t tracefs none /sys/kernel/tracing 2>/dev/null
T=/sys/kernel/tracing; echo 'p:a52ue kobject_uevent_env kobj=+0(+0($arg1)):string act=$arg2 env0=+0(+0($arg3)):string' > $T/kprobe_events; r "kprobe rc=$?"
echo 1 > $T/events/kprobes/a52ue/enable
for d in hall_ic msm_dwc3 pcie-wifi sdcard sddata sdinfo sec_abc sec_abc_hub sec_misc sec_nad sec_sysup typec_manager; do
	r "dir $d $($B readlink -f $S/$d)"
	for a in $S/$d/*; do [ -f "$a" ] || continue; n=${a##*/}; [ "$n" = uevent ] && continue
		r "ls $d $($B stat -c '%A %u:%g %n' "$a" | $B sed "s|$S/$d/||")"
		case $n in edtbo_update) ;; *) r "val $d/$n=[$(rd $a)]";; esac
	done
done
# hall: state, count, uevent (netlink is not available in busybox here: count via the counter)
r "hall0=[$(rd $S/hall_ic/hall_detect)]"
echo 1 > /sys/module/fakehall/parameters/lid; r "hall1=[$(rd $S/hall_ic/hall_detect)]"
echo 0 > /sys/module/fakehall/parameters/lid; r "hall2=[$(rd $S/hall_ic/hall_detect)]"
echo 1 > /sys/module/fakehall/parameters/lid; $B sleep 1
$B grep -o 'a52ue.*kobj="hall_ic".*' $T/trace | $B sed 's/^/SMK: uevent /'; echo 0 > $T/events/kprobes/a52ue/enable
r "count=[$(rd $S/hall_ic/hall_count)] count-after-read=[$(rd $S/hall_ic/hall_count)]"
# writes
echo 0 > $S/pcie-wifi/pcie_l1ss_ctrl; r "pcie write rc=$?"
echo bogus > $S/pcie-wifi/pcie_l1ss_ctrl; r "pcie bogus write rc=$?"
echo 1 > $S/sec_abc/enabled; r "abc en1 rc=$? -> $(rd $S/sec_abc/enabled)"
echo 0 > $S/sec_abc/enabled; r "abc en0 rc=$? -> $(rd $S/sec_abc/enabled)"
echo ALL_REPORT=1,PRE_EVENT=0 > $S/sec_abc/enabled; r "abc labo rc=$? -> $(rd $S/sec_abc/enabled)"
echo BOGUS=1 > $S/sec_abc/enabled; r "abc bogus rc=$? -> $(rd $S/sec_abc/enabled)"
echo ALL_REPORT=0 > $S/sec_abc/enabled; r "abc labo0 rc=$? -> $(rd $S/sec_abc/enabled)"
echo 1 > $S/sec_abc_hub/enable; r "hub en rc=$? -> $(rd $S/sec_abc_hub/enable)"
echo fsck,12 > $S/sec_abc_hub/bootc_offset; r "bootc_offset rc=$? -> $(rd $S/sec_abc_hub/bootc_offset)"
echo other,5 > $S/sec_abc_hub/bootc_offset; r "bootc_offset other rc=$? -> $(rd $S/sec_abc_hub/bootc_offset)"
echo 23456 > $S/sec_abc_hub/bootc_time; r "bootc_time rc=$? -> $(rd $S/sec_abc_hub/bootc_time)"
echo x > $S/sec_abc_hub/bootc_time; r "bootc_time bad rc=$? -> $(rd $S/sec_abc_hub/bootc_time)"
echo 1 > $S/sec_sysup/edtbo_update; r "edtbo 1 rc=$?"
echo 2 > $S/sec_sysup/edtbo_update; r "edtbo 2 rc=$?"
echo 1 > $S/sdcard/status 2>/dev/null; r "ro write rc=$?"
# init-like chown/chmod (OneUI init.rc on boot)
$B chown 1000:1001 $S/sec_abc/enabled && $B chmod 0664 $S/sec_abc/enabled; r "chown rc=$? $($B stat -c '%A %u:%g' $S/sec_abc/enabled)"
# flip cover code per userspace (a52sxq.ko switch): aosp = SW_LID only; samsung = a second "hall" input
# with the Samsung flip code 0x10 (capabilities/sw 10000) and SW_LID kept away from evdev
$B mkdir -p /dev/input /tmp; nd() { for i in /sys/class/input/input*; do [ "$($B cat $i/name)" = hall ] || continue
	[ "$($B cat $i/capabilities/sw)" = "$1" ] || continue; e=$($B ls $i | $B grep '^event'); [ -n "$e" ] || continue
	[ -e /dev/input/$e ] || $B mknod /dev/input/$e c $($B tr ':' ' ' < $i/$e/dev); echo /dev/input/$e; return; done; }
hx() { $B hexdump -v -e '24/1 "%02x" "\n"' "$1" | $B cut -c33- | $B tr "\n" ","; }
echo 0 > /sys/module/fakehall/parameters/lid; $B sleep 1; rd $S/hall_ic/hall_count > /dev/null
r "flip noswitch lid=$(nd 1) flip=$(nd 10000)"
$B insmod /a52sxq.ko; r "a52sxq rc=$?"; $B sleep 3
r "flip aosp us=$($B cat /sys/module/a52sxq/parameters/userspace) lid=$(nd 1) flip=$(nd 10000)"
echo samsung > /sys/module/a52sxq/parameters/userspace; $B sleep 1
L=$(nd 1); F=$(nd 10000); r "flip samsung us=$($B cat /sys/module/a52sxq/parameters/userspace) lid=$L flip=$F"
$B cat $L > /tmp/lid.s & P1=$!; $B cat $F > /tmp/flip.s & P2=$!; $B sleep 1
echo 1 > /sys/module/fakehall/parameters/lid; $B sleep 1; r "flip samsung close detect=[$(rd $S/hall_ic/hall_detect)]"
echo 0 > /sys/module/fakehall/parameters/lid; $B sleep 1; kill $P1 $P2 2>/dev/null
r "flip samsung events lid=[$(hx /tmp/lid.s)] flip=[$(hx /tmp/flip.s)] count=[$(rd $S/hall_ic/hall_count)]"
echo aosp > /sys/module/a52sxq/parameters/userspace; $B sleep 1
$B cat $L > /tmp/lid.a & P1=$!; $B cat $F > /tmp/flip.a & P2=$!; $B sleep 1
echo 1 > /sys/module/fakehall/parameters/lid; $B sleep 1; echo 0 > /sys/module/fakehall/parameters/lid; $B sleep 1; kill $P1 $P2 2>/dev/null
r "flip back-to-aosp events lid=[$(hx /tmp/lid.a)] flip=[$(hx /tmp/flip.a)] count=[$(rd $S/hall_ic/hall_count)]"
# a second load must leave the devices alone and still return 0 (duplicate names skipped)
$B rmmod a52sxq_sec_class; r "rmmod rc=$? left=$(ls $S | $B grep -cE '^(hall_ic|msm_dwc3|pcie-wifi|sdcard|sddata|sdinfo|sec_abc|sec_abc_hub|sec_misc|sec_nad|sec_sysup|typec_manager)$')"
$B insmod /a52sxq_sec_class.ko; r "reload rc=$? n=$(ls $S | $B wc -l)"
$B rmmod fakehall; r "rmmod fakehall rc=$? hall=[$(rd $S/hall_ic/hall_detect)] number=[$(rd $S/hall_ic/hall_number)]"
$B rmmod a52sxq_sec_class; r "rmmod2 rc=$? n=$(ls $S | $B wc -l)"
$B dmesg | $B grep -iE "a52sxq|sec_class|WARN|BUG|Oops|Call trace|duplicate" | $B sed 's/^/SMK: dmesg /'
echo "SMK: END"
$B poweroff -f
