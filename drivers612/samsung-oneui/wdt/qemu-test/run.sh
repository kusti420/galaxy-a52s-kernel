#!/bin/bash
# Offline QEMU test (bsp612 GKI Image, QEMU virt, no phone) of the watchdog core's timing and suspend handling.
# The hypervisor is replaced by sim/a52_wdt_sim.ko (same ops, same dev_pm_ops as gh_virt_wdt; reports "BARK" when an
# armed watchdog goes unpetted for longer than the bark time = a reset on the phone). gh_virt_wdt.ko itself cannot
# run here (its SMCs need the Qualcomm hypervisor).
#   drivers612/samsung-oneui/wdt/qemu-test/run.sh            the a52 variant (out/qcom_wdt_core.ko): must PASS
#   CORE=dist drivers612/samsung-oneui/wdt/qemu-test/run.sh  negative control: the stock dist core (expected: BARK)
#   CORE_ARGS="bark_ms=11000" ...                            module parameters for the core
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/../.." && pwd); TOP=$(cd "$S/../.." && pwd)
M=$TOP/bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734
CORE=${CORE:-a52}; WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev" "$WORK/rd/m"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
# minidump + qcom-scm (what qcom_wdt_core imports) with their dependencies, in load order (modules.dep lists them reversed)
: > "$WORK/rd/mods.order"
for d in $(grep '^drivers/soc/qcom/minidump.ko:' "$M/modules.dep" | tr ' ' '\n' | sed 's/:$//' | tac); do
	cp "$M/$d" "$WORK/rd/m/"; basename "$d" >> "$WORK/rd/mods.order"
done
if [ "$CORE" = dist ]; then cp "$M/drivers/soc/qcom/qcom_wdt_core.ko" "$WORK/rd/"; else cp "$Q/../out/qcom_wdt_core.ko" "$WORK/rd/"; fi
echo "${CORE_ARGS:-}" > "$WORK/rd/core.args"
cp "$Q/../sim/out/a52_wdt_sim.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb"
GIC=$(awk '/intc@/{f=1} f&&/phandle = /{gsub(/[^0-9a-fx]/,"",$3); print $3; exit}' "$WORK/virt.dts")
# the sim's bark interrupt: an unused SPI (never fires)
printf '\n/ { a52-wdt-sim { compatible = "a52,wdt-sim"; interrupt-parent = <%s>; interrupts = <0 200 1>; }; };\n' "$GIC" >> "$WORK/virt.dts"
dtc -q -I dts -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dts"
timeout 900 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M no_console_suspend" > "$WORK/console.txt" 2>&1 || true
grep -a '^WT: ' "$WORK/console.txt" | tr -d '\r' > "$Q/result-$CORE.txt" || true
C=$Q/result-$CORE.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
no() { if grep -aqE -- "$1" "$C"; then echo "FAIL $2"; f=1; else echo "ok   $2"; fi; }
chk "WT: sim rc=0" "core + sim load, sim registered"
chk "WT: END" "script ran to the end"
if [ "$CORE" = dist ]; then
	chk "WDTSIM: BARK" "NEGATIVE CONTROL: the stock core barks in this test (as expected)"
	echo "console: $WORK/console.txt, result: $C"; exit 0
fi
no "BARK=[1-9]" "no bark in any step"
no "WDTSIM: BARK|WARNING|BUG:|Oops" "no BARK / WARNING / BUG / Oops in dmesg"
chk "WT: load: .* en=1 dis=0 .* armed=Y bark_ms=20000 bite_ms=23000" "armed at load, bark 20 s, bite 23 s"
chk "WT: idle21: pet=[3-9]" "petted while idle (>= 2 pets in 21 s after the first)"
chk "WT: pmtest-devices: .* en=1 dis=0 .* armed=Y" "suspend stopped before suspend_late: watchdog stays armed and petted"
chk "WT: pmtest-platform5: .* en=2 dis=1 .* armed=Y" "suspend_late disarms, resume_early re-arms"
chk "WT: pmtest-platform26: .* en=3 dis=2 BARK=0" "26 s inside suspend (> bite time): no bark, disarmed during the window"
chk "WT: faildisable write rc=1" "disable refused -> the suspend is refused"
chk "WT: last_failed_dev=a52-wdt-sim" "suspend_stats names the watchdog device"
chk "WT: faildisable\+12: .* BARK=0 armed=Y" "after the refused suspend the pet timer runs again"
chk "WT: failenable: .* armed=N .* enabled=0 .* resume_enable_fails=1" "enable failure on resume: recorded, no watchdog"
chk "WT: recover: .* armed=Y .* enabled=1" "next resume re-arms"
chk "WT: s2idle-rtc27 write rc=0" "real s2idle, RTC wake after 27 s (> bite time)"
chk "WT: s2idle-rtc27: .* BARK=0 armed=Y" "no bark over the real s2idle"
chk "WT: final: .* BARK=0 armed=Y" "armed and petted at the end"
echo "console: $WORK/console.txt, result: $C"
[ $f = 0 ] && echo PASS || { echo FAILED; exit 1; }
