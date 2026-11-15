#!/bin/bash
# drivers612/modem/build-618.sh: the kernel-only modem test M2-K (README sections 10-11) for the
# 6.18 kernel (ACK 6.18.33 + forward-ported BSP, bsp618/), assembled OFFLINE. Nothing here
# touches a phone; nothing is flashed. The 6.12 outputs (out/) are read, never written.
#
#   ./build-618.sh          -> out-618/pack-modem-618.tgz, out-618/android-modem-r02-618.dtb,
#                              out-618/cmdline-m2-618.txt, out-618/check-load.txt
#   ./build-618.sh clean
#
# Inputs (all read only):
#   kernel     bsp618/android/out/dist/Image (= the a8 package's Image, byte-identical to
#              bsp618/out-survey/gki/arch/arm64/boot/Image) + dist/lib/modules/<KREL>
#   first stg  bsp618/android/out/bringup/ramdisk-618.cpio.gz (mkramdisk-618.sh: same
#              bsp612/ramdisk/init and module order as the 6.12 kernel-only runs)
#   dsp        bsp618/android/stage-618/dsp/ (mkstages-618.py: the 6.12 dsp stage, 6.18 builds)
#   modem      the same targets as the 6.12 pack (stages/modem/targets.txt, stages/therm/
#              targets.txt), resolved over the 6.18 modules.dep: dist (soc-repo + GKI) +
#              bsp618/src/drivers612/conn/data (6.18 dataipa/datarmnet, IPA3 fix + patches
#              0040/0041) + a52_modem_guard built here against bsp618/out-survey/lahaina
#   userspace  out/kpack/bin/{rmtfs,tqftpserv,qrtr-lookup,efsdump,qmi-nas} + qrtrls + mkdevs: static
#              aarch64, kernel-independent: the exact files of the 6.12 pack that passed M2-K
#              (run kx-m2k-p1-p1-192337), copied, sha256 printed
#   scripts    kpack/*.sh unchanged (m1.sh/therm.sh/common.sh/all.sh are kernel-agnostic)
#   DT         bsp618/android/out/android-r02-618.dtb (KEXEC_BASE of the 6.18 runs) through
#              dt/mkmodemtree.sh (modem_pas okay, memshare client_4 disabled + its checks)
#   cmdline    bsp618/android/android-cmdline-618.txt without androidboot.* (kernel only)
# HARD RULE (2026-11-13 incident): no firmware image (.mdt/.bNN/.mbn) is ever packed here.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); B=$TOP/bsp618; A=$B/android
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
RUSTBIN=$HOME/.rustup/toolchains/1.91.1-x86_64-unknown-linux-gnu/bin
DIST=$A/out/dist; KREL=$(ls "$DIST/lib/modules" | head -1); MODS=$DIST/lib/modules/$KREL
LAH=$B/out-survey/lahaina; SOCSYM=$B/src/bsp612/soc-repo-staging/build/Module.symvers
DATA=$B/src/drivers612/conn/data/out/lib/modules/$KREL/extra
DSP=$A/stage-618/dsp; BRINGUP=$A/out/bringup/ramdisk-618.cpio.gz
OUT=$HERE/out-618; P612=$HERE/out/kpack
fail() { echo "FAILED: $*" >&2; exit 1; }
[ "${1:-}" = clean ] && { rm -rf "$OUT"; exit 0; }
[ "$KREL" = 6.18.33-4k-g00c8666046c2-dirty ] || fail "dist release is $KREL"
[ "$(cat "$LAH/include/config/kernel.release")" = "$KREL" ] || fail "out-survey/lahaina is not $KREL"
for f in "$DIST/Image" "$MODS/modules.dep" "$DIST/System.map" "$SOCSYM" "$BRINGUP" "$DSP/load.list" \
	"$A/out/android-r02-618.dtb" "$A/android-cmdline-618.txt" "$B/out-survey/gki/Module.symvers"; do
	[ -f "$f" ] || fail "missing $f"
