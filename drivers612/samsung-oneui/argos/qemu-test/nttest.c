// SPDX-License-Identifier: GPL-2.0-only
/*
 * Freestanding aarch64 test client for sec_argos.ko (QEMU only). Writes to
 * /dev/network_throughput exactly like the stock OneUI argosd does: one fd held open (O_RDWR),
 * text "0x%x%x\n" = Mbps then the boot_device index, written with the trailing NUL
 * (count = strlen + 1). After each step prints the cpufreq_limit CFLM_ARGOS request line
 * ("requested: [3] ...") from /sys/devices/system/cpu/cflm/info.
 */
typedef long s64; typedef int s32;
static long sc(long n, long a, long b, long c, long d)
{
	register long x8 asm("x8") = n, x0 asm("x0") = a, x1 asm("x1") = b, x2 asm("x2") = c, x3 asm("x3") = d;
	asm volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define AT_FDCWD -100
static int op(const char *p, int fl) { return sc(56, AT_FDCWD, (long)p, fl, 0); }
static long wr(int fd, const void *b, long n) { return sc(64, fd, (long)b, n, 0); }
static long rd(int fd, void *b, long n) { return sc(63, fd, (long)b, n, 0); }
static void cl(int fd) { sc(57, fd, 0, 0, 0); }
static unsigned long sl(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void ps(const char *s) { wr(1, s, sl(s)); }
static void pn(long v) { char b[24]; int i = 23; int neg = v < 0; if (neg) v = -v; b[i] = 0; do { b[--i] = '0' + v % 10; v /= 10; } while (v); if (neg) b[--i] = '-'; ps(b + i); }
static int hx(char *o, unsigned long v) { char t[20]; int n = 0, i; do { t[n++] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v); for (i = 0; i < n; i++) o[i] = t[n - 1 - i]; return n; }
void *memset(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }

static void cflm3(void)
{
	char b[2048]; int fd = op("/sys/devices/system/cpu/cflm/info", 0); long n, i, s;

	if (fd < 0) { ps("no cflm info\n"); return; }
	n = rd(fd, b, sizeof(b) - 1); cl(fd); if (n < 0) n = 0; b[n] = 0;
	for (i = 0; i < n; i++) {
		if (b[i] == '[' && b[i + 1] == '3' && b[i + 2] == ']') {
			for (s = i; s < n && b[s] != '\n'; s++)
				;
			wr(1, b + i, s - i); break;
		}
	}
	ps("\n");
}

static void report(const char *tag, long rc)
{
	ps("NTT "); ps(tag); ps(" wr="); pn(rc); ps(" "); cflm3();
}

/* argosd: sprintf(buf, "0x%x%x\n", mbps, idx); write(fd, buf, strlen(buf) + 1) */
static void argosd_write(int fd, unsigned long mbps, unsigned long idx, const char *tag)
{
	char b[32]; int n = 0;

	b[n++] = '0'; b[n++] = 'x';
	n += hx(b + n, mbps); n += hx(b + n, idx);
	b[n++] = '\n'; b[n++] = 0;
	report(tag, wr(fd, b, n));
}

void _start(void)
{
	int fd, fd2; s32 v; long r;

	fd = op("/dev/network_throughput", 2);
	ps("NTT open rc="); pn(fd); ps("\n");
	if (fd < 0)
		sc(93, 1, 0, 0, 0);
	report("start", 0);
	argosd_write(fd, 20, 1, "wifitx-20");		/* level 0: little 576000 */
	argosd_write(fd, 199, 1, "wifitx-199");		/* same level */
	argosd_write(fd, 200, 1, "wifitx-200");		/* level 1: max(2131200, 1804800) */
	argosd_write(fd, 800, 4, "ufs-800");		/* 902400 < current max: unchanged */
	argosd_write(fd, 5, 1, "wifitx-5");		/* wifi unlock: max falls to ufs 902400 */
	argosd_write(fd, 900, 2, "wifirx-900");		/* unused table (threshold 0) */
	argosd_write(fd, 100, 9, "idx9-100");		/* no such device */
	argosd_write(fd, 0, 4, "ufs-0");		/* all unlocked: -1 */
	v = (20 << 4) | 1;
	report("raw4-wifitx-20", wr(fd, &v, 4));	/* 5.4: count == 4 -> raw s32 */
	v = 0;
	r = rd(fd, &v, 4);
	ps("NTT read rc="); pn(r); ps(" value="); pn(v); ps("\n");
	fd2 = op("/dev/network_throughput", 2);
	v = (200 << 4) | 1;
	report("fd2-raw4-wifitx-200", wr(fd2, &v, 4));	/* PM_QOS_MAX over both requests */
	cl(fd2);
	report("fd2-closed", 0);			/* aggregate back to 0x141: level 0 */
	report("bogus", wr(fd, "zz\n", 3));		/* -EINVAL */
	cl(fd);
	report("closed", 0);				/* last request gone: released */
	ps("NTT done\n");
	sc(93, 0, 0, 0, 0);
}
