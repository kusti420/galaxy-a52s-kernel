#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Offline QEMU test (bsp612 GKI Image, QEMU virt, no phone) of the three SPEC/03 item-5 modules:
#   sdfat.ko               mount -t sdfat with One UI vold's exact option strings on real exFAT / FAT32 images (loop)
#   a52sxq_sd_ioerror.ko   tracepoint hook + the IOERROR uevent on /sys/class/sec/sdcard (test parameter)
#   a52sxq_usb_moisture.ko power_supply/usb/moisture_* from a fake PDIC chip + fake "usb" supply (fakepdic.ko)
# Uses the out-p1 modules (KO_SDFAT= / KO_IOERR= / KO_MOIST= override), the tree's sec_core.ko, the shipped
# a52sxq_sec_class.ko and the pdic_notifier_module stack of drivers612/power. Builds only fakepdic (in $WORK).
#   drivers612/samsung-oneui/sdfat-alias/qemu-test/run.sh   -> PASS/FAIL, $WORK/console.lf
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); V=$(cd "$Q/.." && pwd); S=$(cd "$V/.." && pwd); TOP=$(cd "$S/../.." && pwd); PW=$TOP/drivers612/power
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/fakepdic"
cp "$Q/fakepdic/Kbuild" "$Q/fakepdic/fakepdic.c" "$WORK/fakepdic/"
python3 "$S/ko2symvers.py" "$WORK/pdic.symvers" "$PW/pdic_notifier_module.ko" >/dev/null
A52_POWER=$PW EXTRA_SYMVERS="$WORK/pdic.symvers" "$S/build.sh" "$WORK/fakepdic" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "${KO_SDFAT:-$V/out-p1/sdfat.ko}" "${KO_IOERR:-$S/sd_ioerror/out-p1/a52sxq_sd_ioerror.ko}" \
	"${KO_MOIST:-$S/usb_moisture/out-p1/a52sxq_usb_moisture.ko}" "$S/sec_class/out/a52sxq_sec_class.ko" \
	"$TOP/samsung612/modules/sec_core/sec_core.ko" "$PW/src/switch/switch_class.ko" "$PW/usb_notify_layer.ko" \
	"$PW/pdic_notifier_module.ko" "$WORK/fakepdic/out/fakepdic.ko" "$WORK/rd/"