done
[ -d "$DATA" ] || fail "no 6.18 conn/data modules ($DATA): bsp618/port/build618.sh"
for f in rmtfs tqftpserv qrtr-lookup efsdump qmi-nas; do [ -x "$P612/bin/$f" ] || fail "no $P612/bin/$f: run drivers612/modem/build.sh (6.12) first"; done
mkdir -p "$OUT"

# ---- 1. a52_modem_guard.ko against the 6.18 vendor kernel (the make line of bsp618/build-survey.sh)
rm -rf "$OUT/build"; mkdir -p "$OUT/build"; cp -r "$HERE/guard" "$OUT/build/guard"
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
make -C "$TOP/ack" ARCH=arm64 LLVM="$CLANG/" RUSTC="$RUSTBIN/rustc" HOSTRUSTC="$RUSTBIN/rustc" \
	O="$LAH" M="$OUT/build/guard" KBUILD_EXTRA_SYMBOLS="$SOCSYM" -j8 modules \
	> "$OUT/build/guard.log" 2>&1 || { tail -20 "$OUT/build/guard.log"; fail "build guard"; }
grep -E "warning:|error:" "$OUT/build/guard.log" && fail "guard: compiler warnings (see $OUT/build/guard.log)"
echo "built: a52_modem_guard.ko ($KREL)"

# ---- 2. 6.18 module tree for dependency resolution: dist + conn/data + guard
T=$OUT/depmod; rm -rf "$T"; mkdir -p "$T/lib/modules/$KREL/extra"
cp -a "$MODS/." "$T/lib/modules/$KREL/"
cp "$DATA"/*.ko "$OUT/build/guard/a52_modem_guard.ko" "$T/lib/modules/$KREL/extra/"
depmod -e -F "$DIST/System.map" -b "$T" "$KREL" > "$OUT/depmod.log" 2>&1 || true
# the 6.18 dist has known unresolved modules outside this test (coresight-*, mhi, mac80211:
# PORT-STATUS.md); only a warning about a module this pack loads is fatal (checked after step 2)
grep -v "needs unknown symbol" "$OUT/depmod.log" | grep . && fail "depmod errors ($OUT/depmod.log)"
# loaded before the modem stage in the kernel-only run: the bring-up first stage + the dsp stage
{ cat "$A/out/bringup/load.list"; grep -vE '^[[:space:]]*(#|$)' "$DSP/load.list" | sed 's/[[:space:]].*//'
} | sed 's#.*/##' | sort -u > "$OUT/already-loaded-kernelonly.txt"
ALREADY=$OUT/already-loaded-kernelonly.txt

