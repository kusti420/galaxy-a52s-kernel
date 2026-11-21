#!/bin/busybox sh
# Pass checks of the real-boot rehearsal (drivers612/realboot/rehearse.sh), run by the rehearsal
# helper inside the test kernel once Android reports sys.boot_completed (or after RH_WAIT s).
# READ-ONLY: it only reads /proc, /sys, dmesg, getprop, dumpsys, logcat. Every result line goes
# to the kernel log as "a52rh: PASS|FAIL|INFO <check>: ..." (dmesg, ramoops/pstore after a
# reboot) and to stdout (/tmp/rh-checks.txt in the helper's root). Ends with a SUMMARY line.
. /a52/rh/env		# V K KREL RBNAME NFIRST MODEM FWPATH WLD SD DCVS
FWPATH=${FWPATH:-/vendor/firmware_mnt/image,/vendor/firmware}
WLD=${WLD:-5.4-gki}; SD=${SD:-none}; DCVS=${DCVS:-0}
RH_WAIT=${RH_WAIT:-360}
P() { echo "a52rh: $*" > /dev/kmsg; echo "$*"; }
NP=0; NF=0
pass() { P "PASS $*"; NP=$((NP + 1)); }
fail() { P "FAIL $*"; NF=$((NF + 1)); }
info() { P "INFO $*"; }
gp() { an "getprop $1" 2>/dev/null | tr -d '\r'; }
present() { grep -q "^$1 " /proc/modules; }
ms() { # "[   12.345678]..." -> milliseconds
	s=$(echo "$1" | sed -n 's/^\[ *\([0-9]*\)\.\([0-9][0-9][0-9]\).*/\1 \2/p')
	set -- $s; [ -n "$1" ] || { echo 0; return; }
	echo $(( $1 * 1000 + $(echo "$2" | sed 's/^0*//;s/^$/0/') ))
}

T0=$(cut -d. -f1 /proc/uptime); BC=0
while [ $(( $(cut -d. -f1 /proc/uptime) - T0 )) -lt $RH_WAIT ]; do
	[ "$(gp sys.boot_completed)" = 1 ] && { BC=1; break; }
	sleep 5
done
UP=$(cut -d. -f1 /proc/uptime)
sleep 20	# let the Wi-Fi HAL, adbd, audioserver settle
P "rehearsal checks for $RBNAME ($V, $(uname -r)), uptime ${UP}s"

# 8. boot_completed (first, so a truncated log still has it)
[ $BC = 1 ] && pass "boot_completed: sys.boot_completed=1 at ${UP}s uptime" || fail "boot_completed: not set after ${RH_WAIT}s"
[ "$(uname -r)" = "$KREL" ] && pass "kernel: $(uname -r)" || fail "kernel: $(uname -r), expected $KREL"

# 1. first stage: the vendor_boot module list, loaded by the ROM's first-stage init
# RH_SD=off: sdhci_msm is refused on purpose (module_blacklist=sdhci_msm), every other module must load
miss=; for n in $(cat /a52/rh/first-stage.names); do [ "$SD" = off ] && [ "$n" = sdhci_msm ] && continue; present "$n" || miss="$miss $n"; done
[ -z "$miss" ] && pass "first-stage: all $NFIRST modules of modules.load are loaded$( [ "$SD" = off ] && echo ' (sdhci_msm refused on purpose, RH_SD=off)')" || fail "first-stage: not loaded:$miss"
info "first-stage: $(dmesg | grep -E 'init: Loaded [0-9]+ (kernel )?modules' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -1)"
info "first-stage: helper prefix: $(dmesg | grep 'rh: prefix of the real' | sed 's/.*rh: //' | tail -1)"
dmesg | grep -E 'init: .*(Failed to insmod|Failed to load kernel module|[Ff]ailed to load modules)' > /tmp/rh-initerr.txt
# RH_SD=off: the refused sdhci-msm line and init's summary line it causes are expected
if [ "$SD" = off ] && grep -q 'sdhci-msm' /tmp/rh-initerr.txt; then grep -v 'sdhci-msm' /tmp/rh-initerr.txt | grep -v 'Failed to load kernel modules, starting console' > /tmp/rh-initerr2.txt; mv /tmp/rh-initerr2.txt /tmp/rh-initerr.txt; fi
nerr=$(grep -c . /tmp/rh-initerr.txt)
[ "$nerr" = 0 ] && pass "first-stage: no module load errors logged by init" || fail "first-stage: $nerr module load errors by init: $(dmesg | grep -E 'init: .*Failed to (insmod|load)' | sed 's/.*init: //' | head -5 | tr '\n' '|')"
info "first-stage: init per-module lines: $(dmesg | grep -c 'init: Loaded kernel module')"

