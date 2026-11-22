#!/bin/bash
# REAL-BOOT REHEARSAL: run the parts of the real boot (out/rb2, out/rb618-1) that no test ever
# ran, on a test phone (PHONE=2 PHONE2, default; PHONE=1 PHONE1) through the kexec
# harness, WITHOUT flashing anything:
#   (1) a52sxq_dsp_boot.ko starts ADSP + CDSP (no helper @adsp job)
#   (2) dwc3 with the real Samsung USB extcon (<&eud>, <&a52sxq_usb_extcon>), not the EUD-only one
#   (3) firmware_class.path=/vendor/firmware_mnt/image,/vendor/firmware, no force_sysfs_fallback
#   (4) sec_battery async_probe=1 (modules.options) instead of the helper's background insmod
#   (5) the vendor add-on: a52sxq-k61x.rc (gated on ro.boot.a52sxq.k61x) loads the audio set from
#       /vendor/lib/modules/6.1x, macloader loads wlan from /vendor/lib/modules/5.4-gki
#   plus: the ROM's first-stage init loading the vendor_boot /lib/modules list itself (libmodprobe,
#   modules.options, first_stage_console=2), androidboot.force_normal_boot=1 and the rest of the
#   bootloader's arguments, the realboot dtb + dtbo.
#   (7) SDCARD=1 builds (rb16, rb618-5): cqhci + sdhci-msm in the first stage. RH_SD=on lets
#       sdhci-msm probe (vold then mounts a card as on the real boot: never formats it); RH_SD=off adds
#       the test word module_blacklist=sdhci_msm (the kernel refuses that one module, init goes on:
#       first_stage_console=2), so no microSD is ever seen. Default: off on PHONE=1 (the inserted
#       card), on on PHONE=2. Checks: probe + 8804000.sdhci bound (on) / refused + no mmcblk (off).
#   (8) bus/GPU DCVS builds (bwmon/memlat/GPU governors in the first stage): kgsl devfreq governor
#       msm-adreno-tz, bwmon + memlat probed (no SCMI defer), the rc's bus_dcvs writes applied
#       (boost_freq dropped), interconnect providers synced (sync_state timeout bootargs).
#   (9) 6.18 Wi-Fi: the 6.18 add-on's rc bind-mounts /vendor/lib/modules/6.18-wlan over 5.4-gki
#       (BUILDINFO wlan=); the phone's own 5.4-gki (6.12 wlan.ko) shows through the RAM overlay
#       underneath, exactly the state the real 6.18 boot meets. Check: the bind + wlan loaded.
#   (6) MODEM=1 builds (rb12): the phone's own modem under the ROM's own radio userspace
#       (rmt_storage, tftp_server, pd-mapper, pm-service, ipacm, rild) with the modem/data modules
#       in the first stage; the EFS is served from RAM (testguard keeps modemst1/2, fsg, fsc
#       read-only: the helper copies them with drivers612/modem's efsdump, attaches loop devices
#       to RAM copies and binds them over the partitions' /dev/block nodes in Android's namespace;
#       efsdump verify at the end proves the partitions unchanged), the modem only boots when its
#       anti-rollback version equals the ADSP image's (else firmware_name a52-modem-refused), and
#       the checks cover IPA, the /dev owners (modem-devnodes.txt), registration and a data ping.
#
#   [PHONE=1|2] drivers612/realboot/rehearse.sh <612|618> <name>     e.g. rehearse.sh 612 rh612a
#     -> out/rh-<name>/{Image,rd.cpio.gz,rh-base.dtb,pack.tgz,cmdline.txt,harness-extra.sh,REPORT.txt}
#        and prints the kx-cycle command. RUN=1 also runs it (needs the phone; the user's call).
# Env: PHONE=2 (default) PHONE2: harness images/a52sxq-ack618-kexec9-p2-recovery.img, NET 43
#      (172.16.43.1), USB 1-5.4.4.2, ABL A528BXXS2DWB5 (bit 2), hw rev 4;
#      PHONE=1 PHONE1: harness images/a52sxq-ack618-kexec9-recovery.img, NET 42 (172.16.42.1),
#      USB 1-5.3, ABL A528BXXU5FWK4 (bit 5), hw rev 3, microSD (mmcblk1: nothing may touch it).
#      Both run the same LineageOS build (lineage-24.0-20261028), so one realboot build serves both;
#      only the bootloader's own arguments differ. When PHONE is not the phone the build was made
#      for (its dump=testdev-<serial>), the measured ABL part is re-targeted with
#      tools/abl-retarget.py: every value that differs between the two phones' harness live trees
#      (serial, revision, subpcb, ap_serial, bootloader, rp, kg.ap, em.did, wb.snapQB) is replaced
#      by the target's, cross-checked against the target's normal-boot live tree (testdev-<serial>/
#      live.dtb + vendor_boot.img of that boot) when present.
#      RB=<realboot build dir> (default out/rb11 / out/rb618-5), DEADMAN=<s> (default 480),
#      RH_SD=on|off (SDCARD=1 builds; default off on PHONE=1, on on PHONE=2),
#      KX_WAIT=<s> (default 300), RH_ABL=full|min (bootloader arguments: full = everything the ABL
#      appends, measured from the phone's 5.4 live tree; min = the test cmdline's androidboot
#      set + panel ids + force_normal_boot), LIVE=<harness live dtb> (offline gen check; default
#      the newest logs/kx-*-p<PHONE>-*/harness-live.dtb), SRC_LIVE=<harness live dtb of the build's
#      phone> (re-targeting only), BINDS="file:/target ..." (extra RAM shims).
# What the harness still imposes (cannot be the real boot): kexec from the 6.18 harness (dtb gets
# memory/hypervisor/uh/watchdog/rmtfs patches from mkkexecdtb.py at `gen`), a52init as PID 1 with
# the helper (dead-man, hang->panic, testguard holding userdata read-only, /data + /metadata on
# zram, test fstab), modules 1..92 of the real list (up to zram.ko) insmod'ed by the helper in the
# same order before Android (testguard needs UFS), zram num_devices=3, the vendor add-on as a RAM
# overlay instead of files on /vendor, the test adb_debug.prop (adb insecure: /data is empty),
# SELinux permissive, loglevel=7 log_buf_len=4M, 6.18: earlycon=a52ram + its reserved node.
# Nothing here touches a phone unless RUN=1.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
KV=${1:?usage: rehearse.sh <612|618> <name>}; NAME=${2:?usage: rehearse.sh <612|618> <name>}
case "$NAME" in *[!a-z0-9-]*) echo "name: a-z 0-9 - only" >&2; exit 2;; esac
AB=$TOP/drivers612/androidboot; R=$HERE/rehearsal
PB=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86
# the two test phones (nothing else may ever be a target)
PHONE=${PHONE:-2}
phone_vars() {   # <1|2> -> PS PNET PHIMG PPORT PBL PREV
	case "$1" in
	1) PS=PHONE1; PNET=42; PHIMG=images/a52sxq-ack618-kexec9-recovery.img; PPORT=1-5.3; PBL=A528BXXU5FWK4; PREV=3;;
	2) PS=PHONE2; PNET=43; PHIMG=images/a52sxq-ack618-kexec9-p2-recovery.img; PPORT=1-5.4.4.2; PBL=A528BXXS2DWB5; PREV=4;;
	*) echo "PHONE must be 1 or 2" >&2; exit 2;;
	esac
}
phone_vars "$PHONE"; S=$PS; NET=$PNET; HIMG=$PHIMG; UPORT=$PPORT; BL=$PBL; HWREV=$PREV; TSHIP=172.16.$NET.1
case "$KV" in
612) RB=${RB:-$HERE/out/rb11}; V=6.12; K=k612; BRINGUP=$TOP/bsp612/out/bringup/ramdisk-612.cpio.gz; KDIST=$TOP/bsp612/out/dist
     TESTGUARD=$AB/testguard/testguard.ko; LLVM=$PB/clang-r547379/bin; TESTED='kx-ab-s74*-p2-*';;