stage() { # stage <name> <targets file>: as build.sh's stage(), over the 6.18 tree
	local n=$1 tf=$2 d=$OUT/stage-$1 m args f b
	rm -rf "$d"; mkdir -p "$d"; : > "$d/load.list"
	grep -vE '^[[:space:]]*(#|$)' "$tf" | while read -r m args; do
		awk -v want="${m%.ko}" -v base="$T/lib/modules/$KREL/" '
			{ p = $1; sub(":$", "", p); n = p; sub(".*/", "", n); sub("\\.ko$", "", n); gsub("-", "_", n)
			  w = want; gsub("-", "_", w)
			  if (n == w) { for (i = NF; i >= 2; i--) print base $i; print base p; exit } }' \
			"$T/lib/modules/$KREL/modules.dep" |
		while read -r f; do
			b=$(basename "$f")
			grep -qx "$b" "$ALREADY" && continue
			grep -q "^$b\( \|$\)" "$d/load.list" && continue
			case "$f" in "$T/lib/modules/$KREL/kernel/"*) fail "$b is a GKI module (signed; not stripped/packed here)";; esac
			cp "$f" "$d/"
			if [ "$b" = "$m" ] && [ -n "$args" ]; then echo "$b $args" >> "$d/load.list"; else echo "$b" >> "$d/load.list"; fi
		done
		grep -q "^$m\( \|$\)" "$d/load.list" || grep -qx "$m" "$ALREADY" || fail "$m: not resolved (modules.dep)"
	done
	for f in "$d"/*.ko; do "$CLANG/llvm-strip" --strip-debug "$f"; done
	echo "stage $n: $(grep -vc '^#' "$d/load.list") modules"
}
stage kmodem "$HERE/stages/modem/targets.txt"
stage ktherm "$HERE/stages/therm/targets.txt"
# same module set as the 6.12 pack that passed (names; order may differ only by dependencies)
diff <(sed 's/[[:space:]].*//' "$OUT/stage-kmodem/load.list") <(grep -vE '^[[:space:]]*(#|$)' "$HERE/stages/modem/resolved-kernelonly.list" | sed 's/[[:space:]].*//') \
	> "$OUT/kmodem-vs-612.diff" && echo "modem list: identical to the 6.12 kernel-only list (stages/modem/resolved-kernelonly.list)" \
	|| { echo "modem list differs from 6.12:"; cat "$OUT/kmodem-vs-612.diff"; }
cp "$OUT/stage-kmodem/load.list" "$HERE/stages/modem/resolved-kernelonly-618.list"
for f in $(cat "$OUT/stage-kmodem/load.list" "$OUT/stage-ktherm/load.list" "$DSP/load.list" "$ALREADY" | sed 's/[[:space:]].*//' | sort -u); do
	grep "/$f needs unknown symbol" "$OUT/depmod.log" && fail "depmod: $f has unresolved symbols"
done
echo "depmod: $(grep -c 'needs unknown symbol' "$OUT/depmod.log") known warnings, none for a module of this test"

# ---- 3. the pack (same layout as out/pack-modem.tgz: /p/{*.sh,qrtrls,mkdevs,*.list,m/,bin/})
K=$OUT/kpack; rm -rf "$K"; mkdir -p "$K/m" "$K/bin"
cp "$HERE/kpack/"*.sh "$K/"
cp "$P612/qrtrls" "$P612/mkdevs" "$K/"
cp "$P612/bin/"{rmtfs,tqftpserv,qrtr-lookup,efsdump,qmi-nas} "$K/bin/"
grep -vE '^[[:space:]]*(#|$)' "$DSP/load.list" > "$K/dsp.list"
cmp -s "$K/dsp.list" "$P612/dsp.list" || fail "6.18 dsp list differs from the 6.12 pack's dsp.list"
cp $(sed "s#^#$DSP/#" "$K/dsp.list") "$K/m/"
"$CLANG/llvm-strip" --strip-debug "$K/m/"*.ko
grep -vE '^[[:space:]]*(#|$)' "$OUT/stage-kmodem/load.list" > "$K/modem.list"
grep -vE '^[[:space:]]*(#|$)' "$OUT/stage-ktherm/load.list" > "$K/therm.list"
cp "$OUT/stage-kmodem/"*.ko "$OUT/stage-ktherm/"*.ko "$K/m/"
# every list entry present, every .ko a list entry, vermagic, no firmware, kernel-independent bins
for l in dsp modem therm; do while read -r m _; do [ -f "$K/m/$m" ] || fail "$l.list: $m missing"; done < "$K/$l.list"; done
for f in "$K/m/"*.ko; do
	grep -qx "$(basename "$f")" <(cat "$K/"{dsp,modem,therm}.list | sed 's/[[:space:]].*//') || fail "$(basename "$f") is in no list"
	strings "$f" | grep "^vermagic=$KREL " >/dev/null || fail "wrong vermagic: $f"
done
echo "vermagic $KREL: all $(ls "$K/m/"*.ko | wc -l) .ko"
find "$K" -name '*.mdt' -o -name '*.mbn' -o -name '*.b[0-9][0-9]' | grep . && fail "firmware image in the test pack"
# microSD HARD RULE (as in build.sh): nothing but efsdump's refusal and mkdevs' filter names mmcblk
for f in "$K"/*.sh "$K/bin/"*; do
	case "$f" in */bin/efsdump) continue;; esac
	grep -qa mmcblk "$f" && fail "$(basename "$f") mentions mmcblk (microSD must never be touched)"
