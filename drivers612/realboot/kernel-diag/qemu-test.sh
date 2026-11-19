#!/bin/bash
# Offline smoke test of the DIAG Image (bsp612/out/diag/Image, a52bc.c) in QEMU: no phone.
#   drivers612/realboot/kernel-diag/qemu-test.sh      -> bsp612/out/diag/qemu/ (console log, RAM dumps, verdict)
# QEMU virt, cortex "max", kernel at EL2 (virtualization=on, kvm-arm.mode=none), 4 GiB RAM from
# 0x40000000 so that 0xf0be0000 is RAM; the dtb is QEMU's own plus the a52,ramcon reservation.
# The kernel drops to EL1 (CONFIG_CMDLINE kvm-arm.mode=protected: no VHE), so the vendor-hyp
# STATUS call really executes; QEMU's firmware emulation answers NOT_SUPPORTED (a0=-1), which
# proves a non-answering hypervisor does not hang the boot. Everything else runs as on the phone: entry breadcrumb + attempt counter, FDT gate, RAM console via setup_earlycon(),
# fixmap re-pointing, memremap at early_initcall, initcall-level lines, heartbeat, tail ring.
# Run 1 boots a tiny busybox initramfs, the RAM area is dumped with the QEMU monitor (pmemsave);
# then system_reset (RAM is kept, like the phone's warm reset) and a second dump must show
# attempt=2. Run 2 uses a dtb WITHOUT the reservation: only entry + fdt lines may appear.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../.." && pwd)
IMG=${1:-$TOP/bsp612/out/diag/Image}
Q=$TOP/bsp612/out/diag/qemu; rm -rf "$Q"; mkdir -p "$Q/rd/bin" "$Q/rd/lib" "$Q/rd/proc" "$Q/rd/dev"
fail() { echo "QEMU TEST FAILED: $*" | tee -a "$Q/VERDICT.txt" >&2; exit 1; }
SOCKD=$(mktemp -d); trap 'rm -rf "$SOCKD"' EXIT   # monitor sockets (short path, tmp)
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 2 -m 4G -nographic)   # no -no-reboot: it turns the monitor's system_reset into an exit

