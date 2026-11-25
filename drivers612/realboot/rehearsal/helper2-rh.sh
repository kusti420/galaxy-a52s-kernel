#!/bin/busybox sh
# Stage B of the REAL-BOOT REHEARSAL helper (packed as /a52/helper2.sh by
# drivers612/realboot/rehearse.sh). A copy of drivers612/androidboot/kexec-rd/helper2.sh (the
# proven test helper, not changed) that leaves the boot to the real-boot pieces wherever the
# harness allows it:
#  - modules: only the first lines of the REAL vendor_boot /lib/modules/modules.load, up to and
#    including zram.ko (a52.rhprefix=<name>), are insmod'ed here, in that order, with the
#    module's modules.options line and <module>.<param>= words of /proc/cmdline (what
#    libmodprobe passes), its modules.dep dependencies first. Needed because testguard must hold
#    userdata (UFS is in that prefix) and the zram disks must exist before Android's init runs.
#    The ROM's first-stage init then loads the WHOLE list itself from /lib/modules (the
#    vendor_boot copy): the prefix gives EEXIST, which libmodprobe counts as loaded, the other
#    ~98 modules (power stack + Samsung USB extcon, display, ..., a52sxq_dsp_boot, sec-battery
#    with async_probe=1 from modules.options) are loaded by the real loader, in the real order.
#    No module stages (a52.mods is ignored), no @adsp job, no wlan.pre/force_sysfs_fallback,
#    no background sec-battery insmod, no sec_core skip.
#  - USB (rh*c, 2026-11-14): no gadget before Android. The UDC only exists once the real Samsung
#    extcon reports VBUS (usb_notify's 10 s booting delay after usb_notifier probes), i.e. after
#    init's first `write g1/UDC` failed; on a real boot adbd's 1 s FUNCTIONFS_BIND retry makes
#    init write it again and Android binds g1 by itself. The helper REHEARSES that: before the UDC
#    exists it only pre-links its NCM function (ncm.a52 -> g1/configs/b.1/zncm, while g1 is
#    unbound), then gives Android a52.rhwait=<s> (default 10) to bind g1 by itself
#    ("rh: PASS|FAIL usb-android"); whoever binds g1 then brings adb + our NCM (telnet
#    172.16.<net>.1) without any unbind. Only if Android does not bind does the helper bind g1
#    (or its own a52 gadget when g1 has no adb function). A 3 s reconcile loop then repairs any
#    state (g1 bound without NCM: unbind/link/rebind, retried; nobody bound: bind; a52 parked:
#    hand over) and logs every state change. (rh*b and older: one racy hand-over; a lost race left
#    g1 with adb only and no NCM = no telnet, never retried: the rh618b "no USB" run.) It does
#    NOT force the dwc3 role: if a bound gadget is not configured by the host a52.rhusb=<s>
#    (default 60) seconds after the UDC appeared, it logs FAIL and writes mode=peripheral once
#    (a52.rhusb=0 = never).
#  - USB evidence for a failed run: "rh: usbdiag" lines (UDC/state, g1/a52 binding, NCM link and
#    IP, dwc3 mode, usb role, glue + extcon state, adbd, sys.usb.* props, last state changes)
#    every 10 s for 3 min after go, then every 30 s, and one at the dead-man: the tail of the
#    console that ramoops keeps (read /sys/fs/pstore/console-ramoops-0 in LineageOS FIRST).
#  - vendor add-on: copied into init's /dev tmpfs (RAM) as soon as first-stage init has mounted
#    it, then right after switch root a read-only overlayfs over /vendor/lib/modules and
#    /vendor/etc/init (a52ovl), so the ROM's own init, vendor_modprobe and macloader find
#    a52sxq-k61x.rc, lib/modules/6.1x/ and lib/modules/5.4-gki/ where a flashed add-on puts them.
#    If the overlay fails, the audio set is loaded here once the ADSP runs (logged as FAIL).
#  - checks: /a52/rh/rh-checks.sh runs after sys.boot_completed and logs "a52rh: PASS|FAIL|INFO"
#    lines to the kernel log (also /tmp/rh-checks.txt).
# Kept unchanged: dead-man timer (a52.deadman, always armed unless /tmp/a52keep), hang/lockup/
# oops -> panic -> reboot, testguard + zram /data + test fstab, inherited watchdog petting
# (until switch root, then off), fatal logcat lines into kmsg.
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
for a in sh ls cat echo dmesg mount umount ifconfig ip sleep ps kill grep sed head tail cut tr wc dd hexdump find mkdir rm ln cp mv sync reboot poweroff vi top free df lsmod insmod rmmod modprobe uname date printf seq test true false stat touch chmod devmem setsid watchdog killall pkill mknod basename readlink sort uniq usleep timeout chroot nsenter base64 tar gzip md5sum sha256sum od losetup cmp; do
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
printf '#!/bin/busybox sh\nexec /bin/busybox nsenter -t $(/bin/busybox pidof logd) -m -r -w -- /system/bin/sh -c "$*"\n' > /bin/an; chmod 755 /bin/an

