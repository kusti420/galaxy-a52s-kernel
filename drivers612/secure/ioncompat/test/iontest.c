// SPDX-License-Identifier: GPL-2.0-only
/*
 * iontest - talks to /dev/ion the way a 5.4 vendor blob does: raw ioctls,
 * the structures and numbers of the 5.4 UAPI (ion_abi.h), hard-coded msm
 * heap id masks and flags. Checks the answers against what the A52s 5.4
 * kernel gives. Static, no libc needed (kernel nolibc), one binary for
 * arm64 and one for 32-bit arm (the compat path).
 *
 * Run on the device as root or system: ./iontest [-v] [-s]
 * Exit status 0: no check failed. "SKIP" lines are allocations whose
 * backing DMA-BUF heap is not there (-ENODEV); they do not fail the run,
 * unless -s (strict: the Qualcomm 6.12 BSP with qcom_dma_heaps + mem_buf,
 * where every secure case has a backing heap) is given.
 *
 * Secure cases (6.12 BSP): the buffer must come back as an fd, mmap of it
 * must be refused (the memory belongs to another VM), and closing it must
 * give the memory back (checked by allocating the same heap many times).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "ion_abi.h"

/* linux/dma-buf.h */
struct t_dma_buf_sync {
	__u64 flags;
};
#define T_DMA_BUF_SYNC_RW	(3 << 0)
#define T_DMA_BUF_SYNC_START	(0 << 2)
#define T_DMA_BUF_SYNC_END	(1 << 2)
#define T_DMA_BUF_IOCTL_SYNC	_IOW('b', 0, struct t_dma_buf_sync)

#define SZ_4K	0x1000UL
#define SZ_1M	0x100000UL

static int ion_fd;
static int failed, passed, skipped;

static void result(int ok, const char *what)
{
	if (ok)
		passed++;
	else
		failed++;
	printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
}

/* ioctl that must fail with one errno */
static void expect_errno(unsigned int cmd, void *arg, int want, const char *what)
{
	int ret = ioctl(ion_fd, cmd, arg);
	int err = errno;

	if (ret >= 0 || err != want)
		printf("      got ret %d errno %d, want errno %d\n", ret, err, want);
	result(ret < 0 && err == want, what);
}

static int ion_alloc_raw(unsigned long len, __u32 mask, __u32 flags, int *fd)
{
	struct t_ion_allocation_data d;

	memset(&d, 0, sizeof(d));
	d.len = len;
	d.heap_id_mask = mask;
	d.flags = flags;
	d.fd = 0xdeadbeef;
	if (ioctl(ion_fd, T_ION_IOC_ALLOC, &d) < 0)
		return -errno;
	*fd = (int)d.fd;
	return 0;
}

static void expect_alloc_errno(unsigned long len, __u32 mask, __u32 flags,
			       int want, const char *what)
{
	int fd = -1;
	int ret = ion_alloc_raw(len, mask, flags, &fd);

	if (!ret)
		close(fd);
	if (ret != -want)
		printf("      got %d, want %d\n", ret, -want);
	result(ret == -want, what);
}

/* map, write, sync, read back, unmap */
static int touch_buffer(int fd, unsigned long len)
{
	struct t_dma_buf_sync sync;
	unsigned char *p;
	unsigned long i;
	int bad = 0;

	p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		printf("      mmap: errno %d\n", errno);
		return -1;
	}
	sync.flags = T_DMA_BUF_SYNC_START | T_DMA_BUF_SYNC_RW;
	if (ioctl(fd, T_DMA_BUF_IOCTL_SYNC, &sync) < 0) {
		printf("      DMA_BUF_IOCTL_SYNC start: errno %d\n", errno);
		bad = 1;
	}
	/* a fresh buffer must not carry old data */
	for (i = 0; i < len; i += 61)
		if (p[i]) {
			printf("      not zeroed at offset %lu\n", i);
			bad = 1;
			break;
		}
	for (i = 0; i < len; i += SZ_4K)
		p[i] = (unsigned char)(i >> 12) ^ 0x5a;
	p[len - 1] = 0xa5;
	for (i = 0; i < len; i += SZ_4K)
		if (p[i] != (unsigned char)((unsigned char)(i >> 12) ^ 0x5a)) {
			printf("      read back differs at offset %lu\n", i);
			bad = 1;
			break;
		}
	if (p[len - 1] != 0xa5)
		bad = 1;
	sync.flags = T_DMA_BUF_SYNC_END | T_DMA_BUF_SYNC_RW;
	if (ioctl(fd, T_DMA_BUF_IOCTL_SYNC, &sync) < 0) {
		printf("      DMA_BUF_IOCTL_SYNC end: errno %d\n", errno);
		bad = 1;
	}
	munmap(p, len);
	return bad ? -1 : 0;
}

