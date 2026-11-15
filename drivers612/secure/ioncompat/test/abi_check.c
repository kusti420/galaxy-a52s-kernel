// SPDX-License-Identifier: GPL-2.0-only
/*
 * Build-time check, no code: the ABI the test (and a blob) uses, ion_abi.h,
 * against the 5.4 kernel headers found through -I (K54 in the Makefile: the
 * real 5.4 tree, or the verbatim copies in ../include/uapi), and both
 * against the literal numbers. Compiled for arm64 and for 32-bit arm; the
 * numbers must be the same for both, because 5.4 has one handler for native
 * and compat callers.
 */
#include <stddef.h>
#include <linux/ion.h>
#include <linux/msm_ion.h>
#include "ion_abi.h"

#define SAME_STRUCT(s, size) \
	_Static_assert(sizeof(struct s) == (size), #s " size"); \
	_Static_assert(sizeof(struct t_##s) == sizeof(struct s), #s " copy size"); \
	_Static_assert(_Alignof(struct t_##s) == _Alignof(struct s), #s " copy align")
#define SAME_FIELD(s, f, off) \
	_Static_assert(offsetof(struct s, f) == (off), #s "." #f " offset"); \
	_Static_assert(offsetof(struct t_##s, f) == (off), #s "." #f " copy offset")
#define SAME_VALUE(name, val) \
	_Static_assert((name) == (val), #name " value"); \
	_Static_assert((T_##name) == (name), #name " copy")

SAME_STRUCT(ion_allocation_data, 24);
SAME_FIELD(ion_allocation_data, len, 0);
SAME_FIELD(ion_allocation_data, heap_id_mask, 8);
SAME_FIELD(ion_allocation_data, flags, 12);
SAME_FIELD(ion_allocation_data, fd, 16);
SAME_FIELD(ion_allocation_data, unused, 20);

SAME_STRUCT(ion_heap_data, 52);
SAME_FIELD(ion_heap_data, name, 0);
SAME_FIELD(ion_heap_data, type, 32);
SAME_FIELD(ion_heap_data, heap_id, 36);
SAME_FIELD(ion_heap_data, reserved0, 40);
SAME_FIELD(ion_heap_data, reserved2, 48);

SAME_STRUCT(ion_heap_query, 24);
SAME_FIELD(ion_heap_query, cnt, 0);
SAME_FIELD(ion_heap_query, reserved0, 4);
SAME_FIELD(ion_heap_query, heaps, 8);
SAME_FIELD(ion_heap_query, reserved1, 16);
SAME_FIELD(ion_heap_query, reserved2, 20);

SAME_STRUCT(ion_prefetch_regions, 16);
SAME_FIELD(ion_prefetch_regions, sizes, 0);
SAME_FIELD(ion_prefetch_regions, vmid, 8);
SAME_FIELD(ion_prefetch_regions, nr_sizes, 12);

SAME_STRUCT(ion_prefetch_data, 24);
SAME_FIELD(ion_prefetch_data, len, 0);
SAME_FIELD(ion_prefetch_data, regions, 8);
SAME_FIELD(ion_prefetch_data, heap_id, 16);
SAME_FIELD(ion_prefetch_data, nr_regions, 20);

SAME_VALUE(ION_IOC_ALLOC, 0xc0184900U);
SAME_VALUE(ION_IOC_HEAP_QUERY, 0xc0184908U);
SAME_VALUE(ION_IOC_ABI_VERSION, 0x80044909U);
SAME_VALUE(ION_IOC_PREFETCH, 0xc0184d03U);
SAME_VALUE(ION_IOC_DRAIN, 0xc0184d04U);
_Static_assert(T_ION_IOC_FREE == 0xc0044901U, "legacy ION_IOC_FREE");

SAME_VALUE(ION_HEAP_TYPE_DMA, 2);
SAME_VALUE(ION_HEAP_TYPE_SECURE_DMA, 16);
SAME_VALUE(ION_HEAP_TYPE_SYSTEM_SECURE, 17);
SAME_VALUE(ION_HEAP_TYPE_HYP_CMA, 18);
SAME_VALUE(ION_HEAP_TYPE_MSM_CARVEOUT, 19);
SAME_VALUE(ION_HEAP_TYPE_SECURE_CARVEOUT, 20);
SAME_VALUE(ION_HEAP_TYPE_MSM_SYSTEM, 21);

SAME_VALUE(ION_QSECOM_TA_HEAP_ID, 0x2U);
SAME_VALUE(ION_DISPLAY_HEAP_ID, 0x8U);
SAME_VALUE(ION_ADSP_HEAP_ID, 0x10U);
SAME_VALUE(ION_AUDIO_ML_HEAP_ID, 0x20U);
SAME_VALUE(ION_USER_CONTIG_HEAP_ID, 0x40U);
SAME_VALUE(ION_QSECOM_HEAP_ID, 0x80U);
SAME_VALUE(ION_AUDIO_HEAP_ID, 0x100U);
SAME_VALUE(ION_CP_MM_HEAP_ID, 0x200U);
SAME_VALUE(ION_SECURE_HEAP_ID, 0x400U);
SAME_VALUE(ION_SECURE_DISPLAY_HEAP_ID, 0x800U);
SAME_VALUE(ION_SPSS_HEAP_ID, 0x4000U);
SAME_VALUE(ION_SECURE_CARVEOUT_HEAP_ID, 0x8000U);
SAME_VALUE(ION_TUI_CARVEOUT_HEAP_ID, 0x10000U);
SAME_VALUE(ION_AUDIO_CARVEOUT_HEAP_ID, 0x20000U);
SAME_VALUE(ION_SYSTEM_HEAP_ID, 0x2000000U);
SAME_VALUE(ION_CAMERA_HEAP_ID, 0x40000000U);

SAME_VALUE(ION_FLAG_CACHED, 1U);
SAME_VALUE(ION_FLAG_CP_TRUSTED_VM, 0x8000U);
SAME_VALUE(ION_FLAG_POOL_FORCE_ALLOC, 0x10000U);
SAME_VALUE(ION_FLAG_CP_TOUCH, 0x20000U);
SAME_VALUE(ION_FLAG_CP_BITSTREAM, 0x40000U);
SAME_VALUE(ION_FLAG_CP_PIXEL, 0x80000U);
SAME_VALUE(ION_FLAG_CP_NON_PIXEL, 0x100000U);
SAME_VALUE(ION_FLAG_CP_CAMERA, 0x200000U);
SAME_VALUE(ION_FLAG_CP_HLOS, 0x400000U);
SAME_VALUE(ION_FLAG_CP_SPSS_SP, 0x800000U);
SAME_VALUE(ION_FLAG_CP_SPSS_SP_SHARED, 0x1000000U);
SAME_VALUE(ION_FLAG_CP_SEC_DISPLAY, 0x2000000U);
SAME_VALUE(ION_FLAG_CP_APP, 0x4000000U);
SAME_VALUE(ION_FLAG_CP_CAMERA_PREVIEW, 0x8000000U);
SAME_VALUE(ION_FLAG_ALLOW_NON_CONTIG, 0x10000000U);
SAME_VALUE(ION_FLAG_CP_CDSP, 0x20000000U);
SAME_VALUE(ION_FLAG_CP_SPSS_HLOS_SHARED, 0x40000000U);
SAME_VALUE(ION_FLAG_SECURE, 0x80000000U);
SAME_VALUE(ION_FLAGS_CP_MASK, 0x6FFE8000U);
