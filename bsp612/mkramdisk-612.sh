#!/bin/bash
# Builds bsp612/out/bringup/ramdisk-612.cpio.gz: the bring-up ramdisk for the Qualcomm 6.12 BSP
# (GKI Image + vendor modules). Same busybox/musl/unudhcpd/rb as the 6.18 flow's mkramdisk.sh
# (which this script does not touch), plus bsp612/ramdisk/{init,leave} and the first-stage
# modules in dependency order. Packs only; nothing is flashed.
#
#   /lib/modules/*.ko        stripped (--strip-debug), flat
#   /lib/modules/load.list   insmod order: one file name per line (+ optional parameters)
#   /lib/modules/hhwdt.ko    modules/hhwdt rebuilt against out/lahaina (copy in out/bringup/hhwdt)
#   /lib/modules/sec_core.ko samsung612/modules/sec_core (restart reasons; loaded by init)
#   /extra/                  bsp612/ramdisk/extra/* if present (test payload)
set -e
BSP=$(cd "$(dirname "$0")" && pwd)
TOP=$(dirname "$BSP")
OUT=$BSP/out/bringup
DIST=$BSP/out/dist
KREL=$(ls "$DIST/lib/modules" | head -1)
MODS=$DIST/lib/modules/$KREL
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
STRIP=$CLANG/llvm-strip
mkdir -p "$OUT"

# ---- 1. hhwdt for 6.12 (separate copy; the 6.18 .ko in modules/hhwdt is not touched)
mkdir -p "$OUT/hhwdt"
cp "$TOP/modules/hhwdt/hhwdt.c" "$TOP/modules/hhwdt/Kbuild" "$OUT/hhwdt/"
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
  make -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" \
  KCONFIG_EXT_PREFIX="$BSP/soc-repo/" M="$OUT/hhwdt" modules > "$OUT/hhwdt.log" 2>&1 \
  || { tail -20 "$OUT/hhwdt.log"; echo "hhwdt build failed" >&2; exit 1; }

# ---- 2. module list: first-stage.a52sxq.list, minus what the first bring-up must not load,
#         plus what the A52s USB path needs; then closed over modules.dep, dependencies first.
#   dropped:
#     qcom-dload-mode   arms Qualcomm ramdump/"download mode" on reset through TCSR/SCM; on a
#                       Samsung phone a crash would then end in upload mode (needs keys)
#     gh_virt_wdt, qcom_wdt_core   Qualcomm's driver for the same hypervisor watchdog hhwdt
#                       drives (proven on this phone; the 5.4 driver's time units were wrong)
#     sdhci-msm, cqhci  SD card: not needed, its board pins/regulators are not described
#     phy-msm-ssusb-qmp the phone runs USB 2.0 only (QMP PHY node disabled in the overlay)
#     msm_sharedmem     modem shared-memory UIO; no modem in this stage
#   added:
#     eud               dwc3-msm's extcon phandle points at it; without it dwc3-msm defers forever
#     phy-generic       "usb-nop-xceiv", the phone's second usb-phy
DROP="qcom-dload-mode gh_virt_wdt qcom_wdt_core sdhci-msm cqhci phy-msm-ssusb-qmp msm_sharedmem"
ADD="drivers/soc/qcom/eud.ko drivers/usb/phy/phy-generic.ko"
python3 - "$DIST/first-stage.a52sxq.list" "$MODS/modules.dep" "$OUT/load.paths" "$DROP" "$ADD" <<'EOF'
import sys, os
lst, dep, out, drop, add = sys.argv[1:6]
drop = set(drop.split())
deps = {}
for l in open(dep):
    k, _, v = l.partition(':')
    deps[k.strip()] = v.split()
def find(path):
    if path in deps: return path
    base = os.path.basename(path)
    hits = [k for k in deps if os.path.basename(k) == base]
    if len(hits) != 1: sys.exit("module %s: %d matches in modules.dep" % (path, len(hits)))
    return hits[0]
want = [l.strip() for l in open(lst) if l.strip() and not l.startswith('#')] + add.split()
# cpufreq-hw before WALT (Qualcomm order). The crashes once blamed on the order were WALT running
# without android_arch_task_struct_size=512 (bsp612/CPUFREQ-ANALYSIS.md).
cf = 'drivers/cpufreq/qcom-cpufreq-hw.ko'
w = [i for i, x in enumerate(want) if os.path.basename(x) == 'sched-walt.ko']
if w and cf not in want and os.environ.get('A52_CPUFREQ', '1') == '1': want.insert(w[0], cf)   # default on since the task_struct_size fix; A52_CPUFREQ=0 leaves it out
order, seen = [], set()
def name(p): return os.path.basename(p)[:-3]
def visit(p, why):
    p = find(p)
    if p in seen: return
    if name(p) in drop:
        if why: sys.exit("dropped module %s is a dependency of %s" % (name(p), why))
        return
    seen.add(p)
    for d in deps[p]: visit(d, name(p))
    order.append(p)
for w in want: visit(w, None)
open(out, 'w').write('\n'.join(order) + '\n')
print("modules: %d (list %d, dropped %d)" % (len(order), len(want), len([w for w in want if name(w) in drop])))
EOF

# ---- 3. ramdisk tree
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/r/bin" "$T/r/lib/modules" "$T/r/usr/bin" "$T/r/sbin"
( cd "$T/src" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox bin/busybox-extras lib/ld-musl-aarch64.so.1 usr/bin/unudhcpd 2>/dev/null )
cp "$T/src/bin/busybox" "$T/src/bin/busybox-extras" "$T/r/bin/"
cp "$T/src/lib/ld-musl-aarch64.so.1" "$T/r/lib/"
ln -s ld-musl-aarch64.so.1 "$T/r/lib/libc.musl-aarch64.so.1"
cp "$T/src/usr/bin/unudhcpd" "$T/r/usr/bin/"
if [ -d "$BSP/ramdisk/extra" ]; then mkdir -p "$T/r/extra"; cp -r "$BSP/ramdisk/extra/." "$T/r/extra/"; fi
cp "$BSP/ramdisk/init" "$T/r/init"; cp "$BSP/ramdisk/leave" "$T/r/leave"; cp "$TOP/tools/rb" "$T/r/rb"
chmod 755 "$T/r/init" "$T/r/leave" "$T/r/rb"
: > "$T/r/lib/modules/load.list"
while read -r p; do
  f=$(basename "$p")
  [ -e "$T/r/lib/modules/$f" ] && { echo "duplicate module file name $f" >&2; exit 1; }
  cp "$MODS/$p" "$T/r/lib/modules/$f"
  echo "$f" >> "$T/r/lib/modules/load.list"
done < "$OUT/load.paths"
cp "$OUT/hhwdt/hhwdt.ko" "$TOP/samsung612/modules/sec_core/sec_core.ko" "$T/r/lib/modules/"
"$STRIP" --strip-debug "$T/r/lib/modules/"*.ko
# every module must be for this kernel
for k in "$T/r/lib/modules/"*.ko; do
  strings "$k" | grep -q "^vermagic=$KREL " || { echo "wrong vermagic: $k" >&2; exit 1; }
done
cp "$T/r/lib/modules/load.list" "$OUT/load.list"
( cd "$T/r" && find . | sort | cpio -o -H newc --quiet -R 0:0 | gzip -9 ) > "$OUT/ramdisk-612.cpio.gz"
echo "modules in ramdisk: $(ls "$T/r/lib/modules/"*.ko | wc -l) files, $(du -sb "$T/r/lib/modules" | cut -f1) bytes stripped"
ls -la "$OUT/ramdisk-612.cpio.gz"