. /a52/rh/env		# V=6.12|6.18 K=k612|k618 KREL=... RBNAME=... MODEM=0|1 FWPATH=... WLD=5.4-gki|6.18-wlan SD=on|off|none DCVS=0|1
WLD=${WLD:-5.4-gki}
DEADMAN=600; NET=42; STAGE=2; SKIP=; PREFIX_END=zram; RHUSB=60; RHWAIT=10
for w in $(cat /proc/cmdline); do case "$w" in
	a52.deadman=*) DEADMAN=${w#a52.deadman=};;
	a52.net=*) NET=${w#a52.net=};;
	a52.stage=*) STAGE=${w#a52.stage=};;
	a52.skip=*) SKIP="$SKIP $(echo "${w#a52.skip=}" | tr ',' ' ' | tr '-' '_')";;
	a52.rhprefix=*) PREFIX_END=$(echo "${w#a52.rhprefix=}" | tr '-' '_');;
	a52.rhusb=*) RHUSB=${w#a52.rhusb=};;
	a52.rhwait=*) RHWAIT=${w#a52.rhwait=};;
	a52.mods=*) log "rh: a52.mods is ignored in the rehearsal (no module stages)";;
esac; done
case "$DEADMAN" in ''|0|*[!0-9]*) DEADMAN=600;; esac   # the dead-man timer cannot be switched off
case "$RHUSB" in ''|*[!0-9]*) RHUSB=60;; esac
case "$RHWAIT" in ''|*[!0-9]*) RHWAIT=10;; esac
log "start REAL-BOOT REHEARSAL helper ($RBNAME, $V, $KREL; stage=$STAGE deadman=${DEADMAN}s prefix<=$PREFIX_END usb-fallback=${RHUSB}s usb-android-wait=${RHWAIT}s)"

