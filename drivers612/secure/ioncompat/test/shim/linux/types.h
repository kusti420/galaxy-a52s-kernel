/* SPDX-License-Identifier: GPL-2.0-only */
/* <linux/types.h> stand-in for the freestanding ABI check: fixed-width types only. */
#ifndef IONTEST_SHIM_TYPES_H
#define IONTEST_SHIM_TYPES_H
typedef __UINT8_TYPE__ __u8;
typedef __UINT16_TYPE__ __u16;
typedef __UINT32_TYPE__ __u32;
typedef __UINT64_TYPE__ __u64;
typedef __INT32_TYPE__ __s32;
typedef __INT64_TYPE__ __s64;
#endif