618) RB=${RB:-$HERE/out/rb618-5}; V=6.18; K=k618; BRINGUP=$TOP/bsp618/android/out/bringup/ramdisk-618.cpio.gz; KDIST=$TOP/bsp618/android/out/dist
     TESTGUARD=$TOP/bsp618/src/drivers612/androidboot/testguard/testguard.ko; LLVM=$PB/clang-r596125/bin; TESTED='kx-ab618-a8*-p2-*';;
*) echo "usage: rehearse.sh <612|618> <name>" >&2; exit 2;;
esac
CC612=$PB/clang-r547379/bin
DEADMAN=${DEADMAN:-480}; KXW=${KX_WAIT:-300}; RH_ABL=${RH_ABL:-full}
O=$HERE/out/rh-$NAME; W=$O/work
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
say() { echo "$*" | tee -a "$O/REPORT.txt"; }
decomp() { case "$(file -b "$1")" in LZ4*) lz4 -dc "$1";; gzip*) gzip -dc "$1";; *) fail "unknown compression: $1";; esac; }
modname() { "$LLVM/llvm-objcopy" -O binary --only-section=.modinfo "$1" "$W/modinfo.bin" && tr '\0' '\n' < "$W/modinfo.bin" | sed -n 's/^name=//p' | head -1; }
vermagic() { [ "$(strings -a "$1" | grep -c "^vermagic=$KREL ")" -ge 1 ] || fail "wrong vermagic: $1"; }

# ---- inputs
# addon=vendor_boot builds (build-realboot.sh ADDON=vendor_boot): no vendor add-on at all; the RAM overlay
# then HIDES every 6.x file an earlier install left on the phone's /vendor (whiteouts on lib/modules/6.1x,
# 6.18-wlan, 5.4-gki and etc/init/a52sxq-k61x.rc), so the run proves nothing comes from /vendor
RBADDON=$(sed -n 's/.* addon=\([^ ]*\).*/\1/p' "$RB/BUILDINFO" 2>/dev/null); RBADDON=${RBADDON:-vendor}
[ "$RBADDON" = vendor ] && ADDF=vendor-addon.SHA256SUMS || ADDF=work/plan/addon-late.load
for f in BUILDINFO REPORT.txt first-stage.modules.load cmdline-predicted-4096.txt dt-bootargs.txt vendor-cmdline.txt \
         realboot.dtbo $ADDF work/chk-b/kernel work/chk-b/ramdisk work/chk-vb/dtb work/chk-vb/vendor_ramdisk; do
	[ -e "$RB/$f" ] || fail "$RB/$f missing (build-realboot.sh first)"; done
RBNAME=$(sed -n 's/^name=\([^ ]*\).*/\1/p' "$RB/BUILDINFO"); KREL=$(sed -n 's/.* krel=\([^ ]*\).*/\1/p' "$RB/BUILDINFO")
RBMODEM=$(sed -n 's/.* modem=\([01]\).*/\1/p' "$RB/BUILDINFO"); RBMODEM=${RBMODEM:-0}
# the dir macloader sees as /vendor/lib/modules/5.4-gki (6.18: 6.18-wlan, bound over 5.4-gki by its rc)
WLD=$(sed -n 's/.* wlan=\([^ ]*\).*/\1/p' "$RB/BUILDINFO"); WLD=${WLD:-5.4-gki}
# SDCARD=1 build: sdhci-msm in the vendor_boot first stage
grep -qx 'sdhci-msm.ko' "$RB/first-stage.modules.load" && RBSD=1 || RBSD=0
RH_SD=${RH_SD:-$([ "$PHONE" = 1 ] && echo off || echo on)}; case "$RH_SD" in on|off) ;; *) echo "RH_SD=on|off" >&2; exit 2;; esac
[ "$RBSD" = 1 ] || RH_SD=none
grep -qx 'bwmon.ko' "$RB/first-stage.modules.load" && RBDCVS=1 || RBDCVS=0
EFSDUMP=$TOP/drivers612/modem/out/kpack/bin/efsdump
if [ "$RBMODEM" = 1 ]; then
	[ -f "$RB/modem-devnodes.txt" ] || fail "$RB is a MODEM=1 build without modem-devnodes.txt"
	[ -x "$EFSDUMP" ] && file -b "$EFSDUMP" | grep -q 'ARM aarch64.*statically linked' || fail "no static aarch64 $EFSDUMP (drivers612/modem/build.sh)"
fi
grep -q "kernel=$V " "$RB/BUILDINFO" || fail "$RB is not a $V build"
# the phone whose dumps (live tree = measured ABL arguments) the build was made from
RBS=$(sed -n '1s/.* dump=[^ ]*testdev-\([A-Z0-9]*\) .*/\1/p' "$RB/REPORT.txt")
case "$RBS" in PHONE1) RBPHONE=1;; PHONE2) RBPHONE=2;; *) fail "cannot tell which phone $RB was built for (dump= in its REPORT.txt)";; esac
[ -f "$TOP/$HIMG" ] || fail "no harness image $HIMG for phone $PHONE"
for f in "$BRINGUP" "$TESTGUARD" "$AB/out/los1/fstab.first" "$AB/out/los1/fstab.second" "$AB/adb_debug.prop"; do [ -f "$f" ] || fail "missing $f"; done
grep -q 'by-name/userdata' "$AB/out/los1/fstab.second" && fail "test fstab names userdata"
grep -E 'formattable' "$AB/out/los1/fstab.second" | grep -v zram && fail "a real partition is formattable in the test fstab"
[ -n "$(grep -Ev 'logical' "$AB/out/los1/fstab.first")" ] && fail "first-stage test fstab has a non-logical entry"
rm -rf "$O"; mkdir -p "$W"
: > "$O/REPORT.txt"
say "real-boot rehearsal $NAME = $RBNAME ($V, $KREL$( [ "$RBMODEM" = 1 ] && echo ', MODEM=1')), $(date '+%F %T'); NOTHING is flashed; kexec test path only"
say "phone $PHONE: $S, harness $HIMG, NET $NET ($TSHIP), USB $UPORT, ABL $BL, hw rev $HWREV; $RBNAME was built from phone $RBPHONE's dumps ($RBS)"

# ---- kernel: the bytes of boot.img
cp "$RB/work/chk-b/kernel" "$O/Image"
say "Image: boot.img kernel of $RBNAME, sha256 $(sha256sum "$O/Image" | cut -c1-16)"

