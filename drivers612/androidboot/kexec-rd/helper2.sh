#!/bin/busybox sh
# Stage B of the test helper: PID != 1, private mount namespace, chroot on tmpfs.
# Order: watchdog pet -> testguard -> bring-up modules (proven order of bsp612) -> zram ->
# extra module stages -> USB gadget + telnet -> watchdog off -> dead-man -> "go" for Android's
# init -> bind the test fstab over /vendor/etc/fstab.qcom -> USB hand-over loop.
# Cmdline: a52.net=<n>, a52.deadman=<s> (default 600; ALWAYS armed unless /tmp/a52keep exists;
# kx-cycle's /tmp/keep is ignored on purpose), a52.skip=<m1,m2>, a52.stage=1 (no Android init),
# a52.mods=<s1,s2> (extra module stages: /a52/mods/<s>.list, lines "file.ko [params]").
B=/bin/busybox
$B mount -t proc proc /proc
$B mount -t sysfs sysfs /sys
$B mount -t tmpfs -o mode=755 tmpfs /dev
$B mknod -m 666 /dev/null c 1 3; $B mknod -m 666 /dev/zero c 1 5; $B mknod -m 600 /dev/kmsg c 1 11
$B mknod -m 666 /dev/urandom c 1 9; $B mknod -m 666 /dev/random c 1 8; $B mknod -m 666 /dev/tty c 5 0
$B mknod -m 600 /dev/console c 5 1; $B mknod -m 666 /dev/ptmx c 5 2
exec </dev/null >/dev/null 2>&1
$B mkdir -p /dev/pts
$B mount -t devpts devpts /dev/pts
$B mount -t tmpfs tmpfs /tmp
$B mount -t configfs configfs /config
$B mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
for a in sh ls cat echo dmesg mount umount ifconfig ip sleep ps kill grep sed head tail cut tr wc dd hexdump find mkdir rm ln cp mv sync reboot poweroff vi top free df lsmod insmod rmmod modprobe uname date printf seq test true false stat touch chmod devmem setsid watchdog killall pkill mknod basename readlink sort uniq usleep timeout chroot nsenter base64 tar gzip md5sum sha256sum; do
	[ -e /bin/$a ] || $B ln -s busybox /bin/$a
done
export PATH=/bin:/sbin:/usr/bin
log() { echo "a52sxq-init: $*" > /dev/kmsg; }
mkdevs() {
	for u in /sys/dev/char/*/uevent /sys/dev/block/*/uevent; do
		[ -r "$u" ] || continue
		MAJOR=; MINOR=; DEVNAME=
		while IFS='=' read -r k v; do
			case "$k" in MAJOR) MAJOR=$v;; MINOR) MINOR=$v;; DEVNAME) DEVNAME=$v;; esac
		done < "$u"
		[ -n "$DEVNAME" ] && [ -n "$MAJOR" ] || continue
		[ -e "/dev/$DEVNAME" ] && continue
		case "$u" in /sys/dev/block/*) t=b;; *) t=c;; esac
		case "$DEVNAME" in */*) mkdir -p "/dev/${DEVNAME%/*}";; esac
		mknod -m 660 "/dev/$DEVNAME" $t "$MAJOR" "$MINOR" 2>/dev/null
	done
}
mkdevs
# shell helper for the telnet session: run a command inside Android's root (logcat, getprop...)
# (init's own namespace is the bootstrap one without the runtime apex: enter logd's instead)
printf '#!/bin/busybox sh\nexec /bin/busybox nsenter -t $(/bin/busybox pidof logd) -m -r -w -- /system/bin/sh -c "$*"\n' > /bin/an; chmod 755 /bin/an

DEADMAN=600; NET=42; STAGE=2; SKIP="sec_core"; MODS=
for w in $(cat /proc/cmdline); do case "$w" in
	a52.deadman=*) DEADMAN=${w#a52.deadman=};;
	a52.net=*) NET=${w#a52.net=};;
	a52.stage=*) STAGE=${w#a52.stage=};;
	a52.mods=*) MODS=$(echo "${w#a52.mods=}" | tr ',' ' ');;
	a52.skip=*) SKIP="$SKIP $(echo "${w#a52.skip=}" | tr ',' ' ')";;
esac; done
case "$DEADMAN" in ''|0|*[!0-9]*) DEADMAN=600;; esac   # the dead-man timer cannot be switched off
log "start androidboot helper (stage=$STAGE deadman=${DEADMAN}s mods=$MODS)"
# dead-man FIRST: whatever happens below, the phone restarts by itself
( sleep "$DEADMAN"; [ -e /tmp/a52keep ] || { log "dead-man timer expired"; /leave deadman; } ) &