# ---- USB evidence: one "rh: usbdiag" line of the whole USB state (see the header). Defined
# before the dead-man so its last line is the dead-man's (always inside the ramoops tail).
G=/config/usb_gadget/a52; G1=/config/usb_gadget/g1; ZN=$G1/configs/b.1/zncm
extcons() { for e in /sys/class/extcon/extcon*; do [ -d "$e" ] && printf '%s[%s] ' "$(cat $e/name 2>/dev/null)" "$(cat $e/state 2>/dev/null | tr '\n' ',')"; done; }
usbdiag() { # <tag>
	local u us f z ni nets i n ip c rl pr
	u=$(ls /sys/class/udc 2>/dev/null | head -1); us=-
	[ -n "$u" ] && us="$u:$(cat /sys/class/udc/$u/state 2>/dev/null):$(cat /sys/class/udc/$u/current_speed 2>/dev/null)"
	f=0; [ -e $G1/configs/b.1/f1 ] && f=1
	z=0; [ -L $ZN ] && z=1
	ni=$(cat $G1/functions/ncm.a52/ifname 2>/dev/null)
	nets=; for i in /sys/class/net/usb*; do [ -e "$i" ] || continue; n=${i##*/}
		ip=$(ifconfig $n 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'); c=$(cat $i/carrier 2>/dev/null)
		nets="$nets$n=${ip:-noip}/c${c:-?} "; done
	rl=$(cat /sys/class/usb_role/*/role 2>/dev/null | tr '\n' ',')
	pr=; pidof logd >/dev/null 2>&1 && pr=$(an "getprop sys.usb.config; getprop sys.usb.state; getprop sys.usb.ffs.ready; getprop init.svc.adbd" 2>/dev/null | tr -d '\r' | tr '\n' '/')
	log "rh: usbdiag $1 up=$(cut -d' ' -f1 /proc/uptime) udc=$us g1=[$(cat $G1/UDC 2>/dev/null)] f1=$f zncm=$z ncm=${ni:--} a52=[$(cat $G/UDC 2>/dev/null)] net=[${nets% }] dwc3mode=$(cat /sys/devices/platform/soc/a600000.ssusb/mode 2>/dev/null) role=$rl glue=[$(cat /sys/bus/platform/devices/soc:a52sxq-usb-extcon/state 2>/dev/null)] extcon=[$(extcons)] adbd=$(pidof adbd || echo -) props=$pr hist=[$(tail -5 /tmp/rh-usbhist 2>/dev/null | tr '\n' ';')]"
}
# dead-man FIRST: whatever happens below, the phone restarts by itself
( sleep "$DEADMAN"; [ -e /tmp/a52keep ] || { log "dead-man timer expired"; usbdiag deadman; /leave deadman; } ) &

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
log "insmod testguard"
insmod /a52/testguard.ko ro=misc,metadata,efs,sec_efs,persist,cache,param,steady,persistent,keyrefuge,modemst1,modemst2,fsg,fsc 2>/tmp/insmod.err && log "testguard loaded" || log "insmod FAILED testguard: $(cat /tmp/insmod.err)"

# ---- the prefix of the real first-stage list, as libmodprobe would load it
canon() { n=${1##*/}; n=${n%.ko}; echo "$n" | tr '-' '_'; }
skipped() { for s in $SKIP; do [ "$s" = "$1" ] && return 0; done; return 1; }
optsfor() {
	o=$(grep "^options $1 " $M/modules.options 2>/dev/null | head -1 | cut -d' ' -f3-)
	for w in $(cat /proc/cmdline); do case "$w" in *.*=*)
		mm=$(echo "${w%%.*}" | tr '-' '_'); [ "$mm" = "$1" ] && o="$o ${w#*.}";; esac; done
	echo $o
}
LOADED=" "; NOK=0; NFAIL=0
ins() {
	local f c d deps rev a
	f=$1; c=$(canon "$f")
	case "$LOADED" in *" $c "*) return 0;; esac
	LOADED="$LOADED$c "
	if skipped "$c"; then log "skip $c (a52.skip: NOT what the real boot does)"; return 0; fi
	deps=$(grep "^$f:" $M/modules.dep | head -1 | cut -d: -f2-); rev=
	for d in $deps; do rev="$d $rev"; done
	for d in $rev; do ins "$d"; done
	a=$(optsfor "$c")
	# test-only: three zram disks (zram1 = /data, zram2 = /metadata); the real boot has one
	[ "$c" = zram ] && a="$a num_devices=3"
	pet
	log "insmod $c $a"
	if insmod "$M/$f" $a 2>/tmp/insmod.err; then NOK=$((NOK + 1))
	else
		case "$(cat /tmp/insmod.err)" in *[Ee]xists*) ;; *)
			NFAIL=$((NFAIL + 1)); log "insmod FAILED $c: $(cat /tmp/insmod.err)"; echo "$c: $(cat /tmp/insmod.err)" >> /tmp/insmod-failed.txt;; esac
	fi
}
NPRE=0
while read -r m rest; do
	case "$m" in ''|'#'*) continue;; esac
	NPRE=$((NPRE + 1)); ins "$m"
	[ "$(canon "$m")" = "$PREFIX_END" ] && break
done < $M/modules.load
log "rh: prefix of the real modules.load done: $NPRE lines (up to $PREFIX_END), $NOK loaded, $NFAIL failed; first-stage init loads all $(grep -c . $M/modules.load)"
pet
ZR=0
if [ -e /sys/block/zram2/disksize ]; then
	echo 134217728 > /sys/block/zram2/disksize && echo 3221225472 > /sys/block/zram1/disksize && ZR=1
fi
log "zram1 (/data) 3 GiB, zram2 (/metadata) 128 MiB: ok=$ZR"
mkdevs
# OneUI 9 port (2026-11-22): its policy lets no e2fs/mke2fs format a ram_device (fs_mgr "formattable" -> mke2fs
# "Permission denied" -> /data read-only -> odsign/tombstoned loop -> reboot): write empty ext4 images made on the PC
if [ "$ZR" = 1 ] && [ -f /a52/rh/zram2.ext4.gz ] && [ -f /a52/rh/zram1.ext4.gz ]; then
	$B zcat /a52/rh/zram2.ext4.gz > /dev/zram2 && $B zcat /a52/rh/zram1.ext4.gz > /dev/zram1 && $B sync && log "zram1/zram2: empty ext4 written (pre-formatted)" || log "zram pre-format FAILED"
fi

# ---- gate for Android's init (testguard must hold userdata, the RAM disks must exist)
i=0; ARMED=0
while [ $i -lt 40 ]; do
	dmesg | grep -q "testguard: armed" && { ARMED=1; break; }
	sleep 1; i=$((i + 1)); pet
done
log "ready (prefix ok=$NOK failed=$NFAIL, testguard armed=$ARMED, zram=$ZR, USB: later, from the real extcon)"
if [ "$STAGE" = 1 ]; then
	touch /old/a52/stay; log "stage 1: no Android init; waiting for the dead-man timer"
	while :; do sleep 3600; done
fi
if [ $ARMED != 1 ] || [ $ZR != 1 ]; then
	touch /old/a52/stay; log "NOT starting Android: testguard armed=$ARMED zram=$ZR"
	while :; do sleep 3600; done