# ---- ramdisk = 1 ROM boot ramdisk | 2 harness tools (bring-up ramdisk minus its modules)
#                | 3 vendor_boot vendor ramdisk, bytes as in the image | 4 rehearsal overlay
# MODLOAD builds: the boot ramdisk ends with a bootconfig trailer (work/bootconfig.bin): decompress without it, append
# it again at the end of rd.cpio.gz (the initrd end, as on the real boot)
BCF=; [ -f "$RB/work/bootconfig.bin" ] && grep -q ' modload=[a-z]' "$RB/BUILDINFO" && BCF=$RB/work/bootconfig.bin
# 2026-11-22: REFUSED. The helper insmods the module prefix (up to zram) itself, sequentially, so first-stage init
# never parallel-loads the core set here; rb100 passed this rehearsal and bootlooped for real (sec_core insmod -517 ->
# first stage fatal). MODLOAD needs a rehearsal mode where first-stage init loads ALL modules itself first.
[ -n "$BCF" ] && fail "MODLOAD build: this rehearsal cannot cover parallel first-stage loading (helper prefix is sequential); banned for real flashes"
if [ -n "$BCF" ]; then n=$(( $(stat -c %s "$RB/work/chk-b/ramdisk") - $(stat -c %s "$BCF") ))
	cmp -s <(tail -c +$((n + 1)) "$RB/work/chk-b/ramdisk") "$BCF" || fail "boot ramdisk does not end with work/bootconfig.bin"
	head -c $n "$RB/work/chk-b/ramdisk" > "$W/boot-ramdisk-nobc"; decomp "$W/boot-ramdisk-nobc" > "$W/1-boot.cpio"
else decomp "$RB/work/chk-b/ramdisk" > "$W/1-boot.cpio"; fi
python3 -I "$HERE/tools/cpiox.py" "$W/1-boot.cpio" "$W/rom" > /dev/null
python3 -I "$HERE/tools/cpiox.py" "$BRINGUP" "$W/bu" > /dev/null
[ "$(grep -c . "$W/bu/.cpiox-nodes.txt")" = 0 ] || fail "bring-up ramdisk has device nodes (repack would drop them)"
[ -f "$W/bu/lib/modules/hhwdt.ko" ] || fail "no hhwdt.ko in $BRINGUP"
find "$W/bu/lib/modules" -mindepth 1 ! -name hhwdt.ko -delete; rm -f "$W/bu/.cpiox-nodes.txt" "$W/bu/init"
( cd "$W/bu" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) > "$W/2-tools.cpio"
decomp "$RB/work/chk-vb/vendor_ramdisk" > "$W/3-vendor.cpio"
OV=$W/ov; mkdir -p "$OV/a52/bind" "$OV/a52/rh" "$OV/a52/addon/vendor" "$OV/first_stage_ramdisk"
CC="$CC612/clang --target=aarch64-linux-gnu -Os -Wall -Werror -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fuse-ld=lld -Wl,--build-id=none"
$CC -o "$OV/init" "$AB/a52init/a52init.c"
$CC -o "$OV/a52/a52bind" "$AB/a52init/a52bind.c"
$CC -o "$OV/a52/a52ovl" "$R/a52ovl.c"
cp "$W/rom/init" "$OV/init.android"
cp "$R/helper-rh.sh" "$OV/a52/helper.sh"; cp "$R/helper2-rh.sh" "$OV/a52/helper2.sh"; cp "$AB/kexec-rd/leave" "$OV/a52/leave"
cp "$R/rh-checks.sh" "$OV/a52/rh/rh-checks.sh"
if [ "$RBMODEM" = 1 ]; then cp "$EFSDUMP" "$OV/a52/rh/efsdump"; chmod 755 "$OV/a52/rh/efsdump"; cp "$RB/modem-devnodes.txt" "$OV/a52/rh/modem-devnodes.txt"; fi
chmod 755 "$OV/init" "$OV/init.android" "$OV/a52/helper.sh" "$OV/a52/helper2.sh" "$OV/a52/leave" "$OV/a52/a52bind" "$OV/a52/a52ovl" "$OV/a52/rh/rh-checks.sh"
cp "$AB/out/los1/fstab.second" "$OV/a52/bind/fstab.qcom"
cp "$AB/out/los1/fstab.first" "$OV/first_stage_ramdisk/fstab.qcom"; cp "$AB/out/los1/fstab.first" "$OV/fstab.qcom"
: > "$OV/force_debuggable"
sed "s/^ro.bpf.kver_override=.*/ro.bpf.kver_override=${KREL%%-*}/" "$AB/adb_debug.prop" > "$OV/adb_debug.prop"
grep -q "^ro.bpf.kver_override=${KREL%%-*}$" "$OV/adb_debug.prop" || fail "adb_debug.prop kver"
cp "$TESTGUARD" "$OV/a52/testguard.ko"; "$LLVM/llvm-strip" --strip-debug "$OV/a52/testguard.ko"
: > "$OV/a52/bind/binds.txt"
for b in ${BINDS:-}; do case "${b%%:*}${b#*:}" in *.mdt*|*.mbn*|*.b[0-9][0-9]*|*firmware*)
	fail "BINDS entry '$b' looks like firmware: refused (only the phone's own firmware may be loaded)";; esac
	cp "${b%%:*}" "$OV/a52/bind/"; echo "$(basename "${b%%:*}") ${b#*:}" >> "$OV/a52/bind/binds.txt"; done
if [ "$RBADDON" = vendor ]; then
# the vendor add-on, byte for byte as build-realboot.sh made it
cp -a "$RB/vendor-addon/etc" "$RB/vendor-addon/lib" "$OV/a52/addon/vendor/"
( cd "$OV/a52/addon" && find vendor -type f | sort | xargs sha256sum | sed 's#  vendor/#  vendor-addon/#' ) > "$W/addon.sha"
diff <(sort -k2 "$W/addon.sha") <(grep " vendor-addon/\(etc/init/a52sxq-$K.rc\|lib/modules/$V/\|lib/modules/$WLD/\)" "$RB/vendor-addon.SHA256SUMS" | sort -k2) > "$W/addon.diff" \
	|| fail "vendor add-on differs from $RB/vendor-addon.SHA256SUMS ($W/addon.diff)"
[ -f "$OV/a52/addon/vendor/etc/init/a52sxq-$K.rc" ] || fail "no a52sxq-$K.rc in the add-on"
if [ "$WLD" != 5.4-gki ]; then
	# 5.4-gki = mount point only (empty in the add-on; the phone's own 6.12 files show through the overlay)
	[ -d "$OV/a52/addon/vendor/lib/modules/5.4-gki" ] && [ -z "$(ls -A "$OV/a52/addon/vendor/lib/modules/5.4-gki")" ] || fail "add-on 5.4-gki is not an empty mount point dir"
	grep -q "^    mount none /vendor/lib/modules/$WLD /vendor/lib/modules/5.4-gki bind$" "$OV/a52/addon/vendor/etc/init/a52sxq-$K.rc" || fail "no $WLD bind in a52sxq-$K.rc"