/*
 * An allocation that 5.4 serves. must_work: the backing heap is in the
 * kernel today, so -ENODEV is a failure; otherwise -ENODEV is a SKIP.
 * map: non-secure memory, so map and touch it.
 */
static void expect_alloc(unsigned long len, __u32 mask, __u32 flags,
			 int must_work, int map, const char *what)
{
	int fd = -1;
	int ret = ion_alloc_raw(len, mask, flags, &fd);
	int ok;

	if (ret == -ENODEV && !must_work) {
		skipped++;
		printf("SKIP  %s (backing heap missing)\n", what);
		return;
	}
	if (ret) {
		printf("      mask 0x%x flags 0x%x len %lu: %d\n", mask, flags, len, ret);
		result(0, what);
		return;
	}
	ok = fd > 2;
	if (ok && map)
		ok = !touch_buffer(fd, len);
	close(fd);
	result(ok, what);
}

static int strict;

/*
 * A secure allocation: fd comes back, the CPU cannot map it. count > 1
 * repeats alloc + close to see that the memory returns (hyp-assign back to
 * HLOS on release); a leak shows as -ENOMEM on the small CMA heaps or as a
 * steadily falling MemFree with the system heap.
 */
static void expect_secure(unsigned long len, __u32 mask, __u32 flags,
			  int count, const char *what)
{
	int fd = -1, ret, i, ok = 1;
	void *p;

	for (i = 0; i < count && ok; i++) {
		ret = ion_alloc_raw(len, mask, flags, &fd);
		if (ret == -ENODEV && !strict) {
			skipped++;
			printf("SKIP  %s (backing heap missing)\n", what);
			return;
		}
		if (ret) {
			printf("      mask 0x%x flags 0x%x len %lu round %d: %d\n",
			       mask, flags, len, i, ret);
			result(0, what);
			return;
		}
		ok = fd > 2;
		p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (p != MAP_FAILED) {
			/* do NOT touch it: an access to lent memory is a stage 2 fault */
			printf("      mmap of a secure buffer succeeded\n");
			munmap(p, len);
			ok = 0;
		}
		p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
		if (p != MAP_FAILED) {
			printf("      read-only mmap of a secure buffer succeeded\n");
			munmap(p, len);
			ok = 0;
		}
		close(fd);
	}
	result(ok, what);
}

/* the heaps the A52s 5.4 kernel reports, in its order (highest id first) */
static const struct {
	const char *name;
	__u32 type;
	__u32 id;
} a52sxq_heaps[] = {
	{ "system",		T_ION_HEAP_TYPE_MSM_SYSTEM,	25 },
	{ "secure_display",	T_ION_HEAP_TYPE_HYP_CMA,	11 },
	{ "secure_heap",	T_ION_HEAP_TYPE_SYSTEM_SECURE,	10 },
	{ "qsecom",		T_ION_HEAP_TYPE_DMA,		7 },
	{ "user_contig",	T_ION_HEAP_TYPE_DMA,		6 },
	{ "audio_ml",		T_ION_HEAP_TYPE_DMA,		5 },
	{ "qsecom_ta",		T_ION_HEAP_TYPE_DMA,		1 },
};
#define N_A52SXQ_HEAPS	(sizeof(a52sxq_heaps) / sizeof(a52sxq_heaps[0]))

