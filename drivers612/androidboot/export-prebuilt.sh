#!/bin/bash
# Stages the prebuilt-kernel directory that patches/0001+0002 expect at
# ${ANDROID_TREE:-$HOME/android}/device/samsung/a52sxq-kernel/6.12, from bsp612/out/dist. Writes ONLY to
# drivers612/androidboot/out/prebuilt/6.12; the main session copies it into the ROM tree.
#   EXTRA_MODULES="a.ko ..."  forward-ported drivers of the other drivers612 agents (second stage)
#   EXTRA_FIRST="a.ko ..."    extra first-stage modules (sec_core is added by default)
#   DTBO=<dtbo.img>           default: the bring-up overlay of bsp612 packed alone
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); BSP=$TOP/bsp612
DIST=$BSP/out/dist; KREL=$(ls "$DIST/lib/modules" | head -1); MODS=$DIST/lib/modules/$KREL
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
O=$HERE/out/prebuilt/6.12
BLOCK="qcom_edac qcom-dload-mode gh_virt_wdt qcom_wdt_core tz_log_dlkm"
rm -rf "$O"; mkdir -p "$O/modules" "$O/dtb"
cp "$DIST/Image" "$O/Image"; cp "$DIST/dtb/yupik.dtb" "$O/dtb/"; cp "$DIST/gki.config" "$O/gki.config"
if [ -n "${DTBO:-}" ]; then cp "$DTBO" "$O/dtbo.img"; else
  dtc -q -@ -I dts -O dtb -o "$O/a52sxq.dtbo" "$BSP/dts/a52sxq-bringup-overlay.dts"
  python3 "$MKDTBOIMG" create "$O/dtbo.img" --page_size=4096 "$O/a52sxq.dtbo" >/dev/null; rm "$O/a52sxq.dtbo"; fi
python3 - "$MODS" "$BSP/out/bringup/load.paths" "$BLOCK" "$O" <<'EOF'
import sys, os
mods, first, block, out = sys.argv[1:5]
block = set(block.split()); deps = {}
for l in open(os.path.join(mods, 'modules.dep')):
    k, _, v = l.partition(':'); deps[k.strip()] = v.split()
name = lambda p: os.path.basename(p)[:-3]
def find(p):
    if p in deps: return p
    hits = [k for k in deps if os.path.basename(k) == os.path.basename(p)]
    if len(hits) != 1: sys.exit("module %s: %d matches" % (p, len(hits)))
    return hits[0]
def closure(want, seen, order):
    def visit(p):
        p = find(p)
        if p in seen: return True
        if name(p) in block: return False
        if not all(visit(d) for d in deps[p]):
            print("left out:", name(p)); return False
        seen.add(p); order.append(p); return True
    for w in want: visit(w)
seen = set(); fs = []; closure([l.strip() for l in open(first) if l.strip()], seen, fs)
rest = []; closure(['zram.ko'] + sorted(deps), seen, rest)
open(os.path.join(out, 'first.paths'), 'w').write('\n'.join(fs) + '\n')
open(os.path.join(out, 'vendor.paths'), 'w').write('\n'.join(rest) + '\n')
EOF
for set in first vendor; do
  while read -r p; do f=$(basename "$p"); [ -e "$O/modules/$f" ] && { echo "duplicate $f" >&2; exit 1; }
    cp "$MODS/$p" "$O/modules/$f"
    grep -qxF "$f" "$DIST/modules-gki.list" || "$CLANG/llvm-strip" --strip-debug "$O/modules/$f"
    echo "$f"; done < "$O/$set.paths" > "$O/$set.list"; rm "$O/$set.paths"
done
SEC=$TOP/samsung612/modules/sec_core/sec_core.ko
for m in $SEC ${EXTRA_FIRST:-}; do [ -f "$m" ] || continue; cp "$m" "$O/modules/"; "$CLANG/llvm-strip" --strip-debug "$O/modules/$(basename "$m")"; basename "$m" >> "$O/first.list"; done
for m in ${EXTRA_MODULES:-}; do cp "$m" "$O/modules/"; "$CLANG/llvm-strip" --strip-debug "$O/modules/$(basename "$m")"; basename "$m" >> "$O/vendor.list"; done
mv "$O/first.list" "$O/modules.load.first_stage"; mv "$O/vendor.list" "$O/modules.load.vendor"
cp "$O/modules.load.first_stage" "$O/modules.load.recovery"   # + touch/display modules once they exist
for b in $BLOCK; do echo "blocklist $b"; done > "$O/modules.blocklist"
echo "$KREL" > "$O/kernel.release"
echo "staged $O: $(wc -l < "$O/modules.load.first_stage") first-stage, $(wc -l < "$O/modules.load.vendor") second-stage modules, $(du -sh "$O/modules" | cut -f1)"