fi
else
	mkdir -p "$OV/a52/addon/vendor/lib/modules" "$OV/a52/addon/vendor/etc/init"   # whiteouts are made by the helper (mknod)
	say "addon=vendor_boot: NO vendor add-on; the RAM overlay hides lib/modules/{6.12,6.18,6.18-wlan,5.4-gki} and etc/init/a52sxq-k61{2,8}.rc of the phone's /vendor"
fi
# rehearsal check inputs: module names (from .modinfo), the rc's audio list, the wlan module name
VR=$W/vr; python3 -I "$HERE/tools/cpiox.py" "$W/3-vendor.cpio" "$VR" > /dev/null
cmp -s "$VR/lib/modules/modules.load" "$RB/first-stage.modules.load" || fail "vendor ramdisk modules.load != first-stage.modules.load"
: > "$OV/a52/rh/first-stage.names"
while read -r m; do [ -f "$VR/lib/modules/$m" ] || fail "$m in modules.load but not in the vendor ramdisk"
	n=$(modname "$VR/lib/modules/$m"); [ -n "$n" ] || fail "no modinfo name in $m"; echo "$n" | tr '-' '_' >> "$OV/a52/rh/first-stage.names"; done < "$VR/lib/modules/modules.load"
if [ "$RBADDON" = vendor ]; then
AUD=$(sed -n "s#.*/vendor/bin/modprobe \(-s \)\{0,1\}-a -d /vendor/lib/modules/$V ##p" "$OV/a52/addon/vendor/etc/init/a52sxq-$K.rc")
[ -n "$AUD" ] || fail "no modprobe line in a52sxq-$K.rc"
echo "$AUD" | tr ' ' '\n' | grep . > "$OV/a52/rh/audio.list"
: > "$OV/a52/rh/audio.names"
for m in $AUD; do f="$OV/a52/addon/vendor/lib/modules/$V/$m.ko"; [ -f "$f" ] || fail "rc names $m, no $f"; modname "$f" | tr '-' '_' >> "$OV/a52/rh/audio.names"; done
modname "$OV/a52/addon/vendor/lib/modules/$WLD/qca_cld3_wlan.ko" | tr '-' '_' > "$OV/a52/rh/wlan.name"
[ -s "$OV/a52/rh/wlan.name" ] || fail "no module name in qca_cld3_wlan.ko"
# libmodprobe dry run (tools/modprobesim.py) of what the ROM's loaders will read: first-stage init
# (modules.load), the rc's modprobe line, and 5.4-gki (must resolve nothing: macloader loads wlan)
MPS="python3 -I $HERE/tools/modprobesim.py"
$MPS --label first-stage --dir "$VR/lib/modules" --as /lib/modules --load-file modules.load > "$W/mps.txt" || { cat "$W/mps.txt"; fail "libmodprobe dry run: first stage"; }
$MPS --label "vendor rc" --dir "$OV/a52/addon/vendor/lib/modules/$V" --as /vendor/lib/modules/$V --modules $AUD >> "$W/mps.txt" || { cat "$W/mps.txt"; fail "libmodprobe dry run: the rc's modprobe line would not load the audio set"; }
$MPS --dir "$OV/a52/addon/vendor/lib/modules/$WLD" --as /vendor/lib/modules/5.4-gki --modules qca_cld3_wlan > /dev/null 2>&1 && fail "libmodprobe would load wlan from 5.4-gki (races macloader): $RB predates the rb3/rb618-2 fix"
grep -q -- "modprobe -s -a -d /vendor/lib/modules/$V " "$OV/a52/addon/vendor/etc/init/a52sxq-$K.rc" || fail "the rc's modprobe has no -s (errors would be invisible): $RB predates the fix"
else
	AUD=$(sed 's/\.ko$//' "$RB/work/plan/addon-late.load" | tr '\n' ' ')
	echo "$AUD" | tr ' ' '\n' | grep . > "$OV/a52/rh/audio.list"
	: > "$OV/a52/rh/audio.names"
	for m in $AUD; do f="$VR/lib/modules/$m.ko"; [ -f "$f" ] || fail "addon=vendor_boot: $m.ko not in the vendor ramdisk"; modname "$f" | tr '-' '_' >> "$OV/a52/rh/audio.names"; done
	modname "$VR/lib/modules/wlan.ko" | tr '-' '_' > "$OV/a52/rh/wlan.name"
	NAL=$(sed -n 's/.* async_last=\([^ ]*\).*/\1/p' "$RB/BUILDINFO" | tr '+' ' ' | wc -w)   # ASYNC_LAST modules follow wlan.ko
	[ "$(head -n -"$NAL" "$VR/lib/modules/modules.load" | tail -n1)" = wlan.ko ] || fail "addon=vendor_boot: wlan.ko not last in modules.load (before ASYNC_LAST)"
	MPS="python3 -I $HERE/tools/modprobesim.py"
	$MPS --label first-stage --dir "$VR/lib/modules" --as /lib/modules --load-file modules.load > "$W/mps.txt" || { cat "$W/mps.txt"; fail "libmodprobe dry run: first stage"; }
	grep -qE '^options a52sxq_dsp_boot rescan_after_adsp=1 hold_until_adsp=qcom,adsp-notify\+qcom,msm-audio-apr\+qcom,audio-ref-clk\+qcom,msm-cdc-pinctrl\+qcom,q6core-audio\+qcom,adsp-loader hold_late=qcom,wcd938x-codec( hold_release_ms=[0-9]+)?$' "$VR/lib/modules/modules.options" || fail "addon=vendor_boot: no rescan_after_adsp in modules.options"
	cp "$TOP/tools/tone/tone.dex" "$OV/a52/rh/tone.dex"
fi
FWPATH=$(sed -n 's/.*firmware_class\.path=\([^ ]*\).*/\1/p' "$RB/vendor-cmdline.txt")
[ -n "$FWPATH" ] || fail "no firmware_class.path in $RB/vendor-cmdline.txt"
printf 'V=%s\nK=%s\nKREL=%s\nRBNAME=%s\nNFIRST=%s\nMODEM=%s\nFWPATH=%s\nWLD=%s\nSD=%s\nDCVS=%s\nADDON=%s\n' "$V" "$K" "$KREL" "$RBNAME" "$(grep -c . "$RB/first-stage.modules.load")" "$RBMODEM" "$FWPATH" "$WLD" "$RH_SD" "$RBDCVS" "$RBADDON" > "$OV/a52/rh/env"
( cd "$OV" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) > "$W/4-overlay.cpio"
cat "$W/1-boot.cpio" "$W/2-tools.cpio" "$W/3-vendor.cpio" "$W/4-overlay.cpio" | gzip -6 > "$O/rd.cpio.gz"

