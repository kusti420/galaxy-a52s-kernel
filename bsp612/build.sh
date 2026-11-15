#!/bin/bash
# Builds the Qualcomm 6.12 BSP for lahaina/yupik with plain make. Offline only: flashes nothing.
# Run ./assemble.sh first. Usage: ./build.sh [gki|config|soc|dtbs|collect|dtcompare|all]   (default all)
#   gki     out/gki      ACK gki_defconfig: Image + GKI modules + Module.symvers (pure GKI)
#   config  out/lahaina  gki_defconfig + lahaina_perf.fragment with the soc-repo Kconfig hooked
#                        in; modules_prepare; report fragment symbols that did not take
#   soc     the soc-repo vendor modules (external module tree soc-repo-staging/build)
#   dtbs    the lahaina/yupik dtbs + overlays from devicetree/, with -@
#   collect out/dist: Image, yupik dtbs, stripped modules + modules.dep, lists, first-stage proposal
#   dtcompare  out/dt-compare.txt: stock Samsung dtbo vs the 6.12 yupik base (tools/dtcompare.sh)
set -euo pipefail
BSP=$(cd "$(dirname "$0")" && pwd)
# ACK pins clang r536225 (build.config.constants); the AOSP prebuilts here start at r547379,
# the nearest newer one.
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
J=${J:-20}
# Rust (2026-11-13): android16-6.12's gki_defconfig has CONFIG_RUST=y, and ashmem is a Rust
# driver there (CONFIG_ASHMEM depends on RUST). Without it Android has no ashmem and system
# processes crash with SIGBUS under sys.use_memfd. ACK pins rustc 1.82.0
# (build.config.constants); installed with: rustup toolchain install 1.82.0 --profile minimal
# --component rust-src. bindgen from AOSP prebuilts/clang-tools, libclang from the same clang.
RUSTBIN=${RUSTBIN:-$HOME/.rustup/toolchains/1.82.0-x86_64-unknown-linux-gnu/bin}
export LIBCLANG_PATH=$(dirname "$CLANG")/lib
RUSTARGS="RUSTC=$RUSTBIN/rustc HOSTRUSTC=$RUSTBIN/rustc BINDGEN=${ANDROID_TREE:-$HOME/android}/prebuilts/clang-tools/linux-x86/bin/bindgen"
K="make -C $BSP/kernel ARCH=arm64 LLVM=$CLANG/ $RUSTARGS"
GKI=$BSP/out/gki
LAH=$BSP/out/lahaina
EXT="KCONFIG_EXT_PREFIX=$BSP/soc-repo/"
mkdir -p "$BSP/out"

gki() {
  $K O="$GKI" gki_defconfig >/dev/null
  $K O="$GKI" -j"$J" Image modules 2>&1 | tee "$BSP/out/gki.log" | grep -E 'error:|Error [0-9]|^make.*\*\*\*' || true
  [ -f "$GKI/arch/arm64/boot/Image" ] && [ -f "$GKI/Module.symvers" ]
}

config() {
  $K O="$LAH" $EXT gki_defconfig >/dev/null
  ( cd "$BSP/kernel" && ARCH=arm64 LLVM=$CLANG/ KCONFIG_EXT_PREFIX=$BSP/soc-repo/ \
      scripts/kconfig/merge_config.sh -m -O "$LAH" "$LAH/.config" "$BSP/lahaina_perf.fragment" >/dev/null )
  $K O="$LAH" $EXT olddefconfig >/dev/null
  # Symbols that did not take
  : > "$BSP/out/config-not-taken.txt"
  while IFS= read -r l; do
    case "$l" in
      "# "*) s=${l#\# }; s=${s% is not set}
             grep -q "^$s=" "$LAH/.config" && echo "$s wanted n, is $(grep "^$s=" "$LAH/.config" | cut -d= -f2)" >> "$BSP/out/config-not-taken.txt" ;;
      *)     grep -qxF "$l" "$LAH/.config" || echo "${l%%=*} wanted ${l#*=}, is $(grep "^${l%%=*}=" "$LAH/.config" | cut -d= -f2 || true)" >> "$BSP/out/config-not-taken.txt" ;;
    esac
  done < "$BSP/lahaina_perf.fragment"
  echo "config: $(wc -l < "$BSP/out/config-not-taken.txt") fragment symbols did not take (out/config-not-taken.txt)"
  $K O="$LAH" $EXT -j"$J" modules_prepare 2>&1 | tail -3
  # The vendor modules link against the GKI kernel's symbols, as in kleaf (base_kernel).
  # vmlinux is linked in too so that the modules get their BTF section (pahole needs it).
  cp "$GKI/Module.symvers" "$LAH/Module.symvers"
  ln -sfn "$GKI/vmlinux" "$LAH/vmlinux"
}