# Hang -> panic -> reboot (CONFIG_PANIC_TIMEOUT=-1), so a wedged test kernel comes back by itself
# through the harness instead of needing a manual key press (2026-11-14: a live insmod of
# qcom-cpufreq-hw deadlocked the kernel; nothing spun, so no watchdog could see it). Re-asserted
# every 30 s because Android's init may rewrite them. a52.nohangpanic=1 turns this off.
hangpanic() {
	echo 60 > /proc/sys/kernel/hung_task_timeout_secs; echo 1 > /proc/sys/kernel/hung_task_panic
	echo 1 > /proc/sys/kernel/softlockup_panic; echo 1 > /proc/sys/kernel/panic_on_oops
	echo -1 > /proc/sys/kernel/panic
}
if ! grep -q "a52.nohangpanic=1" /proc/cmdline; then
	hangpanic 2>/dev/null; log "hang/lockup/oops -> panic -> reboot armed"
	( while :; do sleep 30; hangpanic 2>/dev/null; done ) &
fi

M=/lib/modules
WRAW=/sys/module/hhwdt/parameters/raw
insmod $M/hhwdt.ko 2>/dev/null
[ -e $WRAW ] && log "petting the inherited watchdog" || log "hhwdt missing, inherited watchdog NOT pet"
pet() { [ -e $WRAW ] && echo "7 0 0" > $WRAW; return 0; }
pet
# ---- testguard first (needs a52.androidtest=1; holds userdata, misc/metadata/efs.. read-only)
log "insmod testguard"
insmod $M/testguard.ko ro=misc,metadata,efs,sec_efs,persist,cache,param,steady,persistent,keyrefuge,modemst1,modemst2,fsg,fsc 2>/tmp/insmod.err && log "testguard loaded" || log "insmod FAILED testguard: $(cat /tmp/insmod.err)"
# ---- bring-up modules
skipped() { for s in $SKIP; do [ "$s" = "$1" ] && return 0; done; return 1; }
NOK=0; NFAIL=0
loadlist() {
	while read -r m args; do
		case "$m" in ''|'#'*) continue;; esac
		n=${m%.ko}; n=${n##*/}
		if skipped "$n"; then log "skip $n"; continue; fi
		pet
		# a last argument "&" loads the module in the background (sec-battery: its probe waits
		# for the chargers that come after it in the list)
		case "$args" in '&'|*' &') args=${args%&}; log "insmod $n $args (background)"
			( insmod "$1/$m" $args 2>/tmp/insmod-$n.err || { log "insmod FAILED $n: $(cat /tmp/insmod-$n.err)"; echo "$n: $(cat /tmp/insmod-$n.err)" >> /tmp/insmod-failed.txt; } ) &
			sleep 1; continue;; esac
		log "insmod $n $args"
		if insmod "$1/$m" $args 2>/tmp/insmod.err; then NOK=$((NOK + 1))
		else NFAIL=$((NFAIL + 1)); log "insmod FAILED $n: $(cat /tmp/insmod.err)"; echo "$n: $(cat /tmp/insmod.err)" >> /tmp/insmod-failed.txt; fi
	done < "$2"
}
loadlist $M $M/load.list
log "modules done: $NOK loaded, $NFAIL failed"
pet
insmod $M/zsmalloc.ko 2>/dev/null; insmod $M/zram.ko num_devices=3 2>/tmp/insmod.err || log "insmod FAILED zram: $(cat /tmp/insmod.err)"
ZR=0
if [ -e /sys/block/zram2/disksize ]; then
	echo 134217728 > /sys/block/zram2/disksize && echo 3221225472 > /sys/block/zram1/disksize && ZR=1
