/*
 * /init wrapper of the A52s 6.12 Android TEST image (static, no libc, arm64 only).
 *
 * PID 1 execs the ROM's own first-stage init (/init.android) unchanged. Before that it forks a
 * helper that does what cannot be put into a read-only installed ROM:
 *   1. gives the throwaway zram disks their size (zram1 = /data, zram2 = /metadata of the test
 *      fstab; zram0 is left to the ROM's own swap setup);
 *   2. once first-stage init has switched root to the real system, bind-mounts the files listed
 *      in /a52test/binds.txt over files of the mounted ROM (RAM only: the copies live on init's
 *      /dev tmpfs, nothing on the phone's storage is changed). The important one is the test
 *      fstab over /vendor/etc/fstab.qcom, so the second stage never asks for the real userdata;
 *   3. asks dwc3-msm for device mode (no charger/Type-C driver does it on this kernel yet).
 * If the fstab bind fails, the helper restarts the phone into Download mode instead of letting
 * the ROM go on with its own fstab (modules/testguard would stop the mount anyway).
 *
 * Works only with SELinux permissive (userdebug/eng ROM + androidboot.selinux=permissive): the
 * helper stays in the kernel domain and the copies carry tmpfs labels. For an enforcing ROM see
 * README.md ("user builds").
 *
 * The idea and the namespace handling follow donors/redwood-6.12/bringup/logsaver.c.
 */
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0100
#define O_TRUNC 01000
#define O_CLOEXEC 02000000
#define CLONE_NEWNS 0x00020000
#define MS_BIND 4096
#define MS_REC 16384
#define MS_PRIVATE (1 << 18)
#define SIGCHLD 17

#ifndef DATA_BYTES
#define DATA_BYTES "3221225472"   /* zram1: /data, 3 GiB uncompressed limit */
#endif
#ifndef META_BYTES
#define META_BYTES "134217728"    /* zram2: /metadata, 128 MiB */
#endif
#ifndef DEADMAN_S
#define DEADMAN_S 600             /* seconds after the helper's setup phase */
#endif
#define USBMODE "/devices/platform/soc/a600000.ssusb/mode"
#define MAXBIND 16
#define ROOT1 "/a52test/proc/1/root"

