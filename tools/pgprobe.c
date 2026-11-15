/* pgprobe: find page-cache pages of a file that the CPU cannot read (synchronous external
 * abort -> SIGBUS BUS_OBJERR), and print their physical frame numbers from /proc/self/pagemap.
 *   pgprobe <file> [all]
 *   pgprobe <file> x <hexoffset>   branch to that file offset in a child, print its exit status
 * Maps the file with MAP_POPULATE (the kernel fills the page cache by DMA, no CPU access),
 * then a forked child loads one byte of every page. When the child dies on a signal the page
 * it was touching is reported and probing resumes after it. "all" also prints every page's PFN.
 * Run as root (pagemap hides PFNs otherwise). Static, no libc (built like rb.c):
 *   clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fuse-ld=lld -o pgprobe pgprobe.c */
static long sc(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e, x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}
static void out(const char *s) { long n = 0; while (s[n]) n++; sc(64, 1, (long)s, n, 0, 0, 0); }
static void hex(unsigned long v) {
	char b[19]; int i = 18; b[i] = 0;
	do { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
	b[--i] = 'x'; b[--i] = '0'; out(b + i);
}
static unsigned long pfn(int pm, unsigned long va) {
	unsigned long e = 0;
	if (sc(67, pm, (long)&e, 8, (va >> 12) * 8, 0, 0) != 8) return ~0UL;
	return (e >> 63) ? (e & ((1UL << 55) - 1)) : ~0UL;
}
void start_c(long *sp) {
	long argc = sp[0]; char **argv = (char **)(sp + 1);
	if (argc < 2) { out("usage: pgprobe <file> [all]\n"); sc(93, 2, 0, 0, 0, 0, 0); }
	int all = argc > 2 && argv[2][0] == 'a';
	unsigned long xoff = 0; int xmode = argc > 3 && argv[2][0] == 'x';
	if (xmode) for (char *c = argv[3]; *c; c++) xoff = xoff * 16 + (*c <= '9' ? *c - '0' : (*c | 32) - 'a' + 10);
	long fd = sc(56, -100, (long)argv[1], 0, 0, 0, 0);
	if (fd < 0) { out("open failed\n"); sc(93, 3, 0, 0, 0, 0, 0); }
	long size = sc(62, fd, 0, 2, 0, 0, 0);
	unsigned long np = (size + 4095) >> 12;
	/* PROT_READ|PROT_EXEC, MAP_SHARED|MAP_POPULATE */
	unsigned long base = sc(222, 0, size, 1 | 4, 1 | 0x8000, fd, 0);
	volatile unsigned long *idx = (unsigned long *)sc(222, 0, 4096, 3, 1 | 0x20, -1, 0);
	int pm = sc(56, -100, (long)"/proc/self/pagemap", 0, 0, 0, 0);
	out("size "); hex(size); out(" pages "); hex(np); out(" base "); hex(base); out("\n");
	if (all) for (unsigned long i = 0; i < np; i++) {
		hex(i << 12); out(" "); hex(pfn(pm, base + (i << 12))); out("\n");
	}
	if (xmode) {
		/* branch into the mapping at file offset xoff in a child and report how it dies */
		long pid = sc(220, 17, 0, 0, 0, 0, 0);
		if (pid == 0) { ((void (*)(void))(base + xoff))(); sc(93, 0, 0, 0, 0, 0, 0); }
		int st = 0; sc(260, pid, (long)&st, 0, 0, 0, 0);
		out("exec off "); hex(xoff); out(" status "); hex(st); out(" pfn "); hex(pfn(pm, base + (xoff & ~4095UL))); out("\n");
		sc(93, 0, 0, 0, 0, 0, 0);
	}
	unsigned long bad = 0; *idx = 0;
	while (*idx < np) {
		long pid = sc(220, 17 /* SIGCHLD */, 0, 0, 0, 0, 0);
		if (pid == 0) {
			for (unsigned long i = *idx; i < np; i++) { *idx = i; (void)*(volatile char *)(base + (i << 12)); }
			*idx = np; sc(93, 0, 0, 0, 0, 0, 0);
		}
		int st = 0; sc(260, pid, (long)&st, 0, 0, 0, 0);
		if ((st & 0x7f) == 0) break;
		bad++;
		out("BAD off "); hex(*idx << 12); out(" sig "); hex(st & 0x7f); out(" pfn "); hex(pfn(pm, base + (*idx << 12))); out("\n");
		*idx += 1;
	}
	out("done, bad pages "); hex(bad); out("\n");
	sc(93, bad ? 1 : 0, 0, 0, 0, 0, 0);
}
__asm__(".globl _start\n_start:\n mov x0, sp\n b start_c\n");