done
grep -q 'mmcblk\*|block/mmcblk\*) continue' "$K/mkdevs" || fail "mkdevs: no mmcblk filter (rebuild the 6.12 pack)"
for f in "$K/bin/"* "$K/qrtrls"; do
	file -b "$f" | grep "ARM aarch64.*statically linked" >/dev/null || fail "$f is not a static aarch64 binary"
done
for f in "$K/"*.sh "$K/mkdevs"; do cmp -s "$f" "$P612/$(basename "$f")" || fail "$(basename "$f") differs from the 6.12 pack"; done
(cd "$K/bin" && sha256sum rmtfs tqftpserv qrtr-lookup efsdump qmi-nas ../qrtrls) | sed 's#\.\./##' > "$OUT/userspace.sha256"
echo "userspace (reused from the passing 6.12 pack, byte-identical):"; sed 's/^/  /' "$OUT/userspace.sha256"
(cd "$K" && tar czf "$OUT/pack-modem-618.tgz" --owner=0 --group=0 .)
echo "kernel-only test pack: $OUT/pack-modem-618.tgz ($(stat -c %s "$OUT/pack-modem-618.tgz") bytes)"

# ---- 4. insmod simulation of the kernel-only order (bsp612/ramdisk/init, then m1.sh)
RD=$OUT/rd; rm -rf "$RD"; mkdir -p "$RD"; ( cd "$RD" && zcat "$BRINGUP" | cpio -id --quiet 'lib/modules/*' )
python3 -I "$HERE/check-load-kernelonly.py" --check-load "$A/check-load.py" --krel "$KREL" \
	--symvers "$B/out-survey/gki/Module.symvers" --builtin "$MODS/modules.builtin" \
	--first "$RD/lib/modules" --pack "$K" --therm > "$OUT/check-load.txt" || { cat "$OUT/check-load.txt"; fail "insmod simulation"; }
cat "$OUT/check-load.txt"
rm -rf "$RD"

