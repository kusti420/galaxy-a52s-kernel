#!/bin/bash
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of cpufreq_limit, ufs_sec_sysfs (+ the
# ramdisk's sec_core.ko) and the ss_mon / conn_gadget configfs functions: load, nodes, writes, configfs
# mkdir/symlink/rmdir, rmmod, no WARN/BUG. QEMU has no cpufreq and no UFS: cpufreq_limit only records the
# requests (attach retries), ufs_sec_sysfs creates its nodes with an empty UN. Based on input_booster/qemu-test.
#   drivers612/samsung-oneui/qemu-smoke/run.sh [sec_core.ko]   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/.." && pwd); TOP=$(cd "$S/../.." && pwd)
SEC=${1:-$TOP/samsung612/modules/sec_core/sec_core.ko}
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$S/input_booster/qemu-test/fakewalt" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$S/input_booster/qemu-test/fakewalt/out/fakewalt.ko" "$S/cpufreq_limit/out/cpufreq_limit.ko" "$S/ufs_sec/out/ufs_sec_sysfs.ko" \
	"$S/usb_gadget/out/usb_f_ss_mon_gadget.ko" "$S/usb_gadget/out/usb_f_ss_conn_gadget.ko" "$WORK/rd/"
cp "$SEC" "$WORK/rd/sec_core.ko"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: cflm rc=0" "cpufreq_limit loads (no policies)"
chk "SMK: ls -rw-r--r-- .* cpufreq_max_limit" "cpufreq_max_limit 0644"
chk "SMK: ls -r--r--r-- .* cpufreq_table" "cpufreq_table 0444"
chk "SMK: ls -rw-r--r-- .* limit_stat" "limit_stat 0644"
chk "min=-1 max=-1 over=0" "initial values -1/-1/0"
chk "SMK: min write rc=0 -> 1324800" "min_limit write"
chk "SMK: max write rc=0 -> 1056000" "max_limit write"
chk "SMK: bogus write rc=1" "bad input -> EINVAL"
chk "SMK: info requested: \[0\] min\(1324800\), max\(1056000\)" "info shows the userspace request"
chk "SMK: ufs rc=0" "ufs_sec_sysfs loads (no UFS)"
chk "SMK: ufs -r--r----- .* un" "un 0440"
chk "SMK: ss_mon rc=0" "ss_mon loads"
chk "SMK: conn rc=0" "conn_gadget loads"
chk "SMK: mkdir ss_mon.mtp rc=0" "mkdir ss_mon.mtp"
chk "SMK: mkdir ss_mon.ptp rc=0" "mkdir ss_mon.ptp"
chk "SMK: mkdir conn_gadget.0 rc=0" "mkdir conn_gadget.0"
chk "SMK: misc usb_mtp_gadget" "/dev/usb_mtp_gadget misc device"
chk "SMK: misc android_ssusbcon" "/dev/android_ssusbcon misc device"
chk "SMK: rmdir ptp rc=0 misc=1" "mtp node kept while ss_mon.mtp exists"
chk "SMK: rmdir rest rc=0 misc=0" "nodes gone after rmdir"
chk "SMK: rmmod cpufreq_limit rc=0" "rmmod all"
chk "SMK: power nodes after rmmod: 0" "/sys/power nodes removed"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
