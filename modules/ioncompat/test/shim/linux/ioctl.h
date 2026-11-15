/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * <linux/ioctl.h> stand-in for the freestanding ABI check. arm and arm64
 * both use the kernel's asm-generic/ioctl.h unchanged (found with
 * -idirafter <kernel>/include/uapi).
 */
#ifndef IONTEST_SHIM_IOCTL_H
#define IONTEST_SHIM_IOCTL_H
#include <asm-generic/ioctl.h>
#endif
