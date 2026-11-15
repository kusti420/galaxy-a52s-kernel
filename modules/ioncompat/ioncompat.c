// SPDX-License-Identifier: GPL-2.0-only
/*
 * ioncompat - the 5.4 msm ION ABI on top of DMA-BUF heaps.
 *
 * The Galaxy A52s 5G (a52sxq, SM7325) vendor blobs were built for a 5.4
 * kernel and allocate through /dev/ion only, with hard-coded msm heap id
 * bits and content protection flags. Kernel 6.18 has DMA-BUF heaps and no
 * ION. This module provides
 *   - /dev/ion with the ioctls of the 5.4 kernel (ION_IOC_ALLOC,
 *     ION_IOC_HEAP_QUERY, ION_IOC_ABI_VERSION; the same code path serves
 *     32-bit callers), and
 *   - ion_alloc() and the msm_ion helpers for forward-ported drivers,
 * and takes the memory from the DMA-BUF heap that stands for the 5.4 heap.
 * See README.md for the heap table and for the backing heaps that still
 * have to be written.
 *
 * Started from modules/ioncompat/ioncompat.c of the redwood-6.12 project
 * (POCO X5 Pro, same SoC, GPL-2.0-only, no copyright line in the file;
 * https://github.com/suvojeet-sengupta/redwood-6.12): the idea of a misc
 * device that turns the ION allocation ioctl into dma_heap_find() +
 * dma_heap_buffer_alloc(), and the lesson that the CP flag selects the
 * secure memory. The heap selection was rewritten to follow the 5.4 ION
 * core (drivers/staging/android/ion, Copyright (C) 2011 Google, Inc.,
 * Copyright (c) 2017-2021 The Linux Foundation), whose ioctl and heap
 * walking logic is reproduced here.
 */

#define pr_fmt(fmt) "ioncompat: " fmt

#include <linux/bitops.h>
#include <linux/build_bug.h>
#include <linux/debugfs.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/ion.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/msm_ion.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/uaccess.h>

/* what ION_IOC_ABI_VERSION returns on 5.4 (ION_CURRENT_ABI_VERSION in ion.c) */
#define IONC_ABI_VERSION	2

#define IONC_NAME_MAX		64

/* VMIDs of the 5.4 include/soc/qcom/secure_buffer.h */
#define IONC_VMID_HLOS			0x3
#define IONC_VMID_CP_TOUCH		0x8
#define IONC_VMID_CP_BITSTREAM		0x9
#define IONC_VMID_CP_PIXEL		0xA
#define IONC_VMID_CP_NON_PIXEL		0xB
#define IONC_VMID_CP_CAMERA		0xD
#define IONC_VMID_CP_SEC_DISPLAY	0x11
#define IONC_VMID_CP_APP		0x12
#define IONC_VMID_CP_SPSS_SP		0x1A
#define IONC_VMID_CP_CAMERA_PREVIEW	0x1D
#define IONC_VMID_CP_SPSS_SP_SHARED	0x22
#define IONC_VMID_CP_SPSS_HLOS_SHARED	0x24
#define IONC_VMID_CP_CDSP		0x2A

/*
 * One line per ION_FLAG_CP_* bit: the VMID the memory is assigned to and
 * the word that names it in a backing heap name. ION_FLAG_CP_TRUSTED_VM
 * (bit 15) is absent: its VMID comes from the Haven resource manager,
 * which this phone does not run.
 */