soc() {
  # Qualcomm's build/Makefile: obj-y over soc-repo-staging, soc-repo headers ahead of ACK's.
  $K O="$LAH" $EXT KERNEL_SRC="$BSP/kernel" M="$BSP/soc-repo-staging/build" -j"$J" ${KEEP_GOING:+-k} modules \
    2>&1 | tee "$BSP/out/soc.log" | grep -E 'error:|Error |ERROR|undefined!|^make.*\*\*\*' || true
  grep -q '\*\*\*' "$BSP/out/soc.log" && return 1 || return 0
}

dtbs() {
  # DTC_INCLUDE must come from the environment: Makefile.dtbs appends to it (as kleaf does).
  DTC_INCLUDE="$BSP/soc-repo/include" $K O="$LAH" $EXT DTC_FLAGS=-@ dtstree=arch/arm64/boot/dts/vendor \
    -j"$J" dtbs 2>&1 | tee "$BSP/out/dtbs.log" | grep -E 'fatal error|Error [0-9]|\*\*\*' || true
  grep -q '\*\*\*' "$BSP/out/dtbs.log" && return 1 || return 0
}

collect() {
  D=$BSP/out/dist; rm -rf "$BSP/out/dist"; mkdir -p "$D/dtb"
  cp "$GKI/arch/arm64/boot/Image" "$GKI/System.map" "$D/"
  cp "$LAH/.config" "$D/lahaina_perf.config"; cp "$GKI/.config" "$D/gki.config"
  # yupik.dtb is the base the A52s bootloader would pick (msm-id 475/515 rev 0x10000, board-id 0 0);
  # the others are Qualcomm's reference bases and boards, kept for comparison.
  for f in yupik.dtb yupik-hsp.dtb yupik-iot.dtb yupik-idp-overlay.dtbo yupik-qrd-overlay.dtbo yupik-atp-overlay.dtbo; do
    cp "$LAH/arch/arm64/boot/dts/vendor/qcom/$f" "$D/dtb/"
  done
  # Stripped modules + modules.dep: GKI ones under kernel/, soc-repo ones under updates/.
  $K O="$GKI" INSTALL_MOD_PATH="$D" INSTALL_MOD_STRIP=1 modules_install >/dev/null
  $K O="$LAH" $EXT KERNEL_SRC="$BSP/kernel" M="$BSP/soc-repo-staging/build" INSTALL_MOD_PATH="$D" \
    INSTALL_MOD_STRIP=1 modules_install 2>&1 >/dev/null | grep -v 'Skipping depmod' || true
  R=$(ls "$D/lib/modules")
  # (the soc-repo tree is built as M=.../build with ../ paths, so its modules install beside
  # and partly inside kernel/ instead of under updates/; take the lists from the build trees)
  find "$GKI" -name '*.ko' -printf '%f\n' | sort > "$D/modules-gki.list"
  find "$BSP/soc-repo-staging" -name '*.ko' -printf '%f\n' | sort > "$D/modules-soc.list"
  # One modules.dep over both sets; -e -F reports any symbol neither the Image nor a module has.
  depmod -b "$D" -F "$D/System.map" -e "$R" 2>&1 | tee "$BSP/out/depmod.log" | head -20
  # Entries of Qualcomm's first-stage list that this build does not produce (stale names).
  grep '\.ko$' "$BSP/soc-repo/modules-lists/modules.list.msm.lahaina" | sort \
    | comm -23 - <(sort -u "$D/modules-gki.list" "$D/modules-soc.list") > "$D/first-stage-not-built.list"
  python3 -I "$BSP/tools/first-stage.py" "$D"
  echo "dist: $R, Image $(stat -c %s "$D/Image") bytes, yupik.dtb $(stat -c %s "$D/dtb/yupik.dtb") bytes," \
    "$(wc -l < "$D/modules-gki.list") GKI + $(wc -l < "$D/modules-soc.list") soc-repo modules," \
    "$(du -sh "$D/lib/modules" | cut -f1) stripped"
}

for step in ${@:-all}; do
  case "$step" in
    all) gki; config; soc; dtbs; collect; "$BSP/tools/dtcompare.sh" >/dev/null ;;
    gki|config|soc|dtbs|collect) $step ;;
    dtcompare) "$BSP/tools/dtcompare.sh" ;;
    *) echo "unknown step $step"; exit 2 ;;
  esac
done
