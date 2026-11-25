#!/bin/busybox sh
# QEMU init of sdfat-alias/qemu-test/run.sh: sdfat.ko, a52sxq_sd_ioerror.ko, a52sxq_usb_moisture.ko
B=/bin/busybox
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mkdir -p /mnt /tmp; $B mknod /dev/null c 1 3
for i in 0 1 2; do $B mknod /dev/loop$i b 7 $i; done
r() { echo "SMK: $*"; }
rd() { $B cat "$1" 2>&1 | $B tr "\n" "|"; }
mnt() { $B grep " /mnt " /proc/mounts | $B tr "\n" "|"; }
$B mount -t tracefs none /sys/kernel/tracing 2>/dev/null; T=/sys/kernel/tracing
echo 'p:a52ue kobject_uevent_env kobj=+0(+0($arg1)):string act=$arg2 env0=+0(+0($arg3)):string env1=+0(+8($arg3)):string' > $T/kprobe_events; r "kprobe rc=$?"
echo 1 > $T/events/kprobes/a52ue/enable; echo 1 > $T/tracing_on
ue() { $B grep -o "a52ue.*kobj=\"$1\".*" $T/trace | $B tail -n 1 | $B sed 's/^[^ ]* *//'; }

# ---------------------------------------------------------------- sdfat alias
r "fs before: sdfat=$($B grep -c sdfat /proc/filesystems) exfat=$($B grep -c exfat /proc/filesystems) vfat=$($B grep -c vfat /proc/filesystems)"
$B insmod /sdfat.ko; r "sdfat rc=$?"
r "procfs [$($B grep sdfat /proc/filesystems | $B tr '\t' '_')]"
$B losetup /dev/loop0 /exfat.img; r "loop0 rc=$?"; $B losetup /dev/loop1 /vfat.img; r "loop1 rc=$?"; $B losetup /dev/loop2 /zero.img
# 1. exFAT exactly as One UI vold mounts it
$B mount -t sdfat -o fs=exfat,adj_req,iocharset=iso8859-1,utf8,uid=1023,gid=1023,fmask=7,dmask=7 /dev/loop0 /mnt; r "m1 exfat-vold rc=$?"
r "m1 mounts [$(mnt)]"
echo hello-exfat > /mnt/hello.txt; echo utf > "/mnt/tõde-ä.txt"; r "m1 write rc=$? ls=[$($B ls /mnt | $B tr '\n' ' ')] stat=$($B stat -c '%u:%g %a' /mnt/hello.txt)"
$B mount -o remount,ro /mnt; r "m1 remount-ro rc=$? [$(mnt | $B cut -d' ' -f3-4 | $B cut -c1-12)]"
$B umount /mnt; r "m1 umount rc=$?"
# 2. the same card through the native type: data + UTF-8 name written through the alias are there
$B mount -t exfat -o iocharset=utf8 /dev/loop0 /mnt; r "m2 native-exfat rc=$? hello=[$(rd /mnt/hello.txt)] utf=[$(rd '/mnt/tõde-ä.txt')]"; $B umount /mnt
# 3. FAT32 exactly as One UI vold mounts it (+ time_offset)
$B mount -t sdfat -o fs=vfat,smart,delay,adj_req,adj_hid,iocharset=iso8859-1,utf8,uid=1023,gid=1023,fmask=7,dmask=7,time_offset=120 /dev/loop1 /mnt; r "m3 vfat-vold rc=$?"
r "m3 mounts [$(mnt)]"
r "m3 host file=[$(rd /mnt/HOST.TXT)]"; echo hello-vfat > /mnt/MixedCase.txt; echo utf > "/mnt/tõde-ä.txt"; r "m3 write rc=$? ls=[$($B ls /mnt | $B tr '\n' ' ')] stat=$($B stat -c '%u:%g %a' /mnt/MixedCase.txt)"
$B umount /mnt; r "m3 umount rc=$?"
$B mount -t vfat -o utf8 /dev/loop1 /mnt; r "m3n native-vfat rc=$? mixed=[$(rd /mnt/MixedCase.txt)] utf=[$(rd '/mnt/tõde-ä.txt')]"; $B umount /mnt
# 4. no fs= option: exfat is tried first, then vfat
$B mount -t sdfat /dev/loop0 /mnt; r "m4 auto-exfat rc=$? type=$(mnt | $B cut -d' ' -f3)"; $B umount /mnt
$B mount -t sdfat /dev/loop1 /mnt; r "m4 auto-vfat rc=$? type=$(mnt | $B cut -d' ' -f3)"; $B umount /mnt
# 5. read-only mount, failures
$B mount -t sdfat -o ro,fs=exfat,utf8 /dev/loop0 /mnt; r "m5 ro rc=$? [$(mnt | $B cut -d' ' -f3-4 | $B cut -c1-12)]"; echo x > /mnt/no 2>/dev/null; r "m5 ro write rc=$?"; $B umount /mnt
$B mount -t sdfat -o fs=exfat /dev/loop1 /mnt 2>/dev/null; r "m5 exfat-on-vfat rc=$? mounted=[$(mnt)]"
$B mount -t sdfat -o fs=bogus /dev/loop0 /mnt 2>/dev/null; r "m5 fs=bogus rc=$? mounted=[$(mnt)]"
$B mount -t sdfat /dev/loop2 /mnt 2>/dev/null; r "m5 blank rc=$? mounted=[$(mnt)]"
$B mount -t sdfat -o fs=vfat /dev/nonexistent /mnt 2>/dev/null; r "m5 nodev rc=$?"
# 6. 30 mount/umount rounds, then unload while mounted (the superblock is exfat's, not ours)
i=0; ok=0; while [ $i -lt 30 ]; do $B mount -t sdfat -o fs=exfat,adj_req,iocharset=iso8859-1,utf8,uid=1023,gid=1023,fmask=7,dmask=7 /dev/loop0 /mnt && $B umount /mnt && ok=$((ok+1)); i=$((i+1)); done; r "m6 rounds ok=$ok"
$B mount -t sdfat -o fs=exfat,utf8 /dev/loop0 /mnt; r "m6 refcnt mounted=$($B cat /sys/module/sdfat/refcnt)"
$B rmmod sdfat; r "m6 rmmod-while-mounted rc=$? hello=[$(rd /mnt/hello.txt)] procfs=$($B grep -c sdfat /proc/filesystems)"
$B umount /mnt; r "m6 umount rc=$?"
$B mount -t sdfat -o fs=exfat /dev/loop0 /mnt 2>/dev/null; r "m6 after rmmod rc=$?"

