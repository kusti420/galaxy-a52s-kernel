// SPDX-License-Identifier: GPL-2.0-only
/*
 * kgsltest - talks to /dev/kgsl-3d0 the way the phone's closed 5.4-era libgsl does: raw ioctls
 * with the structures and numbers of the phone's own 5.4 msm_kgsl.h (uapi54/, verbatim copy).
 * Static, kernel nolibc, one binary for arm64 and one for 32-bit arm (compat path).
 *
 * What it proves on hardware, in order: device node + ioctl numbers, GMU/SQE/zap firmware load
 * and GPU power-up (first context), memory allocation + mmap, command submission and retire,
 * and the old-libgsl "list size passed as entry size" convention (patch 0003).
 * Run as root:  ./kgsltest64 ; ./kgsltest32     Exit status 0 = no check failed.
 */

/* libc: the kernel nolibc.h, force-included by the Makefile */
#define __user
#include <linux/msm_kgsl.h>

#define CP_NOP_HDR 0x70108000u	/* cp_type7_packet(CP_NOP, 0) */

static int fails;
#define CHECK(cond, ...) do { if (cond) { printf("ok    "); } else { printf("FAIL  "); fails++; } \
	printf(__VA_ARGS__); printf("\n"); } while (0)

static int submit(int fd, unsigned int ctx, unsigned int id, __u64 gpuaddr, unsigned int n,
		  unsigned int cmdsize, const char *what)
{
	struct kgsl_command_object obj[2];
	struct kgsl_gpu_command cmd;
	struct kgsl_device_waittimestamp_ctxtid w;
	int ret;

	memset(obj, 0, sizeof(obj));
	obj[0].gpuaddr = gpuaddr;      obj[0].size = 16; obj[0].flags = KGSL_CMDLIST_IB; obj[0].id = id;
	obj[1].gpuaddr = gpuaddr + 32; obj[1].size = 16; obj[1].flags = KGSL_CMDLIST_IB; obj[1].id = id;
	memset(&cmd, 0, sizeof(cmd));
	cmd.cmdlist = (__u64)(unsigned long)obj;
	cmd.cmdsize = cmdsize;
	cmd.numcmds = n;
	cmd.context_id = ctx;
	ret = ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &cmd);
	CHECK(ret == 0, "GPU_COMMAND %s: numcmds=%u cmdsize=%u -> ret=%d errno=%d ts=%u",
	      what, n, cmdsize, ret, ret ? errno : 0, cmd.timestamp);
	if (ret)
		return ret;
	w.context_id = ctx; w.timestamp = cmd.timestamp; w.timeout = 3000;
	ret = ioctl(fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID, &w);
	CHECK(ret == 0, "  retired within 3 s (ret=%d errno=%d)", ret, ret ? errno : 0);
	return ret;
}

