#!/bin/bash
# static aarch64 build of rpmbprobe (AOSP clang r547379 + musl sysroot, as drivers612/modem/userspace/build.sh)
set -e; cd "$(dirname "$0")"; AOSP=${ANDROID_TREE:-$HOME/android}/prebuilts
CL=$AOSP/clang/host/linux-x86/clang-r547379; SR=$AOSP/build-tools/sysroots/aarch64-unknown-linux-musl
RT=$CL/lib/clang/20/lib/linux/aarch64-unknown-linux-musl/lib/linux/libclang_rt.builtins-aarch64.a
$CL/bin/clang --target=aarch64-linux-musl --sysroot=$SR -nostdinc -isystem $CL/lib/clang/20/include -isystem $SR/include \
	-O2 -Wall -fno-stack-protector -c rpmbprobe.c -o rpmbprobe.o
$CL/bin/clang --target=aarch64-linux-musl -fuse-ld=lld -static -nostdlib -o rpmbprobe $SR/lib/crt1.o $SR/lib/crti.o \
	$SR/lib/crtbeginT.o rpmbprobe.o $SR/lib/libc.a $RT $SR/lib/crtend.o $SR/lib/crtn.o
$CL/bin/llvm-strip rpmbprobe; rm -f rpmbprobe.o; ls -la rpmbprobe