# ---------------------------------------------------------------- SD IOERROR uevent
$B insmod /sec_core.ko; r "sec_core rc=$?"
$B insmod /a52sxq_sd_ioerror.ko; r "ioerr rc=$? hooked=$(rd /sys/module/a52sxq_sd_ioerror/parameters/hooked)"
echo YES > /sys/module/a52sxq_sd_ioerror/parameters/test; r "ioerr test-without-sdcard-dev rc=$?"; $B sleep 1
r "ioerr noti0=[$(rd /sys/module/a52sxq_sd_ioerror/parameters/noti)]"
$B insmod /a52sxq_sec_class.ko; r "secclass rc=$? sdcard=$($B readlink -f /sys/class/sec/sdcard)"
echo YES > /sys/module/a52sxq_sd_ioerror/parameters/test; r "ioerr test YES rc=$?"; $B sleep 1
r "ioerr uevent1 $(ue sdcard)"
echo NoCard > /sys/module/a52sxq_sd_ioerror/parameters/test; $B sleep 1; r "ioerr uevent2 $(ue sdcard)"
echo bogus > /sys/module/a52sxq_sd_ioerror/parameters/test 2>/dev/null; r "ioerr bogus rc=$?"
r "ioerr noti=[$(rd /sys/module/a52sxq_sd_ioerror/parameters/noti)] sd_data=[$(rd /sys/module/a52sxq_sd_ioerror/parameters/sd_data)]"
r "ioerr modes $($B stat -c '%A' /sys/module/a52sxq_sd_ioerror/parameters/test) $($B stat -c '%A' /sys/module/a52sxq_sd_ioerror/parameters/sd_data)"
$B rmmod a52sxq_sd_ioerror; r "ioerr rmmod rc=$?"

# ---------------------------------------------------------------- USB moisture nodes
P=/sys/class/power_supply/usb
$B insmod /switch_class.ko; $B insmod /usb_notify_layer.ko; $B insmod /pdic_notifier_module.ko; r "pdic rc=$?"
$B insmod /a52sxq_usb_moisture.ko; r "moist rc=$?"; $B sleep 2
r "moist early nodes=$($B ls $P 2>/dev/null | $B grep -c moisture)"
$B insmod /fakepdic.ko; r "fakepdic rc=$?"; $B sleep 3
r "moist ls $($B stat -c '%A %u:%g %n' $P/moisture_detected $P/moisture_detection_enabled | $B sed "s|$P/||g" | $B tr '\n' ' ')"
r "moist dry detected=[$(rd $P/moisture_detected)] enabled=[$(rd $P/moisture_detection_enabled)]"
echo 1 > /sys/module/fakepdic/parameters/water; $B sleep 1
r "moist wet detected=[$(rd $P/moisture_detected)] ccic_water=[$(rd /sys/class/sec/ccic/water)]"; r "moist uevent-wet $(ue usb)"
echo 0 > /sys/module/fakepdic/parameters/water; $B sleep 1
r "moist dried detected=[$(rd $P/moisture_detected)]"; r "moist uevent-dry $(ue usb)"
echo 0 > $P/moisture_detection_enabled; r "moist disable rc=$?"; echo 1 > /sys/module/fakepdic/parameters/water; $B sleep 1
r "moist disabled+wet detected=[$(rd $P/moisture_detected)] enabled=[$(rd $P/moisture_detection_enabled)] last-uevent $(ue usb | $B grep -o 'env0=.*')"
echo 1 > $P/moisture_detection_enabled; r "moist re-enabled detected=[$(rd $P/moisture_detected)]"
echo x > $P/moisture_detection_enabled 2>/dev/null; r "moist bogus rc=$?"
$B rmmod a52sxq_usb_moisture; r "moist rmmod rc=$? nodes=$($B ls $P | $B grep -c moisture)"
# wet at load time: the notification came before the module listened
$B insmod /a52sxq_usb_moisture.ko; $B sleep 2; r "moist reload-wet detected=[$(rd $P/moisture_detected)]"; r "moist uevent-reload $(ue usb)"
$B rmmod a52sxq_usb_moisture; $B rmmod fakepdic; r "moist rmmod all rc=$?"
r "END"
$B dmesg | $B grep -E "sdfat|sd_ioerror|usb_moisture|exFAT-fs|FAT-fs" | $B tail -n 30
$B poweroff -f