static void test_query(int verbose)
{
	struct t_ion_heap_data heaps[32];
	struct t_ion_heap_query q;
	unsigned int i;
	int ok;

	/* libion: first the count (heaps == NULL), then the list */
	memset(&q, 0, sizeof(q));
	ok = !ioctl(ion_fd, T_ION_IOC_HEAP_QUERY, &q) && q.cnt == N_A52SXQ_HEAPS;
	if (!ok)
		printf("      cnt %u, want %u (errno %d)\n", q.cnt,
		       (unsigned int)N_A52SXQ_HEAPS, errno);
	result(ok, "HEAP_QUERY count");

	memset(&q, 0, sizeof(q));
	memset(heaps, 0xff, sizeof(heaps));
	q.cnt = 32;
	q.heaps = (__u64)(unsigned long)heaps;
	ok = !ioctl(ion_fd, T_ION_IOC_HEAP_QUERY, &q) && q.cnt == N_A52SXQ_HEAPS;
	for (i = 0; ok && i < N_A52SXQ_HEAPS; i++) {
		if (verbose)
			printf("      %2u %-16s type %u\n", heaps[i].heap_id,
			       heaps[i].name, heaps[i].type);
		ok = !strcmp(heaps[i].name, a52sxq_heaps[i].name) &&
		     heaps[i].type == a52sxq_heaps[i].type &&
		     heaps[i].heap_id == a52sxq_heaps[i].id &&
		     !heaps[i].reserved0 && !heaps[i].reserved1 && !heaps[i].reserved2;
		if (!ok)
			printf("      entry %u: %s type %u id %u\n", i,
			       heaps[i].name, heaps[i].type, heaps[i].heap_id);
	}
	result(ok, "HEAP_QUERY list is the A52s 5.4 list");

	/* a short buffer gets the first entries only */
	memset(&q, 0, sizeof(q));
	q.cnt = 2;
	q.heaps = (__u64)(unsigned long)heaps;
	ok = !ioctl(ion_fd, T_ION_IOC_HEAP_QUERY, &q) && q.cnt == 2;
	result(ok, "HEAP_QUERY truncates to cnt");

	memset(&q, 0, sizeof(q));
	q.heaps = (__u64)(unsigned long)heaps;
	expect_errno(T_ION_IOC_HEAP_QUERY, &q, EINVAL, "HEAP_QUERY with buffer and cnt 0: EINVAL");

	memset(&q, 0, sizeof(q));
	q.reserved1 = 1;
	expect_errno(T_ION_IOC_HEAP_QUERY, &q, EINVAL, "HEAP_QUERY with reserved set: EINVAL");
}