fi
# inherited watchdog: keep petting while first-stage init loads the rest (max 600 s), off after
# switch root (as the test helper, which switched it off before Android)
( i=0; while [ ! -e /tmp/rh-switched ] && [ $i -lt 120 ]; do pet; sleep 5; i=$((i + 1)); done
  # WDT=1 builds: gh_virt_wdt owns the watchdog by now (loaded by first-stage init): leave it alone
  if [ -d /sys/module/gh_virt_wdt ]; then log "gh_virt_wdt loaded: watchdog left to the kernel driver"
  else [ -e $WRAW ] && echo "5 2 0" > $WRAW && log "inherited watchdog disabled"; fi ) &
touch /old/a52/go
T0=$(cut -d. -f1 /proc/uptime)

# ---- USB: rehearse Android's own g1 bind (real boot), with our NCM pre-linked (see the header)
mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/ncm.usb0 $G/functions/acm.usb0
echo 0x1209 > $G/idVendor; echo 0xa528 > $G/idProduct
echo a52sxq-android612 > $G/strings/0x409/manufacturer
echo "a52sxq realboot rehearsal $(uname -r)" > $G/strings/0x409/product
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
upms() { local u f; u=$(cut -d' ' -f1 /proc/uptime); f=${u#*.}; f=${f#0}; echo $(( ${u%.*} * 1000 + ${f:-0} * 10 )); }
udcof() { cat "$1/UDC" 2>/dev/null; }
hist() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> /tmp/rh-usbhist; }
TD=0; UPIF=" "
ipup() { # <ifname>: 172.16.<net>.1 on it (only there), one DHCP server per interface, one telnetd
	local o
	[ -n "$1" ] && [ -d /sys/class/net/$1 ] || return 1
	for o in /sys/class/net/usb*; do o=${o##*/}
		[ "$o" != "$1" ] && ifconfig $o 2>/dev/null | grep -q "inet addr:172\.16\.$NET\.1 " && ifconfig $o 0.0.0.0 down; done
	ifconfig "$1" 2>/dev/null | grep -q "inet addr:172\.16\.$NET\.1 " || ifconfig "$1" 172.16.$NET.1 netmask 255.255.255.0 up
	case "$UPIF" in *" $1 "*) ;; *)
		/usr/bin/unudhcpd -i "$1" -s 172.16.$NET.1 -c 172.16.$NET.2 >/dev/null 2>&1 &
		UPIF="$UPIF$1 "; log "rh: usb: 172.16.$NET.1 on $1 (dhcp server started)";; esac
	[ $TD = 1 ] || { /bin/busybox-extras telnetd -b 172.16.$NET.1:23 -l /bin/sh && TD=1; }
	return 0
}
g1link() { # our NCM into Android's g1, only while g1 is unbound (configfs refuses links into a
	   # bound gadget, and unlinking from one unbinds it): 0 = linked
	[ -L $ZN ] && return 0
	[ -d $G1/configs/b.1 ] && [ -z "$(udcof $G1)" ] || return 1
	mkdir -p $G1/functions/ncm.a52 2>/dev/null
	ln -s $G1/functions/ncm.a52 $ZN 2>/dev/null
	[ -L $ZN ] && { hist "zncm linked"; return 0; }
	return 1
}
g1bind() { # the helper binds g1 itself (NCM linked first if possible): 0 = g1 holds the UDC
	g1link
	echo "$UDC" > $G1/UDC 2>/tmp/g1bind.err
	[ "$(udcof $G1)" = "$UDC" ] && { hist "g1 bound by helper"; return 0; }
	return 1
}
g1join() { # g1 is bound without our NCM: unbind, link, rebind. adbd sees the unbind, restarts its
	   # ffs (that unbinds g1 once more) and init binds g1 again: the link is in either way
	local i
	hist "join: unbind g1"
	echo "" > $G1/UDC 2>/dev/null
	i=0; while [ $i -lt 40 ] && ! g1link; do usleep 25000; i=$((i + 1)); done
	[ -n "$(udcof $G1)" ] || { usleep 300000; [ -n "$(udcof $G1)" ] || g1bind; }
	[ -L $ZN ]
}
usbloop() {
	local UDC= UDCMS=0 UDCT=0 OWNER=none NEXT=0 CONF=0 FB=0 NOUDC=0 EMPTY=0 NJOIN=0 JNEXT=0 LAST= n=0 now t g a st S z
	# 1. until the UDC exists: pre-link our NCM into g1 as soon as Android has made it
	while :; do
		if [ ! -e /tmp/nohandover ]; then
			g1link
			UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
			[ -n "$UDC" ] && break
			now=$(cut -d. -f1 /proc/uptime)
			[ $NOUDC = 0 ] && [ $now -ge $((T0 + 180)) ] && { NOUDC=1; touch /tmp/rh-usb-fail; hist "no UDC after 180 s"
				log "rh: FAIL usb: no UDC $((now - T0)) s after go: dwc3 did not probe (waits for the Samsung extcon of the power stack); extcon: $(extcons)"; }
		fi
		[ $NOUDC = 1 ] && sleep 3 || usleep 250000
	done
	UDCMS=$(upms); UDCT=$(cut -d. -f1 /proc/uptime); hist "UDC $UDC appeared"
	z=0; [ -L $ZN ] && z=1
	log "rh: usb: UDC $UDC appeared $((UDCT - T0)) s after go; g1 [$(udcof $G1)] f1=$([ -e $G1/configs/b.1/f1 ] && echo 1 || echo 0) zncm=$z; extcon: $(extcons)"
	# 2. Android's turn: the real boot has no helper, init + adbd must bind g1 by themselves
	while [ -z "$(udcof $G1)" ] && [ $(( $(upms) - UDCMS )) -lt $((RHWAIT * 1000)) ]; do g1link; usleep 250000; done
	t=$(( $(upms) - UDCMS )); z=0; [ -L $ZN ] && z=1
	if [ -n "$(udcof $G1)" ]; then
		OWNER=g1; touch /tmp/rh-usb-android-ok; hist "g1 bound by Android +${t}ms zncm=$z"
		log "rh: PASS usb-android: Android bound g1 by itself ${t} ms after the UDC appeared (the real-boot path); our NCM pre-linked: $z"
	else
		touch /tmp/rh-usb-android-fail; hist "Android did not bind g1 in ${RHWAIT}s"
		log "rh: FAIL usb-android: Android did not bind g1 within ${RHWAIT} s of the UDC (f1=$([ -e $G1/configs/b.1/f1 ] && echo 1 || echo 0), adbd $(pidof adbd || echo -), props $(an 'getprop sys.usb.config; getprop sys.usb.ffs.ready' 2>/dev/null | tr -d '\r' | tr '\n' '/')): the helper binds"
		if [ -e $G1/configs/b.1/f1 ] && g1bind; then OWNER=g1; log "rh: usb: helper bound g1 (adb + ncm=$([ -L $ZN ] && echo 1 || echo 0))"
		elif echo "$UDC" > $G/UDC 2>/tmp/a52bind.err; then OWNER=a52; NEXT=3; hist "a52 bound"; log "rh: usb: gadget a52 on $UDC (g1 not bindable: $(cat /tmp/g1bind.err 2>/dev/null))"
		else log "rh: usb: neither g1 nor a52 could be bound ($(cat /tmp/g1bind.err /tmp/a52bind.err 2>/dev/null | tr '\n' ' ')): retrying in the loop"; fi
	fi
	mkdevs
	# 3. reconcile every 3 s: adb + NCM on whoever holds the UDC, repair lost states, log changes
	while :; do
		g=$(udcof $G1); a=$(udcof $G)
		if [ -n "$g" ]; then
			EMPTY=0; OWNER=g1
			if [ -L $ZN ]; then ipup "$(cat $G1/functions/ncm.a52/ifname 2>/dev/null)"
			elif [ $NJOIN -lt 6 ] && [ $n -ge $JNEXT ]; then
				NJOIN=$((NJOIN + 1)); JNEXT=$((n + 4))
				if g1join; then log "rh: usb: join $NJOIN: our NCM linked into g1 (g1 [$(udcof $G1)])"
				else log "rh: usb: join $NJOIN failed (g1 [$(udcof $G1)], zncm missing): retry in 12 s"; fi
			fi
		elif [ -n "$a" ]; then
			EMPTY=0; OWNER=a52; ipup "$(cat $G/functions/ncm.usb0/ifname 2>/dev/null)"
			if [ -e $G1/configs/b.1/f1 ] && [ $n -ge $NEXT ]; then
				log "rh: usb: Android gadget g1 is waiting for the UDC, handing over"; hist "handover a52 -> g1"
				echo "" > $G/UDC
				if g1bind; then OWNER=g1; log "rh: usb: g1 bound (adb + ncm=$([ -L $ZN ] && echo 1 || echo 0))"
				else log "rh: usb: g1 bind failed ($(cat /tmp/g1bind.err 2>/dev/null)), back to gadget a52"
					echo "$UDC" > $G/UDC && hist "a52 bound"; NEXT=$((n + 7)); fi
			fi
		else
			EMPTY=$((EMPTY + 1))
			if [ $EMPTY -ge 2 ]; then	# nobody for two polls: not init in the middle of a switch
				EMPTY=0; hist "nobody held the UDC"
				if [ -e $G1/configs/b.1/f1 ] && g1bind; then OWNER=g1; log "rh: usb: nobody held the UDC: helper bound g1"
				elif echo "$UDC" > $G/UDC 2>/tmp/a52bind.err; then OWNER=a52; NEXT=$((n + 3)); hist "a52 bound"; log "rh: usb: nobody held the UDC: gadget a52 on $UDC"
				else log "rh: usb: nobody holds the UDC and binding failed ($(cat /tmp/g1bind.err /tmp/a52bind.err 2>/dev/null | tr '\n' ' '))"; fi
			fi
		fi
		now=$(cut -d. -f1 /proc/uptime)
		st=$(cat /sys/class/udc/$UDC/state 2>/dev/null)
		if [ $CONF = 0 ] && [ "$st" = configured ]; then
			CONF=1; hist "configured ($OWNER)"
			if [ $FB = 0 ]; then log "rh: PASS usb: gadget $OWNER configured by the host $((now - UDCT)) s after the UDC appeared (role from the real extcon); extcon: $(extcons)"
			else log "rh: usb: gadget configured only AFTER the mode=peripheral fallback"; fi
		fi
		# the role fallback only when a gadget IS bound and the host still does not configure it
		if [ $CONF = 0 ] && [ $FB = 0 ] && [ "$RHUSB" != 0 ] && [ -n "$(udcof $G1)$(udcof $G)" ] && [ $now -ge $((UDCT + RHUSB)) ]; then
			FB=1; touch /tmp/rh-usb-fail; hist "FAIL not configured, mode=peripheral"
			log "rh: FAIL usb: not configured ${RHUSB} s after the UDC appeared (state '$st', $OWNER bound): the extcon did not give dwc3 the peripheral role; extcon: $(extcons); FALLBACK mode=peripheral"
			usbmode && log "rh: usb fallback: mode=peripheral written" || log "rh: usb fallback failed: $(cat /tmp/usbmode.err)"
		fi
		S="g1=[$(udcof $G1)] a52=[$(udcof $G)] zncm=$([ -L $ZN ] && echo 1 || echo 0) state=$st"
		[ "$S" != "$LAST" ] && { log "rh: usb: now $S"; LAST=$S; }
		sleep 3; n=$((n + 1))
		[ $((n % 5)) = 0 ] && mkdevs
		ip rule 2>/dev/null | grep -q "^100:" || ip rule add pref 100 from all lookup main 2>/dev/null
		while [ -e /tmp/nohandover ]; do sleep 3; done
	done
}
usbloop &
# USB evidence in the kernel log: every 10 s for 3 min after go, then every 30 s
( i=0; while :; do usbdiag t$i; i=$((i + 1)); [ $i -le 18 ] && sleep 10 || sleep 30; done ) &

