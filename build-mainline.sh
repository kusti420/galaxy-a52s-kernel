#!/bin/sh
# Builds the mainline track kernel (sc7280-mainline 7.3 in linux-7.3/, our patch series
# patches/mainline-7.3/) for a52sxq into out-ml/, then runs the offline checks and makes the
# kexec bring-up payload. Offline only: talks to no phone, flashes nothing.
# Usage: ./build-mainline.sh            config (if missing) + Image + dtb + modules + hhwdt
#                                       + checks + ramdisk + kexec dtb dry run
#        ./build-mainline.sh config     (re)create out-ml/.config only
#        ./build-mainline.sh check      checks + ramdisk + dry run on the existing build
#        ./build-mainline.sh <targets>  plain make targets in out-ml/
# Env: LIVE=<harness live dtb> for the mkkexecdtb dry run (default: newest phone-2 harness tree
#      in logs/kx-*-p2-*/harness-live.dtb; kx-cycle "gen" fetches the real one at run time).
set -e
cd "$(dirname "$0")"
TOP=$(pwd)
OUT=$TOP/out-ml
FRAG=$TOP/patches/mainline-7.3/a52sxq-ml.config
# The exact clang ACK pins (build.config.constants CLANG_VERSION), as build-ack.sh.
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
# Generic build identity: the version string must not carry the builder's login or host.
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
# -@ keeps /__symbols__ in the dtb (the ABL needs it for any later real boot; harmless for kexec)
# LOCALVERSION= (empty) keeps setlocalversion from appending "+": release = 7.3.0-a52sxq
MAKE="make -C $TOP/linux-7.3 ARCH=arm64 LLVM=$CLANG/ O=$OUT DTC_FLAGS=-@ LOCALVERSION="
DTB=$OUT/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dtb
IMG=$OUT/arch/arm64/boot/Image
HARNESS_DTB=$TOP/out-ack/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dtb
mkdir -p $OUT