# initramfs: busybox from the postmarketOS initramfs (as mkramdisk.sh), /init sleeps, then powers off
( cd "$Q" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$Q/bin/busybox" "$Q/rd/bin/"; cp "$Q/lib/ld-musl-aarch64.so.1" "$Q/rd/lib/"
printf '#!/bin/busybox sh\n/bin/busybox mount -t proc proc /proc\necho "a52bc-qemu: init up $(/bin/busybox cat /proc/uptime)"\n/bin/busybox sleep 30\necho "a52bc-qemu: init done"\n/bin/busybox poweroff -f\n' > "$Q/rd/init"
chmod +x "$Q/rd/init" "$Q/rd/bin/busybox"
( cd "$Q/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$Q/rd.cpio.gz"

"${QM[@]}" -machine dumpdtb="$Q/virt.dtb" >/dev/null 2>&1
# padded: QEMU must be able to add bootargs/initrd to the -dtb blob (else the kernel keeps
# CONFIG_CMDLINE console=ttynull and prints nothing)
dtc -q -I dtb -O dtb -p 8192 -o "$Q/nores.dtb" "$Q/virt.dtb"
cp "$Q/virt.dtb" "$Q/diag.dtb"
fdtput -c "$Q/diag.dtb" /reserved-memory
fdtput -t u "$Q/diag.dtb" /reserved-memory '#address-cells' 2; fdtput -t u "$Q/diag.dtb" /reserved-memory '#size-cells' 2
fdtput "$Q/diag.dtb" /reserved-memory ranges
A=/reserved-memory/a52ram@f0be0000
fdtput -c "$Q/diag.dtb" $A; fdtput -t s "$Q/diag.dtb" $A compatible a52,ramcon
fdtput -t x "$Q/diag.dtb" $A reg 0 f0be0000 0 20000; fdtput "$Q/diag.dtb" $A no-map

mon() {   # <sock> <cmd>...: send monitor commands
	python3 -I - "$@" <<'PYEOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(0.3)
def rd():
    b = b''
    try:
        while True:
            c = s.recv(65536)
            if not c: break
            b += c
    except socket.timeout: pass
    return b
rd()
for c in sys.argv[2:]:
    s.sendall(c.encode() + b'\n'); time.sleep(0.5); rd()
PYEOF
}

# QEMU is TCG here: under a busy PC (parallel builds, load ~36 on 24 cores) 6 s were not enough to reach
# ic:late / the second dump. Scale the waits by 1 + loadavg/cores (or QEMU_SLOW=<factor>).
SLOW=${QEMU_SLOW:-$(awk -v n="$(nproc)" '{f = 1 + int($1 / n + 0.5); print (f > 4 ? 4 : f)}' /proc/loadavg)}
run() {   # <tag> <dtb> <seconds before the dump> [reset] [extra cmdline]
	local tag=$1 dtb=$2 wait=$(( $3 * SLOW )) sock=$SOCKD/$1.mon
	"${QM[@]}" -kernel "$IMG" -dtb "$dtb" -initrd "$Q/rd.cpio.gz" \
		-append "console=ttyAMA0 kvm-arm.mode=none keep_bootcon initcall_debug ignore_loglevel softlockup_panic=1 panic=-1 ${5:-}" \
		-monitor unix:"$sock",server=on,wait=off > "$Q/$tag-console.txt" 2>&1 &
	local pid=$!
	for i in $(seq 50); do [ -S "$sock" ] && break; sleep 0.1; done
	sleep "$wait"
	mon "$sock" "pmemsave 0xf0be0000 0x20000 \"$Q/$tag-1.bin\""
	if [ "${4:-}" = reset ]; then
		mon "$sock" "system_reset"
		sleep "$wait"
		mon "$sock" "pmemsave 0xf0be0000 0x20000 \"$Q/$tag-2.bin\""
	fi
	mon "$sock" quit || true
	wait $pid || true
}
text() { tr -d '\000' < "$1"; }   # what the harness's /proc/a52ram prints

run diag "$Q/diag.dtb" 6 reset a52bc.wdt=off   # rb6w path: CONTROL(2) is issued (QEMU answers -1)
run nores "$Q/nores.dtb" 5
: > "$Q/VERDICT.txt"
for f in diag-1.bin diag-2.bin nores-1.bin; do [ -s "$Q/$f" ] || fail "no RAM dump $f (console: $Q/${f%%-*}-console.txt)"; text "$Q/$f" > "$Q/${f%.bin}.txt"; done
D1=$Q/diag-1.txt; D2=$Q/diag-2.txt; N1=$Q/nores-1.txt
grep -q 'a52bc-qemu: init up' "$Q/diag-console.txt" || fail "kernel did not reach /init (console: $Q/diag-console.txt)"
grep -q '^A52BC1 attempt=1$' "$D1" || fail "run 1: no attempt=1 header"
for w in '^entry t=' '^wdt? entry a0=-[0-9]' '^fdt t=.* ramcon=1 ' '^wdt? before-off a0=' '^wdt CONTROL(2) a0=' '^wdt? after-off a0=' '^param t=.* earlycon=0$' '^paging t=.* dram=0x40000000-' '^setup_end t=' \
	'^ic:early t=' '^ic:core ' '^ic:postcore ' '^ic:arch ' '^ic:subsys ' '^ic:fs ' '^ic:rootfs ' '^ic:device ' '^ic:late ' '^ic:late_sync ' '^hb#[0-9]* t=.* pid1=init '; do
	grep -q "$w" "$D1" || fail "run 1: no line matching '$w' ($D1)"; done
HB=$(sed -n 's/^hb#\([0-9]*\) .*/\1/p' "$D1"); [ "${HB:-0}" -ge 2 ] || fail "run 1: heartbeat did not repeat (hb#$HB)"
grep -q 'Booting Linux on physical CPU' "$D1" && grep -q 'earlycon: a52ram0 at MMIO' "$D1" || fail "run 1: RAM console head lacks the boot banner / earlycon line"
grep -q 'printk: legacy bootconsole \[a52ram0\] enabled' "$D1" || fail "run 1: a52ram0 not registered"
grep -q 'bootconsole \[a52ram0\] disabled\|bootconsole .*a52ram0.* uses init memory' "$D1" "$Q/diag-console.txt" && fail "run 1: a52ram0 was disabled (keep_bootcon / init section)"
grep -q '^T[0-9a-f]\{8\}$' "$D1" || fail "run 1: no tail pointer (console head never filled?)"
grep -q 'Run /init as init process' "$D1" || fail "run 1: 'Run /init' not in the RAM console tail"
TW=$(sed -n 's/^T\([0-9a-f]\{8\}\)$/\1/p' "$D1" | tail -1); echo "tail pointer: T$TW (offset | wraps<<20)"
grep -q '^A52BC1 attempt=2$' "$D2" || fail "run 1 after system_reset: no attempt=2 (counter across a warm reset)"
grep -q '^fdt t=.* ramcon=0 ' "$N1" && grep -q 'breadcrumbs stop here' "$N1" || fail "run 2 (no reservation): gate did not stop at fdt"
grep -q '^param t=\|^ic:' "$N1" && fail "run 2 (no reservation): wrote past the fdt stage"
grep -q 'a52bc-qemu: init up' "$Q/nores-console.txt" || fail "run 2: kernel did not reach /init without the reservation"
python3 -I "$HERE/../tools/a52ram-decode.py" "$D1" -o "$Q/diag-1.decoded.txt" || fail "a52ram-decode.py on the NUL-dropped dump"
python3 -I "$HERE/../tools/a52ram-decode.py" "$Q/diag-1.bin" -o "$Q/diag-1.decoded-raw.txt" || fail "a52ram-decode.py on the raw dump"
tail -c 2000 "$Q/diag-1.decoded.txt" | grep -q 'Run /init as init process\|TERM=linux' || fail "decoded tail does not end at /init ($Q/diag-1.decoded.txt)"
{ echo "QEMU smoke test PASSED ($(date '+%F %T')), Image $(sha256sum < "$IMG" | cut -c1-16)"
  echo "run 1 breadcrumb page:"; sed -n '/^A52BC1/,$p' "$D1" | cut -c1-200 | sed 's/ *$//'; } | tee "$Q/VERDICT.txt"
