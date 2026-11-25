#!/bin/bash
# static aarch64 build (as tools/dmkat): tools/selftest/oneui/actl/build.sh -> tools/selftest/oneui/actl/actl-arm64
set -euo pipefail; HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; export CARGO_TARGET_DIR=$HERE/target
RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld -C target-feature=+crt-static --remap-path-prefix=$HERE=actl --remap-path-prefix=$HOME=~" \
	cargo build --release --offline --target aarch64-unknown-linux-musl -q
install -m 0755 target/aarch64-unknown-linux-musl/release/actl actl-arm64; file actl-arm64