# 2. a52sxq_dsp_boot.ko instead of the helper's @adsp job
dmesg | grep -iE 'a52sxq.dsp' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -6 | while read -r l; do info "dsp_boot: $l"; done
present a52sxq_dsp_boot && pass "dsp_boot: module loaded (first stage)" || fail "dsp_boot: a52sxq_dsp_boot not loaded"
for d in adsp cdsp; do
	st=; for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name 2>/dev/null)" in *$d*) st=$(cat $r/state);; esac; done
	if [ -e /sys/kernel/a52sxq_dsp/${d}_running ] && [ "$st" = running ]; then pass "dsp_boot: $d running, /sys/kernel/a52sxq_dsp/${d}_running present"
	else fail "dsp_boot: $d remoteproc state '$st', ${d}_running $( [ -e /sys/kernel/a52sxq_dsp/${d}_running ] && echo present || echo missing)"; fi
done

# 3. dwc3 with the real Samsung USB extcon
x=/proc/device-tree/soc/ssusb@a600000/extcon
case "$(wc -c < $x 2>/dev/null)" in
	8) pass "usb: tree has the real extcon (<&eud>, <&a52sxq_usb_extcon>)";;
	4) fail "usb: tree has the EUD-only test extcon (wrong dtb)";;
	*) fail "usb: $x unreadable";;
esac
dmesg | grep -E 'a52sxq-init: rh: ((PASS|FAIL) usb|usb[: ])' | grep -v 'rh: usbdiag' | sed 's/.*a52sxq-init: rh: //' | while read -r l; do info "usb: helper: $l"; done
[ -e /tmp/rh-usb-fail ] && fail "usb: the extcon did not bring the gadget up by itself (see helper lines; fallback used or no UDC)" \
	|| pass "usb: gadget configured without forcing the dwc3 role"
# the real boot has no helper: init (re-triggered by adbd's 1 s FUNCTIONFS_BIND retry) must bind g1
if [ -e /tmp/rh-usb-android-ok ]; then pass "usb-android: Android bound g1 by itself after the UDC appeared (real-boot path)"
elif [ -e /tmp/rh-usb-android-fail ]; then fail "usb-android: Android did NOT bind g1 by itself (a real boot would have no adb; the helper bound it)"
else fail "usb-android: no UDC, Android's g1 bind never tested"; fi
info "usb: arm-smmu fault lines in dmesg: $(dmesg | grep -ciE 'context fault|smmu.*fault') (dwc3 SID 0xe0 faults are non-fatal in this dtb: a fault there is silent USB loss)"
for u in /sys/class/udc/*; do [ -e "$u" ] && info "usb: UDC ${u##*/} state $(cat $u/state 2>/dev/null)"; done
for e in /sys/class/extcon/extcon*; do [ -d "$e" ] && info "usb: extcon $(cat $e/name 2>/dev/null): $(cat $e/state 2>/dev/null | tr '\n' ' ')"; done
a=$(gp init.svc.adbd); s=$(gp sys.usb.state)
[ "$a" = running ] && case "$s" in *adb*) true;; *) false;; esac && pass "usb: adbd running, sys.usb.state=$s" || fail "usb: adbd '$a', sys.usb.state '$s'"

# 4. firmware_class.path with two entries, no force_sysfs_fallback
fp=$(cat /sys/module/firmware_class/parameters/path 2>/dev/null)
[ "$fp" = "$FWPATH" ] && pass "firmware: path=$fp" || fail "firmware: path='$fp', expected $FWPATH"
# force_sysfs_fallback: the ROM's init.qti.kernel.rc writes 1 at early-init (as on 5.4). Direct
# loads (firmware_class.path) are still tried first; only a failed one would go to ueventd.
fs=$(cat /proc/sys/kernel/firmware_config/force_sysfs_fallback 2>/dev/null)
nfb=$(dmesg | grep -c 'Falling back to sysfs fallback')
info "firmware: force_sysfs_fallback=${fs:-n/a} (set by the ROM's init.qti.kernel.rc at early-init, not by the cmdline/kernel)"
[ "$nfb" = 0 ] && pass "firmware: no request needed the sysfs/ueventd fallback (all direct from firmware_class.path)" \
	|| info "firmware: $nfb requests went through the sysfs fallback: $(dmesg | grep 'Falling back to sysfs fallback' | sed 's/.*for: //' | sort -u | head -8 | tr '\n' ' ')"
