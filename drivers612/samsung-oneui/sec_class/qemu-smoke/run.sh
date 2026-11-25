#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of a52sxq_sec_class.ko after the ramdisk's
# sec_core.ko. QEMU has no hall, no 8804000.sdhci, no qcom,qfprom: fakehall.ko (input "hall", SW_LID) stands in
# for the 6.12 gpio-keys hall; the SD nodes give their no-card answers, msm_feature_id its no-map answer.
# Checks: load rc 0, 12 devices under /sys/devices/virtual/sec, attribute set + modes = 5.4, read formats,
# hall OPEN/CLOSE/FCNT, store semantics, init-style chown, rmmod clean, reload, no WARN/BUG.
#   drivers612/samsung-oneui/sec_class/qemu-smoke/run.sh [sec_core.ko]   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); V=$(cd "$Q/.." && pwd); S=$(cd "$V/.." && pwd); TOP=$(cd "$S/../.." && pwd)
SEC=${1:-/tmp/claude-1000/-home-a52sxq-kernel/d4b12d88-589d-46e3-9702-c5a044916aae/scratchpad/s99o/lib/modules/sec_core.ko}
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
EXTRA_SYMVERS="$V/sec_core.symvers" "$S/build.sh" "$V" >/dev/null
"$S/build.sh" "$Q/fakehall" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$V/out/a52sxq_sec_class.ko" "$Q/fakehall/out/fakehall.ko" "$WORK/rd/"; cp "$S/a52sxq_core/out-flavor/a52sxq.ko" "$WORK/rd/"; cp "$SEC" "$WORK/rd/sec_core.ko"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 2G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
tr -d "\r" < "$WORK/console.txt" > "$WORK/console.lf"; C=$WORK/console.lf; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: secclass rc=0" "module loads, rc 0"
for d in hall_ic msm_dwc3 pcie-wifi sdcard sddata sdinfo sec_abc sec_abc_hub sec_misc sec_nad sec_sysup typec_manager; do
	chk "SMK: dir $d /sys/devices/virtual/sec/$d\$" "$d at /sys/devices/virtual/sec/$d"
