/* i2cpoke <i2c-dev> <addr> <byte>...: writes the bytes (hex) to the 7-bit address (hex) in one
 * I2C write message, with I2C_SLAVE_FORCE (works while a kernel driver is bound). Used by
 * patches/mainline-7.3/m3touch.sh to make the FTS5 touch IC post a command echo (0x62 = clear
 * event FIFO, harmless) so its attention interrupt fires without a finger on the screen.
 * Exit 0 = written; 1 usage/open, 2 ioctl, 3 write. Static, no libc (as tools/ffbuzz.c).
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -o i2cpoke i2cpoke.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define I2C_SLAVE_FORCE 0x0706
static long hex(const char *s) {
	long v = 0;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
	for (; *s; s++) {
		int d = *s >= '0' && *s <= '9' ? *s - '0' : *s >= 'a' && *s <= 'f' ? *s - 'a' + 10 :
			*s >= 'A' && *s <= 'F' ? *s - 'A' + 10 : -1;
		if (d < 0) return -1;
		v = v * 16 + d;
	}
	return v;
}
void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	unsigned char buf[32];
	long n = sp[0] - 3, i;
	if (n < 1 || n > 32) sc(93, 1, 0, 0, 0);
	long addr = hex(argv[2]);
	if (addr < 0 || addr > 0x7f) sc(93, 1, 0, 0, 0);
	for (i = 0; i < n; i++) {
		long b = hex(argv[3 + i]);
		if (b < 0 || b > 0xff) sc(93, 1, 0, 0, 0);
		buf[i] = (unsigned char)b;
	}
	long fd = sc(56, -100, (long)argv[1], 2 /* O_RDWR */, 0);
	if (fd < 0) sc(93, 1, 0, 0, 0);
	if (sc(29, fd, I2C_SLAVE_FORCE, addr, 0) < 0) sc(93, 2, 0, 0, 0);
	if (sc(64, fd, (long)buf, n, 0) != n) sc(93, 3, 0, 0, 0);
	sc(57, fd, 0, 0, 0);
	sc(93, 0, 0, 0, 0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