for r in /sys/class/remoteproc/remoteproc*; do info "firmware: remoteproc $(cat $r/name 2>/dev/null): $(cat $r/state 2>/dev/null)"; done
st=; for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name 2>/dev/null)" in *wpss*) st=$(cat $r/state);; esac; done
[ "$st" = running ] && pass "firmware: WPSS running" || fail "firmware: WPSS state '$st'"
# load errors are INFO (adsp/cdsp -2 before /vendor/firmware_mnt is mounted, then booted; regulatory.db,
# panel .dat and touch .bin are optional files): the subsystem checks decide
dmesg | grep -iE 'Direct firmware load|request_firmware failed|falling back to sysfs' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | sort | uniq -c | head -15 | while read -r l; do info "firmware: log: $l"; done
gpuerr=$(dmesg | grep -iE 'Direct firmware load|request_firmware' | grep -icE 'a660|gmu|sqe|zap')
[ "$gpuerr" = 0 ] && pass "firmware: no GPU firmware (a660 sqe/gmu/zap) load error" || fail "firmware: $gpuerr GPU firmware load errors"
[ -d /sys/class/kgsl/kgsl-3d0 ] && pass "firmware: kgsl-3d0 present (GPU)" || fail "firmware: no kgsl-3d0"
[ -e /sys/class/video4linux/video32 ] && pass "firmware: msm_vidc video32 present" || info "firmware: no video32"

# 5. sec_battery: async_probe=1 from modules.options instead of the helper's background insmod
present sec_battery && pass "sec_battery: module loaded by first-stage init" || fail "sec_battery: not loaded"
grep -q '^options sec_battery async_probe=1' /lib/modules/modules.options && info "sec_battery: modules.options has async_probe=1"
L=$(dmesg | grep 'init: Loaded kernel module' | grep -A1 '/sec-battery.ko' | head -2)
if [ "$(echo "$L" | grep -c .)" = 2 ]; then
	d=$(( $(ms "$(echo "$L" | tail -1)") - $(ms "$(echo "$L" | head -1)") ))
	[ $d -lt 5000 ] && pass "sec_battery: first stage went on after ${d} ms (no 20 s probe stall)" || fail "sec_battery: next module came ${d} ms later"
else info "sec_battery: no per-module init lines to time the load"; fi
b=/sys/class/power_supply/battery
if [ -d $b ]; then
	c=$(cat $b/capacity 2>/dev/null); pass "sec_battery: battery psy: capacity $c, status $(cat $b/status 2>/dev/null), health $(cat $b/health 2>/dev/null)"
	[ "${c:-0}" -gt 0 ] || fail "sec_battery: capacity ${c:-?}"
else fail "sec_battery: no /sys/class/power_supply/battery"; fi
info "sec_battery: dumpsys: $(an 'dumpsys battery' 2>/dev/null | grep -E 'level|status|USB powered|AC powered' | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"

if [ "${ADDON:-vendor}" = vendor_boot ]; then
# 6b. ADDON=vendor_boot: nothing from /vendor. Audio + wlan.ko in the first stage, dsp_boot rescans after
# the ADSP, built-in bus DCVS tunables; the phone's old add-on files are hidden by the RAM overlay
[ "$(gp ro.boot.a52sxq.${K}vb)" = 1 ] && [ "$(gp ro.boot.a52sxq.$K)" != 1 ] && pass "vb: gate ro.boot.a52sxq.${K}vb=1, old add-on gate ro.boot.a52sxq.$K unset" \
	|| fail "vb: gates ${K}vb='$(gp ro.boot.a52sxq.${K}vb)' $K='$(gp ro.boot.a52sxq.$K)'"
F=/proc/1/root/vendor
[ ! -e /tmp/rh-hide-fail ] && [ ! -e $F/lib/modules/$V ] && [ ! -e $F/lib/modules/5.4-gki ] && [ ! -e $F/etc/init/a52sxq-$K.rc ] \
	&& pass "vb: /vendor/lib/modules/{$V,5.4-gki} and /vendor/etc/init/a52sxq-$K.rc do not exist for Android (hidden)" || fail "vb: old add-on files visible to Android"