fi
log "zram1 (/data) 3 GiB, zram2 (/metadata) 128 MiB: ok=$ZR"
# A stage named <s>@adsp is loaded in the background once the ADSP remoteproc is running
# (Android's vendor init starts it). The audio codecs only enumerate on SoundWire with the
# LPASS up; loaded earlier they defer forever (2026-11-13).
for s in $MODS; do
	case "$s" in *@adsp)
		n=${s%@adsp}
		[ -f /a52/mods/$n.list ] || { log "module stage $n: no list"; continue; }
		( i=0; while [ $i -lt 300 ]; do
			for r in /sys/class/remoteproc/remoteproc*; do
				case "$(cat $r/name 2>/dev/null)" in *adsp*)
					st=$(cat $r/state 2>/dev/null)
					[ "$st" = running ] && break 2
					# start it ourselves; this fails until Android has mounted the firmware
					# partition at firmware_class.path, so retry every 3 s
					[ "$st" = offline ] && [ $((i % 3)) = 0 ] && echo start > $r/state 2>/dev/null;;
				esac
			done; sleep 1; i=$((i + 1)); done
		  log "module stage $n: ADSP running after ${i}s"
		  # the CDSP too (its firmware is on the same partition); a52.nocdsp=1 leaves it off.
		  # Works with FastRPC since the cb13-16 SID fix (2026-11-13).
		  if ! grep -q "a52.nocdsp=1" /proc/cmdline; then
			for r in /sys/class/remoteproc/remoteproc*; do
				case "$(cat $r/name 2>/dev/null)" in *cdsp*)
					[ "$(cat $r/state)" = offline ] && echo start > $r/state 2>/dev/null
					log "CDSP: $(cat $r/state)";;
				esac
			done
		  fi
		  sleep 2
		  [ -f /a52/mods/$n.pre ] && { log "module stage $n: pre script"; sh /a52/mods/$n.pre >> /tmp/$n.pre.log 2>&1; log "module stage $n: pre script rc=$?"; }
		  loadlist /a52/mods/$n /a52/mods/$n.list; log "module stage $n done" ) &
		continue;;
	esac
	[ -f /a52/mods/$s.list ] || { log "module stage $s: no list"; continue; }
	log "module stage $s"; loadlist /a52/mods/$s /a52/mods/$s.list; pet
	# optional <stage>.post: run in the background after the stage (e.g. dcvs: bus tunables
	# once Android has booted, drivers612/busdcvs/post.sh)
	[ -f /a52/mods/$s.post ] && { log "module stage $s: post script (background)"
		( sh /a52/mods/$s.post >> /tmp/$s.post.log 2>&1; log "module stage $s: post script rc=$?" ) & }
done
mkdevs

