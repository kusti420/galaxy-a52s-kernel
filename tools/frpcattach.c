/* frpcattach <fastrpc device>: opens an upstream FastRPC device (/dev/fastrpc-adsp, -cdsp) and
 * attaches to the DSP's guest-OS process domain (FASTRPC_IOCTL_INIT_ATTACH, as adsprpcd/cdsprpcd
 * do first). That is one remote invoke whose buffer the DSP reads through its SMMU compute
 * context bank: the first real test of the CB stream IDs (a wrong SID resets the SoC silently,
 * notes 2026-11-13). Exit 0 = attached, 1 = open failed, 2 = ioctl failed (errno printed).
 * Static, no libc. Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding
 * -fno-stack-protector -fuse-ld=lld -o frpcattach frpcattach.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define FASTRPC_IOCTL_INIT_ATTACH 0x5204L	/* _IO('R', 4) */
static void out(const char *s) { long n = 0; while (s[n]) n++; sc(64, 1, (long)s, n, 0); }
static void num(long v) { char b[24]; int i = 23; b[i] = 0; if (v < 0) v = -v; do { b[--i] = '0' + v % 10; v /= 10; } while (v); out(b + i); }
void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	if (sp[0] < 2) sc(93, 9, 0, 0, 0);
	long fd = sc(56, -100, (long)argv[1], 2 /* O_RDWR */, 0);
	if (fd < 0) { out("frpcattach: open failed, errno "); num(fd); out("\n"); sc(93, 1, 0, 0, 0); }
	long r = sc(29, fd, FASTRPC_IOCTL_INIT_ATTACH, 0, 0);
	if (r < 0) { out("frpcattach: INIT_ATTACH failed, errno "); num(r); out("\n"); sc(93, 2, 0, 0, 0); }
	out("frpcattach: attached to the guest OS PD of "); out(argv[1]); out("\n");
	sc(57, fd, 0, 0, 0);
	sc(93, 0, 0, 0, 0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