truncate -s 16M "$WORK/rd/exfat.img" "$WORK/rd/vfat.img"; truncate -s 4M "$WORK/rd/zero.img"
mkfs.exfat -q "$WORK/rd/exfat.img" >/dev/null 2>&1 || mkfs.exfat "$WORK/rd/exfat.img" >/dev/null
mkfs.vfat -F 32 "$WORK/rd/vfat.img" >/dev/null
echo host-file > "$WORK/host.txt"; mcopy -i "$WORK/rd/vfat.img" "$WORK/host.txt" ::HOST.TXT
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -1 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 2G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
tr -d "\r" < "$WORK/console.txt" > "$WORK/console.lf"; C=$WORK/console.lf; f=0; n=0
chk() { n=$((n+1)); if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
VO='uid=1023,gid=1023,fmask=0007,dmask=0007'
chk "SMK: fs before: sdfat=0 exfat=1 vfat=1" "kernel has exfat + vfat, no sdfat"
chk "SMK: sdfat rc=0" "sdfat.ko loads"
chk "SMK: procfs \[_sdfat\]" "/proc/filesystems lists sdfat as a block-device type"
chk "SMK: m1 exfat-vold rc=0" "exFAT: mount -t sdfat with vold's option string"
chk "SMK: m1 mounts \[/dev/loop0 /mnt exfat rw,.*$VO,.*iocharset=utf8" "exFAT: superblock type exfat, uid/gid/masks applied, UTF-8 names"
chk "SMK: m1 write rc=0 ls=\[hello.txt tõde-ä.txt \] stat=1023:1023 770" "exFAT: write, UTF-8 name, owner 1023:1023 mode 770"
chk "SMK: m1 remount-ro rc=0 \[exfat ro" "exFAT: remount ro (goes to exfat)"
chk "SMK: m1 umount rc=0" "exFAT: umount"
chk "SMK: m2 native-exfat rc=0 hello=\[hello-exfat\|\] utf=\[utf\|\]" "exFAT: native mount reads what the alias mount wrote"
chk "SMK: m3 vfat-vold rc=0" "FAT32: mount -t sdfat with vold's option string + time_offset"
chk "SMK: m3 mounts \[/dev/loop1 /mnt vfat rw,.*$VO,.*iocharset=iso8859-1,shortname=mixed,utf8,time_offset=120" "FAT32: superblock type vfat, masks, time_offset, shortname=mixed, utf8"
chk "SMK: m3 host file=\[host-file\|\]" "FAT32: file written on the host is read"
chk "SMK: m3 write rc=0 ls=\[HOST.TXT MixedCase.txt tõde-ä.txt \] stat=1023:1023 770" "FAT32: write, case kept, UTF-8 name"
chk "SMK: m3n native-vfat rc=0 mixed=\[hello-vfat\|\] utf=\[utf\|\]" "FAT32: native mount reads it back"
chk "SMK: m4 auto-exfat rc=0 type=exfat" "no fs=: exFAT image -> exfat"
chk "SMK: m4 auto-vfat rc=0 type=vfat" "no fs=: FAT32 image -> vfat"
chk "SMK: m5 ro rc=0 \[exfat ro" "ro mount is ro"
chk "SMK: m5 ro write rc=[1-9]" "ro mount refuses a write"
chk "SMK: m5 exfat-on-vfat rc=[1-9][0-9]* mounted=\[\]" "fs=exfat on a FAT32 image fails cleanly"
chk "SMK: m5 fs=bogus rc=[1-9][0-9]* mounted=\[\]" "fs=bogus fails cleanly"
chk "SMK: m5 blank rc=[1-9][0-9]* mounted=\[\]" "blank device fails cleanly"
chk "SMK: m5 nodev rc=[1-9]" "missing device fails cleanly"
chk "SMK: m6 rounds ok=30" "30 mount/umount rounds"
chk "SMK: m6 refcnt mounted=0" "a mounted card holds no reference on sdfat.ko"
chk "SMK: m6 rmmod-while-mounted rc=0 hello=\[hello-exfat\|\] procfs=0" "rmmod while mounted: mount keeps working"
chk "SMK: m6 umount rc=0" "umount after rmmod"
chk "SMK: m6 after rmmod rc=[1-9]" "no sdfat type after rmmod"
chk "SMK: ioerr rc=0 hooked=Y\|" "sd_ioerror loads, mmc_request_done probe registered"
chk "SMK: ioerr noti0=\[0\|\]" "no sec/sdcard device: nothing sent, no crash"
chk "SMK: secclass rc=0 sdcard=/sys/devices/virtual/sec/sdcard" "sec/sdcard device (a52sxq_sec_class)"
chk "SMK: ioerr uevent1 .*kobj=\"sdcard\" act=0x2 env0=\"DEVNAME=sdcard\" env1=\"IOERROR=YES\"" "KOBJ_CHANGE on sec/sdcard with DEVNAME=sdcard IOERROR=YES"
chk "SMK: ioerr uevent2 .*env1=\"IOERROR=NoCard\"" "IOERROR=NoCard variant"
chk "SMK: ioerr bogus rc=1" "bad test value -> EINVAL"
chk "SMK: ioerr noti=\[2\|\] sd_data=\[\"GE\":\"0\",\"CC\":\"0\",\"ECC\":\"0\",\"WP\":\"0\",\"OOR\":\"0\",\"CRC\":\"0\",\"TMO\":\"0\"\|\]" "noti count 2, sd_data in the 5.4 format"
chk "SMK: ioerr modes --w------- -r--------" "test 0200, sd_data 0400"
chk "SMK: ioerr rmmod rc=0" "sd_ioerror unloads"
chk "SMK: moist rc=0" "usb_moisture loads before the supply / chip exist"
chk "SMK: moist early nodes=0" "no nodes yet"
chk "SMK: fakepdic rc=0" "fake usb supply + PDIC chip"
chk "SMK: moist ls -r--r--r-- 0:0 moisture_detected -rw-rw-r-- 0:0 moisture_detection_enabled" "nodes appear on power_supply/usb: 0444 + 0664"
chk "SMK: moist dry detected=\[0\|\] enabled=\[1\|\]" "dry: 0, enabled 1"
chk "SMK: moist wet detected=\[1\|\] ccic_water=\[1\|\]" "wet: 1 (= sec/ccic/water)"
chk "SMK: moist uevent-wet .*kobj=\"usb\" act=0x2 env0=\"POWER_SUPPLY_MOISTURE_DETECTED=1\"" "uevent POWER_SUPPLY_MOISTURE_DETECTED=1 on power_supply/usb"
chk "SMK: moist dried detected=\[0\|\]" "dried: 0"
chk "SMK: moist uevent-dry .*env0=\"POWER_SUPPLY_MOISTURE_DETECTED=0\"" "uevent ...=0"
chk "SMK: moist disable rc=0" "moisture_detection_enabled accepts 0"
chk "SMK: moist disabled\+wet detected=\[0\|\] enabled=\[0\|\] last-uevent env0=\"POWER_SUPPLY_MOISTURE_DETECTED=0\"" "disabled: reads 0, no uevent"
chk "SMK: moist re-enabled detected=\[1\|\]" "re-enabled: live state again"
chk "SMK: moist bogus rc=1" "bad value -> EINVAL"
chk "SMK: moist rmmod rc=0 nodes=0" "rmmod removes the nodes"
chk "SMK: moist reload-wet detected=\[1\|\]" "loaded with a wet port: 1"
chk "SMK: moist uevent-reload .*env0=\"POWER_SUPPLY_MOISTURE_DETECTED=1\"" "loaded with a wet port: uevent sent"
chk "SMK: moist rmmod all rc=0" "unload all"
chk "SMK: END" "script ran to the end"
n=$((n+1)); if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|Unknown symbol|disagrees about version" "$C"; then echo "FAIL kernel warning/oops/symbol"; f=1; else echo "ok   no WARN/BUG/oops, no symbol/CRC complaint"; fi
echo "console: $C ($n checks)"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
