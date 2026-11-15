/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * In-kernel ION allocation API of the 5.4 msm kernel, provided by ioncompat
 * on top of DMA-BUF heaps so that forward-ported drivers (camera, adsprpc,
 * audio, vidc) keep their ion_alloc() calls.
 *
 * Only the consumer side exists. The heap provider side of 5.4
 * (struct ion_heap, ion_device_add_heap, ...) is gone: heaps are DMA-BUF
 * heaps now.
 */
#ifndef _IONCOMPAT_LINUX_ION_H
#define _IONCOMPAT_LINUX_ION_H

#include <linux/dma-buf.h>
#include <linux/types.h>
#include <uapi/linux/ion.h>

/**
 * ion_alloc - allocate a dma-buf the way ION_IOC_ALLOC does
 * @len:          size in bytes, rounded up to pages
 * @heap_id_mask: mask of 5.4 heap id bits (ION_SYSTEM_HEAP_ID, ...)
 * @flags:        ION_FLAG_CACHED, ION_FLAG_SECURE, ION_FLAG_CP_*
 *
 * Heaps in the mask are tried from the highest id down, as in 5.4.
 * Returns the dma-buf (drop it with dma_buf_put()) or an ERR_PTR:
 * -ENODEV when no heap in the mask exists or its backing DMA-BUF heap is
 * not registered, -EINVAL for flags the heap type refuses.
 */
struct dma_buf *ion_alloc(size_t len, unsigned int heap_id_mask,
			  unsigned int flags);

/**
 * ion_query_heaps_kernel - same data as ION_IOC_HEAP_QUERY
 * @hdata: array to fill, or anything when @size is 0
 * @size:  number of elements in @hdata; 0 returns the heap count
 */
size_t ion_query_heaps_kernel(struct ion_heap_data *hdata, size_t size);

#endif /* _IONCOMPAT_LINUX_ION_H */