dmesg | grep -cE "modprobe: .*/vendor/lib/modules/$V/" | { read n; [ "$n" = 0 ] && pass "vb: no module loaded from /vendor/lib/modules/$V" || fail "vb: $n modprobe lines for /vendor/lib/modules/$V"; }
miss=; for n in $(cat /a52/rh/audio.names); do present "$n" || miss="$miss $n"; done
[ -z "$miss" ] && pass "vb: all $(grep -c . /a52/rh/audio.names) audio modules loaded (first stage)" || fail "vb: audio modules missing:$miss"
dmesg | grep -E 'a52sxq_dsp_boot: (rescan|bus DCVS|tunable)|bound to .* on rescan' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | head -24 | while read -r l; do info "vb: $l"; done
grep -q '^ *[0-9]* \[' /proc/asound/cards 2>/dev/null && pass "vb: sound card: $(grep '^ *[0-9]* \[' /proc/asound/cards | head -1 | tr -s ' ')" || fail "vb: no sound card"
info "vb: asound cards: $(cat /proc/asound/cards 2>/dev/null | tr -s ' ' | tr '\n' '|')"
for n in 0 1 2 3 4 5 6 7 8 9 10 11; do an "cmd media_session volume --stream $n --set 0" > /dev/null 2>&1; done
if [ -f /proc/1/root/dev/.a52addon/tone.dex ]; then
	# zygote's mount namespace (apex + linkerconfig) and its ART environment (logd's namespace has neither)
	ZP=$(/bin/busybox pidof zygote64 | cut -d' ' -f1)
	ZE=$(tr '\0' '\n' < /proc/$ZP/environ | grep -E '^(BOOTCLASSPATH|DEX2OATBOOTCLASSPATH|SYSTEMSERVERCLASSPATH|ANDROID_[A-Z_]+)=' | tr '\n' ' ')
	TO=$(/bin/busybox nsenter -t $ZP -m -- /system/bin/env $ZE /system/bin/app_process -cp /dev/.a52addon/tone.dex / Tone 2>&1 | tr -d '\r' | tail -4 | tr '\n' '|')
	case "$TO" in *48000/48000*) pass "vb: tone playback (muted): $TO";; *) fail "vb: tone playback: $TO";; esac
else fail "vb: no tone.dex in /dev/.a52addon"; fi
WN=$(cat /a52/rh/wlan.name)
present "$WN" && pass "vb: wlan module '$WN' loaded (first stage)" || fail "vb: wlan module '$WN' not loaded"
[ -d /sys/class/net/wlan0 ] && pass "vb: wlan0 present" || fail "vb: no wlan0"
info "vb: wlan0 operstate $(cat /sys/class/net/wlan0/operstate 2>/dev/null) flags $(cat /sys/class/net/wlan0/flags 2>/dev/null)"
info "vb: addresses wlan0 $(cat /sys/class/net/wlan0/address 2>/dev/null) p2p0 $(cat /sys/class/net/p2p0/address 2>/dev/null) wifi-aware0 $(cat /sys/class/net/wifi-aware0/address 2>/dev/null) swlan0 $(cat /sys/class/net/swlan0/address 2>/dev/null)"
dmesg | grep -iE 'provisioned MAC|derived MAC|wlan_mac|mac_addr_store' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | head -6 | while read -r l; do info "vb: mac: $l"; done
info "vb: macloader: $(an 'logcat -d -b all' 2>/dev/null | grep -i ' macloader' | grep -v avc | tail -6 | tr -d '\r' | sed 's/^.*macloader: //' | tr '\n' '|')"
info "vb: wifi: $(an 'cmd wifi status' 2>/dev/null | head -2 | tr -d '\r' | tr '\n' ' ')"
info "vb: kernel-domain avc for sysfs writes (enforcing real boot would deny these): $(dmesg | grep 'avc:  denied' | grep 'scontext=u:r:kernel:s0' | grep -c '{ write }')"
dmesg | grep 'avc:  denied' | grep 'scontext=u:r:kernel:s0' | grep '{ write }' | sed 's/.*denied/denied/' | sort -u | head -4 | while read -r l; do info "vb: avc: $l"; done
else
# 6. vendor add-on: rc gated by ro.boot.a52sxq.k61x, audio set + wlan from /vendor/lib/modules
[ "$(gp ro.boot.a52sxq.$K)" = 1 ] && pass "addon: ro.boot.a52sxq.$K=1" || fail "addon: ro.boot.a52sxq.$K='$(gp ro.boot.a52sxq.$K)'"
grep -E ' /vendor/(lib/modules|etc/init) overlay' /proc/1/mounts | while read -r l; do info "addon: emulated by RAM overlay: $(echo $l | cut -d' ' -f2)"; done
[ -e /tmp/rh-addon-fail ] && fail "addon: overlay failed: the helper loaded the audio set itself (NOT the real path)" \
	|| pass "addon: /vendor/etc/init/a52sxq-$K.rc + /vendor/lib/modules/$V + $WLD visible to init"
