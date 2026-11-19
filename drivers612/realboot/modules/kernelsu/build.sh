#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# KernelSU-Next as a loadable module (LKM mode) for the 6.12 real boot, GKI Image untouched.
#   drivers612/realboot/modules/kernelsu/build.sh        -> out/kernelsu.ko (stripped), out/ksuinit (static arm64)
# Source: donors/KernelSU-Next at tag v3.4.0 (kernel version 33294 = manager com.rifsxd.ksunext v3.4.0;
# the ROM's 5.4 kernel carries v3.4.0-legacy). Cloned from the local copy in the ROM tree or from upstream.
# kernelsu.ko has unexported kernel symbols left undefined (KBUILD_MODPOST_WARN=1): only ksuinit can load it
# (it resolves them from /proc/kallsyms), a first-stage insmod cannot.
# ksuinit = upstream userspace/ksuinit + ksuinit-a52-rdinit-crash-guard.patch: started by the kernel as
# rdinit=/ksuinit from the vendor_boot ramdisk, loads /kernelsu.ko, execs the ROM's own /init (not replaced);
# a ramoops panic record of the previous boot (/sys/fs/pstore/dmesg-*) = do not load for this one boot.
# Packaging (until build-realboot.sh has KSU=1): mkimg.sh <base rb dir> <new name>.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd)
K=$TOP/donors/KernelSU-Next; TAG=${KSU_TAG:-v3.4.0}
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
if [ ! -d "$K/.git" ]; then
	SRC=$HOME/git/android/kernel/samsung/sm7325/KernelSU-Next
	[ -d "$SRC/.git" ] || SRC=https://github.com/KernelSU-Next/KernelSU-Next.git
	git clone -q --branch "$TAG" "$SRC" "$K"
fi
[ "$(git -C "$K" describe --tags)" = "$TAG" ] || { echo "donors/KernelSU-Next is not at $TAG" >&2; exit 1; }
git -C "$K" diff --quiet -- userspace/ksuinit || git -C "$K" checkout -q -- userspace/ksuinit
git -C "$K" apply "$HERE/ksuinit-a52-rdinit-crash-guard.patch"
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
make -C "$TOP/bsp612/kernel" ARCH=arm64 LLVM="$CLANG/" O="$TOP/bsp612/out/lahaina" M="$K/kernel" CONFIG_KSU=m \
	KBUILD_MODPOST_WARN=1 KCFLAGS="-I$TOP/bsp612/out/gki/security/selinux" -j20 modules > "$HERE/build.log" 2>&1
( cd "$K/userspace/ksuinit" && RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static --remap-path-prefix=$HOME=~" \
	cargo build --release --target aarch64-unknown-linux-musl -q )
mkdir -p "$HERE/out"
cp "$K/kernel/kernelsu.ko" "$HERE/out/kernelsu.ko"
${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-strip --strip-debug "$HERE/out/kernelsu.ko"
install -m 0755 "$K/userspace/ksuinit/target/aarch64-unknown-linux-musl/release/ksuinit" "$HERE/out/ksuinit"
grep -a -o 'vermagic=[^ ]*' "$HERE/out/kernelsu.ko" | head -n 1
echo "undefined (resolved by ksuinit): $(grep -c 'undefined!' "$HERE/build.log")"
sha256sum "$HERE/out/kernelsu.ko" "$HERE/out/ksuinit"
