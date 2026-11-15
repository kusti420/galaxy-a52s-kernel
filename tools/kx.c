/* kx: load a kernel for kexec with kexec_file_load(2). Static, no libc (built like rb.c).
 *   kx <Image> <initramfs or -> "<cmdline>"
 * Loads only. The jump is `rb kexec` (reboot syscall, LINUX_REBOOT_CMD_KEXEC).
 * The base device tree is the running kernel's own FDT, or the blob written to
 * /sys/firmware/kexec_fdt before this call (a52sxq patch in ack/drivers/of/kexec.c).
 * Exit: 0 loaded, 2 usage, 3 cannot open Image, 4 cannot open initramfs, 5 syscall failed
 * (the errno is printed). */
static long sc(long n, long a, long b, long c, long d, long e) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static void say(const char *s) { sc(64, 2, (long)s, slen(s), 0, 0); }
static void saynum(long v) {
	char b[24]; int i = 23; b[i] = 0;
	if (v == 0) b[--i] = '0';
	while (v > 0) { b[--i] = '0' + v % 10; v /= 10; }
	say(b + i);
}
static void die(int code, const char *msg, long err) {
	say("kx: "); say(msg);
	if (err) { say(": errno "); saynum(-err); }
	say("\n");
	sc(93, code, 0, 0, 0, 0);
}
#define AT_FDCWD (-100)
#define KEXEC_FILE_NO_INITRAMFS 4
void start_c(long *sp) {
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	long kfd, ifd = -1, flags = 0, r;
	if (argc != 4) die(2, "usage: kx <Image> <initramfs or -> \"<cmdline>\"", 0);
	kfd = sc(56, AT_FDCWD, (long)argv[1], 0, 0, 0); /* openat O_RDONLY */
	if (kfd < 0) die(3, "cannot open the kernel image", kfd);
	if (argv[2][0] == '-' && argv[2][1] == 0) flags = KEXEC_FILE_NO_INITRAMFS;
	else {
		ifd = sc(56, AT_FDCWD, (long)argv[2], 0, 0, 0);
		if (ifd < 0) die(4, "cannot open the initramfs", ifd);
	}
	/* kexec_file_load(kernel_fd, initrd_fd, cmdline_len incl. NUL, cmdline, flags) */
	r = sc(294, kfd, ifd, slen(argv[3]) + 1, (long)argv[3], flags);
	if (r < 0) die(5, "kexec_file_load failed", r);
	say("kx: loaded\n");
	sc(93, 0, 0, 0, 0, 0);
}
__asm__(".globl _start\n_start:\n mov x0, sp\n bl start_c\n");