# ---- ramdisk checks on the unpacked result (later archives replace earlier files, like the kernel)
F=$W/final; python3 -I "$HERE/tools/cpiox.py" "$O/rd.cpio.gz" "$F" > "$W/final.txt"
cmp -s "$F/init" "$OV/init" || fail "/init is not a52init"
cmp -s "$F/init.android" "$W/rom/init" || fail "/init.android is not the ROM's init"
for f in first_stage_ramdisk/fstab.qcom fstab.qcom; do cmp -s "$F/$f" "$AB/out/los1/fstab.first" || fail "/$f is not the logical-only test fstab"; done
cmp -s "$F/lib/modules/modules.load" "$RB/first-stage.modules.load" || fail "/lib/modules/modules.load"
grep -qx 'options sec_battery async_probe=1' "$F/lib/modules/modules.options" || fail "modules.options lacks sec_battery async_probe=1"
diff <(cd "$VR/lib/modules" && ls) <(cd "$F/lib/modules" && ls | grep -vx hhwdt.ko) > /dev/null || fail "/lib/modules is not exactly the vendor_boot set + hhwdt.ko"
for f in "$VR"/lib/modules/*; do cmp -s "$f" "$F/lib/modules/${f##*/}" || fail "${f##*/} differs from the vendor ramdisk"; done
[ -n "$(find "$F" \( -iname '*.mdt' -o -iname '*.mbn' -o -iregex '.*\.b[0-9][0-9]' \))" ] && fail "firmware image in the ramdisk: refused (2026-11-13 rule)"
for k in $(find "$F" -name '*.ko'); do vermagic "$k"; done
# SD/MMC host driver (phone 1 has a microSD = mmcblk1 that nothing may format): the Qualcomm SDHC
# driver is a module and never built in (mmc_core/mmc_block/sdhci/sdhci-pltfm built in bind nothing
# without it). SDCARD=0 builds: in no set, blocklisted. SDCARD=1 builds: cqhci + sdhci-msm in the
# first stage only (never in the add-on), not blocklisted; RH_SD=off refuses sdhci_msm by the test word
# module_blacklist=sdhci_msm (below), so the rehearsal never sees a card.
[ -f "$KDIST/lib/modules/$KREL/modules.builtin" ] || fail "no $KDIST/lib/modules/$KREL/modules.builtin"
grep -q 'sdhci-msm\|sdhci_msm\|cqhci' "$KDIST/lib/modules/$KREL/modules.builtin" && fail "sdhci-msm/cqhci built into $KREL"
[ -n "$(find "$OV/a52/addon" \( -name 'sdhci*.ko' -o -name 'cqhci*.ko' -o -name 'mmc*.ko' \))" ] && fail "SD/MMC module in the add-on"
if [ "$RBSD" = 1 ]; then
	[ "$(cd "$F/lib/modules" && ls | grep -E '^(sdhci|cqhci|mmc).*\.ko$' | tr '\n' ' ')" = "cqhci.ko sdhci-msm.ko " ] || fail "SDCARD=1 build: expected exactly cqhci.ko + sdhci-msm.ko in /lib/modules"
	grep -qx 'blocklist sdhci-msm' "$F/lib/modules/modules.blocklist" && fail "SDCARD=1 build but sdhci-msm blocklisted"
else
	[ -n "$(find "$F" \( -name 'sdhci*.ko' -o -name 'cqhci*.ko' -o -name 'mmc*.ko' \))" ] && fail "SD/MMC module in the rehearsal ramdisk"
	grep -qx 'blocklist sdhci-msm' "$F/lib/modules/modules.blocklist" || fail "sdhci-msm not blocklisted in the vendor_boot modules"
fi
[ -f "$F/force_debuggable" ] && grep -q "^ro.bpf.kver_override=${KREL%%-*}$" "$F/adb_debug.prop" && grep -qx "ro.adb.secure=0" "$F/adb_debug.prop" || fail "/adb_debug.prop (test version must win)"
SZ=$(du -scb "$F/lib" "$F/a52" "$F/bin" "$F/usr" | tail -1 | cut -f1)
[ "$SZ" -lt 360000000 ] || fail "helper root ~$((SZ / 1048576)) MiB > the 400 MiB tmpfs budget"
say "libmodprobe dry run: $(sed -n 's/^modprobe dry run \([^(]*\)(.*: \([0-9/]*\) requested.*/\1\2/p' "$W/mps.txt" | tr '\n' ';') 5.4-gki: nothing (macloader only)"
[ "$RBMODEM" = 1 ] && say "MODEM=1: EFS RAM shim with efsdump ($(sha256sum < "$EFSDUMP" | cut -c1-16)), modem rollback guard, $(grep -c . "$RB/modem-devnodes.txt") /dev owner checks (modem-devnodes.txt)"
say "ramdisk: $(stat -c %s "$O/rd.cpio.gz") bytes gz; /lib/modules = vendor_boot's $(grep -c . "$RB/first-stage.modules.load")-module set + hhwdt.ko (cmp OK); test fstab wins over the ROM's first_stage_ramdisk/fstab.qcom; add-on = $RB/vendor-addon.SHA256SUMS; vermagic $KREL; no firmware; $( [ "$RBSD" = 1 ] && echo "SD host cqhci + sdhci-msm in the first stage (RH_SD=$RH_SD)" || echo "no SD host driver (sdhci-msm blocklisted, not built in)"); Wi-Fi dir $WLD$( [ "$WLD" != 5.4-gki ] && echo " (bound over 5.4-gki on post-fs)"); helper root ~$((SZ / 1048576)) MiB"

# ---- device tree: vendor_boot dtb + the realboot dtbo (what the ABL merges); 6.18 + a52ram
fdtoverlay -i "$RB/work/chk-vb/dtb" -o "$O/rh-base.dtb" "$RB/realboot.dtbo"
[ "$(fdtget "$O/rh-base.dtb" /soc a52sxq,realboot)" = "$RBNAME" ] || fail "realboot dtbo marker not applied"
[ "$(fdtget -t x "$O/rh-base.dtb" /soc/ssusb@a600000 extcon | wc -w)" = 2 ] || fail "dwc3 does not have the two-entry real extcon"
fdtget -t x "$O/rh-base.dtb" /reserved-memory/ramoops@F0B00000 reg | grep -qx "0 f0b00000 0 e0000" || fail "ramoops is not 0xf0b00000+0xe0000 (harness crash guard)"
[ -n "$(fdtget -l "$O/rh-base.dtb" /reserved-memory | grep -i '^rmtfs\|^kexec-live')" ] && fail "base already reserves rmtfs: the carry-over check below would be meaningless"
if [ "$KV" = 618 ]; then
	N=/reserved-memory/a52ram@f0be0000
	fdtput -c "$O/rh-base.dtb" $N; fdtput -t s "$O/rh-base.dtb" $N compatible "a52,ramcon"
	fdtput -t x "$O/rh-base.dtb" $N reg 0 0xf0be0000 0 0x20000; fdtput -t s "$O/rh-base.dtb" $N no-map ""
fi
say "dtb: $RB vendor_boot dtb + realboot.dtbo (fdtoverlay), dwc3 extcon = $(fdtget -t x "$O/rh-base.dtb" /soc/ssusb@a600000 extcon) (real), no rmtfs node$( [ "$KV" = 618 ] && echo ', + a52ram@f0be0000 for earlycon (kexec-only)')"
LIVE=${LIVE:-$(ls -t "$TOP"/logs/kx-*-p$PHONE-[0-9][0-9][0-9][0-9][0-9][0-9]/harness-live.dtb 2>/dev/null | head -1 || true)}
if [ -n "$LIVE" ] && [ -f "$LIVE" ]; then
	( cd "$TOP" && python3 kexec/mkkexecdtb.py --base "$O/rh-base.dtb" --live "$LIVE" -o "$W/sim-kexec.dtb" ) > "$O/mkkexecdtb-sim.txt" 2>&1 || fail "mkkexecdtb.py on the rehearsal base failed ($O/mkkexecdtb-sim.txt)"
	grep -q '^3b\. /reserved-memory/kexec-live-rmtfs' "$O/mkkexecdtb-sim.txt" || fail "gen would NOT carry rmtfs over (SIGBUS risk): $O/mkkexecdtb-sim.txt"
	grep -q '^check: 0xf0b00000' "$O/mkkexecdtb-sim.txt" || fail "gen result does not reserve the harness ramoops"
	grep -q '^WARNING' "$O/mkkexecdtb-sim.txt" && say "  mkkexecdtb warnings: $(grep '^WARNING' "$O/mkkexecdtb-sim.txt" | tr '\n' ' ')"
	say "gen check (mkkexecdtb.py with $LIVE): $(grep '^3b\.' "$O/mkkexecdtb-sim.txt" | cut -d: -f1-2); memory, /hypervisor, uh regions, watchdog status copied as in every run"
	T=$(ls -t "$TOP"/logs/$TESTED/kexec.dtb 2>/dev/null | head -1 || true)
	if [ -n "$T" ]; then
		diff <(dtc -q -I dtb -O dts -s "$T") <(dtc -q -I dtb -O dts -s "$W/sim-kexec.dtb") > "$O/kexec-dtb-vs-tested.diff" || true
		say "vs the tested kexec tree $T: $(grep -c '^[<>]' "$O/kexec-dtb-vs-tested.diff") changed lines (kexec-dtb-vs-tested.diff: expect extcon, realboot marker, /chosen bootargs, memory)"
	fi
else
	say "WARNING: no phone-$PHONE harness-live.dtb in logs/: the rmtfs carry-over of gen was NOT checked offline"
fi

# ---- command line: kernel's CONFIG_CMDLINE is prepended by the kernel itself; we pass
#      DT bootargs + vendor_boot cmdline + bootloader part (as on a real boot) + test words
CFG=$(sed -n 's/^CONFIG_CMDLINE (prepended): //p' "$RB/REPORT.txt")
[ -n "$CFG" ] || fail "no CONFIG_CMDLINE in $RB/REPORT.txt"
DTB_ARGS=$(cat "$RB/dt-bootargs.txt"); VC=$(cat "$RB/vendor-cmdline.txt")
PRED=$(sed -n '/^== predicted \/proc\/cmdline/{n;p;q}' "$RB/cmdline-predicted-4096.txt")
case "$PRED" in "$CFG $DTB_ARGS $VC "*) ABL=${PRED#"$CFG $DTB_ARGS $VC "};; *) fail "predicted cmdline does not start with CONFIG_CMDLINE + DT bootargs + vendor cmdline";; esac
if [ "$RH_ABL" = min ]; then
	T612=$(cat "$( [ "$KV" = 618 ] && echo "$TOP/bsp618/android/android-cmdline-618.txt" || echo "$AB/out/android-cmdline.txt")")
	ABL="$(for w in $T612; do case "$w" in androidboot.*) case " $VC " in *" ${w%%=*}="*) ;; *) echo "$w";; esac;; esac; done | grep -v 'androidboot.selinux' | tr '\n' ' ')"
	ABL="$ABL $(for w in $PRED; do case "$w" in msm_drm.*|sec_common_fn.*|androidboot.force_normal_boot=*) echo "$w";; esac; done | tr '\n' ' ')"
fi
# the ABL part was measured on phone $RBPHONE: re-target it when rehearsing on the other phone
if [ "$PHONE" != "$RBPHONE" ]; then
	phone_vars "$RBPHONE"
	SRC_LIVE=${SRC_LIVE:-$(ls -t "$TOP"/logs/kx-*-p$RBPHONE-[0-9][0-9][0-9][0-9][0-9][0-9]/harness-live.dtb 2>/dev/null | head -1 || true)}
	[ -n "$SRC_LIVE" ] && [ -f "$SRC_LIVE" ] || fail "no phone-$RBPHONE harness-live.dtb in logs/ (SRC_LIVE=): cannot re-target the ABL part"
	[ -n "$LIVE" ] && [ -f "$LIVE" ] || fail "no phone-$PHONE harness-live.dtb in logs/ (LIVE=): cannot re-target the ABL part"
	printf '%s\n' "$ABL" > "$W/abl-src.txt"
	NL=(); ND=$TOP/testdev-$S
	if [ "$RH_ABL" = full ] && [ -f "$ND/live.dtb" ] && [ -f "$ND/vendor_boot.img" ]; then
		# that boot's ROM: its dtb /chosen/bootargs + vendor cmdline come before the ABL's words
		unpack_bootimg --boot_img "$ND/vendor_boot.img" --out "$W/nvb" > "$W/nvb.info"
		python3 -I - "$W/nvb/dtb" "$W/nvb-base.dtb" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read(); i = 0; last = None
while i < len(d):
    assert d[i:i + 4] == b'\xd0\x0d\xfe\xed'; n = struct.unpack('>I', d[i + 4:i + 8])[0]; last = d[i:i + n]; i += n
open(sys.argv[2], 'wb').write(last)
EOF
		printf '%s %s\n' "$(fdtget "$W/nvb-base.dtb" /chosen bootargs)" "$(sed -n 's/^vendor command line args: //p' "$W/nvb.info")" > "$W/nvb-prefix.txt"
		NL=(--normal-live "$ND/live.dtb" --normal-prefix "$W/nvb-prefix.txt")
	fi
	python3 -I "$HERE/tools/abl-retarget.py" --abl "$W/abl-src.txt" --src-harness "$SRC_LIVE" --dst-harness "$LIVE" \
		--expect "androidboot.serialno=$S" --expect "androidboot.bootloader=$BL" --expect "androidboot.revision=$HWREV" \
		"${NL[@]}" -o "$W/abl-dst.txt" > "$O/abl-retarget.txt" 2>&1 || { cat "$O/abl-retarget.txt"; fail "ABL re-targeting phone $RBPHONE -> phone $PHONE"; }
	ABL=$(cat "$W/abl-dst.txt")
	say "ABL part re-targeted phone $RBPHONE ($PS) -> phone $PHONE ($S) from the two harness live trees ($SRC_LIVE, $LIVE): $(grep -c '^retarget:' "$O/abl-retarget.txt") words (abl-retarget.txt)"
	say "  $(grep '^retarget:' "$O/abl-retarget.txt" | sed 's/^retarget: //' | tr '\n' ';')"
	grep -q '^cross-check' "$O/abl-retarget.txt" && say "  $(grep '^cross-check' "$O/abl-retarget.txt")" \
		|| say "  WARNING: not cross-checked against a normal boot of phone $PHONE (RH_ABL=min, or no testdev-$S/live.dtb + vendor_boot.img)"
	phone_vars "$PHONE"
fi
for w in "androidboot.serialno=$S" "androidboot.bootloader=$BL" "androidboot.revision=$HWREV"; do
	case " $ABL " in *" $w "*) ;; *) fail "bootloader part lacks $w (phone $PHONE)";; esac; done
