#!/bin/bash
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of a52sxq_msm_subsys.ko: load, the 7 subsysN
# nodes with 5.4 names under /sys/devices/platform/soc/<5.4 PIL node>/ (the test dtb adds a /soc simple-bus),
# attribute formats/modes, 5.4 write semantics, lazy state lookup (a qcom,yupik-modem-pas node without driver),
# hand-over to a stand-in owner module (fakeowner/msub_fakeowner.ko, yield_to=msub_fakeowner) and back, idle load behind it, no-/soc
# fallback, rmmod clean, no WARN/BUG. Pattern of drivers612/samsung-oneui/qemu-smoke/run.sh.
#   drivers612/samsung-oneui/msm_subsys/qemu/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); M=$(cd "$Q/.." && pwd); S=$(cd "$M/.." && pwd); TOP=$(cd "$S/../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$M" >/dev/null
"$S/build.sh" "$Q/fakeowner" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$M/out/a52sxq_msm_subsys.ko" "$Q/fakeowner/out/msub_fakeowner.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb"
cat >> "$WORK/virt.dts" <<'DTS'
/ {
	soc {
		compatible = "simple-bus";
		#address-cells = <1>;
		#size-cells = <1>;
		ranges;
		remoteproc-mss {
			compatible = "qcom,yupik-modem-pas";
		};
	};
};
DTS
dtc -q -I dts -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dts"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0; sed -i "s/\r$//" "$C"
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
P=/sys/devices/platform/soc
chk "SMK: load rc=0" "module loads"
chk "SMK: devices: subsys0 subsys1 subsys2 subsys3 subsys4 subsys5 subsys6 ?$" "subsys0..6"
chk "SMK: A subsys0 path=$P/soc:qcom,ipa_fws/subsys0 name=yupik_ipa_fws state=OFFLINE crash=0 level=SYSTEM fw=yupik_ipa_fws dbg=reset" "subsys0 = yupik_ipa_fws, 5.4 path + defaults"
chk "SMK: A subsys1 path=$P/soc:qcom,kgsl-hyp/subsys1 name=a660_zap " "subsys1 = a660_zap"
chk "SMK: A subsys2 path=$P/soc:qcom,wpss@8a00000/subsys2 name=wpss " "subsys2 = wpss"
chk "SMK: A subsys3 path=$P/4080000.qcom,mss/subsys3 name=modem state=OFFLINE " "subsys3 = modem (rproc lookup, none)"
chk "SMK: A subsys4 path=$P/3700000.qcom,lpass/subsys4 name=adsp " "subsys4 = adsp"
chk "SMK: A subsys5 path=$P/a300000.qcom,turing/subsys5 name=cdsp " "subsys5 = cdsp"
chk "SMK: A subsys6 path=$P/aab0000.qcom,venus/subsys6 name=venus " "subsys6 = venus"
chk "SMK: ls3 -r--r--r-- .* name ?$" "name 0444"
chk "SMK: ls3 -r--r--r-- .* state ?$" "state 0444"
chk "SMK: ls3 -r--r--r-- .* crash_count ?$" "crash_count 0444"
chk "SMK: ls3 -rw-r--r-- .* restart_level ?$" "restart_level 0644"
chk "SMK: ls3 -rw-r--r-- .* firmware_name ?$" "firmware_name 0644"
chk "SMK: ls3 -rw-r--r-- .* system_debug ?$" "system_debug 0644"
chk "SMK: level RELATED rc=0 -> RELATED" "restart_level RELATED"
chk "SMK: level sys rc=0 -> SYSTEM" "restart_level prefix match (5.4 strncasecmp)"
chk "SMK: level bogus rc=1 -> SYSTEM" "restart_level bad input -> error, unchanged"
chk "SMK: debug set rc=0 -> set" "system_debug set"
chk "SMK: debug nope rc=1 -> set" "system_debug bad input -> error"
chk "SMK: debug reset rc=0 -> reset" "system_debug reset"
chk "SMK: fw modem2 rc=0 -> modem2" "firmware_name store"
chk "SMK: state x40 reads done: OFFLINE" "repeated state reads"
chk "msub_fakeowner loading: handing msm_subsys over" "yields on owner COMING"
chk "msub_fakeowner: bus_register 0" "owner's bus_register succeeds"
chk "SMK: owner load rc=0" "owner loads"
chk "SMK: devices with owner: subsys99 +parents=0" "only the user's devices, parents gone"
chk "SMK: devices after owner left: subsys0 subsys1 subsys2 subsys3 subsys4 subsys5 subsys6 ?$" "fallback back after owner rmmod"
chk "SMK: B subsys3 path=$P/4080000.qcom,mss/subsys3 name=modem state=OFFLINE crash=0 level=SYSTEM fw=modem dbg=reset" "values kept across hand-over"
chk "SMK: rmmod rc=0" "rmmod"
chk "SMK: after rmmod: bus=no parents=0" "bus + parents removed"
chk "SMK: load behind owner rc=0" "loads rc 0 behind an existing bus"
chk "already registered elsewhere, staying idle" "idle behind owner"
chk "SMK: devices behind owner: subsys99 ?$" "owner's devices untouched"
chk "SMK: rmmod idle rc=0" "rmmod idle"
chk "SMK: owner rmmod2 rc=0" "owner rmmod (fallback gone, nothing re-registered)"
chk "SMK: load nosoc rc=0" "loads without /soc"
chk "SMK: nosoc subsys3 path=/sys/devices/subsys3 name=modem" "no-parent fallback path"
chk "SMK: rmmod nosoc rc=0" "rmmod nosoc"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|duplicate filename" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops/dup"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