# ---- 5. the modem device tree from the 6.18 Android test tree
"$HERE/dt/mkmodemtree.sh" "$A/out/android-r02-618.dtb" "$OUT/android-modem-r02-618.dtb"
D=$OUT/android-modem-r02-618.dtb
sym() { fdtget "$D" /__symbols__ "$1"; }
[ "$(fdtget "$D" "$(sym modem_pas)" status)" = okay ] || fail "modem_pas not okay"
[ "$(fdtget "$D" /soc/qcom,memshare/qcom,client_4 status)" = disabled ] || fail "memshare client_4 not disabled"
U=/soc/qcom,rmtfs_sharedmem@0
[ "$(fdtget "$D" $U compatible)" = qcom,sharedmem-uio ] || fail "$U compatible $(fdtget "$D" $U compatible)"
[ "$(fdtget "$D" $U reg-names)" = rmtfs ] || fail "$U reg-names"
[ "$(fdtget "$D" /soc "#address-cells") $(fdtget "$D" /soc "#size-cells") $(fdtget -t x "$D" $U reg)" = "1 1 0 280000" ] || fail "$U reg $(fdtget -t x "$D" $U reg)"
[ "$(fdtget "$D" $U qcom,client-id)" = 1 ] || fail "$U client-id"
[ "$(fdtget "$D" $U status 2>/dev/null || echo okay)" = okay ] || fail "$U disabled"
fdtget "$D" /reserved-memory/a52ram@f0be0000 compatible >/dev/null || fail "no a52ram node (earlycon=a52ram)"
# vs the 6.12 modem tree that passed: only the two mkdtb-618.sh edits may differ
if [ -f "$HERE/out/android-modem-r02.dtb" ]; then
	diff <(dtc -q -I dtb -O dts "$HERE/out/android-modem-r02.dtb") <(dtc -q -I dtb -O dts "$D") > "$OUT/dtb-vs-612.diff" || true
	# nothing removed; added only the a52ram node (5 lines + blank) and the dwc3 property
	{ grep '^<' "$OUT/dtb-vs-612.diff"
	  grep '^>' "$OUT/dtb-vs-612.diff" | sed 's/^>[[:space:]]*//' | grep -vxE 'a52ram@f0be0000 \{|no-map = \[00\];|reg = <0x00 0xf0be0000 0x00 0x20000>;|compatible = "a52,ramcon";|\};|qcom,iommu-faults = "non-fatal";|'
	} > "$OUT/dtb-vs-612.unexpected" || true
	[ -s "$OUT/dtb-vs-612.unexpected" ] && { cat "$OUT/dtb-vs-612.unexpected"; fail "6.18 modem tree differs from the 6.12 one beyond a52ram/dwc3 non-fatal"; }
	echo "dtb vs 6.12 modem tree: only a52ram@f0be0000 + dwc3 qcom,iommu-faults (dtb-vs-612.diff)"
fi
echo "$D: modem_pas okay, client_4 disabled, $U uio (rmtfs, 0x280000, client 1)"

# ---- 6. kernel-only cmdline: the 6.18 test cmdline without the Android parts
W=$(tr ' ' '\n' < "$A/android-cmdline-618.txt" | grep -vE '^(androidboot\.|a52\.androidtest=|a52\.deadman=|a52\.net=|firmware_class\.path=|loop\.max_part=|$)' | tr '\n' ' ')
C="loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused a52.deadman=420 a52.net=42"
for w in $W; do case " $C " in *" $w "*) ;; *) C="$C $w";; esac; done
C="$C log_buf_len=4M"
for w in $(cat "$TOP/bsp612/qcom-bootargs.txt") sched_proxy_exec=0 earlycon=a52ram,0xf0be0000; do
	case " $C " in *" $w "*) ;; *) fail "cmdline lacks $w";; esac
done
case " $C " in *" androidboot."*|*" a52.stage="*|*" a52.mods="*) fail "cmdline has Android parts";; esac
echo "$C" > "$OUT/cmdline-m2-618.txt"
echo "cmdline ($(echo -n "$C" | wc -c) B): $C"
# the longer radio/data runs (README section 12) only differ in the dead-man
echo "$C" | sed 's/ a52\.deadman=420 / a52.deadman=900 /' > "$OUT/cmdline-m2nas-618.txt"
echo "$C" | sed 's/ a52\.deadman=420 / a52.deadman=1500 /' > "$OUT/cmdline-m2data-618.txt"
grep -q ' a52\.deadman=900 ' "$OUT/cmdline-m2nas-618.txt" && grep -q ' a52\.deadman=1500 ' "$OUT/cmdline-m2data-618.txt" || fail "nas/data cmdline variants"
echo "cmdline variants: cmdline-m2nas-618.txt (deadman 900), cmdline-m2data-618.txt (deadman 1500)"

# ---- 7. what run-m2-618.sh will stage, fingerprinted (it refuses to run if any of it changed
# after these checks, e.g. a later bsp618 rebuild of the Image or the bring-up ramdisk)
(cd "$TOP" && sha256sum bsp618/android/out/dist/Image bsp618/android/out/bringup/ramdisk-618.cpio.gz \
	drivers612/modem/out-618/pack-modem-618.tgz drivers612/modem/out-618/android-modem-r02-618.dtb \
	drivers612/modem/out-618/cmdline-m2-618.txt drivers612/modem/out-618/cmdline-m2nas-618.txt \
	drivers612/modem/out-618/cmdline-m2data-618.txt) > "$OUT/inputs.sha256"
echo "fingerprints: $OUT/inputs.sha256"