# ---- USB: our own gadget "a52" (NCM + ACM, telnet) until Android's gadget g1 is ready
G=/config/usb_gadget/a52
mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/ncm.usb0 $G/functions/acm.usb0
echo 0x1209 > $G/idVendor; echo 0xa528 > $G/idProduct
echo a52sxq-android612 > $G/strings/0x409/manufacturer
echo "a52sxq android test $(uname -r)" > $G/strings/0x409/product
echo a52sxqtest > $G/strings/0x409/serialnumber
echo "ncm+acm" > $G/configs/c.1/strings/0x409/configuration
ln -s $G/functions/ncm.usb0 $G/configs/c.1/
ln -s $G/functions/acm.usb0 $G/configs/c.1/
usbmode() {
	for f in /sys/devices/platform/soc/a600000.ssusb/mode /sys/devices/platform/soc/*.ssusb/mode /sys/bus/platform/devices/*.ssusb/mode; do
		[ -e "$f" ] || continue
		echo peripheral > "$f" 2>/tmp/usbmode.err && return 0
	done
	return 1
}
i=0; MODESET=0; UDC=
while [ $i -lt 60 ]; do
	if [ $MODESET = 0 ] && usbmode; then MODESET=1; log "usb mode=peripheral after ${i}s"; fi
	UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
	[ -n "$UDC" ] && break
	sleep 1; i=$((i + 1)); pet
done
if [ -n "$UDC" ]; then
	[ $MODESET = 0 ] && usbmode
	echo "$UDC" > $G/UDC && log "gadget a52 on $UDC after ${i}s"
	mkdevs
	ifconfig usb0 172.16.$NET.1 netmask 255.255.255.0 up
	/usr/bin/unudhcpd -i usb0 -s 172.16.$NET.1 -c 172.16.$NET.2 >/dev/null 2>&1 &
	/bin/busybox-extras telnetd -b 172.16.$NET.1:23 -l /bin/sh
else
	log "no UDC appeared"
fi
if [ -e $WRAW ]; then echo "5 2 0" > $WRAW; log "inherited watchdog disabled"; fi

# ---- gate for Android's init
i=0; ARMED=0
while [ $i -lt 40 ]; do
	dmesg | grep -q "testguard: armed" && { ARMED=1; break; }
	sleep 1; i=$((i + 1))
done
log "ready (modules ok=$NOK failed=$NFAIL, testguard armed=$ARMED, zram=$ZR, udc=${UDC:-none})"
if [ "$STAGE" = 1 ]; then
	touch /old/a52/stay; log "stage 1: no Android init; waiting for the dead-man timer"
	while :; do sleep 3600; done
fi
if [ $ARMED != 1 ] || [ $ZR != 1 ]; then
	touch /old/a52/stay; log "NOT starting Android: testguard armed=$ARMED zram=$ZR"
	while :; do sleep 3600; done
fi
touch /old/a52/go
# ---- after the switch to the real root: test fstab over the ROM's (RAM only)
i=0; BOUND=0
while [ $i -lt 2400 ]; do
	if [ -e /proc/1/root/system/bin/init ] && [ -d /proc/1/root/vendor/etc ] && [ ! -e /proc/1/root/system/system ]; then
		ARGS="/a52/bind/fstab.qcom /vendor/etc/fstab.qcom"
		[ -f /a52/bind/binds.txt ] && while read -r bs bt; do [ -n "$bt" ] && ARGS="$ARGS /a52/bind/$bs $bt"; done < /a52/bind/binds.txt
		if /a52/a52bind $ARGS > /tmp/a52bind.log 2>&1; then BOUND=1; else BOUND=2; fi
		break
	fi
	usleep 50000; i=$((i + 1))
done
case $BOUND in
1) log "test fstab bound after switch root (poll $i)"; dmesg > /tmp/dmesg-switchroot.txt; ( sleep 12; dmesg > /tmp/dmesg-12s.txt ) & ;;
*) log "test fstab NOT bound (state $BOUND, poll $i): leaving"; /leave nobind;;
esac

# fatal logcat lines into the kernel log (ramoops keeps them when Android restarts the phone)
( while ! pidof logd >/dev/null 2>&1; do usleep 300000; done; sleep 1
  an "logcat -b main,system,crash -v brief *:F" 2>/dev/null | while read -r l; do echo "LC: $l" > /dev/kmsg; done ) &
# ---- USB hand-over: when Android's gadget g1 has adb in b.1 but no UDC (ours holds it),
# add an NCM function to g1 and give it the UDC: adb + telnet over one composite gadget.
G1=/config/usb_gadget/g1
OWNER=a52; NEXT=0; n=0
while :; do
	sleep 3; n=$((n + 1))
	[ $((n % 5)) = 0 ] && mkdevs
	# netd's policy routing ends in "32000: from all unreachable": our telnet replies need main
	ip rule 2>/dev/null | grep -q "^100:" || ip rule add pref 100 from all lookup main 2>/dev/null
	[ -n "$UDC" ] || continue
	[ -e /tmp/nohandover ] && continue
	if [ $OWNER = a52 ] && [ -e $G1/configs/b.1/f1 ] && [ -z "$(cat $G1/UDC 2>/dev/null)" ] && [ $n -ge $NEXT ]; then
		log "usb: Android gadget g1 is waiting for the UDC, handing over"
		echo "" > $G/UDC
		mkdir -p $G1/functions/ncm.a52
		[ -e $G1/configs/b.1/zncm ] || ln -s $G1/functions/ncm.a52 $G1/configs/b.1/zncm
		if echo "$UDC" > $G1/UDC 2>/tmp/handover.err; then
			IF=$(cat $G1/functions/ncm.a52/ifname)
			ifconfig usb0 0.0.0.0 down
			ifconfig $IF 172.16.$NET.1 netmask 255.255.255.0 up
			/usr/bin/unudhcpd -i $IF -s 172.16.$NET.1 -c 172.16.$NET.2 >/dev/null 2>&1 &
			OWNER=g1; log "usb: g1 bound (adb + ncm on $IF)"
		else
			log "usb: g1 bind failed ($(cat /tmp/handover.err)), back to gadget a52"
			rm -f $G1/configs/b.1/zncm
			echo "$UDC" > $G/UDC
			NEXT=$((n + 7))
		fi
	elif [ $OWNER = g1 ] && [ -z "$(cat $G1/UDC 2>/dev/null)" ]; then
		# Android took its gadget down (config change): take the UDC back until it is ready again
		IF=$(cat $G1/functions/ncm.a52/ifname 2>/dev/null)
		[ -n "$IF" ] && ifconfig $IF 0.0.0.0 down
		rm -f $G1/configs/b.1/zncm
		echo "$UDC" > $G/UDC && { ifconfig usb0 172.16.$NET.1 netmask 255.255.255.0 up; OWNER=a52; NEXT=$((n + 3)); log "usb: gadget a52 back on the UDC"; }
	fi
done