static long sc(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
static long xopen(const char *p, long fl, long mode) { return sc(56, AT_FDCWD, (long)p, fl, mode, 0); }
static long xclose(long fd) { return sc(57, fd, 0, 0, 0, 0); }
static long xread(long fd, void *b, long n) { return sc(63, fd, (long)b, n, 0, 0); }
static long xwrite(long fd, const void *b, long n) { return sc(64, fd, (long)b, n, 0, 0); }
static long xmkdir(const char *p) { return sc(34, AT_FDCWD, (long)p, 0755, 0, 0); }
static long xmount(const char *s, const char *t, const char *fs, long fl, const char *d)
{ return sc(40, (long)s, (long)t, (long)fs, fl, (long)d); }
static long xaccess(const char *p) { return sc(48, AT_FDCWD, (long)p, 0, 0, 0); }
static void xexit(long c) { for (;;) sc(93, c, 0, 0, 0, 0); }
static void msleep(long ms)
{
	long ts[2] = { ms / 1000, (ms % 1000) * 1000000L };
	sc(101, (long)ts, 0, 0, 0, 0);
}
static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static char *scat(char *d, const char *s) { while (*s) *d++ = *s++; *d = 0; return d; }

static long kfd = -1;
static void say(const char *lvl, const char *a, const char *b, long err)
{
	char buf[400], *p = buf, num[24];
	int i = 0;

	if (slen(a) + slen(b) > 300)
		b = "";
	p = scat(p, lvl); p = scat(p, "a52test: "); p = scat(p, a); p = scat(p, b);
	if (err) {
		long v = err < 0 ? -err : err;
		p = scat(p, err < 0 ? " (errno " : " (");
		do { num[i++] = '0' + v % 10; v /= 10; } while (v);
		while (i) *p++ = num[--i];
		*p++ = ')';
	}
	*p++ = '\n';
	if (kfd >= 0)
		xwrite(kfd, buf, p - buf);
}

static long put(const char *path, const char *val)
{
	long fd = xopen(path, O_WRONLY, 0), r;

	if (fd < 0)
		return fd;
	r = xwrite(fd, val, slen(val));
	xclose(fd);
	return r < 0 ? r : 0;
}

static void download(const char *why)
{
	say("<0>", why, ": restarting into Download mode", 0);
	sc(81, 0, 0, 0, 0, 0);
	msleep(300);
	/* needs sec_core (PON reason 0x15); without it this is a plain restart */
	sc(142, 0xfee1dead, 672274793, 0xA1B2C3D4, (long)"download", 0);
	xexit(1);
}

static char list[4096];
static char *bname[MAXBIND], *btarget[MAXBIND];
static long bfd[MAXBIND];
static int nbind;
static long secfd = -1;

static void read_binds(void)
{
	long fd = xopen("/a52test/binds.txt", O_RDONLY, 0), n;
	char *p, *e, path[300];

	if (fd < 0)
		return;
	n = xread(fd, list, sizeof(list) - 1);
	xclose(fd);
	if (n <= 0)
		return;
	list[n] = 0;
	for (p = list; *p && nbind < MAXBIND; p = e) {
		char *sp = 0;

		for (e = p; *e && *e != '\n'; e++)
			if (*e == ' ' && !sp)
				sp = e;
		if (*e)
			*e++ = 0;
		if (*p == '#' || !sp || slen(p) > 200)
			continue;
		*sp = 0;
		scat(scat(path, "/a52test/bind/"), p);
		bfd[nbind] = xopen(path, O_RDONLY | O_CLOEXEC, 0);
		if (bfd[nbind] < 0) {
			say("<3>", "missing shim ", path, bfd[nbind]);
			continue;
		}
		bname[nbind] = p;
		btarget[nbind] = sp + 1;
		nbind++;
	}
}

/* runs in init's mount namespace, after the switch to the real root */
static int do_binds(void)
{
	static char buf[65536];
	char path[300];
	int i, bad = 0;

	xmkdir("/dev/.a52test");
	for (i = 0; i < nbind; i++) {
		long out, n, r;

		scat(scat(path, "/dev/.a52test/"), bname[i]);
		out = xopen(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (out < 0) {
			say("<3>", "can't create ", path, out);
			bad++;
			continue;
		}
		while ((n = xread(bfd[i], buf, sizeof(buf))) > 0)
			xwrite(out, buf, n);
		xclose(out);
		r = xmount(path, btarget[i], 0, MS_BIND, 0);
		if (r) {
			say("<3>", "bind failed on ", btarget[i], r);
			bad++;
		} else {
			say("<6>", "bound over ", btarget[i], 0);
		}
	}
	return bad;
}

static void helper(void)
{
	int zram = 0, usb = 0, bound = 0, sec = secfd < 0, i;
	const char *sys = "/a52test/sys";
	char path[200];
	long r;

	/* own mount namespace: first-stage init moves every mount it can see into the new root
	 * and dies if that fails, so our proc and sysfs must be invisible to it */
	r = sc(97, CLONE_NEWNS, 0, 0, 0, 0);
	if (r)
		download("helper: unshare failed");
	xmount(0, "/", 0, MS_REC | MS_PRIVATE, 0);
	r = xmount("proc", "/a52test/proc", "proc", 0, 0);
	if (r)
		download("helper: no proc");
	xmount("sysfs", "/a52test/sys", "sysfs", 0, 0);
	say("<6>", "helper started", "", 0);

	for (i = 0; i < 9000; i++) {	/* 3 minutes */
		if (!zram) {
			scat(scat(path, sys), "/block/zram2/disksize");
			if (!xaccess(path)) {
				r = put(path, META_BYTES);
				scat(scat(path, sys), "/block/zram1/disksize");
				r |= put(path, DATA_BYTES);
				say(r ? "<3>" : "<6>", "zram1 (/data) " DATA_BYTES ", zram2 (/metadata) " META_BYTES, "", r);
				zram = 1;
			}
		}
		if (!usb) {
			scat(scat(path, sys), USBMODE);
			if (!xaccess(path) && !put(path, "peripheral")) {
				say("<6>", "usb: peripheral mode requested", "", 0);
				usb = 1;
			}
		}
		if (!bound && !xaccess(ROOT1 "/system/bin/init") && !xaccess(ROOT1 "/vendor/etc") &&
		    xaccess(ROOT1 "/system/system")) {
			long ns = xopen("/a52test/proc/1/ns/mnt", O_RDONLY, 0);

			r = ns < 0 ? ns : sc(268, ns, CLONE_NEWNS, 0, 0, 0);
			if (r)
				download("helper: can't enter init's mount namespace");
			sys = "/sys";
			if (do_binds())
				download("helper: a shim could not be bound");
#ifndef NO_ZRAM
			if (!zram)
				download("helper: no zram disks, /data would have no device");
#endif
			bound = 1;
			say("<6>", "shims in place", "", 0);
		}
		/* sec_core's init returns -EPROBE_DEFER until the PMIC SDAM has probed; first-stage
		 * init does not retry a failed module, and without sec_core "reboot download" is a
		 * plain restart into this same image. Keep trying from here. */
		if (!sec && i % 25 == 0) {
			scat(scat(path, sys), "/module/sec_core");
			if (!xaccess(path)) {
				sec = 1;
			} else if (!sc(273, secfd, (long)"clear_on_load=0", 0, 0, 0)) {
				say("<6>", "sec_core loaded by the helper", "", 0);
				sec = 1;
			}
		}
		if (bound && usb && sec)
			break;
		msleep(20);
	}
	if (!bound)
		say("<3>", "the real root never appeared (first-stage mount failed?)", "", 0);
	if (!usb)
		say("<3>", "usb: no ", USBMODE, 0);
	if (!sec)
		say("<3>", "sec_core never loaded: reboot download is a plain restart", "", 0);
	/* dead-man timer: nobody reached the phone (no adb, hung boot) -> leave by ourselves.
	 * "adb shell touch /dev/.a52test/keep" stops it. Storage is safe to cut: the real
	 * partitions are read-only and /data is a RAM disk. */
	for (i = 0; i < DEADMAN_S; i++) {
		if (bound && !xaccess("/dev/.a52test/keep")) {
			say("<6>", "dead-man timer stopped by /dev/.a52test/keep", "", 0);
			xexit(0);
		}
		msleep(1000);
	}
	download("dead-man timer expired");
}

void start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	char **envp = argv + argc + 1;
	long pid;

	kfd = xopen("/dev/kmsg", O_WRONLY, 0);	/* static node in the boot ramdisk; not CLOEXEC on purpose: the helper keeps its copy */
	read_binds();
	secfd = xopen("/lib/modules/sec_core.ko", O_RDONLY | O_CLOEXEC, 0);
	pid = sc(220, SIGCHLD, 0, 0, 0, 0);	/* fork */
	if (pid == 0)
		helper();
	if (pid < 0)
		download("fork failed");
	if (kfd >= 0)
		xclose(kfd);
	sc(221, (long)"/init.android", (long)argv, (long)envp, 0, 0);
	kfd = xopen("/dev/kmsg", O_WRONLY, 0);
	download("exec /init.android failed");
}
__asm__(".globl _start\n_start:\n mov x29, #0\n mov x0, sp\n and sp, x0, #-16\n bl start_c\n");
/* the compiler may still emit calls to these */
void *memset(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