# ---- vendor add-on into init's /dev tmpfs, as soon as first-stage init has mounted it
A=/proc/1/root/dev/.a52addon
addcopy() { mkdir -p $A && cp -a /a52/addon/vendor $A/ && [ "$(find $A/vendor -type f | wc -l)" = "$(find /a52/addon/vendor -type f | wc -l)" ] && addhide; }
# ADDON=vendor_boot: the overlay layer HIDES the 6.x files of an earlier install (overlayfs whiteouts =
# char 0:0 in the upper lowerdir), so the phone's /vendor looks like it never had an add-on
addhide() {
	[ "${ADDON:-vendor}" = vendor_boot ] || return 0
	for w in lib/modules/6.12 lib/modules/6.18 lib/modules/6.18-wlan lib/modules/5.4-gki etc/init/a52sxq-k612.rc etc/init/a52sxq-k618.rc; do
		[ -e $A/vendor/$w ] || mknod $A/vendor/$w c 0 0 || return 1; done
	cp /a52/rh/tone.dex $A/tone.dex 2>/dev/null; return 0
}
i=0; ADD=0
while [ $i -lt 1200 ]; do grep -q "^tmpfs /dev tmpfs" /proc/1/mounts 2>/dev/null && break; usleep 50000; i=$((i + 1)); done
addcopy && ADD=1
log "rh: vendor add-on copied into init's /dev tmpfs: ok=$ADD (poll $i)"