config() {
  $MAKE fp5_defconfig >/dev/null
  (cd linux-7.3 && ARCH=arm64 LLVM=$CLANG/ ./scripts/kconfig/merge_config.sh -m -O $OUT $OUT/.config $FRAG >/dev/null)
  $MAKE olddefconfig >/dev/null
  bad=0
  for s in $(grep -E '^CONFIG_[A-Z0-9_]+=' $FRAG | cut -d= -f1); do
    want=$(grep "^$s=" $FRAG); grep -qx "$want" $OUT/.config || { echo "CONFIG DID NOT TAKE: $want (have: $(grep "^$s=\|^# $s " $OUT/.config))"; bad=1; }
  done
  for s in $(grep -E '^# CONFIG_[A-Z0-9_]+ is not set' $FRAG | cut -d' ' -f2); do
    grep -q "^$s=[ym]" $OUT/.config && { echo "CONFIG STILL SET: $s"; bad=1; }
  done
  [ $bad = 0 ] || exit 1
}

hhwdt() { # modules/hhwdt built against this kernel, in a copy (modules/hhwdt holds the 6.18 build)
  rm -rf $OUT/ext/hhwdt; mkdir -p $OUT/ext/hhwdt
  cp modules/hhwdt/hhwdt.c modules/hhwdt/Kbuild $OUT/ext/hhwdt/
  $MAKE M=$OUT/ext/hhwdt modules >/dev/null
}

checks() {
  fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
  echo "== offline checks"
  # kernel config / image
  grep -q '^CONFIG_RELOCATABLE=y' $OUT/.config || fail "CONFIG_RELOCATABLE is off"
  for s in KEXEC KEXEC_FILE DEVTMPFS PSTORE_RAM USB_CONFIGFS_NCM USB_CONFIGFS_ACM SERIAL_EARLYCON; do
    grep -q "^CONFIG_$s=y" $OUT/.config || fail "CONFIG_$s is not =y"
  done
  grep -q '^CONFIG_GUNYAH_WATCHDOG=m' $OUT/.config || fail "CONFIG_GUNYAH_WATCHDOG is not =m (built in it would stop the inherited watchdog)"
  [ "$(od -An -c -j56 -N4 $IMG | tr -d ' ')" = 'ARMd' ] || fail "Image has no arm64 magic"
  # header flags (offset 24): bit 0 = big endian, bits 1-2 page size (1 = 4K), bit 3 = may be placed anywhere
  FL=$(od -An -tu8 -j24 -N8 $IMG | tr -d ' ')
  [ $((FL & 1)) = 0 ] && [ $(((FL >> 1) & 3)) = 1 ] || fail "Image header flags $FL: not LE/4K"
  ISZ=$(od -An -tu8 -j16 -N8 $IMG | tr -d ' ')
  echo "ok   Image: RELOCATABLE, LE, 4K, header flags $FL, file $(stat -c %s $IMG) B, image_size $ISZ B"
  # command line: 4096 in the uapi header and in the built kernel (boot_command_line size)
  grep -q 'define COMMAND_LINE_SIZE[[:space:]]*4096' linux-7.3/arch/arm64/include/uapi/asm/setup.h || fail "COMMAND_LINE_SIZE is not 4096"
  BCL=$($CLANG/llvm-nm -S $OUT/vmlinux | awk '$4=="boot_command_line"{print $2}')
  [ $((0x$BCL)) = 4096 ] || fail "boot_command_line is 0x$BCL bytes, not 4096"
  echo "ok   COMMAND_LINE_SIZE 4096 (boot_command_line 0x$BCL)"
  # kexec alternative FDT + nocfi + a52ram are in
  $CLANG/llvm-nm $OUT/vmlinux | grep -q ' bin_attr_kexec_fdt$' || fail "/sys/firmware/kexec_fdt patch missing"
  $CLANG/llvm-nm $OUT/vmlinux | grep -q 'a52ram' || fail "a52ram earlycon not built"
  echo "ok   kexec_fdt sysfs file, a52ram earlycon built in"
  # device tree
  python3 - "$DTB" "$HARNESS_DTB" <<'EOF' || fail "device tree checks"
import sys, libfdt
from libfdt import Fdt, QUIET_NOTFOUND
f = Fdt(open(sys.argv[1], 'rb').read())
bad = []
def node(p):
    # exact names per component: libfdt's path lookup lets "/soc" match "soc@0", and this tree
    # has both (kodiak's soc@0 and our /soc placeholder for the hypervisor overlay)
    o = 0
    for c in [x for x in p.split('/') if x]:
        s = f.first_subnode(o, QUIET_NOTFOUND)
        while s >= 0 and f.get_name(s) != c: s = f.next_subnode(s, QUIET_NOTFOUND)
        if s < 0: return -1
        o = s
    return o
def prop(p, n):
    o = node(p)
    if o < 0: return None
    v = f.getprop(o, n, QUIET_NOTFOUND)
    return None if isinstance(v, int) else bytes(v)
def u(b, i=0, c=2): return int.from_bytes(b[i*4:(i+c)*4], 'big')
def sub(p):
    o = node(p); out = []
    c = f.first_subnode(o, QUIET_NOTFOUND)
    while c >= 0: out.append(f.get_name(c)); c = f.next_subnode(c, QUIET_NOTFOUND)
    return out
# 1. __symbols__ and the labels the ABL / hypervisor overlay need (research/bootloader-acceptance.md):
#    soc, intc as in mkimage-ack.sh, plus the stock labels and placeholders
if node('/__symbols__') < 0: bad.append('no /__symbols__')
for l in ('soc', 'intc', 'aliases', 'firmware', 'reserved_memory', 'wdog', 'qcom_tzlog', 'arch_timer'):
    if prop('/__symbols__', l) is None: bad.append(f'label {l} missing')
for p in ('/soc/qcom,wdt@17c10000', '/soc/timer', '/soc/tz-log@0x146aa720', '/aliases', '/firmware',
          '/soc@0/watchdog@17c10000', '/timer'):
    if node(p) < 0: bad.append(f'node {p} missing')
if prop('/soc@0/watchdog@17c10000', 'status') not in (b'reserved\0', b'disabled\0'): bad.append('watchdog@17c10000 is not reserved/disabled')
if prop('/reboot-mode', 'mode-download') != (0x15).to_bytes(4, 'big'): bad.append('/reboot-mode mode-download != 0x15')
# 2. reserved-memory: no overlaps among static regions
rs = []
for n in sub('/reserved-memory'):
    r = prop('/reserved-memory/' + n, 'reg')
    if r and len(r) >= 16: rs.append((u(r, 0), u(r, 2), n))
rs.sort(); ov = [(a, b) for a, b in zip(rs, rs[1:]) if a[0] + a[1] > b[0]]
for a, b in ov: bad.append(f'reserved-memory overlap: {a[2]} {a[0]:#x}+{a[1]:#x} / {b[2]} {b[0]:#x}+{b[1]:#x}')
print(f"ok   reserved-memory: {len(rs)} static regions, {len(ov)} overlaps" if not ov else "FAIL reserved-memory overlaps")
for need in ('kaslr@a0001000', 'a52ram@f0be0000'):
    if need not in [x[2] for x in rs]: bad.append(f'/reserved-memory/{need} missing')
# rmtfs (the harness assigns it to the modem; mkkexecdtb carries it otherwise)
if not any(n.startswith('rmtfs') for _, _, n in rs): print("note rmtfs not reserved in the base (mkkexecdtb 3b adds it)")
# 3. ramoops identical to the 6.18 harness (the harness's crash guard reads our console from it)
h = Fdt(open(sys.argv[2], 'rb').read())
def hprop(p, n):
    o = h.path_offset(p, QUIET_NOTFOUND); v = h.getprop(o, n, QUIET_NOTFOUND) if o >= 0 else -1
    return None if isinstance(v, int) else bytes(v)
for n in ('reg', 'record-size', 'console-size', 'ftrace-size', 'pmsg-size', 'compatible'):
    a, b = prop('/reserved-memory/ramoops@f0b00000', n), hprop('/reserved-memory/ramoops@f0b00000', n)
    if a is None or a != b: bad.append(f'ramoops {n} differs from the harness ({a} vs {b})')
r = prop('/reserved-memory/ramoops@f0b00000', 'reg')
if r and (u(r, 0), u(r, 2)) != (0xf0b00000, 0xe0000): bad.append('ramoops reg is not 0xf0b00000+0xe0000')
if prop('/reserved-memory/ramoops@f0b00000', 'record-size') != (0x20000).to_bytes(4, 'big'): bad.append('ramoops record-size != 0x20000')
# 4. regulators: every rpmh regulator pinned min == max
pinned = 0
for rg in ('/soc@0/rsc@18200000/regulators-0', '/soc@0/rsc@18200000/regulators-1'):
    for n in sub(rg) if node(rg) >= 0 else []:
        lo, hi = prop(f'{rg}/{n}', 'regulator-min-microvolt'), prop(f'{rg}/{n}', 'regulator-max-microvolt')
        if lo is None or lo != hi: bad.append(f'{rg}/{n}: min != max')
        else: pinned += 1
if pinned == 0: bad.append('no pinned rpmh regulators found (apps_rsc path changed?)')
if bad:
    print('\n'.join('FAIL ' + b for b in bad)); sys.exit(1)
print(f"ok   dtb: __symbols__ + labels soc intc aliases firmware reserved_memory wdog qcom_tzlog arch_timer, "
      f"overlay placeholders, watchdog reserved, mode-download 0x15, ramoops = harness (0xe0000, record 0x20000), "
      f"{pinned} rpmh regulators pinned min == max, {f.totalsize()} B")
EOF
}

payload() {
  echo "== ramdisk + kexec dtb"
  # our bring-up ramdisk with the 7.3 hhwdt.ko (/hhwdt.ko: init disarms the inherited watchdog
  # with it) and the upstream gunyah_wdt.ko in /extra (by hand only)
  rm -rf $OUT/rd-extra; mkdir -p $OUT/rd-extra
  cp $OUT/drivers/watchdog/gunyah_wdt.ko $OUT/rd-extra/
  [ -f ramdisk/extra/rb.prev ] && cp ramdisk/extra/rb.prev $OUT/rd-extra/
  OUT_RD=$OUT/ramdisk-ml.cpio.gz HHWDT=$OUT/ext/hhwdt/hhwdt.ko EXTRA_DIR=$OUT/rd-extra ./mkramdisk.sh >/dev/null
  zcat $OUT/ramdisk-ml.cpio.gz | cpio -it --quiet | sed "s|^\./||" > $OUT/ramdisk-ml.list
  for f in init leave kexec-run kx rb hhwdt.ko extra/gunyah_wdt.ko bin/busybox; do
    grep -qx "$f" $OUT/ramdisk-ml.list || { echo "CHECK FAILED: ramdisk lacks $f" >&2; exit 1; }
  done
  # the 7.3 hhwdt.ko must carry this kernel's vermagic
  VM=$(modinfo -F vermagic $OUT/ext/hhwdt/hhwdt.ko)
  KR=$(cat $OUT/include/config/kernel.release)
  case "$VM" in "$KR "*) ;; *) echo "CHECK FAILED: hhwdt vermagic '$VM' vs kernel $KR" >&2; exit 1;; esac
  echo "ok   ramdisk $OUT/ramdisk-ml.cpio.gz: hhwdt.ko ($KR) + extra/gunyah_wdt.ko"
  # dry run of the dtb hand-over (kx-cycle 'gen' does the same with the harness's live tree of that boot)
  L=${LIVE:-$(ls -t logs/kx-*-p2-*/harness-live.dtb 2>/dev/null | head -1)}
  [ -n "$L" ] || L=testdev-PHONE2/live.dtb
  mkdir -p $OUT/kx
  python3 kexec/mkkexecdtb.py --base $DTB --live "$L" -o $OUT/kx/kexec-dryrun.dtb > $OUT/kx/mkkexecdtb-dryrun.txt
  echo "live tree: $L" >> $OUT/kx/mkkexecdtb-dryrun.txt
  grep -q WARNING $OUT/kx/mkkexecdtb-dryrun.txt && { cat $OUT/kx/mkkexecdtb-dryrun.txt; echo "CHECK FAILED: mkkexecdtb warnings" >&2; exit 1; }
  echo "ok   mkkexecdtb dry run against $L: $(tail -n 2 $OUT/kx/mkkexecdtb-dryrun.txt | head -1)"
}

summary() {
  echo "== artefacts"
  for f in $IMG $DTB $OUT/ramdisk-ml.cpio.gz $OUT/kx/kexec-dryrun.dtb $OUT/ext/hhwdt/hhwdt.ko $OUT/drivers/watchdog/gunyah_wdt.ko; do
    [ -f $f ] && echo "$(sha256sum $f | cut -c1-64)  $(stat -c %s $f)  ${f#$TOP/}"
  done
  echo "kernel release: $(cat $OUT/include/config/kernel.release)"
}

case "${1:-}" in
  config) config; exit 0;;
  check) checks; payload; summary; exit 0;;
  "") ;;
  *) $MAKE -j22 "$@"; exit 0;;
esac
[ -f $OUT/.config ] || config
$MAKE -j22 Image qcom/sm7325-samsung-a52sxq.dtb modules > $OUT/build.log 2>&1 || { tail -n 30 $OUT/build.log; exit 1; }
hhwdt
checks
payload
summary
