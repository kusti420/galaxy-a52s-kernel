#!/bin/bash
# Builds lsmioctl (aarch64) and lsmioctl32 (armv7, the compat path of a 32-bit audio HAL). Static, no libc.
set -euo pipefail
cd "$(dirname "$0")"
CB=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
F="-Os -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -fuse-ld=lld -Wall -Wno-unused-function"
"$CB/clang" --target=aarch64-linux-gnu $F -o lsmioctl lsmioctl.c
"$CB/clang" --target=armv7a-linux-gnueabi -marm -mfloat-abi=soft $F -o lsmioctl32 lsmioctl.c
sha256sum lsmioctl lsmioctl32
