/* vidcsec: kernel-level secure video session test for the msm_vidc port (drivers612/gpu-video), no
 * Android media stack needed (venus firmware vpu20_1v must be loadable: /vendor mounted).
 *
 *   vidcsec [dec] [h264|hevc|vp9] [secure|clear] [/dev/video32] [hold-ms]
 *       Opens the decoder node, sets V4L2_CID_MPEG_VIDC_VIDEO_SECURE=1 (unless "clear"), formats
 *       (bitstream 1280x720 in, NV12 UBWC out), REQBUFS (USERPTR) on both ports, STREAMON on both.
 *       The second STREAMON runs the driver's start_streaming(): firmware boot, session init/load
 *       resources, then msm_comm_set_scratch_buffers() + msm_comm_set_persist_buffers(), i.e. in
 *       secure mode msm_smem_alloc() from the dma heaps qcom,secure-bitstream (SCRATCH, PERSIST),
 *       qcom,secure-non-pixel (SCRATCH_1, PERSIST_1) and qcom,secure-pixel (SCRATCH_2), mapped into
 *       the secure context banks and handed to the firmware. No input buffer is ever queued. Holds
 *       (default 2000 ms), STREAMOFF both, REQBUFS 0, close (frees the internal buffers).
 *   vidcsec heap <heap-name> [bytes] [hold-ms]
 *       DMA_HEAP_IOCTL_ALLOC from /dev/dma_heap/<heap-name> (default 1 MiB), hold, close: the bare
 *       hyp_assign round trip of a secure heap, before any video session.
 *
 * Every step prints "vidcsec: <step> rc=<n>"; last line "RESULT vidcsec PASS|FAIL <detail>".
 * Exit 0 = PASS. A SoC reset shows as the tool never returning (run it LAST in a kexec rehearsal,
 * `sync` first). Driver errors: dmesg | grep -E "msm_vidc|secure|hyp_assign|smem".
 * Static, no libc. Build (headers of the 6.12 kernel + the port's control ids):
 *   clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld \
 *     -I ../../bsp612/out/gki/usr/include -o vidcsec vidcsec.c
 */
#include <linux/videodev2.h>
#include <linux/dma-heap.h>

/* drivers612/gpu-video/video/include/uapi/vidc/media/msm_vidc_utils.h */
#define V4L2_PIX_FMT_NV12_UBWC v4l2_fourcc('Q', '1', '2', '8')
#define V4L2_CID_MPEG_MSM_VIDC_BASE (V4L2_CTRL_CLASS_MPEG | 0x2000)
#define V4L2_CID_MPEG_VIDC_VIDEO_SECURE (V4L2_CID_MPEG_MSM_VIDC_BASE + 16)

static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
void *memset(void *d, int c, unsigned long n) { volatile char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sc(64, 1, (long)s, slen(s), 0); }
static void num(long v) { char b[24]; int i = 23; unsigned long u = v < 0 ? -v : v; b[i] = 0;
	do { b[--i] = '0' + u % 10; u /= 10; } while (u); if (v < 0) b[--i] = '-'; put(b + i); }