dmesg | grep -E "init: .*(a52sxq_dsp/adsp_running|vendor_modprobe|modprobe -a -d /vendor/lib/modules/$V|exec_background)" | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -4 | while read -r l; do info "addon: $l"; done
ex=$(dmesg | grep "modprobe -s -a -d /vendor/lib/modules/$V " | grep -o 'exited with status [0-9]*' | tail -1)
case "$ex" in *" 0") pass "addon: the rc's modprobe $ex";; '') fail "addon: the rc's modprobe never ran or never exited";; *) fail "addon: the rc's modprobe $ex";; esac
info "addon: modprobe -s: $(dmesg | grep -c "modprobe: Loaded kernel module /vendor/lib/modules/$V/") modules loaded, $(dmesg | grep -E 'modprobe: ' | grep -ciE 'error|failed|unable|malformed') error lines"
dmesg | grep -E 'modprobe: ' | grep -iE 'error|failed|unable|malformed' | sed 's/.*modprobe: //' | head -6 | while read -r l; do info "addon: modprobe: $l"; done
miss=; for n in $(cat /a52/rh/audio.names); do present "$n" || miss="$miss $n"; done
[ -z "$miss" ] && pass "addon: all $(grep -c . /a52/rh/audio.names) audio modules loaded" || fail "addon: audio modules missing:$miss"
grep -q '^ *[0-9]* \[' /proc/asound/cards 2>/dev/null && pass "addon: sound card: $(grep '^ *[0-9]* \[' /proc/asound/cards | head -1 | tr -s ' ')" || fail "addon: no sound card"
WN=$(cat /a52/rh/wlan.name)
if [ "$WLD" != 5.4-gki ]; then
	# the rc's "mount none /vendor/lib/modules/$WLD /vendor/lib/modules/5.4-gki bind" (on post-fs)
	grep -q ' /vendor/lib/modules/5.4-gki ' /proc/1/mounts && pass "wlan-bind: a mount on /vendor/lib/modules/5.4-gki (the rc's bind of $WLD)" \
		|| fail "wlan-bind: nothing mounted on /vendor/lib/modules/5.4-gki ($(dmesg | grep -E "init: .*(5.4-gki|$WLD)" | sed 's/.*init: //' | tail -2 | tr '\n' '|'))"
	cmp -s /proc/1/root/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko /proc/1/root/vendor/lib/modules/$WLD/qca_cld3_wlan.ko \
		&& pass "wlan-bind: macloader's path 5.4-gki/qca_cld3_wlan.ko is the $V wlan.ko" || fail "wlan-bind: 5.4-gki/qca_cld3_wlan.ko is not the $WLD file"
fi
present "$WN" && pass "addon: wlan module '$WN' loaded (5.4-gki/qca_cld3_wlan.ko path)" || fail "addon: wlan module '$WN' not loaded"
[ -d /sys/class/net/wlan0 ] && pass "addon: wlan0 present" || fail "addon: no wlan0"
info "addon: macloader: $(an 'logcat -d -b all' 2>/dev/null | grep -i macloader | tail -2 | tr -d '\r' | tr '\n' '|')"
info "addon: wifi: $(an 'cmd wifi status' 2>/dev/null | head -2 | tr -d '\r' | tr '\n' ' ')"
fi

# 10. SDCARD=1 builds: on = sdhci-msm probes (card INFO only, read-only checks), off = refused on purpose
case "$SD" in
on)
	present sdhci_msm && pass "sd: sdhci_msm loaded" || fail "sd: sdhci_msm not loaded"
	[ -e /sys/bus/platform/drivers/sdhci_msm/8804000.sdhci ] && pass "sd: 8804000.sdhci bound to sdhci_msm" || fail "sd: 8804000.sdhci not bound ($(dmesg | grep -iE 'sdhci|mmc[01]' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -2 | tr '\n' '|'))"
	info "sd: block: $(ls /sys/block | grep mmcblk | tr '\n' ' ')"
	info "sd: vold: $(an 'sm list-volumes all' 2>/dev/null | tr -d '\r' | tr '\n' '|')";;
off)
	present sdhci_msm && fail "sd: sdhci_msm loaded although RH_SD=off" || pass "sd: sdhci_msm refused ($(dmesg | grep -c 'sdhci_msm is blacklisted') 'blacklisted' line(s)): the microSD is not seen"
	ls /sys/block | grep -q mmcblk && fail "sd: an mmcblk device exists with RH_SD=off" || pass "sd: no mmcblk device";;