int main(void)
{
	struct kgsl_device_getproperty gp;
	struct kgsl_devinfo info;
	struct kgsl_version ver;
	struct kgsl_drawctxt_create cc;
	struct kgsl_drawctxt_destroy cd;
	struct kgsl_gpuobj_alloc ga;
	struct kgsl_gpuobj_info gi;
	struct kgsl_gpuobj_free gf;
	unsigned int *p;
	int fd, ret, i;

	fd = open("/dev/kgsl-3d0", O_RDWR);
	CHECK(fd >= 0, "open /dev/kgsl-3d0 (errno=%d)", fd < 0 ? errno : 0);
	if (fd < 0)
		return 1;

	memset(&ver, 0, sizeof(ver));
	gp.type = KGSL_PROP_VERSION; gp.value = &ver; gp.sizebytes = sizeof(ver);
	ret = ioctl(fd, IOCTL_KGSL_DEVICE_GETPROPERTY, &gp);
	CHECK(ret == 0 && ver.drv_major == 3 && ver.drv_minor == 14,
	      "PROP_VERSION drv %u.%u dev %u.%u (5.4 phone: drv 3.14)", ver.drv_major, ver.drv_minor,
	      ver.dev_major, ver.dev_minor);

	memset(&info, 0, sizeof(info));
	gp.type = KGSL_PROP_DEVICE_INFO; gp.value = &info; gp.sizebytes = sizeof(info);
	ret = ioctl(fd, IOCTL_KGSL_DEVICE_GETPROPERTY, &gp);
	CHECK(ret == 0 && (info.chip_id & 0xffffff00) == 0x06030500,
	      "PROP_DEVICE_INFO chip_id=0x%x gpu_id=%u mmu=%u gmem=0x%lx (want chip 0x060305xx)",
	      info.chip_id, info.gpu_id, info.mmu_enabled, (unsigned long)info.gmem_sizebytes);

	/* the flag set libgsl uses for a GL context; first context powers the GPU up:
	 * GMU + SQE firmware from /vendor/firmware, zap shader a660_zap.mdt */
	cc.flags = KGSL_CONTEXT_NO_GMEM_ALLOC | KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_PER_CONTEXT_TS |
		   KGSL_CONTEXT_TYPE_GL << KGSL_CONTEXT_TYPE_SHIFT;
	cc.drawctxt_id = 0;
	ret = ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &cc);
	CHECK(ret == 0, "DRAWCTXT_CREATE flags=0x%x -> id=%u (errno=%d)", cc.flags, cc.drawctxt_id,
	      ret ? errno : 0);
	if (ret)
		return 1;

	memset(&ga, 0, sizeof(ga));
	ga.size = 4096;
	ga.flags = (__u64)KGSL_MEMTYPE_COMMAND << KGSL_MEMTYPE_SHIFT;
	ret = ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ga);
	CHECK(ret == 0, "GPUOBJ_ALLOC 4096 -> id=%u mmapsize=%lu (errno=%d)", ga.id,
	      (unsigned long)ga.mmapsize, ret ? errno : 0);
	if (ret)
		return 1;
	memset(&gi, 0, sizeof(gi));
	gi.id = ga.id;
	ret = ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &gi);
	CHECK(ret == 0 && gi.gpuaddr, "GPUOBJ_INFO gpuaddr hi=0x%lx lo=0x%lx size=%lu",
	      (unsigned long)(gi.gpuaddr >> 32), (unsigned long)(gi.gpuaddr & 0xffffffff),
	      (unsigned long)gi.size);

	p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)ga.id << 12);
	CHECK(p != MAP_FAILED, "mmap of the object (errno=%d)", p == MAP_FAILED ? errno : 0);
	if (p == MAP_FAILED)
		return 1;
	for (i = 0; i < 64; i++)
		p[i] = CP_NOP_HDR;

	submit(fd, cc.drawctxt_id, ga.id, gi.gpuaddr, 1, sizeof(struct kgsl_command_object),
	       "one IB, entry size");
	submit(fd, cc.drawctxt_id, ga.id, gi.gpuaddr, 2, sizeof(struct kgsl_command_object),
	       "two IBs, entry size");
	/* old libgsl convention (redwood-6.12 finding): cmdsize = size of the whole list.
	 * 5.4 accepts it; unpatched 6.12 kgsl returns EFAULT here. */
	submit(fd, cc.drawctxt_id, ga.id, gi.gpuaddr, 2, 2 * sizeof(struct kgsl_command_object),
	       "two IBs, LIST size as cmdsize (old libgsl)");

	munmap(p, 4096);
	memset(&gf, 0, sizeof(gf));
	gf.id = ga.id;
	ret = ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &gf);
	CHECK(ret == 0, "GPUOBJ_FREE (errno=%d)", ret ? errno : 0);
	cd.drawctxt_id = cc.drawctxt_id;
	ret = ioctl(fd, IOCTL_KGSL_DRAWCTXT_DESTROY, &cd);
	CHECK(ret == 0, "DRAWCTXT_DESTROY (errno=%d)", ret ? errno : 0);
	close(fd);
	printf("kgsltest: %d failed\n", fails);
	return fails ? 1 : 0;
}