# ---- after the switch to the real root: overlays, then the test fstab (RAM only)
i=0; BOUND=0; OVL=0
while [ $i -lt 2400 ]; do
	if [ -e /proc/1/root/system/bin/init ] && [ -d /proc/1/root/vendor/etc ] && [ ! -e /proc/1/root/system/system ]; then
		touch /tmp/rh-switched
		# first-stage init may have moved /dev under the copy: check, copy again if needed
		if [ "${ADDON:-vendor}" = vendor_boot ]; then [ -c $A/vendor/lib/modules/$V ] || { addcopy && ADD=1 || ADD=0; }
		else [ -f $A/vendor/etc/init/a52sxq-$K.rc ] && [ -f $A/vendor/lib/modules/$V/modules.dep ] || { addcopy && ADD=1 || ADD=0; }; fi
		if [ $ADD = 1 ] && /a52/a52ovl /vendor/lib/modules /dev/.a52addon/vendor/lib/modules:/vendor/lib/modules \
				/vendor/etc/init /dev/.a52addon/vendor/etc/init:/vendor/etc/init > /tmp/a52ovl.log 2>&1; then OVL=1; fi
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
# 6.18 (WLD=6.18-wlan): the rc binds $WLD over 5.4-gki later (post-fs); 5.4-gki must exist as its mount point
if [ "${ADDON:-vendor}" = vendor_boot ]; then
	F=/proc/1/root/vendor
	if [ $OVL = 1 ] && [ ! -e $F/lib/modules/$V ] && [ ! -e $F/lib/modules/5.4-gki ] && [ ! -e $F/etc/init/a52sxq-k612.rc ] && [ ! -e $F/etc/init/a52sxq-k618.rc ] && [ -d $F/lib/modules ]; then
		log "rh: addon=vendor_boot: phone's /vendor 6.x files HIDDEN from init (lib/modules: $(ls $F/lib/modules | tr '\n' ' '); etc/init a52sxq*: $(ls $F/etc/init | grep -c a52sxq))"
	else touch /tmp/rh-hide-fail; log "rh: FAIL addon=vendor_boot hide overlay (copy=$ADD ovl=$OVL: $(cat /tmp/a52ovl.log | tr '\n' ' '))"; fi
