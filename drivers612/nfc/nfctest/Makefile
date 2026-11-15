# SPDX-License-Identifier: GPL-2.0-only
# nfctest: static arm64 test binary for /dev/sec-nfc (kernel nolibc, no NDK).
#   make  -> build/nfctest
TOP    := $(abspath $(CURDIR)/../../..)
ACK    ?= $(TOP)/bsp612/kernel
KOUT   ?= $(TOP)/bsp612/out/lahaina
CLANG  ?= $(ANDROID_TREE)/prebuilts/clang/host/linux-x86/clang-r547379/bin

build/nfctest: nfctest.c
	@mkdir -p build
	$(CLANG)/clang --target=aarch64-linux-gnu -nostdlib -nostdlibinc -static -ffreestanding \
		-fno-stack-protector -fuse-ld=lld -Os -Wall -Wextra -Werror \
		-include $(ACK)/tools/include/nolibc/nolibc.h -I$(ACK)/tools/include/nolibc \
		-isystem $(KOUT)/usr/include -o $@ nfctest.c

clean:
	rm -rf build
.PHONY: clean
