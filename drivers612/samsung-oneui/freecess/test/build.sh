#!/bin/bash
# static aarch64 build of kfreecess_test (AOSP clang r547379 + musl sysroot, as tools/voippcm/build.sh)
set -e; cd "$(dirname "$0")"; AOSP=${ANDROID_TREE:-$HOME/android}/prebuilts
CL=$AOSP/clang/host/linux-x86/clang-r547379; SR=$AOSP/build-tools/sysroots/aarch64-unknown-linux-musl
RT=$CL/lib/clang/20/lib/linux/aarch64-unknown-linux-musl/lib/linux/libclang_rt.builtins-aarch64.a
mkdir -p out
$CL/bin/clang --target=aarch64-linux-musl --sysroot=$SR -nostdinc -isystem $CL/lib/clang/20/include -isystem $SR/include \
	-O2 -Wall -fno-stack-protector -c kfreecess_test.c -o out/kfreecess_test.o
$CL/bin/clang --target=aarch64-linux-musl -fuse-ld=lld -static -nostdlib -o out/kfreecess_test $SR/lib/crt1.o $SR/lib/crti.o \
	$SR/lib/crtbeginT.o out/kfreecess_test.o $SR/lib/libc.a $RT $SR/lib/crtend.o $SR/lib/crtn.o
$CL/bin/clang --target=aarch64-linux-musl --sysroot=$SR -nostdinc -isystem $CL/lib/clang/20/include -isystem $SR/include \
	-O1 -Wall -fno-stack-protector -c halfthaw.c -o out/halfthaw.o
$CL/bin/clang --target=aarch64-linux-musl -fuse-ld=lld -static -nostdlib -o out/halfthaw $SR/lib/crt1.o $SR/lib/crti.o \
	$SR/lib/crtbeginT.o out/halfthaw.o $SR/lib/libc.a $RT $SR/lib/crtend.o $SR/lib/crtn.o
$CL/bin/llvm-strip out/halfthaw; rm -f out/halfthaw.o
$CL/bin/llvm-strip out/kfreecess_test; rm -f out/kfreecess_test.o; ls -la out/kfreecess_test