static const struct ionc_cp {
	u32 flag;
	u32 vmid;
	const char *word;
} ionc_cp[] = {
	{ ION_FLAG_CP_TOUCH,		IONC_VMID_CP_TOUCH,		"touch" },
	{ ION_FLAG_CP_BITSTREAM,	IONC_VMID_CP_BITSTREAM,		"bitstream" },
	{ ION_FLAG_CP_PIXEL,		IONC_VMID_CP_PIXEL,		"pixel" },
	{ ION_FLAG_CP_NON_PIXEL,	IONC_VMID_CP_NON_PIXEL,		"non-pixel" },
	{ ION_FLAG_CP_CAMERA,		IONC_VMID_CP_CAMERA,		"camera" },
	{ ION_FLAG_CP_HLOS,		IONC_VMID_HLOS,			"hlos" },
	{ ION_FLAG_CP_SPSS_SP,		IONC_VMID_CP_SPSS_SP,		"spss-sp" },
	{ ION_FLAG_CP_SPSS_SP_SHARED,	IONC_VMID_CP_SPSS_SP_SHARED,	"spss-sp-shared" },
	{ ION_FLAG_CP_SEC_DISPLAY,	IONC_VMID_CP_SEC_DISPLAY,	"sec-display" },
	{ ION_FLAG_CP_APP,		IONC_VMID_CP_APP,		"app" },
	{ ION_FLAG_CP_CAMERA_PREVIEW,	IONC_VMID_CP_CAMERA_PREVIEW,	"camera-preview" },
	{ ION_FLAG_CP_CDSP,		IONC_VMID_CP_CDSP,		"cdsp" },
	{ ION_FLAG_CP_SPSS_HLOS_SHARED,	IONC_VMID_CP_SPSS_HLOS_SHARED,	"spss-hlos-shared" },
};

/* the CP flags the 5.4 secure system heap accepts (is_cp_flag_present()) */
#define IONC_SYSTEM_SECURE_FLAGS \
	(ION_FLAG_CP_TOUCH | ION_FLAG_CP_BITSTREAM | ION_FLAG_CP_PIXEL | \
	 ION_FLAG_CP_NON_PIXEL | ION_FLAG_CP_CAMERA)

enum ionc_kind {
	/* 5.4 type exists in msm_ion_ids.h, but no mapping is defined yet */
	IONC_UNMAPPED,
	/* page allocator; refuses secure flags; cached or uncached */
	IONC_SYSTEM,
	/* contiguous non-secure memory of one reserved region; refuses secure flags */
	IONC_CONTIG,
	/* memory hyp-assigned to the VMIDs of the CP flags; one heap per VMID set */
	IONC_SECURE,
};

/**
 * struct ionc_heap - one 5.4 msm ION heap
 * @id:        bit number in heap_id_mask (and heap_id in ION_IOC_HEAP_QUERY)
 * @name:      5.4 heap name (ION_IOC_HEAP_QUERY)
 * @type:      5.4 heap type (ION_IOC_HEAP_QUERY)
 * @kind:      how an allocation is turned into a DMA-BUF heap name
 * @backing:   IONC_SYSTEM: cached heap; IONC_CONTIG: the region's heap;
 *             IONC_SECURE: prefix, completed with the CP words
 * @backing2:  IONC_SYSTEM: uncached heap; IONC_CONTIG: second choice
 * @cp_allowed: IONC_SECURE: at least one of these CP flags must be set
 * @cp_single: IONC_SECURE: exactly one CP flag may be set
 * @cma_fallback: IONC_CONTIG: may use the default CMA area (see parameter)
 */
struct ionc_heap {
	u8 id;
	const char *name;
	u32 type;
	enum ionc_kind kind;
	const char *backing;
	const char *backing2;
	u32 cp_allowed;
	bool cp_single;
	bool cma_fallback;
};

/* the default CMA area, registered by drivers/dma-buf/heaps/cma_heap.c */
#define IONC_DEFAULT_CMA	"default_cma_region"

/*
 * All heap ids of the 5.4 include/uapi/linux/msm_ion_ids.h, highest id
 * first: that is the order in which 5.4 tries the heaps of a mask and lists
 * them in ION_IOC_HEAP_QUERY. Names are those of msm_ion_priv.h. Types of
 * the heaps on the A52s are those of its device tree (qcom,ion-heap-type in
 * downstream-dt/a52sxq-r02.dts).
 */
