#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# ReSukiSU as a loadable module (LKM mode) for the 6.12 real boot, GKI Image untouched: the root flavour that
# matches the OneUI 9 port (K4_UN1CA), whose 5.4 bone-machine kernel has ReSukiSU 8770c7e3 (version 35203)
# built in and whose preinstalled manager is com.resukisu.resukisu 35222.
#   drivers612/realboot/modules/resukisu/build.sh        -> out/kernelsu.ko (stripped), out/ksuinit (static arm64)
# Source: donors/ReSukiSU at commit 8770c7e3 (v4.2.0-rc3-32-g8770c7e3; KSU_VERSION = 30700 + rev-list count 4503 =
# 35203, so the clone needs the full history). Cloned from the local submodule of ~/git/kernel_a52sxq_bone or upstream.
# Config = upstream's own LKM recipe (kernel/build-all.sh: CONFIG_KSU=m, TRACEPOINT_HOOK, MULTI_MANAGER_SUPPORT).
# kernelsu.ko has unexported kernel symbols left undefined (KBUILD_MODPOST_WARN=1): only ksuinit can load it
# (it resolves them from /proc/kallsyms), a first-stage insmod cannot.
# ksuinit = ReSukiSU's userspace/ksuinit + ksuinit-a52-rdinit-crash-guard.patch (same change as modules/kernelsu:
# started as rdinit=/ksuinit, ROM /init not replaced, ramoops panic record of the previous boot = skip one boot).
# Packaging: ../kernelsu/mkimg.sh <base rb dir> <new name> resukisu  (or build-realboot.sh KSU=1 KSU_FLAVOR=resukisu).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd)
K=$TOP/donors/ReSukiSU; REV=${RESUKISU_REV:-8770c7e324a22895703c4916b8a16520e0b81c79}
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
if [ ! -d "$K/.git" ]; then
	SRC=$HOME/git/kernel_a52sxq_bone/.git/modules/KernelSU
	[ -f "$SRC/HEAD" ] || SRC=https://github.com/ReSukiSU/ReSukiSU.git
	git clone -q "$SRC" "$K"
	git -C "$K" remote set-url origin https://github.com/ReSukiSU/ReSukiSU.git
fi
[ -f "$K/.git/shallow" ] && { echo "donors/ReSukiSU is shallow: the version code needs the full history" >&2; exit 1; }
git -C "$K" diff --quiet -- userspace/ksuinit || git -C "$K" checkout -q -- userspace/ksuinit
git -C "$K" checkout -q "$REV"
[ "$(git -C "$K" rev-list --count HEAD)" = 4503 ] || [ -n "${RESUKISU_REV:-}" ] || { echo "unexpected ReSukiSU history" >&2; exit 1; }
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
# kernel module first (the Kbuild marks the version -dirty if the tree is changed while it runs)
make -C "$TOP/bsp612/kernel" ARCH=arm64 LLVM="$CLANG/" O="$TOP/bsp612/out/lahaina" M="$K/kernel" CONFIG_KSU=m \
	CONFIG_KSU_TRACEPOINT_HOOK=y CONFIG_KSU_MULTI_MANAGER_SUPPORT=y \
	KBUILD_MODPOST_WARN=1 KCFLAGS="-I$TOP/bsp612/out/gki/security/selinux" -j20 modules > "$HERE/build.log" 2>&1
git -C "$K" apply "$HERE/ksuinit-a52-rdinit-crash-guard.patch"
( cd "$K/userspace/ksuinit" && RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static --remap-path-prefix=$HOME=~" \
	cargo build --release --target aarch64-unknown-linux-musl -q )
git -C "$K" checkout -q -- userspace/ksuinit
mkdir -p "$HERE/out"
cp "$K/kernel/kernelsu.ko" "$HERE/out/kernelsu.ko"
${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-strip --strip-debug "$HERE/out/kernelsu.ko"
install -m 0755 "$K/userspace/ksuinit/target/aarch64-unknown-linux-musl/release/ksuinit" "$HERE/out/ksuinit"
grep -a -o 'vermagic=[^ ]*' "$HERE/out/kernelsu.ko" | head -n 1
grep -E 'version (code|name)' "$HERE/build.log" | head -n 2
echo "undefined (resolved by ksuinit): $(grep -c 'undefined!' "$HERE/build.log")"
grep 'undefined!' "$HERE/build.log" | sed 's/.*"\(.*\)".*/  \1/'
sha256sum "$HERE/out/kernelsu.ko" "$HERE/out/ksuinit"