int main(int argc, char **argv)
{
	int verbose = 0;
	struct t_ion_prefetch_data prefetch;
	struct t_ion_handle_data handle;
	char big[64];
	__u32 version = 0xffffffff;
	int ok, i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!strcmp(argv[i], "-s"))
			strict = 1;
	}

	printf("iontest: %u-bit caller\n", (unsigned int)(sizeof(void *) * 8));

	ion_fd = open("/dev/ion", O_RDONLY | O_CLOEXEC);
	if (ion_fd < 0) {
		printf("FAIL  open /dev/ion: errno %d\n", errno);
		return 2;
	}

	ok = !ioctl(ion_fd, T_ION_IOC_ABI_VERSION, &version) && version == 2;
	if (!ok)
		printf("      version %u (errno %d)\n", version, errno);
	result(ok, "ABI_VERSION is 2");

	handle.handle = 0;
	expect_errno(T_ION_IOC_FREE, &handle, ENOTTY,
		     "legacy ION_IOC_FREE probe: ENOTTY (libion: not legacy ION)");
	memset(&prefetch, 0, sizeof(prefetch));
	prefetch.heap_id = T_ION_SECURE_HEAP_ID;
	expect_errno(T_ION_IOC_PREFETCH, &prefetch, ENOTTY, "PREFETCH: ENOTTY, as on 5.4");
	expect_errno(T_ION_IOC_DRAIN, &prefetch, ENOTTY, "DRAIN: ENOTTY, as on 5.4");
	memset(big, 0, sizeof(big));
	expect_errno(_IOC(_IOC_READ | _IOC_WRITE, 'I', 0, sizeof(big)), big, EINVAL,
		     "ioctl larger than the argument union: EINVAL");
	expect_errno(T_ION_IOC_ALLOC, (void *)1, EFAULT, "ALLOC with a bad pointer: EFAULT");

	test_query(verbose);

	/* what must work with the upstream system and CMA heaps */
	expect_alloc(SZ_1M, T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_CACHED, 1, 1,
		     "system, cached, 1 MiB");
	expect_alloc(SZ_1M, T_ION_SYSTEM_HEAP_ID, 0, 1, 1,
		     "system, uncached, 1 MiB");
	expect_alloc(5000, T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_CACHED, 1, 0,
		     "system, 5000 bytes (rounded up to pages)");
	expect_alloc(SZ_1M, 0xffffffffU, T_ION_FLAG_CACHED, 1, 1,
		     "mask ~0 (Codec2 'any heap'): system memory");
	expect_alloc(SZ_1M, T_ION_SYSTEM_HEAP_ID | T_ION_CAMERA_HEAP_ID, 0, 1, 1,
		     "system | camera (CamX): system memory");
	expect_alloc(SZ_1M, T_ION_ADSP_HEAP_ID | T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_CACHED, 1, 1,
		     "adsp | system (adsprpc): system memory");
	expect_alloc(64 * SZ_4K, T_ION_QSECOM_HEAP_ID, 0, 1, 1,
		     "qsecom (libQSEEComAPI), 256 KiB contiguous");
	expect_alloc(SZ_1M, T_ION_QSECOM_TA_HEAP_ID, 0, 1, 1,
		     "qsecom_ta (TA image load), 1 MiB contiguous");
	expect_alloc(SZ_1M, T_ION_USER_CONTIG_HEAP_ID, 0, 1, 1,
		     "user_contig, 1 MiB contiguous");
	expect_alloc(SZ_1M, T_ION_AUDIO_ML_HEAP_ID, 0, 1, 1,
		     "audio_ml, 1 MiB contiguous");

	/* the sizes real users need from the contiguous regions */
	expect_alloc(8 * SZ_1M, T_ION_QSECOM_HEAP_ID, 0, 1, 1,
		     "qsecom, 8 MiB contiguous (Widevine/KeyMint shared buffers)");
	expect_alloc(8 * SZ_1M, T_ION_QSECOM_TA_HEAP_ID, 0, 1, 1,
		     "qsecom_ta, 8 MiB contiguous (large TA image)");
	expect_alloc(SZ_4K, T_ION_QSECOM_HEAP_ID, T_ION_FLAG_CACHED, 1, 1,
		     "qsecom, one page, cached flag");

	/*
	 * Secure memory. 6.12 BSP: pixel and non-pixel from Qualcomm's
	 * pre-assigned pools, the rest allocated and lent (README.md).
	 */
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_PIXEL, 1,
		      "secure_heap, CP_PIXEL (secure video output)");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_NON_PIXEL, 1,
		      "secure_heap, CP_NON_PIXEL");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_BITSTREAM, 1,
		      "secure_heap, CP_BITSTREAM (vidc secure bitstream)");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_CAMERA, 1,
		      "secure_heap, CP_CAMERA");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_TOUCH, 1,
		      "secure_heap, CP_TOUCH");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID, T_ION_FLAG_CP_PIXEL, 1,
		      "secure_heap, CP_PIXEL without ION_FLAG_SECURE");
	expect_secure(SZ_1M, T_ION_SECURE_HEAP_ID | T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_BITSTREAM, 1,
		      "mask 0xc00, CP_BITSTREAM (Codec2 secure input)");
	expect_secure(SZ_1M, T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_SEC_DISPLAY, 1,
		      "secure_display, CP_SEC_DISPLAY (secure UI)");
	expect_secure(SZ_1M, T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_CAMERA, 1,
		      "secure_display, CP_CAMERA (secure camera)");
	expect_secure(SZ_1M, T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_CAMERA | T_ION_FLAG_CP_CDSP, 1,
		      "secure_display, CP_CAMERA | CP_CDSP (two VMIDs)");
	expect_secure(SZ_1M, T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_CAMERA_PREVIEW, 1,
		      "secure_display, CP_CAMERA_PREVIEW");
	/* release gives the memory back: 64 x 16 MiB out of a 140 MiB region */
	expect_secure(16 * SZ_1M, T_ION_SECURE_DISPLAY_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_SEC_DISPLAY, 64,
		      "secure_display, 64 x 16 MiB alloc/free (reclaim on release)");
	expect_secure(4 * SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_BITSTREAM, 64,
		      "secure_heap CP_BITSTREAM, 64 x 4 MiB alloc/free");
	expect_secure(4 * SZ_1M, T_ION_SECURE_HEAP_ID,
		      T_ION_FLAG_SECURE | T_ION_FLAG_CP_PIXEL, 64,
		      "secure_heap CP_PIXEL, 64 x 4 MiB alloc/free");
	/* after all that, normal memory still works and is zeroed */
	expect_alloc(16 * SZ_1M, T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_CACHED, 1, 1,
		     "system, 16 MiB after the secure rounds (zeroed, writable)");

	/* what 5.4 refuses */
	expect_alloc_errno(0, T_ION_SYSTEM_HEAP_ID, 0, EINVAL, "len 0: EINVAL");
	expect_alloc_errno(SZ_4K, 0, 0, ENODEV, "empty mask: ENODEV");
	expect_alloc_errno(SZ_4K, 1, 0, ENODEV,
			   "generic system heap bit 0 (not an msm heap): ENODEV");
	expect_alloc_errno(SZ_4K, T_ION_AUDIO_HEAP_ID, 0, ENODEV,
			   "audio heap (not on the A52s): ENODEV");
	expect_alloc_errno(SZ_4K, T_ION_SECURE_CARVEOUT_HEAP_ID,
			   T_ION_FLAG_SECURE | T_ION_FLAG_CP_CDSP, ENODEV,
			   "secure_carveout (disabled in the A52s DT): ENODEV");
	expect_alloc_errno(SZ_4K, T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_SECURE, EINVAL,
			   "system with ION_FLAG_SECURE: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_SYSTEM_HEAP_ID, T_ION_FLAG_CP_PIXEL, EINVAL,
			   "system with a CP flag: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_SECURE_HEAP_ID, T_ION_FLAG_SECURE, EINVAL,
			   "secure_heap without a CP flag: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_SECURE_HEAP_ID,
			   T_ION_FLAG_SECURE | T_ION_FLAG_CP_PIXEL | T_ION_FLAG_CP_NON_PIXEL,
			   EINVAL, "secure_heap with two CP flags: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_SECURE_HEAP_ID,
			   T_ION_FLAG_SECURE | T_ION_FLAG_CP_SEC_DISPLAY, EINVAL,
			   "secure_heap with CP_SEC_DISPLAY: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_SECURE_DISPLAY_HEAP_ID, T_ION_FLAG_SECURE, EINVAL,
			   "secure_display without a CP flag: EINVAL");
	expect_alloc_errno(SZ_4K, T_ION_QSECOM_HEAP_ID, T_ION_FLAG_SECURE, ENOMEM,
			   "qsecom with ION_FLAG_SECURE: ENOMEM");

	close(ion_fd);
	printf("iontest: %d ok, %d failed, %d skipped\n", passed, failed, skipped);
	return failed ? 1 : 0;
}