TESTW="loglevel=7 log_buf_len=4M a52.deadman=$DEADMAN a52.net=$NET a52.androidtest=1 androidboot.selinux=permissive"
[ "$RH_SD" = off ] && TESTW="$TESTW module_blacklist=sdhci_msm"
[ "$KV" = 618 ] && TESTW="$TESTW earlycon=a52ram,0xf0be0000"
CMD=$(echo "$DTB_ARGS $VC $ABL $TESTW" | tr -s ' ')
[ "$RBADDON" = vendor ] && GATE="androidboot.a52sxq.$K=1" || GATE="androidboot.a52sxq.${K}vb=1"
[ "$RBADDON" = vendor ] || case " $CMD " in *" androidboot.a52sxq.$K=1 "*) fail "addon=vendor_boot cmdline sets the old add-on gate";; esac
for w in "$GATE" firmware_class.path=/vendor/firmware_mnt/image,/vendor/firmware android_arch_task_struct_size=512 \
         androidboot.first_stage_console=2 androidboot.serialno=$S msm_drm.dsi_display0= msm_drm.lcd_id= a52.androidtest=1; do
	case " $CMD " in *" $w"*) ;; *) fail "cmdline lacks $w";; esac; done
[ "$(echo " $CMD " | grep -o ' firmware_class.path=' | wc -l)" = 1 ] || fail "two firmware_class.path"
case " $CMD " in *force_sysfs_fallback*|*" a52.mods="*) fail "test-only word in the cmdline";; esac
LEN=$(( ${#CFG} + 1 + ${#CMD} + ${#NAME} + 13 ))
[ $LEN -lt 4000 ] || fail "cmdline would be $LEN bytes (COMMAND_LINE_SIZE 4096)"
printf '%s\n' "$CMD" > "$O/cmdline.txt"
( cd "$O" && tar czf pack.tgz cmdline.txt )
say "cmdline ($RH_ABL bootloader part): ${#CMD} bytes passed, /proc/cmdline ~$LEN of 4095 (CONFIG_CMDLINE + DT bootargs + vendor_boot cmdline + ABL + test words + a52.kexeced)"
say "  test words: $TESTW"
# kexec-run reads "-" = the harness's /proc/cmdline: HARNESS_EXTRA binds cmdline.txt over it, so the
# 3.5 KB string never goes through the telnet line; if that does not work, it hides the Image so
# /kx fails to load and kx-cycle goes back to Android without jumping.
cat > "$O/harness-extra.sh" <<'EOF'
B=/bin/busybox; $B mkdir -p /tmp/rh && $B tar xzf /mnt/a52kx/pack.tgz -C /tmp/rh && $B mount -o bind /tmp/rh/cmdline.txt /proc/cmdline && [ "$($B cat /proc/cmdline)" = "$($B cat /tmp/rh/cmdline.txt)" ] && echo RH_CMDLINE_OK || { echo RH_CMDLINE_BAD; : > /tmp/rh/empty; $B mount -o bind /tmp/rh/empty /mnt/a52kx/Image; }
EOF
[ $((DEADMAN + 90)) -lt $((KXW + 300)) ] || say "WARNING: DEADMAN $DEADMAN + LineageOS boot > KX_WAIT $KXW + 300: kx-cycle may give up before the phone is back by itself"
[ -n "$BCF" ] && say "WARNING: NOT COVERED: the helper loads the module prefix (up to zram) itself, sequentially; this rehearsal does NOT test parallel loading of those modules (flash-rb.sh refuses MODLOAD builds)"
[ -n "$BCF" ] && { cat "$BCF" >> "$O/rd.cpio.gz"; say "bootconfig trailer appended to rd.cpio.gz ($(tr -d '\0' < "$BCF" | head -1))"; }
sha256sum "$O/Image" "$O/rd.cpio.gz" "$O/rh-base.dtb" "$O/pack.tgz" | sed "s#$O/##" > "$O/SHA256SUMS"

D=${O#"$TOP"/}
KXCMD="cd $TOP && D=$D; PHONE=$PHONE HARNESS_IMG=$HIMG KEXEC_BASE=\$D/rh-base.dtb KEXEC_OVERLAY=none KX_PACK=\$D/pack.tgz HARNESS_EXTRA=\"\$(cat \$D/harness-extra.sh)\" KX_HOLD=1 KX_WAIT=$KXW kexec/kx-cycle.sh $NAME \$D/Image \$D/rd.cpio.gz gen -"
MODEM_CHECKS=
[ "$RBMODEM" = 1 ] && MODEM_CHECKS='  efs             (MODEM=1) "rh: efs: 4 of 4" RAM copies bound before init started vendor.rmt_storage; at the end
                  efsdump verify: "all 4 partitions unchanged"; bytes the modem changed in the copies (INFO)
  modem           rollback guard (modem = adsp), MSS remoteproc running, subsys modem ONLINE, no DOG stall / SSR,
                  rmt_storage, tftp_server, pd_mapper, qrtr-ns, per_mgr, ipacm, ril-daemon running; IPA FW loaded,
                  rmnet_ipa0; /dev owners = modem-devnodes.txt (ROM ueventd); voice/data IN_SERVICE (waits 120 s);
                  rmnet_data* with an IPv4 address and a ping through it (needs mobile data on)
'
cat > "$O/HOWTO.txt" <<EOF
Real-boot rehearsal $NAME ($RBNAME, $V) on phone $PHONE ($S, USB $UPORT, ABL $BL) by kexec. Nothing is flashed.
$( [ "$PHONE" = 1 ] && printf '%s\n' "Phone 1: LineageOS has no su: kx-cycle/test-cycle use adb root, so \"Rooted debugging\" must be ON in its" \
"Developer options (USB debugging alone is not enough)." \
"$(case "$RH_SD" in none) echo "Its microSD (mmcblk1) is never touched: no SD host driver is in this kernel's module set (sdhci-msm blocklisted, not built in).";;
off) echo "Its microSD (mmcblk1) is never touched: this build has sdhci-msm in the first stage, the rehearsal cmdline refuses it (module_blacklist=sdhci_msm; RH_SD=on would let vold mount the inserted card, as the real boot does)";;
on) echo "RH_SD=on: sdhci-msm probes and vold MOUNTS the inserted microSD (exFAT, as on the real 6.12 boot rb16; nothing formats it). Explicit OK for that first.";; esac)" \
"$( [ "$RBMODEM" = 1 ] && echo "MODEM=1: its OWN modem boots under the ROM's radio userspace; the EFS (modemst1/2, fsg, fsc) is served from RAM copies (testguard keeps the partitions read-only; efsdump verify at the end), the modem only boots if its anti-rollback version equals the ADSP image's. Registration/data need the SIM (PIN lock off) and mobile data on (fresh zram /data = defaults)." || echo "Its modem stays off in this tree (MODEM=0)." )" )

1. run (about 3 min; KX_HOLD leaves the test boot up until the dead-man at ${DEADMAN} s):
   $KXCMD
   harness-extra.txt in the log dir must say RH_CMDLINE_OK.
2. results (the helper runs the checks itself ~20 s after boot_completed):
   adb -s $S shell dmesg | grep -E 'a52rh:|a52sxq-init: rh:'
   or TSH_IP=$TSHIP tools/tsh.py -t 10 'cat /tmp/rh-checks.txt'
   last line: "a52rh: SUMMARY $RBNAME: pass=N fail=M"
3. end: TSH_IP=$TSHIP tools/tsh.py /leave; PHONE=$PHONE kexec/kx-finish.sh $NAME
   (or let the dead-man do it: ${DEADMAN} s after the kexec the helper restarts the phone; sec_core is
   loaded, so the bootloader boots phone $PHONE's own LineageOS directly)
   Afterwards, in LineageOS (read-only, as root): adb -s $S shell cat /sys/fs/pstore/console-ramoops-0 | grep -E 'a52rh:|rh:' 

Pass checks (a52rh: PASS/FAIL lines):
  boot_completed  sys.boot_completed=1; uname = $KREL
  first-stage     all $(grep -c . "$RB/first-stage.modules.load") modules of the vendor_boot modules.load loaded, init's "Loaded N modules", no init insmod errors
  dsp_boot        a52sxq-dsp-boot "adsp: booted after N attempt(s)", "adsp running: /sys/kernel/a52sxq_dsp/adsp_running",
                  cdsp booted; /sys/kernel/a52sxq_dsp/{adsp,cdsp}_running; remoteproc adsp + cdsp "running"
  usb             dtb extcon has 2 entries; helper "rh: PASS usb: gadget ... configured ... (role from the real extcon)"
                  with no fallback; adbd running, sys.usb.state has adb
  usb-android     Android bound g1 by itself after the UDC appeared (init re-triggered by adbd's 1 s FUNCTIONFS_BIND
                  retry: the only binder on a real boot); the helper waits a52.rhwait=10 s for it, our NCM pre-linked
  firmware        firmware_class path = /vendor/firmware_mnt/image,/vendor/firmware; no request needed the sysfs fallback
                  (force_sysfs_fallback=1 is the ROM's own init.qti.kernel.rc, INFO); WPSS running; no GPU firmware error;
                  kgsl-3d0, video32 (load errors of adsp/cdsp before the mount, regulatory.db, panel .dat, touch .bin = INFO)
  sec_battery     loaded by first-stage init; next module < 5 s later; battery psy capacity > 0 (dumpsys battery)
$MODEM_CHECKS  addon           ro.boot.a52sxq.$K=1; RAM overlay on /vendor/etc/init + /vendor/lib/modules (no helper fallback);
                  the rc's "modprobe -s -a -d /vendor/lib/modules/$V ..." exited with status 0 (its messages: dmesg | grep 'modprobe: ');
                  all $(wc -l < "$OV/a52/rh/audio.list") audio modules loaded; sound card in /proc/asound/cards;
                  wlan module "$(cat "$OV/a52/rh/wlan.name")" loaded via 5.4-gki/qca_cld3_wlan.ko; wlan0 present$( [ "$WLD" != 5.4-gki ] && printf '\n                  %s' "wlan-bind: /vendor/lib/modules/$WLD bound over /vendor/lib/modules/5.4-gki by the rc (on post-fs)")
$( [ "$RBDCVS" = 1 ] && printf '%s\n' "  dcvs            kgsl devfreq governor msm-adreno-tz; bwmon (bus_dcvs/DDR/9091000.qcom,bwmon-ddr) and memlat" "                  (memlat_settings) probed, no memlat -517; the rc's boost_freq writes applied (DDR boost < hw max);" "                  no interconnect provider left with sync_state pending (INFO: ebi/qns_llcc peak if debugfs)")
$(case "$RH_SD" in on) echo "  sd              sdhci_msm loaded, 8804000.sdhci bound to sdhci_msm; mmcblk/vold volumes INFO (never formatted)";;
off) echo "  sd              sdhci_msm refused by module_blacklist (RH_SD=off), no mmcblk device, other first-stage modules all loaded";; esac)

USB: the UDC appears ~10 s after usb_notifier probes (Samsung booting delay), after init's first g1 bind
failed. The helper pre-links its NCM function into g1, waits a52.rhwait=10 s for Android to bind g1 by
itself (usb-android check), binds it itself only if Android does not, and repairs lost states every 3 s
("rh: usb: now ..." on each change). "rh: usbdiag" lines (UDC, g1/a52 binding, NCM + IP, dwc3 mode,
role, glue/extcon, adbd, sys.usb.*, last changes) go to the kernel log every 10 s for 3 min, then every
30 s, and once at the dead-man.
If telnet does not come up but adb does, kx-cycle now says "ADB ONLY" and saves dmesg/logcat/getprop over
adb (kexeced-*.txt; KX_HOLD leaves it running). If nothing answers: kx-cycle prints "nothing came back"
after KX_WAIT=$KXW s, saves the logs of any kexec'd Android it then finds on adb before restarting it
(before-reboot-*.txt), and once the phone is back in its own LineageOS it reads pstore by itself
(pstore-console-ramoops-0.txt in the log dir). At ${DEADMAN} s after the kexec the helper's dead-man
restarts the phone (sec_core: the bootloader boots phone $PHONE's own LineageOS); a hang panics
(hung_task/softlockup/oops) and comes back through the harness or LineageOS. A bound gadget that the
host never configures gets mode=peripheral once 60 s (a52.rhusb=) after the UDC appeared.
AFTER A FAILED REHEARSAL READ PSTORE FIRST, before any other reboot or kx-cycle (the next boot replaces it):
   adb -s $S root; adb -s $S shell cat /sys/fs/pstore/console-ramoops-0 > logs/$NAME-pstore.txt
   grep -E 'usbdiag|rh: (usb|PASS|FAIL)|a52rh:|dead-man|panic' logs/$NAME-pstore.txt | tail -40
The console record keeps only the last 256 KiB (about the last 20-40 s at loglevel 7), hence the
periodic usbdiag lines with the recent state changes in hist=[...]. userdata is never mounted
(testguard + zram /data in every case).
EOF
say ""
say "kx-cycle (phone $PHONE = $S, explicit OK for the run; nothing flashed):"
say "  $KXCMD"
say "results: adb -s $S shell dmesg | grep -E 'a52rh:|a52sxq-init: rh:'   (checks list + USB-failure behaviour: $O/HOWTO.txt)"
say "end:     TSH_IP=$TSHIP tools/tsh.py /leave; PHONE=$PHONE kexec/kx-finish.sh $NAME"
if [ "${RUN:-0}" = 1 ]; then cd "$TOP"; D=$D; PHONE=$PHONE HARNESS_IMG=$HIMG \
	KEXEC_BASE=$D/rh-base.dtb KEXEC_OVERLAY=none KX_PACK=$D/pack.tgz HARNESS_EXTRA="$(cat "$D/harness-extra.sh")" \
	KX_HOLD=1 KX_WAIT=$KXW exec kexec/kx-cycle.sh "$NAME" "$D/Image" "$D/rd.cpio.gz" gen -; fi
