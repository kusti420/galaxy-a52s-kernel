#!/bin/sh
# static, libc-free arm64 binary for the test ramdisk (like tools/rb)
D=$(cd "$(dirname "$0")" && pwd)
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
$CLANG/clang --target=aarch64-linux-gnu -O2 -Wall -Werror -ffreestanding -fno-stack-protector \
  -fno-builtin -nostdlib -static -fuse-ld=lld -o $D/qrtrls $D/qrtrls.c
