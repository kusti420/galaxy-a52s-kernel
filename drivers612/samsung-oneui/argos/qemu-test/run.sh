#!/bin/bash
# Offline QEMU test of sec_argos.ko on the bsp612 GKI Image (QEMU virt, busybox initramfs, no phone).
#   drivers612/samsung-oneui/argos/qemu-test/run.sh   -> PASS/FAIL, $WORK/console-{builtin,dt}.txt
# Two boots: (1) plain virt dtb = 6.12 today (no argos node: built-in table),
#            (2) virt dtb + /soc/argos from ../argos.dtsi (interconnects line dropped: no provider
#                in QEMU) = what argosd will read once the board tree has the node.
# nttest (freestanding aarch64) writes like argosd and prints cflm "[3]" (CFLM_ARGOS) per step.
# QEMU has no cpufreq: cpufreq_limit only records the requests, which is what is checked.
# fakewalt.ko (input_booster/qemu-test) stands in for sched-walt.ko (cpufreq_limit depends on it).
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); A=$(cd "$Q/.." && pwd); S=$(cd "$A/.." && pwd); TOP=$(cd "$S/../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/rd/tmp"
"$S/build.sh" "$S/input_booster/qemu-test/fakewalt" >/dev/null
clang --target=aarch64-linux-gnu -O2 -ffreestanding -fno-stack-protector -nostdlib -static -fuse-ld=lld \
	-Wall -Werror -o "$WORK/rd/bin/nttest" "$Q/nttest.c"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$A/out/sec_argos.ko" "$S/input_booster/qemu-test/fakewalt/out/fakewalt.ko" "$S/cpufreq_limit/out/cpufreq_limit.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/builtin.dtb" "$WORK/virt.dtb"
# dt variant: virt + /soc (simple-bus) + argos.dtsi minus the interconnects line
dtc -q -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb"
grep -v 'interconnects' "$A/argos.dtsi" > "$WORK/argos-noicc.dtsi"
{ cat "$WORK/virt.dts"; echo '/ { soc: soc { compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>; ranges; }; };';
  echo "/include/ \"$WORK/argos-noicc.dtsi\""; } > "$WORK/dt.dts"
dtc -q -I dts -O dtb -p 8192 -o "$WORK/dt.dtb" "$WORK/dt.dts"
f=0
for v in builtin dt; do
	C=$WORK/console-$v.txt
	timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/$v.dtb" -initrd "$WORK/rd.cpio.gz" \
		-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$C" 2>&1 || true
	echo "== $v"
	chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
	chk "SMK: A argos rc=0" "loads without cpufreq_limit (weak link)"
	chk "SMK: A dev c.* 10, +[0-9]+ .*/dev/network_throughput" "misc char device (major 10)"
	chk "SMK: A nttest rc=0 lines=1[0-9]" "argosd-style writes without cpufreq_limit"
	chk "SMK: A status cpu: none" "no CPU vote without cpufreq_limit"
	chk "SMK: A misc after rmmod: 0" "rmmod removes the node"
	chk "SMK: argos rc=0" "loads with cpufreq_limit"
	chk "SMK: status0 cpu: cpufreq_limit max -1" "set_freq_limit linked"
	chk "SMK: NTT open rc=3" "open O_RDWR as argosd"
	chk "SMK: NTT start wr=0 \[3\] min\(0\)" "start: nothing requested"
	chk "SMK: NTT wifitx-20 wr=7 \[3\] min\(576000\)" "WIFI TX 20 Mbps -> level 0 576000"
	chk "SMK: NTT wifitx-199 wr=7 \[3\] min\(576000\)" "WIFI TX 199 Mbps -> same level"
	chk "SMK: NTT wifitx-200 wr=7 \[3\] min\(2131200\)" "WIFI TX 200 Mbps -> level 1 2131200"
	chk "SMK: NTT ufs-800 wr=8 \[3\] min\(2131200\)" "UFS 800 -> 902400 below max, unchanged"
	chk "SMK: NTT wifitx-5 wr=6 \[3\] min\(902400\)" "WIFI TX unlock -> UFS lock 902400 remains"
	chk "SMK: NTT wifirx-900 wr=8 \[3\] min\(902400\)" "WIFI RX (unused table) ignored"
	chk "SMK: NTT idx9-100 wr=7 \[3\] min\(902400\)" "index 9 (no device) ignored"
	chk "SMK: NTT ufs-0 wr=6 \[3\] min\(-1\)" "all unlocked -> -1 (release)"
	chk "SMK: NTT raw4-wifitx-20 wr=4 \[3\] min\(576000\)" "raw s32 write (count 4)"
	chk "SMK: NTT read rc=4 value=321" "read returns aggregate 0x141"
	chk "SMK: NTT fd2-raw4-wifitx-200 wr=4 \[3\] min\(2131200\)" "second fd: PM_QOS_MAX aggregate"
	chk "SMK: NTT fd2-closed wr=0 \[3\] min\(576000\)" "second fd closed: back to first request"
	chk "SMK: NTT bogus wr=-22" "bad input -> EINVAL"
	chk "SMK: NTT closed wr=0 \[3\] min\(-1\)" "last close releases the lock"
	chk "SMK: status1 \[1\] WIFI TX: tables 2 level -1" "status: table 1 = WIFI TX, 2 levels"
	chk "SMK: status1 \[4\] UFS: tables 1 level -1" "status: table 4 = UFS"
	chk "SMK: dmesg .*name:WIFI TX, speed:200Mbps, prev level:0, request level:1" "debug=1 prints 5.4 lines"
	chk "SMK: rmmod sec_argos rc=0" "rmmod sec_argos"
	chk "SMK: rmmod cpufreq_limit rc=0" "rmmod cpufreq_limit after it (no leftover ref)"
	chk "SMK: misc after rmmod: 0" "node gone"
	chk "SMK: END" "script ran to the end"
	if [ $v = dt ]; then
		chk "SMK: dt: argos node present, entries with @: 7" "/proc/device-tree/soc/argos: 7 boot_device@N"
		chk "SMK: dt: @1 node=\[wlan0\] label=\[WIFI TX\]" "argosd strings @1"
		chk "SMK: dt: @4 sysnode=\[/sys/class/sec/ufs/transferred_cnt\]" "argosd sysnode @4"
		chk "SMK: status0 source: dt" "tables parsed from the DT node"
		chk "SMK: platform bound: 1" "platform driver bound to soc:argos (no icc: DDR none)"
	else
		chk "SMK: dt: no argos node" "no DT node"
		chk "SMK: status0 source: builtin" "built-in A52s table"
		chk "SMK: platform bound: 0" "no platform device"
	fi
	if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
	n=$(sed -n '1,/SMK: debug on/p' "$C" | grep -a 'sec_argos' | grep -av 'SMK:' | grep -acvE 'taints kernel|module verification failed' || true)
	if [ "$n" = 0 ]; then echo "ok   silent by default (0 sec_argos lines before debug=1)"; else echo "FAIL $n sec_argos lines with debug=0"; f=1; fi
	echo "console: $C"
done
[ $f = 0 ] && echo PASS || echo FAIL; exit $f