elif [ $OVL = 1 ] && [ -f /proc/1/root/vendor/etc/init/a52sxq-$K.rc ] && [ -f /proc/1/root/vendor/lib/modules/$V/modules.dep ] && [ -f /proc/1/root/vendor/lib/modules/$WLD/qca_cld3_wlan.ko ] \
		&& [ -d /proc/1/root/vendor/lib/modules/5.4-gki ]; then
	log "rh: vendor add-on visible to init: /vendor/etc/init/a52sxq-$K.rc, /vendor/lib/modules/$V, /vendor/lib/modules/$WLD (RAM overlay); 5.4-gki holds: $(ls /proc/1/root/vendor/lib/modules/5.4-gki 2>/dev/null | tr '\n' ' ')"
else
	touch /tmp/rh-addon-fail
	log "rh: FAIL vendor add-on overlay (copy=$ADD ovl=$OVL: $(cat /tmp/a52ovl.log | tr '\n' ' ')): FALLBACK: the helper loads the audio set once the ADSP runs"
	( j=0; while [ ! -e /sys/kernel/a52sxq_dsp/adsp_running ] && [ $j -lt 300 ]; do sleep 1; j=$((j + 1)); done
	  for m in $(cat /a52/rh/audio.list); do insmod /a52/addon/vendor/lib/modules/$V/$m.ko 2>/dev/null || log "fallback insmod FAILED $m"; done
	  log "rh: fallback audio set loaded (adsp_running after ${j}s)" ) &
fi

