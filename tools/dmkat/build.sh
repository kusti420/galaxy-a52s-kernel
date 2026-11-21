#!/bin/bash
# static aarch64 build (as a52boot): tools/dmkat/build.sh -> tools/dmkat/out/dmkat-arm64
set -euo pipefail; HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; export CARGO_TARGET_DIR=$HERE/target
RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static --remap-path-prefix=$HERE=dmkat --remap-path-prefix=$HOME=~" \
	cargo build --release --offline --target aarch64-unknown-linux-musl -q
mkdir -p out; install -m 0755 target/aarch64-unknown-linux-musl/release/dmkat out/dmkat-arm64; file out/dmkat-arm64
