/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * The 5.4 msm ION userspace ABI as a vendor blob has it compiled in:
 * structures and numbers copied from include/uapi/linux/ion.h,
 * msm_ion.h and msm_ion_ids.h of the A52s 5.4 kernel
 * (Copyright (C) 2011 Google, Inc.; Copyright (c) 2018-2021 The Linux
 * Foundation), under a T_/t_ prefix so that abi_check.c can compare them
 * with the real headers in one translation unit.
 */
#ifndef IONTEST_ION_ABI_H
#define IONTEST_ION_ABI_H

#include <linux/ioctl.h>
#include <linux/types.h>

struct t_ion_allocation_data {
	__u64 len;
	__u32 heap_id_mask;
	__u32 flags;
	__u32 fd;
	__u32 unused;
};

struct t_ion_heap_data {
	char name[32];
	__u32 type;
	__u32 heap_id;
	__u32 reserved0;
	__u32 reserved1;
	__u32 reserved2;
};

struct t_ion_heap_query {
	__u32 cnt;
	__u32 reserved0;
	__u64 heaps;
	__u32 reserved1;
	__u32 reserved2;
};

struct t_ion_prefetch_regions {
	__u64 sizes;
	__u32 vmid;
	__u32 nr_sizes;
};

struct t_ion_prefetch_data {
	__u64 len;
	__u64 regions;
	__u32 heap_id;
	__u32 nr_regions;
};

/* pre-4.12 ION, only used to probe: new ION answers -ENOTTY (libion's ion_is_legacy()) */
struct t_ion_handle_data {
	__s32 handle;
};

#define T_ION_IOC_ALLOC		_IOWR('I', 0, struct t_ion_allocation_data)
#define T_ION_IOC_FREE		_IOWR('I', 1, struct t_ion_handle_data)
#define T_ION_IOC_HEAP_QUERY	_IOWR('I', 8, struct t_ion_heap_query)
#define T_ION_IOC_ABI_VERSION	_IOR('I', 9, __u32)
#define T_ION_IOC_PREFETCH	_IOWR('M', 3, struct t_ion_prefetch_data)
#define T_ION_IOC_DRAIN		_IOWR('M', 4, struct t_ion_prefetch_data)

/* heap types (ion.h, msm_ion.h) */
#define T_ION_HEAP_TYPE_DMA		2
#define T_ION_HEAP_TYPE_SECURE_DMA	16
#define T_ION_HEAP_TYPE_SYSTEM_SECURE	17
#define T_ION_HEAP_TYPE_HYP_CMA		18
#define T_ION_HEAP_TYPE_MSM_CARVEOUT	19
#define T_ION_HEAP_TYPE_SECURE_CARVEOUT	20
#define T_ION_HEAP_TYPE_MSM_SYSTEM	21

/* heap id masks (msm_ion_ids.h) */
#define T_ION_QSECOM_TA_HEAP_ID		(1U << 1)
#define T_ION_DISPLAY_HEAP_ID		(1U << 3)
#define T_ION_ADSP_HEAP_ID		(1U << 4)
#define T_ION_AUDIO_ML_HEAP_ID		(1U << 5)
#define T_ION_USER_CONTIG_HEAP_ID	(1U << 6)
#define T_ION_QSECOM_HEAP_ID		(1U << 7)
#define T_ION_AUDIO_HEAP_ID		(1U << 8)
#define T_ION_CP_MM_HEAP_ID		(1U << 9)
#define T_ION_SECURE_HEAP_ID		(1U << 10)
#define T_ION_SECURE_DISPLAY_HEAP_ID	(1U << 11)
#define T_ION_SPSS_HEAP_ID		(1U << 14)
#define T_ION_SECURE_CARVEOUT_HEAP_ID	(1U << 15)
#define T_ION_TUI_CARVEOUT_HEAP_ID	(1U << 16)
#define T_ION_AUDIO_CARVEOUT_HEAP_ID	(1U << 17)
#define T_ION_SYSTEM_HEAP_ID		(1U << 25)
#define T_ION_CAMERA_HEAP_ID		(1U << 30)

/* flags (ion.h, msm_ion.h) */
#define T_ION_FLAG_CACHED		1U
#define T_ION_FLAG_CP_TRUSTED_VM	(1U << 15)
#define T_ION_FLAG_POOL_FORCE_ALLOC	(1U << 16)
#define T_ION_FLAG_CP_TOUCH		(1U << 17)
#define T_ION_FLAG_CP_BITSTREAM		(1U << 18)
#define T_ION_FLAG_CP_PIXEL		(1U << 19)
#define T_ION_FLAG_CP_NON_PIXEL		(1U << 20)
#define T_ION_FLAG_CP_CAMERA		(1U << 21)
#define T_ION_FLAG_CP_HLOS		(1U << 22)
#define T_ION_FLAG_CP_SPSS_SP		(1U << 23)
#define T_ION_FLAG_CP_SPSS_SP_SHARED	(1U << 24)
#define T_ION_FLAG_CP_SEC_DISPLAY	(1U << 25)
#define T_ION_FLAG_CP_APP		(1U << 26)
#define T_ION_FLAG_CP_CAMERA_PREVIEW	(1U << 27)
#define T_ION_FLAG_ALLOW_NON_CONTIG	(1U << 28)
#define T_ION_FLAG_CP_CDSP		(1U << 29)
#define T_ION_FLAG_CP_SPSS_HLOS_SHARED	(1U << 30)
#define T_ION_FLAG_SECURE		(1U << 31)
#define T_ION_FLAGS_CP_MASK		0x6FFE8000U

#endif /* IONTEST_ION_ABI_H */
