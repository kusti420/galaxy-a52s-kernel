/*
 * /init of the A52s 6.12 Android TEST ramdisk, kexec flavour (2026-11-12). Static, no libc.
 * (The recovery-flash design of 2026-11-11 is kept in ../old/a52init-flash-design.c.)
 *
 * PID 1 forks the helper (busybox script /a52/helper.sh, in its OWN mount namespace so that
 * first-stage init never sees its mounts), then waits:
 *   /a52/go    appears -> exec the ROM's first-stage init (/init.android), unchanged
 *   /a52/stay  appears -> never start Android (stage-1 test); the helper's dead-man timer ends it
 *   neither within WAIT_S seconds -> plain restart (under kexec that lands in the harness)
 * The helper creates "go" only after testguard reports "armed" and the zram disks exist.
 */
#define AT_FDCWD (-100)
#define O_WRONLY 1
#define CLONE_NEWNS 0x00020000
#define MS_REC 16384
#define MS_PRIVATE (1 << 18)
#define SIGCHLD 17
#ifndef WAIT_S
#define WAIT_S 240
#endif
static long sc(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
static long xopen(const char *p, long fl) { return sc(56, AT_FDCWD, (long)p, fl, 0, 0); }
static long xaccess(const char *p) { return sc(48, AT_FDCWD, (long)p, 0, 0, 0); }
static void msleep(long ms) { long ts[2] = { ms / 1000, (ms % 1000) * 1000000L }; sc(101, (long)ts, 0, 0, 0, 0); }
static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static long kfd = -1;
static void say(const char *m) { if (kfd >= 0) sc(64, kfd, (long)m, slen(m), 0, 0); }
static void restart(const char *why)
{
	say(why);
	sc(81, 0, 0, 0, 0, 0);
	msleep(300);
	sc(142, 0xfee1dead, 672274793, 0x01234567, 0, 0);	/* LINUX_REBOOT_CMD_RESTART */
	for (;;) msleep(1000);
}
void start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	char **envp = argv + argc + 1;
	static char *hargv[] = { "sh", "/a52/helper.sh", 0 };
	static char *henv[] = { "PATH=/bin:/sbin:/usr/bin", 0 };
	long pid, i;

	kfd = xopen("/dev/kmsg", O_WRONLY);
	say("<6>a52sxq-init: a52init (kexec flavour) is PID 1\n");
	pid = sc(220, SIGCHLD, 0, 0, 0, 0);
	if (pid == 0) {
		if (sc(97, CLONE_NEWNS, 0, 0, 0, 0))
			say("<3>a52sxq-init: helper: unshare failed\n");
		else {
			sc(40, 0, (long)"/", 0, MS_REC | MS_PRIVATE, 0);
			sc(221, (long)"/bin/busybox", (long)hargv, (long)henv, 0, 0);
			say("<3>a52sxq-init: helper: exec busybox failed\n");
		}
		for (;;) sc(93, 1, 0, 0, 0, 0);
	}
	if (pid < 0)
		restart("<0>a52sxq-init: fork failed, restarting\n");
	for (i = 0; i < WAIT_S * 10; i++) {
		if (!xaccess("/a52/go"))
			break;
		if (!xaccess("/a52/stay")) {
			say("<6>a52sxq-init: /a52/stay: Android init is NOT started\n");
			for (;;) msleep(1000);
		}
		msleep(100);
	}
	if (i == WAIT_S * 10)
		restart("<0>a52sxq-init: helper gave neither go nor stay, restarting\n");
	say("<6>a52sxq-init: go: exec /init.android (ROM first-stage init)\n");
	if (kfd >= 0)
		sc(57, kfd, 0, 0, 0, 0);
	sc(221, (long)"/init.android", (long)argv, (long)envp, 0, 0);
	kfd = xopen("/dev/kmsg", O_WRONLY);
	restart("<0>a52sxq-init: exec /init.android failed, restarting\n");
}
__asm__(".globl _start\n_start:\n mov x29, #0\n mov x0, sp\n and sp, x0, #-16\n bl start_c\n");
void *memset(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
