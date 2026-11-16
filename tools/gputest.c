/* gputest [drm node]: minimal Adreno submit test for upstream drm/msm, no Mesa. Opens the node
 * (default /dev/dri/renderD128; the first open makes msm load the SQE/GMU firmware, boot the GMU
 * and load the zap shader), prints GPU_ID / CHIP_ID / GMEM / MAX_FREQ / rings / VA range and two
 * always-on TIMESTAMP reads, then runs one real submit: a 4 KiB command buffer with
 * CP_NOP + CP_MEM_WRITE(result BO, 0xcafe0000 | n) + CP_NOP, waits for the fence and checks that
 * the GPU wrote the value (CHIP_ID bits 32..39 = the fused speed bin). Repeats the submit COUNT times (argv[2], default 3).
 * `gputest <node> 0 hang`: instead submits ONE IB that never finishes (CP_WAIT_REG_MEM on a
 * memory word that stays 0) and waits up to 20 s for drm/msm's hangcheck to recover the GPU and
 * retire the fence; exit 0 = recovered (run a normal gputest afterwards: the GPU must work again).
 * Exit 0 = every submit retired and wrote its value; 1 open, 2 param, 3 BO, 4 submit, 5 fence,
 * 6 wrong value. Static, no libc. Build (headers from `make headers_install`):
 *   clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector \
 *     -fuse-ld=lld -I out-ml/hdr/include -o tools/gputest tools/gputest.c */
#include <drm/msm_drm.h>