static const struct ionc_heap ionc_heaps[] = {
	{ .id = 30, .name = "camera_heap", .type = ION_HEAP_TYPE_CUSTOM,
	  .kind = IONC_UNMAPPED },
	{ .id = 25, .name = "system", .type = ION_HEAP_TYPE_MSM_SYSTEM,
	  .kind = IONC_SYSTEM,
	  .backing = "system", .backing2 = "system-uncached" },
	{ .id = 17, .name = "audio_carveout", .type = ION_HEAP_TYPE_MSM_CARVEOUT,
	  .kind = IONC_CONTIG, .backing = "qcom,audio-carveout" },
	{ .id = 16, .name = "tui_carveout", .type = ION_HEAP_TYPE_MSM_CARVEOUT,
	  .kind = IONC_CONTIG, .backing = "qcom,tui" },
	{ .id = 15, .name = "secure_carveout", .type = ION_HEAP_TYPE_SECURE_CARVEOUT,
	  .kind = IONC_SECURE, .backing = "qcom,secure",
	  .cp_allowed = ION_FLAGS_CP_MASK, .cp_single = true },
	{ .id = 14, .name = "spss", .type = ION_HEAP_TYPE_HYP_CMA,
	  .kind = IONC_UNMAPPED },
	{ .id = 11, .name = "secure_display", .type = ION_HEAP_TYPE_HYP_CMA,
	  .kind = IONC_SECURE, .backing = "qcom,cp-display",
	  .cp_allowed = ION_FLAGS_CP_MASK },
	{ .id = 10, .name = "secure_heap", .type = ION_HEAP_TYPE_SYSTEM_SECURE,
	  .kind = IONC_SECURE, .backing = "qcom,secure",
	  .cp_allowed = IONC_SYSTEM_SECURE_FLAGS, .cp_single = true },
	{ .id = 9, .name = "mm", .type = ION_HEAP_TYPE_SECURE_DMA,
	  .kind = IONC_UNMAPPED },
	{ .id = 8, .name = "audio", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,audio" },
	{ .id = 7, .name = "qsecom", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,qseecom", .cma_fallback = true },
	{ .id = 6, .name = "user_contig", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,user-contig", .cma_fallback = true },
	{ .id = 5, .name = "audio_ml", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,audio-ml", .cma_fallback = true },
	{ .id = 4, .name = "adsp", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,adsp" },
	{ .id = 3, .name = "display", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,display" },
	{ .id = 1, .name = "qsecom_ta", .type = ION_HEAP_TYPE_DMA,
	  .kind = IONC_CONTIG, .backing = "qcom,qseecom-ta", .cma_fallback = true },
};

/*
 * The heaps the A52s 5.4 kernel registers (enabled qcom,ion-heap nodes):
 * system 25, secure_display 11, secure_heap 10, qsecom 7, user_contig 6,
 * audio_ml 5, qsecom_ta 1. secure_carveout (15) is status = "disabled".
 */
#define IONC_A52SXQ_HEAPS \
	(BIT(25) | BIT(11) | BIT(10) | BIT(7) | BIT(6) | BIT(5) | BIT(1))

static unsigned int enabled_heaps = IONC_A52SXQ_HEAPS;
module_param(enabled_heaps, uint, 0444);
MODULE_PARM_DESC(enabled_heaps,
		 "Mask of 5.4 heap id bits that exist (default: the A52s set, 0x02000ce2)");

static bool cma_fallback = true;
module_param(cma_fallback, bool, 0644);
MODULE_PARM_DESC(cma_fallback,
		 "Take qsecom, qsecom_ta, user_contig and audio_ml memory from the default CMA area while their own heaps are missing (default: Y)");

static bool ionc_heap_enabled(const struct ionc_heap *h)
{
	return enabled_heaps & BIT(h->id);
}

static const struct ionc_heap *ionc_heap_by_mask(int heap_id)
{
	unsigned int i;

	if (!heap_id)
		return NULL;
	/* 5.4 get_ion_heap(): the lowest set bit names the heap */
	heap_id = __ffs(heap_id);
	for (i = 0; i < ARRAY_SIZE(ionc_heaps); i++)
		if (ionc_heaps[i].id == heap_id && ionc_heap_enabled(&ionc_heaps[i]))
			return &ionc_heaps[i];
	return NULL;
}

static bool ionc_is_secure_allocation(u32 flags)
{
	return flags & (ION_FLAGS_CP_MASK | ION_FLAG_SECURE);
}

/* "<prefix>-<word>[-<word>...]", CP flags in ascending bit order */
static int ionc_secure_name(char *buf, const char *prefix, u32 flags)
{
	u32 cp = flags & ION_FLAGS_CP_MASK;
	unsigned int i;

	if (strscpy(buf, prefix, IONC_NAME_MAX) < 0)
		return -EINVAL;
	for (i = 0; i < ARRAY_SIZE(ionc_cp) && cp; i++) {
		if (!(cp & ionc_cp[i].flag))
			continue;
		if (strlcat(buf, "-", IONC_NAME_MAX) >= IONC_NAME_MAX ||
		    strlcat(buf, ionc_cp[i].word, IONC_NAME_MAX) >= IONC_NAME_MAX)
			return -EINVAL;
		cp &= ~ionc_cp[i].flag;
	}
	/* a CP bit without a VMID here (ION_FLAG_CP_TRUSTED_VM) */
	return cp ? -EINVAL : 0;
}

/*
 * The DMA-BUF heap names for one 5.4 heap and one set of flags, in the
 * order to try. Returns the number of names (0 to 2) or the errno the 5.4
 * heap gives for these flags.
 */
static int ionc_backing_names(const struct ionc_heap *h, u32 flags,
			      char names[2][IONC_NAME_MAX])
{
	u32 cp = flags & ION_FLAGS_CP_MASK;
	int n = 0, ret;

	switch (h->kind) {
	case IONC_SYSTEM:
		/* "System heap doesn't support secure allocations" */
		if (ionc_is_secure_allocation(flags))
			return -EINVAL;
		strscpy(names[n++],
			(flags & ION_FLAG_CACHED) ? h->backing : h->backing2,
			IONC_NAME_MAX);
		break;
	case IONC_CONTIG:
		/* "CMA heap doesn't support secure allocations", -ENOMEM on 5.4 */
		if (ionc_is_secure_allocation(flags))
			return -ENOMEM;
		strscpy(names[n++], h->backing, IONC_NAME_MAX);
		if (h->backing2)
			strscpy(names[n++], h->backing2, IONC_NAME_MAX);
		else if (h->cma_fallback && cma_fallback)
			strscpy(names[n++], IONC_DEFAULT_CMA, IONC_NAME_MAX);
		break;
	case IONC_SECURE:
		if (!(flags & h->cp_allowed))
			return -EINVAL;
		if (h->cp_single && hweight32(cp) != 1)
			return -EINVAL;
		ret = ionc_secure_name(names[n], h->backing, flags);
		if (ret)
			return ret;
		n++;
		break;
	case IONC_UNMAPPED:
		break;
	}
	return n;
}

static struct dma_buf *ionc_heap_alloc(const struct ionc_heap *h, size_t len,
				       u32 flags, char *used)
{
	char names[2][IONC_NAME_MAX];
	struct dma_buf *buf = ERR_PTR(-ENODEV);
	struct dma_heap *heap;
	int i, n;

	n = ionc_backing_names(h, flags, names);
	if (n < 0)
		return ERR_PTR(n);

	for (i = 0; i < n; i++) {
		strscpy(used, names[i], IONC_NAME_MAX);
		heap = dma_heap_find(names[i]);
		if (!heap)
			continue;
		buf = dma_heap_buffer_alloc(heap, len, O_RDWR | O_CLOEXEC, 0);
		dma_heap_put(heap);
		if (!IS_ERR(buf))
			return buf;
	}
	return buf;
}

/* ion_alloc - documented in include/linux/ion.h */
struct dma_buf *ion_alloc(size_t len, unsigned int heap_id_mask,
			  unsigned int flags)
{
	struct dma_buf *buf = ERR_PTR(-ENODEV);
	char used[IONC_NAME_MAX] = "none";
	unsigned int i;

	if (!len)
		return ERR_PTR(-EINVAL);
	len = PAGE_ALIGN(len);
	if (!len)
		return ERR_PTR(-EINVAL);

	/*
	 * As in 5.4: every enabled heap whose bit is in the mask, highest
	 * id first, until one succeeds. The last error is the result;
	 * -ENODEV when the mask names no enabled heap.
	 */
	for (i = 0; i < ARRAY_SIZE(ionc_heaps); i++) {
		const struct ionc_heap *h = &ionc_heaps[i];

		if (!ionc_heap_enabled(h) || !(heap_id_mask & BIT(h->id)))
			continue;
		buf = ionc_heap_alloc(h, len, flags, used);
		if (!IS_ERR(buf))
			return buf;
	}

	pr_warn_ratelimited("%s[%d]: %zu bytes, mask 0x%x flags 0x%x failed: %ld (last heap tried: %s)\n",
			    current->comm, task_tgid_nr(current), len,
			    heap_id_mask, flags, PTR_ERR(buf), used);
	return buf;
}
EXPORT_SYMBOL_GPL(ion_alloc);

size_t ion_query_heaps_kernel(struct ion_heap_data *hdata, size_t size)
{
	size_t n = 0;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ionc_heaps); i++) {
		const struct ionc_heap *h = &ionc_heaps[i];

		if (!ionc_heap_enabled(h))
			continue;
		if (size) {
			if (n >= size)
				break;
			memset(&hdata[n], 0, sizeof(*hdata));
			strscpy(hdata[n].name, h->name, sizeof(hdata[n].name));
			hdata[n].type = h->type;
			hdata[n].heap_id = h->id;
		}
		n++;
	}
	return n;
}
EXPORT_SYMBOL_GPL(ion_query_heaps_kernel);

bool msm_ion_heap_is_secure(int heap_id)
{
	const struct ionc_heap *h = ionc_heap_by_mask(heap_id);

	return h && (h->type == ION_HEAP_TYPE_SECURE_CARVEOUT ||
		     h->type == ION_HEAP_TYPE_SYSTEM_SECURE ||
		     h->type == ION_HEAP_TYPE_HYP_CMA);
}
EXPORT_SYMBOL_GPL(msm_ion_heap_is_secure);

int get_ion_flags(u32 vmid)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ionc_cp); i++)
		if (ionc_cp[i].vmid == vmid)
			return ionc_cp[i].flag;
	return -EINVAL;
}
EXPORT_SYMBOL_GPL(get_ion_flags);

int ion_populate_vm_list(unsigned long flags, unsigned int *vm_list,
			 int nelems)
{
	unsigned int bit, i;

	flags &= ION_FLAGS_CP_MASK;
	if (!flags)
		return -EINVAL;

	for_each_set_bit(bit, &flags, BITS_PER_LONG) {
		for (i = 0; i < ARRAY_SIZE(ionc_cp); i++)
			if (ionc_cp[i].flag == BIT(bit))
				break;
		if (i == ARRAY_SIZE(ionc_cp) || !nelems)
			return -EINVAL;
		vm_list[--nelems] = ionc_cp[i].vmid;
	}
	return 0;
}
EXPORT_SYMBOL_GPL(ion_populate_vm_list);

int msm_ion_heap_prefetch(int heap_id, struct ion_prefetch_region *regions,
			  int nr_regions)
{
	return ionc_heap_by_mask(heap_id) ? -ENOTSUPP : -EINVAL;
}
EXPORT_SYMBOL_GPL(msm_ion_heap_prefetch);

int msm_ion_heap_drain(int heap_id, struct ion_prefetch_region *regions,
		       int nr_regions)
{
	return ionc_heap_by_mask(heap_id) ? -ENOTSUPP : -EINVAL;
}
EXPORT_SYMBOL_GPL(msm_ion_heap_drain);

struct device *msm_ion_heap_device_by_id(int heap_id)
{
	return ERR_PTR(ionc_heap_by_mask(heap_id) ? -ENODEV : -EINVAL);
}
EXPORT_SYMBOL_GPL(msm_ion_heap_device_by_id);

/* ---- /dev/ion ---- */

union ionc_ioctl_arg {
	struct ion_allocation_data allocation;
	struct ion_heap_query query;
	u32 ion_abi_version;
};

static int ionc_query_heaps(struct ion_heap_query *query)
{
	struct ion_heap_data __user *buffer = u64_to_user_ptr(query->heaps);
	struct ion_heap_data hdata;
	unsigned int i, cnt = 0;

	if (!buffer) {
		query->cnt = ion_query_heaps_kernel(NULL, 0);
		return 0;
	}
	if (!query->cnt)
		return -EINVAL;

	for (i = 0; i < ARRAY_SIZE(ionc_heaps) && cnt < query->cnt; i++) {
		const struct ionc_heap *h = &ionc_heaps[i];

		if (!ionc_heap_enabled(h))
			continue;
		memset(&hdata, 0, sizeof(hdata));
		strscpy(hdata.name, h->name, sizeof(hdata.name));
		hdata.type = h->type;
		hdata.heap_id = h->id;
		if (copy_to_user(&buffer[cnt], &hdata, sizeof(hdata)))
			return -EFAULT;
		cnt++;
	}
	query->cnt = cnt;
	return 0;
}

/*
 * Same order of checks as ion_ioctl() of the 5.4 kernel, so that probing
 * userspace sees the same errno: size check, copy in, validate, dispatch.
 * 32-bit callers use the same structures (no pointers or longs in them;
 * __u64 is 8-byte aligned in the arm EABI too), so 5.4 pointed .compat_ioctl
 * at the same function and so does this.
 */
static long ionc_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	void __user *uarg = (void __user *)arg;
	union ionc_ioctl_arg data;
	struct dma_buf *dmabuf = NULL;
	int fd = -1;
	int ret = 0;

	if (_IOC_SIZE(cmd) > sizeof(data))
		return -EINVAL;

	if (copy_from_user(&data, uarg, _IOC_SIZE(cmd)))
		return -EFAULT;

	if (cmd == ION_IOC_HEAP_QUERY &&
	    (data.query.reserved0 || data.query.reserved1 || data.query.reserved2))
		return -EINVAL;

	if (!(_IOC_DIR(cmd) & _IOC_WRITE))
		memset(&data, 0, sizeof(data));

	switch (cmd) {
	case ION_IOC_ALLOC:
		dmabuf = ion_alloc(data.allocation.len,
				   data.allocation.heap_id_mask,
				   data.allocation.flags);
		if (IS_ERR(dmabuf))
			return PTR_ERR(dmabuf);
		fd = get_unused_fd_flags(O_CLOEXEC);
		if (fd < 0) {
			dma_buf_put(dmabuf);
			return fd;
		}
		data.allocation.fd = fd;
		break;
	case ION_IOC_HEAP_QUERY:
		ret = ionc_query_heaps(&data.query);
		break;
	case ION_IOC_ABI_VERSION:
		data.ion_abi_version = IONC_ABI_VERSION;
		break;
	case ION_IOC_PREFETCH:
	case ION_IOC_DRAIN:
		/*
		 * In the 5.4 UAPI header (msm_ion.h), but the 5.4 kernel has
		 * no handler for them: /dev/ion answers -ENOTTY there, and
		 * the same here. In 5.4 only the video driver prefetches,
		 * through msm_ion_heap_prefetch() in the kernel.
		 */
		pr_debug("%s: ION_IOC_%s is not implemented by the 5.4 kernel either\n",
			 current->comm, cmd == ION_IOC_PREFETCH ? "PREFETCH" : "DRAIN");
		return -ENOTTY;
	default:
		return -ENOTTY;
	}

	if (_IOC_DIR(cmd) & _IOC_READ) {
		if (copy_to_user(uarg, &data, _IOC_SIZE(cmd))) {
			/* unlike 5.4, do not leave an fd behind that nobody knows */
			if (dmabuf) {
				put_unused_fd(fd);
				dma_buf_put(dmabuf);
			}
			return -EFAULT;
		}
	}
	if (dmabuf)
		fd_install(fd, dmabuf->file);
	return ret;
}

