/*
 * a52bind <source file> <target path in init's namespace> [<source> <target> ...]
 * Run by the helper (own mount namespace, chroot) after first-stage init switched root: opens
 * the sources, enters PID 1's mount namespace, copies each source to /dev/.a52test/<n> (init's
 * /dev tmpfs: RAM only) and bind-mounts the copy over the target. Exit 0 only if all are bound.
 */
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0100
#define O_TRUNC 01000
#define CLONE_NEWNS 0x00020000
#define MS_BIND 4096
static long sc(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static long kfd = -1;
static void say(const char *a, const char *b)
{
	char buf[400], *p = buf; const char *s;
	for (s = "<6>a52sxq-init: a52bind: "; *s; ) *p++ = *s++;
	for (s = a; *s && p < buf + 200; ) *p++ = *s++;
	for (s = b; *s && p < buf + 390; ) *p++ = *s++;
	*p++ = '\n';
	if (kfd >= 0) sc(64, kfd, (long)buf, p - buf, 0, 0);
	sc(64, 1, (long)buf + 3, p - buf - 3, 0, 0);
}
void start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	static char buf[65536];
	long fd[8], ns, i, n = (argc - 1) / 2, bad = 0;
	char path[64] = "/dev/.a52test/0";

	kfd = sc(56, AT_FDCWD, (long)"/dev/kmsg", O_WRONLY, 0, 0);
	if (n < 1 || n > 8) { say("usage", ""); goto out1; }
	for (i = 0; i < n; i++) {
		fd[i] = sc(56, AT_FDCWD, (long)argv[1 + 2 * i], O_RDONLY, 0, 0);
		if (fd[i] < 0) { say("can't open ", argv[1 + 2 * i]); goto out1; }
	}
	ns = sc(56, AT_FDCWD, (long)"/proc/1/ns/mnt", O_RDONLY, 0, 0);
	if (ns < 0 || sc(268, ns, CLONE_NEWNS, 0, 0, 0)) { say("can't enter init's mount namespace", ""); goto out1; }
	sc(34, AT_FDCWD, (long)"/dev/.a52test", 0755, 0, 0);
	for (i = 0; i < n; i++) {
		long out, r;
		path[slen(path) - 1] = '0' + i;
		out = sc(56, AT_FDCWD, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644, 0);
		if (out < 0) { say("can't create ", path); bad++; continue; }
		while ((r = sc(63, fd[i], (long)buf, sizeof(buf), 0, 0)) > 0)
			sc(64, out, (long)buf, r, 0, 0);
		sc(57, out, 0, 0, 0, 0);
		if (sc(40, (long)path, (long)argv[2 + 2 * i], 0, MS_BIND, 0)) { say("bind FAILED on ", argv[2 + 2 * i]); bad++; }
		else say("bound over ", argv[2 + 2 * i]);
	}
	for (;;) sc(93, bad ? 1 : 0, 0, 0, 0, 0);
out1:
	for (;;) sc(93, 2, 0, 0, 0, 0);
}
__asm__(".globl _start\n_start:\n mov x29, #0\n mov x0, sp\n and sp, x0, #-16\n bl start_c\n");
void *memset(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
