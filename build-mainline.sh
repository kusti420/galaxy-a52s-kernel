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
# base + sm7325-samsung-a52sxq-panel.dtbo (MDSS/DSI0/S6E3FC3 panel): the M3 display test tree
PANEL_DTB=$OUT/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq-panel.dtb
# base + panel + sm7325-samsung-a52sxq-gpu.dtbo (Adreno 642L + GMU + own zap): the M3 GPU test tree
GPU_DTB=$OUT/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq-gpu.dtb
# base + sm7325-samsung-a52sxq-wifi.dtbo (WPSS remoteproc + WCN6750 ath11k): the M4 Wi-Fi test tree
WIFI_DTB=$OUT/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq-wifi.dtb
# wifi tree + sm7325-samsung-a52sxq-bt.dtbo (QUP0 SE7 UART + WCN6750 Bluetooth): the M4 BT test tree
BT_DTB=$OUT/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq-wifi-bt.dtb
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
  # read-only EPSS register dump (L3 / CPU domain votes and current levels) for the L3 check
  rm -rf $OUT/ext/epssdump; mkdir -p $OUT/ext/epssdump
  cp drivers612/debug/epssdump/epssdump.c drivers612/debug/epssdump/Kbuild $OUT/ext/epssdump/
  $MAKE M=$OUT/ext/epssdump modules >/dev/null
  # read-only DPU scanout state (which buffer the panel shows, timing engine running)
  rm -rf $OUT/ext/mdpdump; mkdir -p $OUT/ext/mdpdump
  cp modules/mdpdump/mdpdump.c modules/mdpdump/Kbuild $OUT/ext/mdpdump/
  $MAKE M=$OUT/ext/mdpdump modules >/dev/null
}

# modules the ramdisk carries in /extra (loaded by hand only: KX_EXTRA / the shell)
EXTRA_KO="drivers/watchdog/gunyah_wdt.ko drivers/remoteproc/qcom_pil_info.ko drivers/remoteproc/qcom_common.ko
  drivers/remoteproc/qcom_q6v5.ko drivers/remoteproc/qcom_q6v5_pas.ko drivers/misc/fastrpc.ko
  drivers/mmc/host/sdhci-msm.ko drivers/input/misc/gpio-vibra.ko ext/epssdump/epssdump.ko ext/mdpdump/mdpdump.ko
  drivers/gpu/drm/panel/panel-samsung-s6e3fc3.ko drivers/input/touchscreen/stmfts5.ko
  drivers/net/wireless/ath/ath11k/ath11k_ahb.ko drivers/bluetooth/btqca.ko drivers/bluetooth/hci_uart.ko"

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
# 4. regulators: every rpmh regulator pinned min == max, at exactly the downstream
#    qcom,init-voltage of that rail (downstream-dt/regulators-r02.txt, e.g. "vrm ldob7 ... init= 2952000")
init = {}
for line in open('downstream-dt/regulators-r02.txt'):
    w = line.split()
    if len(w) > 2 and w[0] == 'vrm' and '_ao' not in w[2] and '_so' not in w[2] and 'init=' in line:
        v = line.split('init=')[1].split()[0]
        if v != '-': init[w[1]] = int(v)
pinned = 0
for rg, pm in (('/soc@0/rsc@18200000/regulators-0', 'b'), ('/soc@0/rsc@18200000/regulators-1', 'c'),
               ('/soc@0/rsc@18200000/regulators-2', 'e')):
    for n in sub(rg) if node(rg) >= 0 else []:
        lo, hi = prop(f'{rg}/{n}', 'regulator-min-microvolt'), prop(f'{rg}/{n}', 'regulator-max-microvolt')
        key = ('smp' if n.startswith('smps') else 'ldo') + pm + n.lstrip('smpsldo')
        if lo is None or lo != hi: bad.append(f'{rg}/{n}: min != max')
        elif key not in init: bad.append(f'{rg}/{n}: no downstream init voltage for {key}')
        elif u(lo, 0, 1) != init[key]: bad.append(f'{rg}/{n}: {u(lo, 0, 1)} uV != downstream init {init[key]} ({key})')
        else: pinned += 1
if pinned == 0: bad.append('no pinned rpmh regulators found (apps_rsc path changed?)')
if bad:
    print('\n'.join('FAIL ' + b for b in bad)); sys.exit(1)