esac

# 11. bus/GPU DCVS builds: governors, bwmon/memlat probed, the rc's bus_dcvs writes, interconnect sync
if [ "$DCVS" = 1 ]; then
	# ADDON=vendor_boot: a52sxq_dsp_boot writes the tunables itself at the WALT boost release (~45 s after its probe)
	if [ "${ADDON:-vendor}" = vendor_boot ]; then j=0; while ! dmesg | grep -q 'a52sxq_dsp_boot: bus DCVS tunables' && [ $j -lt 90 ]; do sleep 2; j=$((j + 2)); done
		l=$(dmesg | grep 'a52sxq_dsp_boot: bus DCVS tunables' | sed 's/.*a52sxq_dsp_boot: //' | tail -1)
		# all N of N applied (56 = busdcvs.conf; LPM=1 adds 2 rows)
		n=$(echo "$l" | sed -n 's/^bus DCVS tunables \([0-9]*\)\/\([0-9]*\) applied.*/\1 \2/p')
		if [ -n "$n" ] && [ "${n% *}" = "${n#* }" ] && [ "${n% *}" -ge 56 ]; then pass "dcvs: kernel wrote the tunables: $l"; else fail "dcvs: tunables: '${l:-no line after ${j}s}'"; fi; fi
	g=; for d in /sys/class/devfreq/*; do [ "$(cat $d/governor 2>/dev/null)" = msm-adreno-tz ] && g="$g ${d##*/}"; done
	[ -n "$g" ] && pass "dcvs: GPU devfreq governor msm-adreno-tz on$g" || fail "dcvs: no devfreq with governor msm-adreno-tz ($(for d in /sys/class/devfreq/*; do echo "${d##*/}=$(cat $d/governor 2>/dev/null)"; done | tr '\n' ' '))"
	B=/sys/devices/system/cpu/bus_dcvs
	[ -d $B/DDR/9091000.qcom,bwmon-ddr ] && pass "dcvs: bwmon DDR probed" || fail "dcvs: no $B/DDR/9091000.qcom,bwmon-ddr"
	[ -e $B/memlat_settings ] && pass "dcvs: memlat probed ($B/memlat_settings)" || fail "dcvs: memlat not probed ($(dmesg | grep -iE 'memlat|qcom-pmu|scmi' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -2 | tr '\n' '|'))"
	dmesg | grep -q 'Failure to probe memlat device: -517' && fail "dcvs: memlat deferred (-517)" || true
	s=; for h in DDR LLCC L3 DDRQOS; do s="$s $h=$(cat $B/$h/boost_freq 2>/dev/null)/$(cat $B/$h/hw_max_freq 2>/dev/null)/$(cat $B/$h/cur_freq 2>/dev/null)"; done
	info "dcvs: boost/hw_max/cur:$s"
	bd=$(cat $B/DDR/boost_freq 2>/dev/null); bm=$(cat $B/DDR/hw_max_freq 2>/dev/null)
	[ -n "$bd" ] && [ -n "$bm" ] && [ "$bd" -lt "$bm" ] && pass "dcvs: DDR boot boost ended by the rc (boost_freq $bd < hw max $bm)" || fail "dcvs: DDR boost_freq '$bd' (hw max '$bm'): the rc's bus_dcvs writes did not apply"
	pend=$(dmesg | grep 'sync_state() pending due to' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -3 | tr '\n' '|')
	info "dcvs: sync_state pending lines (boot): ${pend:-none}"
	ns=0; for p in /sys/devices/platform/soc/*interconnect*/state_synced; do [ "$(cat $p 2>/dev/null)" = 1 ] || ns=$((ns + 1)); done
	[ $ns = 0 ] && pass "dcvs: every interconnect provider state_synced=1" || fail "dcvs: $ns interconnect provider(s) not synced"
	S=/sys/kernel/debug/interconnect/interconnect_summary
	[ -r $S ] && info "dcvs: icc: $(grep -E '^ *(ebi|qns_llcc) ' $S | tr -s ' ' | tr '\n' '|')"
fi

# 9. MODEM=1 builds: the phone's own modem under the ROM's radio userspace (EFS on RAM copies)
if [ "${MODEM:-0}" = 1 ]; then
	dmesg | grep -E 'a52sxq-init: rh: (PASS |FAIL )?(modem|efs)' | sed 's/.*a52sxq-init: rh: //' | while read -r l; do info "modem: helper: $l"; done
	[ -e /tmp/rh-modem-refused ] && fail "modem-guard: the modem was refused or unguarded (helper lines above)" || pass "modem-guard: anti-rollback modem = adsp, firmware name restored"
	if [ -e /tmp/rh-efs-ok ]; then
		n=$(dmesg | grep 'a52sxq-init: rh: efs: 4 of 4' | sed -n 's/.*(\([0-9]*\) rmt_storage start.*/\1/p' | tail -1)
		[ "$n" = 0 ] && pass "efs: 4 of 4 partitions on RAM copies before vendor.rmt_storage started" || fail "efs: RAM copies bound, but rmt_storage had started before ($n start lines)"
	else fail "efs: the EFS RAM shim is incomplete (helper lines): rmt_storage may have found read-only partitions"; fi
	# radio: wait for registration (up to 120 s more); only the registration states are read, never
	# SIM identifiers (no IMSI/ICCID/MSISDN/IMEI: grep -o of four fields of the service state)
	T1=$(cut -d. -f1 /proc/uptime); RS=
	while [ $(( $(cut -d. -f1 /proc/uptime) - T1 )) -lt 120 ]; do
		RS=$(an 'dumpsys telephony.registry' 2>/dev/null | tr -d '\r' | grep -oE 'm(Voice|Data)RegState=[0-9]+\([A-Z_]+\)' | head -2 | tr '\n' ' ')
		case "$RS" in *IN_SERVICE*) break;; esac; sleep 5
	done
	for sv in vendor.rmt_storage vendor.tftp_server vendor.pd_mapper vendor.qrtr-ns vendor.per_mgr vendor.per_proxy vendor.ipacm ril-daemon; do
		st=$(gp init.svc.$sv); [ "$st" = running ] && pass "modem: service $sv running" || fail "modem: service $sv '$st'"; done
	ms=; for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name 2>/dev/null)" in *mss*|*modem*) ms=$(cat $r/state);; esac; done
	[ "$ms" = running ] && pass "modem: MSS remoteproc running" || fail "modem: MSS remoteproc state '$ms'"
	ss=; for d in /sys/bus/msm_subsys/devices/subsys*; do [ "$(cat $d/name 2>/dev/null)" = modem ] && ss=$(cat $d/state 2>/dev/null); done
	[ "$ss" = ONLINE ] && pass "modem: msm_subsys modem ONLINE" || fail "modem: msm_subsys modem state '$ss'"
	nd=$(dmesg | grep -c 'DOG detects stalled'); nc=$(dmesg | grep -cE 'handling crash #|fatal error received')
	[ "$nd" = 0 ] && [ "$nc" = 0 ] && pass "modem: no DOG stall, no crash/SSR" || fail "modem: $nd DOG stalls, $nc crash/fatal lines: $(dmesg | grep -E 'fatal error received|DOG detects' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | head -2 | tr '\n' '|')"
	dmesg | grep -q 'IPA FW loaded successfully' && pass "modem: IPA FW loaded (ipa_fws.rc write /dev/ipa)" || fail "modem: no 'IPA FW loaded successfully'"
	dmesg | grep -q 'IPA driver initialization was successful' && pass "modem: IPA driver initialization successful" || fail "modem: IPA init not completed"
	info "modem: IOVA: $(dmesg | grep -c 'Cannot reserve IOVA region of 0 size') 'Cannot reserve IOVA region of 0 size' lines (0 expected with the ipa-iova-fix tree)"
	[ -d /sys/class/net/rmnet_ipa0 ] && pass "modem: rmnet_ipa0 present" || fail "modem: no rmnet_ipa0"
	u=; for d in /sys/class/uio/uio*; do [ "$(cat $d/name 2>/dev/null)" = rmtfs ] && u=${d##*/}; done
	[ -n "$u" ] && pass "modem: rmtfs UIO is $u ($(cat /sys/class/uio/$u/maps/map0/size 2>/dev/null))" || fail "modem: no UIO named rmtfs"
	info "modem: firmware: $(dmesg | grep -iE 'remoteproc-mss.*(Booting fw|is now up)|modem\.mdt' | sed 's/^\[[^]]*\]\(\[[^]]*\]\)* *//' | tail -3 | tr '\n' '|')"
	# /dev owners: the ROM's ueventd rules as computed offline (modem-devnodes.txt: name mode uid gid provider)
	while read -r n mo uid gid prov; do
		f=/proc/1/root/dev/$n
		if [ -e "$f" ]; then
			got=$(stat -L -c '%a %u %g' "$f" 2>/dev/null)
			[ "$got" = "$mo $uid $gid" ] && pass "devnode: /dev/$n $got ($prov)" || fail "devnode: /dev/$n is '$got', ueventd rule says '$mo $uid $gid'"
		else
			case "$n" in uio*|rmnet_ctrl|dpl_ctrl|ipa_adpl|ipa_odl_ctl|ipaNatTable|apr_apps2) info "devnode: /dev/$n absent (optional: $prov)";;
			*) fail "devnode: /dev/$n missing ($prov)";; esac
		fi
	done < /a52/rh/modem-devnodes.txt
	info "modem: rmt_storage log: $(an 'logcat -d -b all -s rmt_storage' 2>/dev/null | tr -d '\r' | tail -3 | sed 's/^.*rmt_storage[^:]*: //' | tr '\n' '|')"
	case "$RS" in *IN_SERVICE*) pass "radio: $RS";; *) fail "radio: not in service after 120 s: '${RS:-no service state}', SIM state $(gp gsm.sim.state)";; esac
	# data: an rmnet_data interface with an IPv4 address (not printed) and a ping through it
	di=; for i in /sys/class/net/rmnet_data*; do [ -e "$i" ] || continue; an "ip -4 addr show ${i##*/}" 2>/dev/null | grep -q 'inet ' && { di=${i##*/}; break; }; done
	if [ -n "$di" ]; then
		pass "data: $di has an IPv4 address"
		pr=$(an "ping -c 3 -W 5 -I $di 1.1.1.1" 2>&1 | tr -d '\r' | grep -E 'packets transmitted|bad|unknown')
		case "$pr" in *" 0 received"*|*"0 packets received"*|'') fail "data: ping 1.1.1.1 over $di: ${pr:-no output}";; *) pass "data: ping 1.1.1.1 over $di: $pr";; esac
	else fail "data: no rmnet_data* with an IPv4 address (mobile data off? $(gp gsm.network.type))"; fi
	# SELinux: the rehearsal is permissive, the real boot enforcing: every denial of a radio/data
	# domain here would block that access on the real boot (6.x sysfs/dev paths the ROM's 5.4 policy
	# does not label the same way)
	{ dmesg; an 'logcat -d -b all' 2>/dev/null; } | tr -d '\r' | grep 'avc: *denied' \
		| grep -E 'scontext=u:r:(rmt_storage|tftp_server|vendor_pd_mapper|vendor_qrtr|vendor_per_mgr|vendor_per_proxy|per_mgr|per_proxy|rild|vendor_rild|ipacm|vendor_ipacm|netmgrd|vendor_modprobe|ueventd|hal_.*radio.*)' \
		| sed -n 's/.*denied *{ *\([^}]*\)}.*comm="\([^"]*\)".*\(name="[^"]*"\)\{0,1\}.*scontext=u:r:\([^:]*\):.*tcontext=u:object_r:\([^:]*\):.*tclass=\([a-z_]*\).*/\4 \1-> \5 \6 (\2)/p' \
		| sort -u > /tmp/rh-radio-avc.txt
	na=$(grep -c . /tmp/rh-radio-avc.txt)
	[ "$na" = 0 ] && pass "selinux: no denials of the radio/data domains (enforcing real boot would allow the same)" \
		|| { info "selinux: $na distinct radio/data denials (would be BLOCKED on the enforcing real boot):"; head -12 /tmp/rh-radio-avc.txt | while read -r l; do info "selinux: $l"; done; }
	# the real partitions are still what was copied before Android started (all writes went to RAM)
	if [ -e /tmp/rh-efs-ok ]; then
		v=$(/a52/rh/efsdump verify /tmp/efs 2>&1 | tail -1)
		case "$v" in *"all 4 partitions unchanged"*) pass "efs: $v";; *) fail "efs: $v";; esac
		for f in modem_fs1 modem_fs2 modem_fsg modem_fsc; do info "efs: $f: $(cmp -l /tmp/efs/$f /tmp/efs-rw/$f 2>/dev/null | wc -l) bytes changed by the modem (RAM copy only)"; done
	fi
fi

# 7. general health
info "health: testguard: $(dmesg | grep -c 'testguard: armed') armed line(s); crashes in logcat: $(an 'logcat -d -b crash' 2>/dev/null | grep -cE 'FATAL EXCEPTION|Fatal signal|\*\*\* \*\*\*')"
info "health: kernel WARN/BUG lines: $(dmesg | grep -cE 'WARNING: CPU|BUG:|Oops|Unable to handle')"
info "health: selinux $(cat /sys/fs/selinux/enforce 2>/dev/null) (0 = permissive, as in every test run)"
P "SUMMARY $RBNAME: pass=$NP fail=$NF"
