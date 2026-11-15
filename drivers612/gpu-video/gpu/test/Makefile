# SPDX-License-Identifier: GPL-2.0-only
# kgsltest: static nolibc binaries (arm64 + 32-bit arm) using the phone's 5.4 msm_kgsl.h.
# Nothing runs on the build host. Reads bsp612/kernel and bsp612/out/lahaina only.
TOP   := $(abspath $(CURDIR)/../../../..)
KSRC  ?= $(TOP)/bsp612/kernel
KOUT  ?= $(TOP)/bsp612/out/lahaina
CLANG ?= $(ANDROID_TREE)/prebuilts/clang/host/linux-x86/clang-r547379/bin
CC    := $(CLANG)/clang
T64   := --target=aarch64-linux-gnu
T32   := --target=armv7a-linux-gnueabi -mfloat-abi=softfp -marm
NOLIBC := -nostdlib -nostdlibinc -static -ffreestanding -fno-stack-protector -fuse-ld=lld -Os \
	  -Wall -Wextra -Werror -include $(KSRC)/tools/include/nolibc/nolibc.h \
	  -I$(KSRC)/tools/include/nolibc -Iuapi54

all: build/kgsltest64 build/kgsltest32
build/kgsltest64: kgsltest.c
	@mkdir -p build
	$(CC) $(T64) $(NOLIBC) -isystem $(KOUT)/usr/include -o $@ $<
build/hdr-arm/include/linux/ioctl.h:
	@mkdir -p build/hdr-arm build/kobj-arm
	$(MAKE) -C $(KSRC) ARCH=arm LLVM=$(CLANG)/ O=$(CURDIR)/build/kobj-arm \
		INSTALL_HDR_PATH=$(CURDIR)/build/hdr-arm headers_install >/dev/null
build/kgsltest32: kgsltest.c build/hdr-arm/include/linux/ioctl.h
	$(CC) $(T32) $(NOLIBC) -isystem build/hdr-arm/include -o $@ $<
clean:
	rm -rf build
.PHONY: all clean