print(f"ok   dtb: __symbols__ + labels soc intc aliases firmware reserved_memory wdog qcom_tzlog arch_timer, "
      f"overlay placeholders, watchdog reserved, mode-download 0x15, ramoops = harness (0xe0000, record 0x20000), "
      f"{pinned} rpmh regulators pinned min == max == downstream init voltage, {f.totalsize()} B")
EOF
  # panel tree (M3): the two panel rails pinned to the panel's own downstream supply entries
  # (qcom,panel-supply-entries of ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD), NOT to the regulator
  # init voltages (L8C 1.62 / L13C 2.7 V); base tree without them; panel + DSI wiring present
  python3 - "$DTB" "$PANEL_DTB" <<'EOF' || fail "panel device tree checks"
import re, subprocess, sys
dts = lambda f: subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', f], capture_output=True, text=True).stdout
base, pan = dts(sys.argv[1]), dts(sys.argv[2])
src = open('downstream-dt/a52sxq-r02.dts').read()
node = src[src.index('ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD: ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD {'):]
node = node[:node.index('qcom,mdss-dsi-display-timings')]
want = {}
for e in re.finditer(r'qcom,panel-supply-entry@\d \{(.*?)\};', node, re.S):
    b = e.group(1)
    lo = int(re.search(r'supply-min-voltage = <(0x[0-9a-f]+)>', b).group(1), 16)
    hi = int(re.search(r'supply-max-voltage = <(0x[0-9a-f]+)>', b).group(1), 16)
    want[re.search(r'supply-name = "(\w+)"', b).group(1)] = (lo, hi)
bad = []
if want != {'panel_vddi': (1800000, 1800000), 'panel_vci': (3000000, 3000000)}:
    bad.append(f'downstream supply entries changed: {want}')
def rail(t, n):
    m = re.search(r'\{([^{}]*regulator-name = "vreg_' + n + r'"[^{}]*)\}', t)
    if not m: return None
    g = lambda p: int(re.search(p + r' = <(0x[0-9a-f]+)>', m.group(1)).group(1), 16)
    return (g('regulator-min-microvolt'), g('regulator-max-microvolt'))
for n, sup in (('l8c', 'panel_vddi'), ('l13c', 'panel_vci')):
    if rail(base, n) is not None: bad.append(f'base tree describes {n} (panel rails belong to the panel overlay only)')
    if rail(pan, n) != want.get(sup): bad.append(f'panel tree {n} = {rail(pan, n)} != downstream {sup} {want.get(sup)}')
for need in ('samsung,s6e3fc3-ams646yd01', 'vddi-supply', 'vci-supply', 'reset-gpios', 'data-lanes = <0x00 0x01 0x02 0x03>'):
    if need not in pan: bad.append(f'panel tree lacks {need}')
if 'simple-framebuffer' not in pan: bad.append('panel tree lost the simple-framebuffer')
if bad:
    print('\n'.join('FAIL ' + b for b in bad)); sys.exit(1)
print(f"ok   panel dtb: L8C {want['panel_vddi'][0]} uV / L13C {want['panel_vci'][0]} uV = downstream panel supply "
      f"entries (not the init voltages), base tree without them, DSI0 4 lanes + S6E3FC3, simple-framebuffer kept")
EOF
  # touch (M3): FTS5CU56A on I2C13, address / attention GPIO / AVDD rail as downstream
  python3 tools/check-touch-dt.py $DTB || fail "touch device tree checks"
  # Wi-Fi (M4): WPSS + wifi only in the wifi tree, values against the downstream WPSS / icnss2 nodes
  python3 tools/check-wifi-dt.py $DTB $WIFI_DTB || fail "Wi-Fi device tree checks"
  # GPU (M3 part 3): gpu tree = panel tree + GPU, values against the downstream kgsl nodes
  python3 tools/check-gpu-dt.py $DTB $PANEL_DTB $GPU_DTB || fail "GPU device tree checks"
}

