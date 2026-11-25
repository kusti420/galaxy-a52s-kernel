#!/bin/bash
# Offline QEMU test of input_booster.ko on the bsp612 GKI Image (no phone):
#   drivers612/samsung-oneui/input_booster/qemu-test/run.sh   -> $WORK/console.txt + PASS/FAIL
# QEMU virt + busybox initramfs; ibtest (freestanding aarch64, uinput) creates a touchscreen+key
# device, the shell opens its evdev node (a "userspace user", needed before the booster opens
# its handle), ibtest injects taps / long press / 2 fingers / volume key / 300-tap burst and
# reads cpufreq_limit's /sys/devices/system/cpu/cflm/info "[1]" (CFLM_TOUCH) line.
# fakewalt.ko stands in for sched-walt.ko (same sched_set_boost CRC, logs every call).
# QEMU has no cpufreq: cpufreq_limit only records the requests, which is what is checked.
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); IB=$(cd "$Q/.." && pwd); TOP=$(cd "$IB/../../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev/input"
"$TOP/drivers612/samsung-oneui/build.sh" "$Q/fakewalt" >/dev/null
clang --target=aarch64-linux-gnu -O2 -ffreestanding -fno-stack-protector -nostdlib -static -fuse-ld=lld \
	-Wall -o "$WORK/rd/bin/ibtest" "$Q/ibtest.c"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$IB/out/input_booster.ko" "$Q/fakewalt/out/fakewalt.ko" \
	"$TOP/drivers612/samsung-oneui/cpufreq_limit/out/cpufreq_limit.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aq -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "IBS: A ib rc=0" "loads without cpufreq_limit / sched-walt"
chk "IBS: ib rc=0" "loads with cpufreq_limit"
chk "touch head=\[200 1324800 1017 2 5\] tail=\[300 1056000 1017 2 5\] level=2" "touch head/tail/level = 5.4 DT"
chk "pen head after short write (ignored): 250 1400000 0 2 0" "head store format check"
chk "tap +100 (head 1324800): \[1\] min(1324800)" "tap: head 1324800"
chk "tap +250 (tail 1056000): \[1\] min(1056000)" "tap: tail 1056000"
chk "tap +650 (released): \[1\] min(-1)" "tap: released after head+tail"
chk "2-finger +130 (2035200): \[1\] min(2035200)" "multitouch head 2035200"
chk "vol +100 (1324800): \[1\] min(1324800)" "volume key boost"
chk "burst +1500 (released): \[1\] min(-1)" "300-tap burst released"
chk "IBS: after rmmod: requested: \[1\] min(-1)" "rmmod while boosted releases"
chk "fakewalt: sched_set_boost(2)" "HMP boost via sched_set_boost(2)"
chk "fakewalt: sched_set_boost(-2)" "HMP release via sched_set_boost(-2)"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