static long sc6(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e, x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}
#define sc(n, a, b, c) sc6(n, (long)(a), (long)(b), (long)(c), 0, 0, 0)
static void out(const char *s) { long n = 0; while (s[n]) n++; sc(64, 1, s, n); }
static void num(long v) { char b[24]; int i = 23; b[i] = 0; int neg = v < 0; unsigned long u = neg ? -v : v; do { b[--i] = '0' + u % 10; u /= 10; } while (u); if (neg) b[--i] = '-'; out(b + i); }
static void hex(unsigned long v) { char b[20]; int i = 19; b[i] = 0; do { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v); b[--i] = 'x'; b[--i] = '0'; out(b + i); }
static void die(int code, const char *what, long err) { out("gputest: FAIL "); out(what); out(" errno "); num(err); out("\n"); sc(93, code, 0, 0); for (;;); }
/* clang may lower loops / struct copies to memset/memcpy calls even when freestanding */
void *memset(void *p, int v, unsigned long n) { volatile char *c = p; while (n--) *c++ = (char)v; return p; }
void *memcpy(void *d, const void *s, unsigned long n) { volatile char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
static void *zero(void *p, unsigned long n) { return memset(p, 0, n); }

static long fd;
static long ioc(unsigned long req, void *arg) { return sc(29, fd, req, arg); }

static unsigned parity(unsigned v) { /* adreno_pm4: odd parity bit of a 28-bit field */
	return (0x9669 >> (0xf & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1;
}
static unsigned pkt7(unsigned op, unsigned cnt) {
	return 0x70000000u | (cnt & 0x7fff) | (parity(cnt) << 15) | ((op & 0x7f) << 16) | (parity(op) << 23);
}
#define CP_NOP 0x10
#define CP_MEM_WRITE 0x3d
#define CP_WAIT_REG_MEM 0x3c

static unsigned long param(unsigned p, const char *name) {
	struct drm_msm_param a; zero(&a, sizeof(a));
	a.pipe = MSM_PIPE_3D0; a.param = p;
	long r = ioc(DRM_IOCTL_MSM_GET_PARAM, &a);
	if (r < 0) { out("gputest: GET_PARAM "); out(name); out(" errno "); num(r); out("\n"); return ~0UL; }
	out("gputest: "); out(name); out(" = "); hex(a.value); out(" ("); num(a.value); out(")\n");
	return a.value;
}
static unsigned bo_new(unsigned long size, unsigned flags) {
	struct drm_msm_gem_new a; zero(&a, sizeof(a)); a.size = size; a.flags = flags;
	long r = ioc(DRM_IOCTL_MSM_GEM_NEW, &a);
	if (r < 0) die(3, "GEM_NEW", r);
	return a.handle;
}
static unsigned long bo_info(unsigned h, unsigned what) {
	struct drm_msm_gem_info a; zero(&a, sizeof(a)); a.handle = h; a.info = what;
	long r = ioc(DRM_IOCTL_MSM_GEM_INFO, &a);
	if (r < 0) die(3, what == MSM_INFO_GET_IOVA ? "GEM_INFO GET_IOVA" : "GEM_INFO GET_OFFSET", r);
	return a.value;
}
static volatile unsigned *bo_map(unsigned h, unsigned long size) {
	long p = sc6(222, 0, size, 3 /* RW */, 1 /* MAP_SHARED */, fd, bo_info(h, MSM_INFO_GET_OFFSET));
	if (p < 0 && p > -4096) die(3, "mmap", p);
	return (volatile unsigned *)p;
}

void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	const char *node = sp[0] > 1 ? argv[1] : "/dev/dri/renderD128";
	long count = 3;
	if (sp[0] > 2) { count = 0; for (char *c = argv[2]; *c; c++) count = count * 10 + (*c - '0'); }
	fd = sc(56, -100, node, 2 /* O_RDWR */);
	if (fd < 0) die(1, "open", fd);
	out("gputest: opened "); out(node); out("\n");
	if (param(MSM_PARAM_GPU_ID, "GPU_ID") == ~0UL) die(2, "GPU_ID (no GPU loaded? see dmesg)", 0);
	param(MSM_PARAM_CHIP_ID, "CHIP_ID");
	param(MSM_PARAM_GMEM_SIZE, "GMEM_SIZE");
	param(MSM_PARAM_MAX_FREQ, "MAX_FREQ");
	param(MSM_PARAM_NR_RINGS, "NR_RINGS");
	param(MSM_PARAM_VA_START, "VA_START");
	param(MSM_PARAM_VA_SIZE, "VA_SIZE");
	param(MSM_PARAM_HIGHEST_BANK_BIT, "HIGHEST_BANK_BIT");
	param(MSM_PARAM_UBWC_SWIZZLE, "UBWC_SWIZZLE");
	unsigned long t0 = param(MSM_PARAM_TIMESTAMP, "TIMESTAMP");
	unsigned long t1 = param(MSM_PARAM_TIMESTAMP, "TIMESTAMP");
	out(t1 > t0 && t0 != ~0UL ? "gputest: always-on counter advances\n" : "gputest: always-on counter NOT advancing\n");

	unsigned cmd = bo_new(4096, MSM_BO_WC), res = bo_new(4096, MSM_BO_WC);
	unsigned long res_iova = bo_info(res, MSM_INFO_GET_IOVA);
	out("gputest: cmd iova "); hex(bo_info(cmd, MSM_INFO_GET_IOVA)); out(", result iova "); hex(res_iova); out("\n");
	volatile unsigned *c = bo_map(cmd, 4096), *r = bo_map(res, 4096);
	int bad = 0;
	if (sp[0] > 3 && argv[3][0] == 'h') { /* hang + recovery test */
		r[1] = 0;
		unsigned i = 0;
		c[i++] = pkt7(CP_WAIT_REG_MEM, 6);
		c[i++] = 3 /* WRITE_EQ */ | 1 << 4 /* POLL_MEMORY */;
		c[i++] = (unsigned)(res_iova + 4); c[i++] = (unsigned)((res_iova + 4) >> 32);
		c[i++] = 1 /* ref: never written */; c[i++] = 0xffffffffu /* mask */; c[i++] = 16 /* delay */;
		struct drm_msm_gem_submit_bo bos[2]; zero(bos, sizeof(bos));
		bos[0].flags = MSM_SUBMIT_BO_READ; bos[0].handle = cmd;
		bos[1].flags = MSM_SUBMIT_BO_READ; bos[1].handle = res;
		struct drm_msm_gem_submit_cmd cm; zero(&cm, sizeof(cm));
		cm.type = MSM_SUBMIT_CMD_BUF; cm.size = i * 4;
		struct drm_msm_gem_submit s; zero(&s, sizeof(s));
		s.flags = MSM_PIPE_3D0; s.nr_bos = 2; s.nr_cmds = 1; s.bos = (unsigned long)bos; s.cmds = (unsigned long)&cm;
		long e = ioc(DRM_IOCTL_MSM_GEM_SUBMIT, &s);
		if (e < 0) die(4, "GEM_SUBMIT (hang IB)", e);
		out("gputest: hang IB submitted, fence "); num(s.fence); out("; waiting for hangcheck recovery\n");
		struct { long sec, nsec; } now;
		sc(113, 1, &now, 0);
		struct drm_msm_wait_fence w; zero(&w, sizeof(w));
		w.fence = s.fence; w.timeout.tv_sec = now.sec + 20; w.timeout.tv_nsec = now.nsec;
		e = ioc(DRM_IOCTL_MSM_WAIT_FENCE, &w);
		if (e < 0) die(5, "WAIT_FENCE (no recovery in 20 s)", e);
		param(MSM_PARAM_FAULTS, "FAULTS");
		out("gputest: PASS hang IB retired by recovery\n");
		sc(93, 0, 0, 0);
	}
	for (long n = 1; n <= count; n++) {
		unsigned want = 0xcafe0000u | (unsigned)n;
		r[0] = 0xdeadbeefu;
		unsigned i = 0;
		c[i++] = pkt7(CP_NOP, 0);
		c[i++] = pkt7(CP_MEM_WRITE, 3);
		c[i++] = (unsigned)res_iova; c[i++] = (unsigned)(res_iova >> 32); c[i++] = want;
		c[i++] = pkt7(CP_NOP, 0);

		struct drm_msm_gem_submit_bo bos[2]; zero(bos, sizeof(bos));
		bos[0].flags = MSM_SUBMIT_BO_READ; bos[0].handle = cmd;
		bos[1].flags = MSM_SUBMIT_BO_WRITE; bos[1].handle = res;
		struct drm_msm_gem_submit_cmd cm; zero(&cm, sizeof(cm));
		cm.type = MSM_SUBMIT_CMD_BUF; cm.submit_idx = 0; cm.submit_offset = 0; cm.size = i * 4;
		struct drm_msm_gem_submit s; zero(&s, sizeof(s));
		s.flags = MSM_PIPE_3D0; s.nr_bos = 2; s.nr_cmds = 1; s.bos = (unsigned long)bos; s.cmds = (unsigned long)&cm;
		s.queueid = 0;
		long e = ioc(DRM_IOCTL_MSM_GEM_SUBMIT, &s);
		if (e < 0) die(4, "GEM_SUBMIT", e);

		struct { long sec, nsec; } now;
		sc(113, 1 /* CLOCK_MONOTONIC */, &now, 0);
		struct drm_msm_wait_fence w; zero(&w, sizeof(w));
		w.fence = s.fence; w.timeout.tv_sec = now.sec + 3; w.timeout.tv_nsec = now.nsec; w.queueid = 0;
		e = ioc(DRM_IOCTL_MSM_WAIT_FENCE, &w);
		if (e < 0) { out("gputest: fence "); num(s.fence); out(" did not retire in 3 s\n"); die(5, "WAIT_FENCE", e); }
		unsigned got = r[0];
		out("gputest: submit "); num(n); out(" fence "); num(s.fence); out(" retired, result "); hex(got);
		out(got == want ? " OK\n" : " WRONG\n");
		if (got != want) bad = 1;
	}
	param(MSM_PARAM_FAULTS, "FAULTS");
	out(bad ? "gputest: FAIL (GPU did not write the value)\n" : "gputest: PASS (CP executed the submitted IB)\n");
	sc(57, fd, 0, 0);
	sc(93, bad ? 6 : 0, 0, 0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
