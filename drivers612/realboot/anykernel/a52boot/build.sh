#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Builds a52boot: static arm64 (the zip's binary) and a host build (tests, mk-ak-zip.sh).
#   drivers612/realboot/anykernel/a52boot/build.sh   -> out/a52boot-arm64, out/a52boot-host
# Static aarch64-unknown-linux-musl, linked by rust-lld (no cross gcc needed), no crates,
# no /home paths in the binary (--remap-path-prefix), reproducible (same rustc -> same bytes).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
export CARGO_TARGET_DIR=$HERE/target
REMAP="--remap-path-prefix=$HERE=a52boot --remap-path-prefix=$HOME=~"
rustup target list --installed | grep -qx aarch64-unknown-linux-musl || rustup target add aarch64-unknown-linux-musl
RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static $REMAP" \
	cargo build --release --locked --offline --target aarch64-unknown-linux-musl -q
RUSTFLAGS="$REMAP" cargo build --release --locked --offline -q
mkdir -p out
install -m 0755 target/aarch64-unknown-linux-musl/release/a52boot out/a52boot-arm64
install -m 0755 target/release/a52boot out/a52boot-host
file out/a52boot-arm64 | sed 's/^/  /'
! grep -aq "$HOME" out/a52boot-arm64 || { echo "a52boot-arm64 contains $HOME" >&2; exit 1; }
sha256sum out/a52boot-arm64 out/a52boot-host
