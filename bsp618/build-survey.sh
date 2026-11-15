#!/bin/bash
# Hop-2 compile survey: builds the 6.12 out-of-tree module set (bsp612 soc-repo, drivers612/*,
# samsung612/modules/*) against ACK android17-6.18 (ack/, 6.18.33) WITHOUT touching the 6.12
# sources or out-ack/. Offline only: flashes nothing.
#
# Layout (everything below bsp618/ except this script and the reports is git-ignored):
#   out-survey/gki      ack/ + gki_defconfig: Image, vmlinux, GKI modules, Module.symvers
#   out-survey/lahaina  gki_defconfig + bsp612/lahaina_perf.fragment, soc-repo Kconfig hooked in,
#                       modules_prepare; Module.symvers/vmlinux from gki (as bsp612/build.sh)
#   survey-src/         a mirror of the repo root so the copied build.sh files work unchanged:
#                       bsp612/kernel -> ../../../ack, bsp612/out -> ../../out-survey,
#                       bsp612/soc-repo (copy), bsp612/soc-repo-staging (ACK 6.18 drivers/ net/
#                       + soc-repo, as assemble.sh step 3), bsp612/techpacks (copy),
#                       drivers612/ + samsung612/modules/ (copies), donors -> ../../donors.
#                       Copied scripts had their absolute repo path and clang-r547379 rewritten.
# Usage: ./build-survey.sh [gki|config|stage|soc|drivers|all]   (logs: out-survey/logs/)
set -uo pipefail
B=$(cd "$(dirname "$0")" && pwd); R=$(cd "$B/.." && pwd)
# SURVEY_SRC/SURVEY_LOGS/SURVEY_RESULTS: build another source mirror against the same kernel
# (bsp618/port/build618.sh uses them for the port tree bsp618/src).
S=${SURVEY_SRC:-$B/survey-src}; BSP=$S/bsp612; O=$B/out-survey; L=${SURVEY_LOGS:-$O/logs}
RS=${SURVEY_RESULTS:-$O}
# ACK android17-6.18 pins clang r596125 and rustc 1.91.1 (build.config.constants).
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin
RUSTBIN=${RUSTBIN:-$HOME/.rustup/toolchains/1.91.1-x86_64-unknown-linux-gnu/bin}
# bindgen 0.72.0 + libclang r596125 (clang 22.0.2) emits every struct with an embedded opaque type as
# opaque (`_address: u8`) and rust/ fails to build; libclang from r584948b (22.0.1) works.
export LIBCLANG_PATH=${LIBCLANG_PATH:-${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r584948b/lib}
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
RUSTARGS="RUSTC=$RUSTBIN/rustc HOSTRUSTC=$RUSTBIN/rustc BINDGEN=${ANDROID_TREE:-$HOME/android}/prebuilts/clang-tools/linux-x86/bin/bindgen"
J=${J:-$(nproc)}
K="make -C $R/ack ARCH=arm64 LLVM=$CLANG/ $RUSTARGS"
EXT="KCONFIG_EXT_PREFIX=$BSP/soc-repo/"
mkdir -p "$L"

gki() {
  $K O="$O/gki" gki_defconfig >/dev/null
  $K O="$O/gki" -j"$J" Image modules > "$L/gki.log" 2>&1; echo "gki rc=$?"
  [ -f "$O/gki/arch/arm64/boot/Image" ] && [ -f "$O/gki/Module.symvers" ]
}

config() {
  local LAH=$O/lahaina
  $K O="$LAH" $EXT gki_defconfig >/dev/null
  ( cd "$R/ack" && ARCH=arm64 LLVM=$CLANG/ KCONFIG_EXT_PREFIX=$BSP/soc-repo/ \
      scripts/kconfig/merge_config.sh -m -O "$LAH" "$LAH/.config" "$R/bsp612/lahaina_perf.fragment" > "$L/merge_config.log" 2>&1 )
  $K O="$LAH" $EXT olddefconfig > "$L/olddefconfig.log" 2>&1
  : > "$O/config-not-taken.txt"
  while IFS= read -r l; do
    case "$l" in
      "# "*) s=${l#\# }; s=${s% is not set}
             grep -q "^$s=" "$LAH/.config" && echo "$s wanted n, is $(grep "^$s=" "$LAH/.config" | cut -d= -f2)" >> "$O/config-not-taken.txt" ;;
      *)     grep -qxF "$l" "$LAH/.config" || echo "${l%%=*} wanted ${l#*=}, is $(grep "^${l%%=*}=" "$LAH/.config" | cut -d= -f2 || true)" >> "$O/config-not-taken.txt" ;;
    esac
  done < "$R/bsp612/lahaina_perf.fragment"
  echo "config: $(wc -l < "$O/config-not-taken.txt") fragment symbols did not take"
  $K O="$LAH" $EXT -j"$J" modules_prepare > "$L/modules_prepare.log" 2>&1; echo "modules_prepare rc=$?"
  cp "$O/gki/Module.symvers" "$LAH/Module.symvers"
  ln -sfn "$O/gki/vmlinux" "$LAH/vmlinux"
}