done
m() { chk "SMK: ls $1 $2 0:0 $3\$" "$1/$3 $2"; }
m hall_ic -r--r--r-- hall_detect; m hall_ic -r--r--r-- hall_count; m hall_ic -r--r--r-- hall_number; m hall_ic -r--r--r-- debounce
m pcie-wifi -rw-rw-r-- pcie_l1ss_ctrl
for a in status cd_cnt max_mode current_mode current_phase sdcard_summary; do m sdcard -r--r--r-- $a; done
m sddata -r--r--r-- sd_data; for a in sd_count data fc; do m sdinfo -r--r--r-- $a; done
for a in enabled spec features; do m sec_abc -rw-r--r-- $a; done
for a in enable bootc_offset bootc_time; do m sec_abc_hub -rw-r--r-- $a; done
m sec_misc -r--r--r-- msm_feature_id; m sec_nad -r--r--r-- quest_fv_flashed
m sec_sysup --w--w---- edtbo_update; m sec_sysup -r--r----- edtbo_version
chk "SMK: val hall_ic/hall_detect=\[OPEN\|\]" "hall_detect OPEN (fake lid 0)"
chk "SMK: val hall_ic/hall_number=\[1\|\]" "hall_number 1"
chk "SMK: val hall_ic/debounce=\[50\|\]" "debounce 50 (no DT: 5.4 default)"
chk "SMK: val hall_ic/hall_count=\[\"FCNT\":\"0\"\]" "hall_count \"FCNT\":\"0\" (initial state not counted, no newline)"
chk "SMK: hall1=\[CLOSE\|\]" "SW_LID 1 -> CLOSE"
chk "SMK: hall2=\[OPEN\|\]" "SW_LID 0 -> OPEN"
chk "SMK: count=\[\"FCNT\":\"3\"\] count-after-read=\[\"FCNT\":\"0\"\]" "3 changes counted, cleared by read"
chk "SMK: val pcie-wifi/pcie_l1ss_ctrl=\[RC0 link is not enabled.\|\]" "pcie_l1ss_ctrl stub text"
chk "SMK: val sdcard/status=\[Remove\|\]" "status Remove (no host)"
chk "SMK: val sdcard/cd_cnt=\[0\|\]" "cd_cnt 0"
chk "SMK: val sdcard/max_mode=\[HS\|\]" "max_mode HS (no host caps)"
chk "SMK: val sdcard/current_mode=\[No Card\|\]" "current_mode No Card"
chk "SMK: val sdcard/current_phase=\[-1\|\]" "current_phase -1"
chk 'SMK: val sdcard/sdcard_summary=\["MANID":"NoCard","SERIAL":"NoCard","SIZE":"NoCard","SPEEDMODE":"NoCard","NOTI":"NoCard"\|\]' "sdcard_summary no-card JSON"
chk 'SMK: val sddata/sd_data=\["GE":"0","CC":"0","ECC":"0","WP":"0","OOR":"0","CRC":"0","TMO":"0"\|\]' "sd_data zero JSON"
chk "SMK: val sdinfo/sd_count=\[no card\|\]" "sd_count no card"
chk "SMK: val sdinfo/data=\[no card\|\]" "data no card"
chk "SMK: val sdinfo/fc=\[NOCARD\|\]" "fc NOCARD"
chk "SMK: val sec_abc/enabled=\[0\|\]" "abc enabled 0"
chk "SMK: val sec_abc/spec=\[spec type1\|\]" "abc spec header"
chk "SMK: val sec_abc/features=\[spec_control\|host\|\]" "abc features"
chk "SMK: val sec_abc_hub/enable=\[0\|\]" "hub enable 0"
chk "SMK: val sec_abc_hub/bootc_offset=\[fsck,0\|\]" "bootc_offset fsck,0"
chk "SMK: val sec_abc_hub/bootc_time=\[-1\|\]" "bootc_time -1"
chk "SMK: val sec_misc/msm_feature_id=\[could not map FEATURE_ID address\|\]" "msm_feature_id: no qfprom node -> no read"
chk "SMK: val sec_nad/quest_fv_flashed=\[0\|\]" "quest_fv_flashed 0"
chk "SMK: val sec_sysup/edtbo_version=\[0\|\]" "edtbo_version 0 (no androidboot.edtbo)"
chk "SMK: uevent a52ue: .*kobj=\"hall_ic\" act=0x2 env0=\"hall=close\"" "KOBJ_CHANGE hall=close on the sec device (5.4 hall_ic_work)"
chk "SMK: uevent a52ue: .*kobj=\"hall_ic\" act=0x2 env0=\"hall=open\"" "KOBJ_CHANGE hall=open"
chk "SMK: pcie write rc=0" "pcie write accepted"; chk "SMK: pcie bogus write rc=0" "pcie bad write accepted (5.4)"
chk "SMK: abc en1 rc=0 -> 1\|" "abc enabled 1"; chk "SMK: abc en0 rc=0 -> 0\|" "abc enabled 0"
chk "SMK: abc labo rc=0 -> 1\|" "abc ALL_REPORT=1,PRE_EVENT=0"; chk "SMK: abc bogus rc=0 -> 1\|" "abc invalid -> unchanged"
chk "SMK: abc labo0 rc=0 -> 0\|" "abc ALL_REPORT=0"
chk "SMK: hub en rc=0 -> 1\|" "hub enable 1"
chk "SMK: bootc_offset rc=0 -> fsck,12\|" "bootc_offset fsck,12"; chk "SMK: bootc_offset other rc=0 -> fsck,12\|" "other module ignored"
chk "SMK: bootc_time rc=0 -> 23456\|" "bootc_time stored"; chk "SMK: bootc_time bad rc=0 -> -1\|" "bad bootc_time -> -1"
chk "SMK: edtbo 1 rc=1" "edtbo_update 1 refused (EOPNOTSUPP)"; chk "SMK: edtbo 2 rc=1" "edtbo_update 2 refused (EINVAL)"
chk "SMK: ro write rc=1" "read-only node refuses writes"
chk "SMK: chown rc=0 -rw-rw-r-- 1000:1001" "init-style chown/chmod"
chk "SMK: flip noswitch lid=/dev/input/event[0-9]+ flip=$" "no a52sxq.ko: only the SW_LID hall"
chk "SMK: flip aosp us=aosp lid=/dev/input/event[0-9]+ flip=$" "a52sxq.ko loaded, aosp: still only SW_LID"
chk "SMK: flip samsung us=samsung lid=/dev/input/event[0-9]+ flip=/dev/input/event[0-9]+$" "samsung: second input 'hall' with switch 0x10"
chk "SMK: flip samsung close detect=\[CLOSE\|\]" "samsung: hall_detect still CLOSE"
chk "SMK: flip samsung events lid=\[\] flip=\[0500100001000000,0000000000000000,0500100000000000,0000000000000000,\] count=\[\"FCNT\":\"2\"\]" "samsung: evdev gets EV_SW 0x10 1/0 on the flip input, nothing on the SW_LID input, hall_count counts"
chk "SMK: flip back-to-aosp events lid=\[0500000001000000,0000000000000000,0500000000000000,0000000000000000,\] flip=\[\] count=\[\"FCNT\":\"2\"\]" "back to aosp: SW_LID 1/0 passes again, flip input silent"
chk "SMK: dmesg .*a52sxq_hall: bound to the userspace switch" "late soft bind to a52sxq.ko"
chk "SMK: rmmod rc=0 left=0" "rmmod removes all 12"
chk "SMK: reload rc=0" "reload rc 0"
chk "SMK: rmmod fakehall rc=0 hall=\[OPEN\|\] number=\[0\|\]" "hall input gone -> OPEN, number 0"
chk "SMK: rmmod2 rc=0 n=0" "second rmmod clean, class empty"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|duplicate filename|a52sxq_sec_class:" "$C"; then echo "FAIL kernel warning/oops or module message"; f=1; else echo "ok   no WARN/BUG/oops, module silent"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