# ---- MODEM=1 builds (rb12): the phone's own modem under the ROM's radio userspace, EFS in RAM
if [ "${MODEM:-0}" = 1 ]; then
	BB=/proc/$$/root/bin/busybox		# our busybox, reachable from init's namespace
	SUB=; for d in /sys/bus/msm_subsys/devices/subsys*; do [ "$(cat $d/name 2>/dev/null)" = modem ] && SUB=$d; done
	# 1. rollback guard (2026-11-13 incident class): refuse first, allow only once the image is
	#    known to carry the ADSP image's anti-rollback version (TZ accepts that one on this phone;
	#    higher could raise the shared counter, lower is refused anyway). pm-service (class core,
	#    "on boot") opens /dev/subsys_modem long after "on fs" mounted both firmware partitions.
	FW0=$(cat $SUB/firmware_name 2>/dev/null)
	if [ -n "$SUB" ] && echo a52-modem-refused > $SUB/firmware_name 2>/dev/null; then
		log "rh: modem: $SUB firmware_name '$FW0' -> a52-modem-refused until the rollback check passed"
		( F=/proc/1/root/vendor; j=0
		  while [ $j -lt 600 ] && ! { [ -r $F/firmware-modem/image/modem.b01 ] && [ -r $F/firmware_mnt/image/adsp.b01 ]; }; do usleep 200000; j=$((j + 1)); done
		  RM=$(od -An -tu1 -j164 -N1 $F/firmware-modem/image/modem.b01 2>/dev/null | tr -d ' ')
		  RA=$(od -An -tu1 -j164 -N1 $F/firmware_mnt/image/adsp.b01 2>/dev/null | tr -d ' ')
		  if [ -n "$RM" ] && [ "$RM" = "$RA" ] && echo "${FW0:-modem}" > $SUB/firmware_name; then
			log "rh: PASS modem-guard: anti-rollback modem=$RM adsp=$RA: firmware_name '$(cat $SUB/firmware_name)' restored (after $((j / 5)) s)"
		  else
			touch /tmp/rh-modem-refused
			log "rh: FAIL modem-guard: anti-rollback modem=${RM:-?} adsp=${RA:-?} (or unreadable after $((j / 5)) s): modem NOT booted (firmware_name a52-modem-refused)"
		  fi ) &
	else
		touch /tmp/rh-modem-refused; log "rh: FAIL modem-guard: no msm_subsys 'modem' or firmware_name not writable ('$SUB'): the modem may boot unguarded"
	fi
	# 2. EFS in RAM. testguard holds modemst1, modemst2, fsg, fsc read-only at the block layer (rmt_storage
	#    opens them read-write; on a real boot it writes the phone's own EFS, the rehearsal must not).
	#    efsdump (drivers612/modem, O_RDONLY + BLKROSET, refuses mmcblk*) copies them into a tmpfs
	#    (pristine, for the final verify); a second copy backs a loop device each, bound over the
	#    partition's /dev/block/sdXN in init's namespace: rmt_storage reads the real contents, the
	#    modem's writes stay in RAM.
	#    Android's first stage creates only the block nodes it mounts: wait for ueventd's coldboot
	#    (second stage, early-init) to create the four, long before "on boot" starts rmt_storage.
	( E=/tmp/efs; ER=/tmp/efs-rw; NE=0
	mkdir -p $E $ER
	if mount -t tmpfs -o size=96m,mode=0700 tmpfs $E && mount -t tmpfs -o size=96m,mode=0700 tmpfs $ER \
			&& /a52/rh/efsdump copy $E > /tmp/efs-copy.txt 2>&1; then
		i=0
		for pf in modemst1:modem_fs1 modemst2:modem_fs2 fsg:modem_fsg fsc:modem_fsc; do
			p=${pf%%:*}; f=${pf#*:}; dev=
			for u in /sys/class/block/sd*/uevent; do grep -qx "PARTNAME=$p" $u && dev=$(sed -n 's/^DEVNAME=//p' $u); done
			case "$dev" in sd[a-z]*[0-9]) ;; *) log "rh: FAIL efs: $p: no UFS partition ('$dev')"; i=$((i + 1)); continue;; esac
			cp $E/$f $ER/$f
			j=0; while [ ! -b /proc/1/root/dev/block/$dev ] && [ $j -lt 600 ]; do usleep 100000; j=$((j + 1)); done
			idx=$((240 + i)); i=$((i + 1))
			if nsenter -t 1 -m -- $BB sh -c "B=$BB; \$B mkdir -p /dev/.a52efs && { [ -b /dev/.a52efs/loop$idx ] || \$B mknod /dev/.a52efs/loop$idx b 7 $((idx * 8)); } \
					&& [ -b /dev/block/$dev ] && \$B losetup /dev/.a52efs/loop$idx /proc/$$/root$ER/$f && \$B mount -o bind /dev/.a52efs/loop$idx /dev/block/$dev" 2>/tmp/efs-$p.err; then
				NE=$((NE + 1)); log "rh: efs: $p (/dev/block/$dev, node after $((j / 10)) s) -> RAM copy on loop$idx"
			else log "rh: FAIL efs: $p (/dev/block/$dev, waited $((j / 10)) s): $(tr '\n' ' ' < /tmp/efs-$p.err)"; fi
		done
	else log "rh: FAIL efs: tmpfs/efsdump copy: $(tail -3 /tmp/efs-copy.txt 2>/dev/null | tr '\n' ' ')"; fi
	[ $NE = 4 ] && touch /tmp/rh-efs-ok
	log "rh: efs: $NE of 4 partitions on RAM copies ($(dmesg | grep -c "starting service 'vendor.rmt_storage'") rmt_storage start line(s) in dmesg before this one)" ) &
fi

# fatal logcat lines into the kernel log (ramoops keeps them when Android restarts the phone)
( while ! pidof logd >/dev/null 2>&1; do usleep 300000; done; sleep 1
  an "logcat -b main,system,crash -v brief *:F" 2>/dev/null | while read -r l; do echo "LC: $l" > /dev/kmsg; done ) &
# the pass checks, once Android has booted (results: dmesg | grep a52rh:, /tmp/rh-checks.txt)
( sh /a52/rh/rh-checks.sh > /tmp/rh-checks.txt 2>&1 ) &
while :; do sleep 3600; done
