/* sync, then reboot(RESTART2, argv[1]) by raw syscalls: no init involvement, so no bootloader
 * control block is written to misc. Static, no libc.
 * `rb kexec` jumps into the kernel loaded by tools/kx (LINUX_REBOOT_CMD_KEXEC) instead; if
 * that fails (nothing loaded), userspace is resumed and the exit code is 3.
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fuse-ld=lld -o rb rb.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
void start_c(long *sp) {
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	sc(81, 0, 0, 0, 0); /* sync */
	sc(81, 0, 0, 0, 0);
	if (argc < 2) sc(93, 2, 0, 0, 0); /* exit(2) */
	sc(129, -1, 19, 0, 0); /* kill(-1, SIGSTOP): freeze userspace so nothing reacts to the shutdown */
	sc(81, 0, 0, 0, 0);
	{
		const char *a = argv[1];
		if (a[0] == 'k' && a[1] == 'e' && a[2] == 'x' && a[3] == 'e' && a[4] == 'c' && !a[5]) {
			sc(142, 0xfee1dead, 672274793, 0x45584543, 0); /* reboot KEXEC */
			sc(129, -1, 18, 0, 0); /* it returned: kill(-1, SIGCONT), give the shell back */
			sc(93, 3, 0, 0, 0);
		}
	}
	sc(142, 0xfee1dead, 672274793, 0xA1B2C3D4, (long)argv[1]); /* reboot RESTART2 */
	sc(93, 1, 0, 0, 0);
}
__asm__(".globl _start\n_start:\n mov x0, sp\n bl start_c\n");
