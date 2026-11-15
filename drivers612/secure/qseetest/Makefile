# SPDX-License-Identifier: GPL-2.0-only
# qseetest: first on-device check of /dev/qseecom, /dev/smcinvoke, /dev/qce (see qseetest.c).
#   make           static test binaries build/qseetest64, build/qseetest32
# The binaries use the kernel's nolibc, so no Android NDK or libc is needed.

TOP    := $(abspath $(CURDIR)/../../..)
ACK    ?= $(TOP)/bsp612/kernel
KOUT   ?= $(TOP)/bsp612/out/lahaina
CLANG  ?= $(ANDROID_TREE)/prebuilts/clang/host/linux-x86/clang-r547379/bin
# 5.4 UAPI headers to check against: the phone's kernel tree if it is there,
# else the verbatim copies shipped with the module.
K54    ?= $(ANDROID_TREE)/kernel/samsung/sm7325
K54INC := $(if $(wildcard $(K54)/include/uapi/linux/msm_ion.h),$(K54)/include/uapi,$(abspath ../include/uapi))

CC       := $(CLANG)/clang
T64      := --target=aarch64-linux-gnu
T32      := --target=armv7a-linux-gnueabi -mfloat-abi=softfp -marm
WARN     := -Wall -Wextra -Werror
CHECKFL  := -fsyntax-only -ffreestanding -nostdlibinc $(WARN) \
	    -idirafter $(ACK)/include/uapi
NOLIBC   := -nostdlib -nostdlibinc -static -ffreestanding -fno-stack-protector \
	    -fuse-ld=lld -Os $(WARN) -include $(ACK)/tools/include/nolibc/nolibc.h \
	    -I$(ACK)/tools/include/nolibc -Inolibc612

all: build/qseetest64 build/qseetest32

# twice: against the 5.4 tree (K54INC) and against the module's own copies
# arm64 UAPI headers come from the kernel build (usr/include)
build/qseetest64: qseetest.c
	@mkdir -p build
	$(CC) $(T64) $(NOLIBC) -isystem $(KOUT)/usr/include -o $@ qseetest.c

# 32-bit arm UAPI headers are exported from the same kernel source
build/hdr-arm/include/linux/ioctl.h:
	@mkdir -p build/hdr-arm build/kobj-arm
	$(MAKE) -C $(ACK) ARCH=arm LLVM=$(CLANG)/ O=$(CURDIR)/build/kobj-arm \
		INSTALL_HDR_PATH=$(CURDIR)/build/hdr-arm headers_install >/dev/null

build/qseetest32: qseetest.c build/hdr-arm/include/linux/ioctl.h
	$(CC) $(T32) $(NOLIBC) -isystem build/hdr-arm/include -o $@ qseetest.c

clean:
	rm -rf build

.PHONY: all check clean