stage() {  # assemble.sh step 3 with ACK 6.18 as the kernel
  local ST=$BSP/soc-repo-staging
  mkdir -p "$ST"
  rsync -a --prune-empty-dirs --include='/drivers/' --include='/drivers/**/' --include='/net/' \
    --include='/net/**/' --include='*.c' --include='*.h' --exclude='*' "$R/ack/" "$ST/"
  sed -n 's/^ *"\(\(lib\|sound\)\/[^"]*\)",$/\1/p' "$BSP/soc-repo/common_sources.bzl" | while read -r f; do
    [ -f "$R/ack/$f" ] && install -D -p -m644 "$R/ack/$f" "$ST/$f"
  done
  rsync -a "$BSP/soc-repo/" "$ST/"
  : > "$RS/stage-patches.txt"
  for rec in \
    'drivers/regulator/qti_fixed_regulator.c|drivers/regulator/fixed.c|drivers/regulator/fixed.diff' \
    'drivers/dma/qcom/gpi_fixed.c|drivers/dma/qcom/gpi.c|drivers/dma/qcom/gpi_fix.diff' \
    'drivers/net/virtio_net.c|drivers/net/virtio_net.c|drivers/net/virtio_net_fix.diff'; do
    dst=${rec%%|*}; tmp=${rec#*|}; src=${tmp%%|*}; diff=${tmp#*|}
    mkdir -p "$ST/$(dirname "$dst")"
    if patch --follow-symlinks -p0 --batch -s -o "$ST/$dst.new" -r "$RS/$(basename "$dst").rej" \
         -i "$BSP/soc-repo/$diff" "$R/ack/$src" >> "$RS/stage-patches.txt" 2>&1; then
      echo "ok   $dst" >> "$RS/stage-patches.txt"
    else
      echo "FAIL $dst ($diff does not apply to 6.18 $src)" >> "$RS/stage-patches.txt"
    fi
    [ -f "$ST/$dst.new" ] && mv "$ST/$dst.new" "$ST/$dst"
  done
  cat "$RS/stage-patches.txt"
}

soc() {  # -i -k: modpost runs over whatever compiled (see drivers())
  $K O="$O/lahaina" $EXT KERNEL_SRC="$R/ack" M="$BSP/soc-repo-staging/build" -j"$J" -i -k KBUILD_MODPOST_WARN=1 modules \
    > "$L/soc.log" 2>&1; echo "soc rc=$?"
}

drivers() {  # every module set of tools/rebuild-612-modules.sh + camera + debug probes + pdmapper
  local LAH=$O/lahaina SOCSYM=$BSP/soc-repo-staging/build/Module.symvers D=$L/drivers
  mkdir -p "$D"
  # -i -k: kbuild then still runs modpost (with -n) over the modules that did compile, so each
  # set gets .ko files + a Module.symvers and real "undefined!" lists (scripts/Makefile.modpost)
  export MAKEFLAGS=ik KBUILD_MODPOST_WARN=1
  Mk() { local n=$1 d=$2; shift 2
    $K O="$LAH" M="$S/$d" KBUILD_EXTRA_SYMBOLS="$SOCSYM" -k -j"$J" "$@" modules > "$D/$n.log" 2>&1 \
      && echo "ok   $n" || echo "FAIL $n"; }
  Sh() { local dir=$1 n; n=$(echo "$1" | tr / _); shift
    ( cd "$S/$dir" && KEEP=1 KEEP_GOING=1 K=1 "$@" ) > "$D/$n.log" 2>&1 && echo "ok   $n" || echo "FAIL $n"; }
  # the scripts call make themselves; -k is passed where they accept make args
  Mk sec_core samsung612/modules/sec_core
  Mk qfprom-sys drivers612/qfprom-sys
  Mk testguard drivers612/androidboot/testguard
  Mk fnprobe drivers612/debug/fnprobe
  Mk seaprobe drivers612/debug/seaprobe
  Mk pdmapper drivers612/hwbringup/pdmapper
  Sh drivers612/secure/ioncompat ./build.sh
  Sh drivers612/secure/securemsm ./build.sh
  Sh drivers612/secure/adsprpc ./build.sh
  Sh drivers612/display ./build.sh
  Sh drivers612/touch ./build.sh modules -k
  Sh drivers612/power ./build.sh -k
  # audio links against mm-drivers (msm_ext_display): 6.12 used bsp612/techpacks/mm-drivers,
  # here the copy display's build.sh just built
  ln -sfn "$S/drivers612/display/techpack/mm-drivers/Module.symvers" "$BSP/techpacks/mm-drivers/Module.symvers"
  Sh drivers612/audio ./build.sh -k
  Sh drivers612/audio/samsung ./build.sh
  Sh drivers612/gpu-video/gpu ./build.sh
  Sh drivers612/gpu-video/video ./build.sh modules
  Sh drivers612/conn/subsys_compat ./build.sh modules -k
  Sh drivers612/conn/rild/drb ./build.sh modules -k
  Sh drivers612/conn/data ./build.sh
  Sh drivers612/conn/bt ./build.sh
  Sh drivers612/conn/wlan bash -c './build.sh prepare && ./build.sh all'
  Mk camera-dep-ioncompat drivers612/camera/deps/ioncompat
  Mk camera-dep-fled-stub drivers612/camera/deps/sm5714-fled-stub
  # camera's Kbuild reaches bsp612/soc-repo as $(srctree)/../soc-repo; srctree is ack/ here
  sed -i "s#\$(srctree)/../soc-repo#$BSP/soc-repo#g" "$S/drivers612/camera/Kbuild.tail" "$S/drivers612/camera/work/drivers/Kbuild"
  # camera.ko imports ion_alloc & co. from ioncompat. The one the Android test loads is
  # secure/ioncompat (stage "secure"), not camera/deps/ioncompat: with 6.18's gendwarfksyms the
  # two copies export different CRCs (different includes -> different DWARF expansion of
  # struct dma_buf; genksyms on 6.12 gave both the same), and insmod refuses camera.ko
  # ("disagrees about version of symbol ion_alloc"). Link against the module that is loaded.
  local ION=$S/drivers612/secure/ioncompat/Module.symvers
  if [ -f "$ION" ]; then Sh drivers612/camera env ION_SYMVERS="$ION" ./port.sh build
  else Sh drivers612/camera ./port.sh build; fi
}

extra() {  # port tree only (bsp618/port/build618.sh): the 6.12 Android-boot modules the survey
  # did not cover (stages fingerprint, nfc, vibrator, susp; real-boot DSP starter; harness watchdog)
  local LAH=$O/lahaina SOCSYM=$BSP/soc-repo-staging/build/Module.symvers D=$L/drivers
  mkdir -p "$D"
  export MAKEFLAGS=ik KBUILD_MODPOST_WARN=1
  Mk() { local n=$1 d=$2; shift 2
    $K O="$LAH" M="$S/$d" KBUILD_EXTRA_SYMBOLS="$SOCSYM" -k -j"$J" "$@" modules > "$D/$n.log" 2>&1 \
      && echo "ok   $n" || echo "FAIL $n"; }
  Mk fingerprint drivers612/fingerprint/src
  Mk nfc drivers612/nfc/src
  Mk vibrator drivers612/vibrator/src
  Mk dspboot drivers612/realboot/modules/dspboot
  Mk hhwdt modules/hhwdt
  Mk a52susp drivers612/suspend/a52susp   # suspend-test safety module (stage susp)
}

for step in ${@:-all}; do
  case "$step" in
    all) gki; config; stage; soc; drivers ;;
    gki|config|stage|soc|drivers|extra) $step ;;
    *) echo "unknown step $step"; exit 2 ;;
  esac
done
