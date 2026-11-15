#!/bin/bash
# bsp618/android/out/bringup/ramdisk-618.cpio.gz: the 6.18 counterpart of bsp612/mkramdisk-612.sh
# (bring-up ramdisk = layer 2 of the Android kexec test ramdisk). Same busybox/musl/unudhcpd/rb,
# same bsp612/ramdisk/{init,leave}, same module selection and order rules as 6.12; only the
# module source is the 6.18 port (bsp618/android/out/dist from mkdist-618.sh). Packs only.
#
#   /lib/modules/*.ko        stripped (--strip-debug), flat
#   /lib/modules/load.list   insmod order (helper2.sh / init read it)
#   /lib/modules/hhwdt.ko    modules/hhwdt rebuilt against the 6.18 vendor kernel (port tree)
#   /lib/modules/sec_core.ko samsung612/modules/sec_core, 6.18 port build
#
# Differences from 6.12, all automatic and printed:
#   - a list entry that the 6.18 GKI has BUILT IN (modules.builtin) is dropped (e.g. hwmon: GKI
#     6.18 has CONFIG_HWMON=y; the soc-repo copy is out of the build, port618.py DROPPED)
#   - out/bringup/compare-612.txt: this load.list vs bsp612/out/bringup/load.list
# Env: A52_CPUFREQ=0 leaves qcom-cpufreq-hw out (default: in, before sched-walt, as on 6.12).
set -e
A=$(cd "$(dirname "$0")" && pwd); B=$(dirname "$A"); TOP=$(dirname "$B")
OUT=$A/out/bringup
DIST=$A/out/dist
KREL=$(ls "$DIST/lib/modules" | head -1)
MODS=$DIST/lib/modules/$KREL
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
STRIP=$CLANG/llvm-strip
HHWDT=$B/src/modules/hhwdt/hhwdt.ko
SECCORE=$B/src/samsung612/modules/sec_core/sec_core.ko
for f in "$DIST/first-stage.a52sxq.list" "$MODS/modules.dep" "$HHWDT" "$SECCORE"; do
  [ -f "$f" ] || { echo "missing $f (run bsp618/port/build618.sh, then mkdist-618.sh)" >&2; exit 1; }
done
mkdir -p "$OUT"

# ---- module list: identical DROP/ADD to bsp612/mkramdisk-612.sh (reasons there)
DROP="qcom-dload-mode gh_virt_wdt qcom_wdt_core sdhci-msm cqhci phy-msm-ssusb-qmp msm_sharedmem"
ADD="drivers/soc/qcom/eud.ko drivers/usb/phy/phy-generic.ko"
python3 -I - "$DIST/first-stage.a52sxq.list" "$MODS/modules.dep" "$OUT/load.paths" "$DROP" "$ADD" "$MODS/modules.builtin" <<'EOF'
import sys, os
lst, dep, out, drop, add, builtin = sys.argv[1:7]
drop = set(drop.split())
gki_builtin = {os.path.basename(l.strip())[:-3] for l in open(builtin) if l.strip()}
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
cf = 'drivers/cpufreq/qcom-cpufreq-hw.ko'
w = [i for i, x in enumerate(want) if os.path.basename(x) == 'sched-walt.ko']
if not w: sys.exit("sched-walt.ko is not in the first-stage list")
if cf not in want and os.environ.get('A52_CPUFREQ', '1') == '1': want.insert(w[0], cf)
order, seen = [], set()
def name(p): return os.path.basename(p)[:-3]
for x in want:
    if name(x) in gki_builtin:
        print("dropped %s: built into the 6.18 GKI (modules.builtin)" % name(x))
        drop.add(name(x))
def visit(p, why):
    p = find(p)
    if p in seen: return
    if name(p) in drop:
        if why: sys.exit("dropped module %s is a dependency of %s" % (name(p), why))
        return
    seen.add(p)
    for d in deps[p]: visit(d, name(p))
    order.append(p)
for x in want: visit(x, None)
open(out, 'w').write('\n'.join(order) + '\n')
print("modules: %d (list %d, dropped %d)" % (len(order), len(want), len([x for x in want if name(x) in drop])))
EOF

# ---- ramdisk tree (as 6.12)
T=$(mktemp -d -p "$A/out")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/r/bin" "$T/r/lib/modules" "$T/r/usr/bin" "$T/r/sbin"
( cd "$T/src" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox bin/busybox-extras lib/ld-musl-aarch64.so.1 usr/bin/unudhcpd 2>/dev/null )
cp "$T/src/bin/busybox" "$T/src/bin/busybox-extras" "$T/r/bin/"
cp "$T/src/lib/ld-musl-aarch64.so.1" "$T/r/lib/"
ln -s ld-musl-aarch64.so.1 "$T/r/lib/libc.musl-aarch64.so.1"
cp "$T/src/usr/bin/unudhcpd" "$T/r/usr/bin/"
cp "$TOP/bsp612/ramdisk/init" "$T/r/init"; cp "$TOP/bsp612/ramdisk/leave" "$T/r/leave"; cp "$TOP/tools/rb" "$T/r/rb"
chmod 755 "$T/r/init" "$T/r/leave" "$T/r/rb"
: > "$T/r/lib/modules/load.list"
while read -r p; do
  f=$(basename "$p")
  [ -e "$T/r/lib/modules/$f" ] && { echo "duplicate module file name $f" >&2; exit 1; }
  cp "$MODS/$p" "$T/r/lib/modules/$f"
  echo "$f" >> "$T/r/lib/modules/load.list"
done < "$OUT/load.paths"
cp "$HHWDT" "$SECCORE" "$T/r/lib/modules/"
"$STRIP" --strip-debug "$T/r/lib/modules/"*.ko
for k in "$T/r/lib/modules/"*.ko; do
  strings "$k" | grep -q "^vermagic=$KREL " || { echo "wrong vermagic: $k" >&2; exit 1; }
done
cp "$T/r/lib/modules/load.list" "$OUT/load.list"
( cd "$T/r" && find . | sort | cpio -o -H newc --quiet -R 0:0 | gzip -9 ) > "$OUT/ramdisk-618.cpio.gz"
# ---- comparison with the working 6.12 first stage
L612=$TOP/bsp612/out/bringup/load.list
if [ -f "$L612" ]; then
  { echo "# 6.18 first stage ($OUT/load.list) vs 6.12 ($L612)"
    echo "# only in 6.12:"; comm -23 <(sort "$L612") <(sort "$OUT/load.list") | sed 's/^/  /'
    echo "# only in 6.18:"; comm -13 <(sort "$L612") <(sort "$OUT/load.list") | sed 's/^/  /'
    echo "# order of the common modules identical: $(diff -q <(grep -Fxf "$OUT/load.list" "$L612") <(grep -Fxf "$L612" "$OUT/load.list") >/dev/null && echo yes || echo NO)"
  } > "$OUT/compare-612.txt"
  cat "$OUT/compare-612.txt"
fi
echo "modules in ramdisk: $(ls "$T/r/lib/modules/"*.ko | wc -l) files, $(du -sb "$T/r/lib/modules" | cut -f1) bytes stripped"
ls -la "$OUT/ramdisk-618.cpio.gz"