payload() {
  echo "== ramdisk + kexec dtb"
  # our bring-up ramdisk with the 7.3 hhwdt.ko (/hhwdt.ko: init disarms the inherited watchdog
  # with it) and the upstream gunyah_wdt.ko in /extra (by hand only)
  rm -rf $OUT/rd-extra; mkdir -p $OUT/rd-extra
  for k in $EXTRA_KO; do
    [ -f $OUT/$k ] || { echo "CHECK FAILED: module $k not built" >&2; exit 1; }
    cp $OUT/$k $OUT/rd-extra/
  done
  # static helpers (tools/*.c, no libc): ffbuzz plays one force-feedback effect (vibrator test),
  # frpcattach attaches to a DSP guest-OS PD over FastRPC (first SMMU compute-CB use),
  # i2cpoke writes raw I2C bytes (touch IRQ self-test), evcount decodes input_event captures
  # gputest runs CP_MEM_WRITE submits through drm/msm (GPU test, no Mesa)
  for t in ffbuzz frpcattach i2cpoke evcount gputest nlscan bthci; do [ -f tools/$t ] && cp tools/$t $OUT/rd-extra/; done
  cp patches/mainline-7.3/m2up.sh patches/mainline-7.3/m2check.sh patches/mainline-7.3/m3touch.sh patches/mainline-7.3/m3gpu.sh patches/mainline-7.3/m4wifi.sh patches/mainline-7.3/m4bt.sh $OUT/rd-extra/
  [ -f ramdisk/extra/rb.prev ] && cp ramdisk/extra/rb.prev $OUT/rd-extra/
  OUT_RD=$OUT/ramdisk-ml.cpio.gz HHWDT=$OUT/ext/hhwdt/hhwdt.ko EXTRA_DIR=$OUT/rd-extra ./mkramdisk.sh >/dev/null
  zcat $OUT/ramdisk-ml.cpio.gz | cpio -it --quiet | sed "s|^\./||" > $OUT/ramdisk-ml.list
  for f in init leave kexec-run kx rb hhwdt.ko bin/busybox extra/m2up.sh extra/m2check.sh extra/m3touch.sh extra/m3gpu.sh extra/m4wifi.sh extra/m4bt.sh extra/ffbuzz extra/frpcattach extra/i2cpoke extra/evcount extra/gputest extra/nlscan extra/bthci $(for k in $EXTRA_KO; do echo extra/${k##*/}; done); do
    grep -qx "$f" $OUT/ramdisk-ml.list || { echo "CHECK FAILED: ramdisk lacks $f" >&2; exit 1; }
  done
  # firmware only ever comes from the phone's own mounted apnhlos (firmware_class.path): the
  # ramdisk carries no firmware directory, and every firmware-name in the dtb is a bare file name
  grep -q -E '^(lib/firmware|vendor/firmware)' $OUT/ramdisk-ml.list && { echo "CHECK FAILED: ramdisk carries firmware" >&2; exit 1; }
  for t in $DTB $PANEL_DTB $GPU_DTB $WIFI_DTB $BT_DTB; do
    FWN=$(dtc -I dtb -O dts $t 2>/dev/null | grep -o 'firmware-name = [^;]*' | grep -v '= "[^/"]*"$' || true)
    [ -z "$FWN" ] || { echo "CHECK FAILED: firmware-name with a path in ${t##*/}: $FWN" >&2; exit 1; }
  done
  echo "ok   firmware: none in the ramdisk; firmware-names $(dtc -I dtb -O dts $GPU_DTB 2>/dev/null | grep -o 'firmware-name = "[^"]*"' | cut -d'"' -f2 | tr '\n' ' ')(bare, resolved in the own apnhlos; SQE/GMU from the own vendor at run time)"
  # the 7.3 hhwdt.ko must carry this kernel's vermagic
  VM=$(modinfo -F vermagic $OUT/ext/hhwdt/hhwdt.ko)
  KR=$(cat $OUT/include/config/kernel.release)
  case "$VM" in "$KR "*) ;; *) echo "CHECK FAILED: hhwdt vermagic '$VM' vs kernel $KR" >&2; exit 1;; esac
  echo "ok   ramdisk $OUT/ramdisk-ml.cpio.gz: hhwdt.ko ($KR) + extra/: $(cd $OUT/rd-extra && echo *)"
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
  for f in $IMG $DTB $PANEL_DTB $GPU_DTB $WIFI_DTB $BT_DTB $OUT/ramdisk-ml.cpio.gz $OUT/kx/kexec-dryrun.dtb $OUT/ext/hhwdt/hhwdt.ko $OUT/drivers/watchdog/gunyah_wdt.ko; do
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
$MAKE -j22 Image qcom/sm7325-samsung-a52sxq.dtb qcom/sm7325-samsung-a52sxq-panel.dtb qcom/sm7325-samsung-a52sxq-gpu.dtb qcom/sm7325-samsung-a52sxq-wifi.dtb qcom/sm7325-samsung-a52sxq-wifi-bt.dtb modules > $OUT/build.log 2>&1 || { tail -n 30 $OUT/build.log; exit 1; }
hhwdt
checks
payload
summary
