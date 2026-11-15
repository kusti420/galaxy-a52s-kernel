/*
 * a52ovl <target> <lowerdir list> [<target> <lowerdir list> ...]     (real-boot rehearsal only)
 * Run by the rehearsal helper (own mount namespace, chroot) after first-stage init switched
 * root: enters PID 1's mount namespace and mounts a read-only overlayfs on each target, e.g.
 *   a52ovl /vendor/lib/modules /dev/.a52addon/vendor/lib/modules:/vendor/lib/modules
 * The upper layers live in init's /dev tmpfs (RAM only; the helper copies them there through
 * /proc/1/root/dev), the lowest layer is the ROM's own read-only directory, so the ROM sees its
 * files plus the realboot vendor add-on, exactly where a flashed add-on would be. Nothing is
 * written to any partition. Exit 0 only if every overlay is mounted. Static, no libc.
 */
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define CLONE_NEWNS 0x00020000
#define MS_RDONLY 1
static long sc(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
static long kfd = -1;
static void say(const char *a, const char *b)
{
	char buf[600], *p = buf; const char *s;
	for (s = "<6>a52sxq-init: a52ovl: "; *s; ) *p++ = *s++;
	for (s = a; *s && p < buf + 200; ) *p++ = *s++;
	for (s = b; *s && p < buf + 590; ) *p++ = *s++;
	*p++ = '\n';
	if (kfd >= 0) sc(64, kfd, (long)buf, p - buf, 0, 0);
	sc(64, 1, (long)buf + 3, p - buf - 3, 0, 0);
}
void start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	static char opt[1024];
	long ns, i, n = (argc - 1) / 2, bad = 0;

	kfd = sc(56, AT_FDCWD, (long)"/dev/kmsg", O_WRONLY, 0, 0);
	if (n < 1 || n > 8 || argc != 2 * n + 1) { say("usage: a52ovl <target> <lowerdirs> ...", ""); goto out2; }
	ns = sc(56, AT_FDCWD, (long)"/proc/1/ns/mnt", O_RDONLY, 0, 0);
	if (ns < 0 || sc(268, ns, CLONE_NEWNS, 0, 0, 0)) { say("can't enter init's mount namespace", ""); goto out2; }
	for (i = 0; i < n; i++) {
		const char *t = argv[1 + 2 * i], *l = argv[2 + 2 * i], *s;
		char *p = opt;
		long r;
		for (s = "lowerdir="; *s; ) *p++ = *s++;
		for (s = l; *s && p < opt + sizeof(opt) - 1; ) *p++ = *s++;
		*p = 0;
		r = sc(40, (long)"a52addon", (long)t, (long)"overlay", MS_RDONLY, (long)opt);
		if (r) { say("overlay FAILED on ", t); bad++; }
		else say("overlay mounted on ", t);
	}
	for (;;) sc(93, bad ? 1 : 0, 0, 0, 0, 0);
out2:
	for (;;) sc(93, 2, 0, 0, 0, 0);
}
__asm__(".globl _start\n_start:\n mov x29, #0\n mov x0, sp\n and sp, x0, #-16\n bl start_c\n");
void *memset(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
