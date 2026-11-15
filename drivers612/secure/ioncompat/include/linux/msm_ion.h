/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * msm ION kernel helpers of the 5.4 kernel, provided by ioncompat.
 * Derived from include/linux/msm_ion.h,
 * Copyright (c) 2019-2020, The Linux Foundation. All rights reserved.
 */
#ifndef _IONCOMPAT_LINUX_MSM_ION_H
#define _IONCOMPAT_LINUX_MSM_ION_H

#include <linux/bitmap.h>
#include <linux/device.h>
#include <linux/dma-buf.h>
#include <linux/err.h>
#include <linux/scatterlist.h>
#include <uapi/linux/msm_ion.h>

struct ion_prefetch_region {
	u64 size;
	u32 vmid;
};

static inline unsigned int ion_get_flags_num_vm_elems(unsigned int flags)
{
	unsigned long vm_flags = flags & ION_FLAGS_CP_MASK;

	return ((unsigned int)bitmap_weight(&vm_flags, BITS_PER_LONG));
}

/* ION_FLAG_CP_* bits -> VMID list (filled from the end, as in 5.4) */
int ion_populate_vm_list(unsigned long flags, unsigned int *vm_list,
			 int nelems);

/* VMID -> ION_FLAG_CP_* bit, -EINVAL when the VMID has none */
int get_ion_flags(u32 vmid);

/* true for the SYSTEM_SECURE, HYP_CMA and SECURE_CARVEOUT heap ids */
bool msm_ion_heap_is_secure(int heap_id);

/*
 * Not implemented, -ENOTSUPP: secure pool prefetch/drain was a speed-up of
 * the 5.4 secure system heap. It belongs in the backing secure heap.
 */
int msm_ion_heap_prefetch(int heap_id, struct ion_prefetch_region *regions,
			  int nr_regions);
int msm_ion_heap_drain(int heap_id, struct ion_prefetch_region *regions,
		       int nr_regions);

/*
 * Not implemented, ERR_PTR(-ENODEV): the 5.4 per-heap platform device (with
 * the heap's reserved-memory region attached) has no equivalent here.
 */
struct device *msm_ion_heap_device_by_id(int heap_id);

/*
 * Who owns the memory of a dma-buf (6.12 BSP: read from Qualcomm mem-buf).
 * ion_compat_dma_buf_get_flags() is the 5.4 dma_buf_get_flags(): ION flags,
 * ION_FLAG_SECURE | ION_FLAG_CP_* for memory assigned away from HLOS, else 0.
 * ion_compat_dma_buf_vmids() returns kmalloc'ed VMID/permission arrays.
 */
int ion_compat_dma_buf_get_flags(struct dma_buf *dmabuf, unsigned long *flags);
int ion_compat_dma_buf_vmids(struct dma_buf *dmabuf, int **vmids, int **perms,
			     int *nr);
bool ion_compat_dma_buf_is_secure(struct dma_buf *dmabuf);

/*
 * 5.4 name, so forward-ported drivers keep their call sites. GKI 6.12 still
 * exports dma_buf_get_flags(), but no Qualcomm heap implements the get_flags
 * op, so it always answers "flags 0" (not secure) there: a 5.4 driver using
 * it unchanged would treat secure buffers as normal memory. Hence the
 * redirection (linux/dma-buf.h is included above, its prototype is unaffected).
 */
#ifndef IONCOMPAT_NO_DMA_BUF_GET_FLAGS
#define dma_buf_get_flags(dmabuf, flags) \
	ion_compat_dma_buf_get_flags(dmabuf, flags)
#endif

static inline int msm_ion_heap_add_memory(int heap_id, struct sg_table *sgt)
{
	return -ENODEV;
}

static inline int msm_ion_heap_remove_memory(int heap_id, struct sg_table *sgt)
{
	return -ENODEV;
}

static inline int msm_ion_dma_buf_lock(struct dma_buf *dmabuf)
{
	return -ENODEV;
}

static inline void msm_ion_dma_buf_unlock(struct dma_buf *dmabuf)
{
}

#endif /* _IONCOMPAT_LINUX_MSM_ION_H */
