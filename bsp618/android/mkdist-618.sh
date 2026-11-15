#!/bin/bash
# bsp618/android/out/dist: the 6.18 equivalent of bsp612/out/dist (bsp612/build.sh collect), made
# from the port build (bsp618/port/build618.sh) and the survey kernel it was built against:
#   Image, System.map, gki.config, lahaina.config      bsp618/out-survey/gki, .../lahaina
#   lib/modules/<krel>/kernel/...                      GKI modules (signed, stripped)
#   lib/modules/<krel>/{drivers,arch,net,...}/...      soc-repo vendor modules (stripped)
#   lib/modules/<krel>/modules.dep                     one depmod over both (-e -F: depmod.log)
#   modules-gki.list, modules-soc.list                 file names per set
#   first-stage.a52sxq.list                            same derivation as bsp612/tools/first-stage.py:
#                                                      Qualcomm's lahaina first-stage list minus the
#                                                      SM8350-only parts + USB + PMIC keys, closed
#                                                      over modules.dep, dependencies first
# Reads bsp618/out-survey and bsp618/src only; nothing outside bsp618/android/out is written.
# Offline only: flashes nothing.   Usage: bsp618/android/mkdist-618.sh
set -euo pipefail
A=$(cd "$(dirname "$0")" && pwd); B=$(dirname "$A"); R=$(dirname "$B")
O=$B/out-survey; GKI=$O/gki; LAH=$O/lahaina; SOC=$B/src/bsp612/soc-repo-staging
D=$A/out/dist
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
RUSTBIN=$HOME/.rustup/toolchains/1.91.1-x86_64-unknown-linux-gnu/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
export LIBCLANG_PATH=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r584948b/lib
# same make variables as bsp618/build-survey.sh, so modules_install sees the build's own config
K="make -C $R/ack ARCH=arm64 LLVM=$CLANG/ RUSTC=$RUSTBIN/rustc HOSTRUSTC=$RUSTBIN/rustc BINDGEN=${ANDROID_TREE:-$HOME/android}/prebuilts/clang-tools/linux-x86/bin/bindgen"
[ -f "$GKI/arch/arm64/boot/Image" ] && [ -f "$SOC/build/Module.symvers" ] || { echo "build first: bsp618/port/build618.sh" >&2; exit 1; }
KREL=$(cat "$GKI/include/config/kernel.release")
[ "$(cat "$LAH/include/config/kernel.release")" = "$KREL" ] || { echo "gki and lahaina kernel.release differ" >&2; exit 1; }
# the Image must be the kernel these modules were built for
grep -aqF "Linux version $KREL " "$GKI/arch/arm64/boot/Image" || { echo "Image is not $KREL" >&2; exit 1; }
rm -rf "$D"; mkdir -p "$D"
cp "$GKI/arch/arm64/boot/Image" "$GKI/System.map" "$D/"
cp "$GKI/.config" "$D/gki.config"; cp "$LAH/.config" "$D/lahaina.config"
$K O="$GKI" INSTALL_MOD_PATH="$D" INSTALL_MOD_STRIP=1 modules_install > "$A/out/modules_install-gki.log" 2>&1
# -i -k: the soc-repo modules.order also names the 14 modules that do not build on 6.18 (the
# build runs with -i -k); they are skipped, everything that was built is installed
$K O="$LAH" KCONFIG_EXT_PREFIX="$B/src/bsp612/soc-repo/" KERNEL_SRC="$R/ack" M="$SOC/build" \
  INSTALL_MOD_PATH="$D" INSTALL_MOD_STRIP=1 -i -k modules_install > "$A/out/modules_install-soc.log" 2>&1 || true
echo "soc-repo modules_install: $(grep -c '^  INSTALL' "$A/out/modules_install-soc.log") installed, $(grep -c 'No rule to make target' "$A/out/modules_install-soc.log") not built (skipped)"
[ "$(ls "$D/lib/modules")" = "$KREL" ] || { echo "modules installed under $(ls "$D/lib/modules"), expected $KREL" >&2; exit 1; }
find "$GKI" -name '*.ko' -printf '%f\n' | sort > "$D/modules-gki.list"
find "$SOC" -name '*.ko' -printf '%f\n' | sort > "$D/modules-soc.list"
depmod -b "$D" -F "$D/System.map" -e "$KREL" > "$A/out/depmod.log" 2>&1 || true
echo "depmod: $(grep -c 'needs unknown symbol' "$A/out/depmod.log" || true) unknown-symbol lines (out/depmod.log)"
python3 -I - "$D" "$B/src/bsp612/soc-repo/modules-lists/modules.list.msm.lahaina" <<'EOF'
import os, sys
D, QC = sys.argv[1:3]
R = os.path.join(D, 'lib/modules', os.listdir(os.path.join(D, 'lib/modules'))[0])
dep, path = {}, {}
for l in open(os.path.join(R, 'modules.dep')):
    k, v = l.split(':', 1)
    n = os.path.basename(k); path[n] = k
    dep[n] = [os.path.basename(x) for x in v.split()]
qc = [l.strip() for l in open(QC) if l.strip().endswith('.ko')]
# as bsp612/tools/first-stage.py
SM8350_ONLY = {'gcc-sm8350.ko', 'dispcc-sm8350.ko', 'pinctrl-lahaina.ko', 'qnoc-lahaina.ko',
               'phy-qcom-ufs-qmp-v4-lahaina.ko', 'phy-qcom-ufs-qrbtc-sdm845.ko'}
USB = ['dwc3-msm.ko', 'phy-msm-snps-hs.ko', 'phy-msm-ssusb-qmp.ko']
EXTRA = ['pinctrl-spmi-gpio.ko', 'qcom-pon.ko', 'pm8941-pwrkey.ko']
seeds, skipped = [], []
for m in qc + USB + EXTRA:
    if m in SM8350_ONLY: continue
    (seeds if m in dep else skipped).append(m)
order, seen = [], set()
def visit(m):
    if m in seen: return
    seen.add(m)
    for d in dep.get(m, []): visit(d)
    order.append(m)
for m in seeds: visit(m)
with open(os.path.join(D, 'first-stage.a52sxq.list'), 'w') as f:
    for m in order: f.write(path[m] + '\n')
with open(os.path.join(D, 'first-stage-not-built.list'), 'w') as f:
    for m in skipped: f.write(m + '\n')
print(f"first-stage.a52sxq.list: {len(order)} modules ({len(seeds)} seeds); not built, skipped: {' '.join(skipped)}")
EOF
echo "dist: $KREL, Image $(stat -c %s "$D/Image") bytes, $(wc -l < "$D/modules-gki.list") GKI + $(wc -l < "$D/modules-soc.list") soc-repo modules, $(du -sh "$D/lib/modules" | cut -f1)"