static const struct file_operations ionc_fops = {
	.owner		= THIS_MODULE,
	.unlocked_ioctl	= ionc_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
};

static struct miscdevice ionc_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "ion",
	.fops	= &ionc_fops,
	/* 5.4 node: 0664 system:system, set by the vendor ueventd.rc */
	.mode	= 0664,
};

/* ---- debugfs: ioncompat/heaps, the table and what is behind it now ---- */

static void ionc_show_backing(struct seq_file *s, const char *name)
{
	struct dma_heap *heap = dma_heap_find(name);

	seq_printf(s, " %s[%s]", name, heap ? "ok" : "MISSING");
	if (heap)
		dma_heap_put(heap);
}

static int ionc_heaps_show(struct seq_file *s, void *unused)
{
	static const char * const kinds[] = {
		[IONC_UNMAPPED] = "unmapped", [IONC_SYSTEM] = "system",
		[IONC_CONTIG] = "contig", [IONC_SECURE] = "secure",
	};
	char name[IONC_NAME_MAX];
	unsigned int i, j;

	seq_puts(s, "id name            type kind     on  backing DMA-BUF heaps\n");
	for (i = 0; i < ARRAY_SIZE(ionc_heaps); i++) {
		const struct ionc_heap *h = &ionc_heaps[i];

		seq_printf(s, "%2u %-15s %4u %-8s %-3s", h->id, h->name, h->type,
			   kinds[h->kind], ionc_heap_enabled(h) ? "yes" : "no");
		switch (h->kind) {
		case IONC_SYSTEM:
			ionc_show_backing(s, h->backing);
			ionc_show_backing(s, h->backing2);
			break;
		case IONC_CONTIG:
			ionc_show_backing(s, h->backing);
			if (h->backing2)
				ionc_show_backing(s, h->backing2);
			else if (h->cma_fallback && cma_fallback)
				ionc_show_backing(s, IONC_DEFAULT_CMA);
			break;
		case IONC_SECURE:
			for (j = 0; j < ARRAY_SIZE(ionc_cp); j++) {
				if (!(h->cp_allowed & ionc_cp[j].flag) ||
				    ionc_secure_name(name, h->backing, ionc_cp[j].flag))
					continue;
				ionc_show_backing(s, name);
			}
			break;
		case IONC_UNMAPPED:
			break;
		}
		seq_putc(s, '\n');
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(ionc_heaps);

static struct dentry *ionc_debugfs;

static int __init ionc_init(void)
{
	int ret;

	/* the 5.4 ABI, for arm64 and for 32-bit arm callers alike */
	BUILD_BUG_ON(sizeof(struct ion_allocation_data) != 24);
	BUILD_BUG_ON(sizeof(struct ion_heap_data) != 52);
	BUILD_BUG_ON(sizeof(struct ion_heap_query) != 24);
	BUILD_BUG_ON(sizeof(struct ion_prefetch_data) != 24);
	BUILD_BUG_ON(ION_IOC_ALLOC != 0xc0184900);
	BUILD_BUG_ON(ION_IOC_HEAP_QUERY != 0xc0184908);
	BUILD_BUG_ON(ION_IOC_ABI_VERSION != 0x80044909);
	BUILD_BUG_ON(ION_IOC_PREFETCH != 0xc0184d03);
	BUILD_BUG_ON(ION_IOC_DRAIN != 0xc0184d04);
	BUILD_BUG_ON(sizeof(union ionc_ioctl_arg) != 24);

	ret = misc_register(&ionc_misc);
	if (ret)
		return ret;

	ionc_debugfs = debugfs_create_dir("ioncompat", NULL);
	debugfs_create_file("heaps", 0444, ionc_debugfs, NULL, &ionc_heaps_fops);
	return 0;
}
module_init(ionc_init);

static void __exit ionc_exit(void)
{
	debugfs_remove_recursive(ionc_debugfs);
	misc_deregister(&ionc_misc);
}
module_exit(ionc_exit);

MODULE_IMPORT_NS("DMA_BUF");
MODULE_DESCRIPTION("5.4 msm ION ABI (/dev/ion, ion_alloc) on DMA-BUF heaps");
MODULE_LICENSE("GPL");