static int eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static long dec(const char *s) { long v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0'; return v; }
static void msleep(long ms) { long ts[2] = { ms / 1000, (ms % 1000) * 1000000L }; sc(101, (long)ts, 0, 0, 0); }
static int fails;
static long step(const char *what, long rc) { put("vidcsec: "); put(what); put(" rc="); num(rc); put("\n"); if (rc < 0) fails++; return rc; }
static void result(const char *d) { put("RESULT vidcsec "); put(fails ? "FAIL " : "PASS "); put(d); put("\n"); sc(93, fails ? 1 : 0, 0, 0, 0); }
static long xioctl(int fd, unsigned long req, void *arg) { return sc(29, fd, req, (long)arg, 0); }

static void heap(const char *name, long bytes, long hold) {
	char path[128] = "/dev/dma_heap/"; unsigned long n = slen(path), i;
	struct dma_heap_allocation_data a;
	long fd;
	for (i = 0; name[i] && n + i < sizeof(path) - 1; i++) path[n + i] = name[i];
	path[n + i] = 0;
	put("vidcsec: heap "); put(path); put(" bytes "); num(bytes); put("\n");
	fd = step("open heap", sc(56, -100, (long)path, 2 /* O_RDWR */ | 02000000, 0));
	if (fd < 0) result("heap node missing or not openable");
	memset(&a, 0, sizeof(a)); a.len = bytes; a.fd_flags = 2 | 02000000;
	if (step("DMA_HEAP_IOCTL_ALLOC", xioctl(fd, DMA_HEAP_IOCTL_ALLOC, &a)) < 0) result("allocation failed");
	put("vidcsec: dma-buf fd "); num(a.fd); put(", holding\n");
	msleep(hold);
	step("close dma-buf (free, hyp unassign)", sc(57, a.fd, 0, 0, 0));
	sc(57, fd, 0, 0, 0);
	msleep(300);
	result("heap alloc + free survived");
}

void _start_c(long *sp) {
	int argc = (int)sp[0], i, secure = 1, cap, out;
	char **argv = (char **)(sp + 1);
	const char *node = "/dev/video32";
	unsigned int codec = V4L2_PIX_FMT_H264;
	long fd, hold = 2000, on_in, on_out;
	struct v4l2_capability qc;
	struct v4l2_control ctl;
	struct v4l2_format f;
	struct v4l2_requestbuffers rb;

	if (argc > 1 && eq(argv[1], "heap")) {
		if (argc < 3) { put("usage: vidcsec heap <name> [bytes] [hold-ms]\n"); sc(93, 2, 0, 0, 0); }
		heap(argv[2], argc > 3 ? dec(argv[3]) : 1 << 20, argc > 4 ? dec(argv[4]) : 1000);
	}
	for (i = 1; i < argc; i++) {
		if (eq(argv[i], "dec")) ;
		else if (eq(argv[i], "h264") || eq(argv[i], "avc")) codec = V4L2_PIX_FMT_H264;
		else if (eq(argv[i], "hevc")) codec = V4L2_PIX_FMT_HEVC;
		else if (eq(argv[i], "vp9")) codec = V4L2_PIX_FMT_VP9;
		else if (eq(argv[i], "secure")) secure = 1;
		else if (eq(argv[i], "clear")) secure = 0;
		else if (argv[i][0] == '/') node = argv[i];
		else hold = dec(argv[i]);
	}
	put("vidcsec: node "); put(node); put(secure ? " SECURE" : " clear"); put(" hold "); num(hold); put(" ms\n");
	fd = step("open", sc(56, -100, (long)node, 2 | 02000000, 0));
	if (fd < 0) result("cannot open the decoder node");
	memset(&qc, 0, sizeof(qc));
	if (step("VIDIOC_QUERYCAP", xioctl(fd, VIDIOC_QUERYCAP, &qc)) == 0) { put("vidcsec: driver "); put((char *)qc.driver); put(" card "); put((char *)qc.card); put("\n"); }
	if (secure) { ctl.id = V4L2_CID_MPEG_VIDC_VIDEO_SECURE; ctl.value = 1;
		if (step("S_CTRL V4L2_CID_MPEG_VIDC_VIDEO_SECURE=1", xioctl(fd, VIDIOC_S_CTRL, &ctl)) < 0) result("secure control refused"); }
	/* bitstream port: V4L2 OUTPUT_MPLANE (the driver's INPUT_PORT) */
	memset(&f, 0, sizeof(f)); f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	f.fmt.pix_mp.width = 1280; f.fmt.pix_mp.height = 720; f.fmt.pix_mp.pixelformat = codec; f.fmt.pix_mp.num_planes = 1;
	step("S_FMT bitstream 1280x720", xioctl(fd, VIDIOC_S_FMT, &f));
	put("vidcsec: bitstream sizeimage "); num(f.fmt.pix_mp.plane_fmt[0].sizeimage); put("\n");
	/* frame port: V4L2 CAPTURE_MPLANE (the driver's OUTPUT_PORT) */
	memset(&f, 0, sizeof(f)); f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	f.fmt.pix_mp.width = 1280; f.fmt.pix_mp.height = 720; f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12_UBWC; f.fmt.pix_mp.num_planes = 2;
	step("S_FMT frames NV12_UBWC 1280x720", xioctl(fd, VIDIOC_S_FMT, &f));
	put("vidcsec: frame planes "); num(f.fmt.pix_mp.num_planes); put(" sizeimage "); num(f.fmt.pix_mp.plane_fmt[0].sizeimage); put("\n");
	ctl.id = V4L2_CID_MIN_BUFFERS_FOR_OUTPUT; ctl.value = 0; out = xioctl(fd, VIDIOC_G_CTRL, &ctl) == 0 ? ctl.value : 0;
	ctl.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE; ctl.value = 0; cap = xioctl(fd, VIDIOC_G_CTRL, &ctl) == 0 ? ctl.value : 0;
	put("vidcsec: min buffers bitstream "); num(out); put(" frames "); num(cap); put("\n");
	if (out < 4) out = 4;
	cap = cap < 6 ? 8 : cap + 2;
	memset(&rb, 0, sizeof(rb)); rb.count = out; rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; rb.memory = V4L2_MEMORY_USERPTR;
	step("REQBUFS bitstream", xioctl(fd, VIDIOC_REQBUFS, &rb));
	memset(&rb, 0, sizeof(rb)); rb.count = cap; rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; rb.memory = V4L2_MEMORY_USERPTR;
	step("REQBUFS frames", xioctl(fd, VIDIOC_REQBUFS, &rb));
	i = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	on_in = step("STREAMON bitstream", xioctl(fd, VIDIOC_STREAMON, &i));
	put("vidcsec: next step starts the session (firmware + internal buffers from the secure heaps)\n");
	i = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	on_out = step("STREAMON frames (start_streaming)", xioctl(fd, VIDIOC_STREAMON, &i));
	if (on_in == 0 && on_out == 0) put("vidcsec: session started, holding\n");
	msleep(hold);
	i = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; step("STREAMOFF frames", xioctl(fd, VIDIOC_STREAMOFF, &i));
	i = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; step("STREAMOFF bitstream", xioctl(fd, VIDIOC_STREAMOFF, &i));
	memset(&rb, 0, sizeof(rb)); rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; rb.memory = V4L2_MEMORY_USERPTR; xioctl(fd, VIDIOC_REQBUFS, &rb);
	memset(&rb, 0, sizeof(rb)); rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; rb.memory = V4L2_MEMORY_USERPTR; xioctl(fd, VIDIOC_REQBUFS, &rb);
	step("close (session + internal buffers released)", sc(57, fd, 0, 0, 0));
	msleep(300);
	result(secure ? "secure decoder session started and closed" : "clear decoder session started and closed");
}

__asm__(".global _start\n_start:\n\tmov x0, sp\n\tb _start_c\n");
