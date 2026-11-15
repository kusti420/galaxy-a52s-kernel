/* ffbuzz <event device> <ms>: uploads one FF_RUMBLE effect (full strength, <ms> long) to an
 * input device with force feedback (e.g. gpio-vibrator), plays it, waits <ms> + 100 ms, stops
 * it and removes it. Exit 0 = played; 1 open, 2 upload (EVIOCSFF), 3 play write failed.
 * Static, no libc (as tools/rb.c).
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -o ffbuzz ffbuzz.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
/* struct ff_effect on arm64: 48 bytes; type @0, id @2, replay.length @10, union @16
 * (ff_rumble_effect: strong_magnitude @16, weak_magnitude @18) */
struct ffe { unsigned short type; short id; unsigned short dir, tbutton, tinterval, rlength, rdelay, pad;
	     unsigned short strong, weak; unsigned char rest[28]; };
struct iev { long sec, usec; unsigned short type, code; int value; };
#define EVIOCSFF 0x40304580L	/* _IOW('E', 0x80, struct ff_effect) */
#define EVIOCRMFF 0x40044581L	/* _IOW('E', 0x81, int) */
#define FF_RUMBLE 0x50
#define EV_FF 0x15
static long num(const char *s) { long v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }
void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	if (sp[0] < 3) sc(93, 9, 0, 0, 0);
	long ms = num(argv[2]);
	long fd = sc(56, -100, (long)argv[1], 2 /* O_RDWR */, 0);
	if (fd < 0) sc(93, 1, 0, 0, 0);
	struct ffe e = { 0 };
	e.type = FF_RUMBLE; e.id = -1; e.rlength = (unsigned short)ms; e.strong = 0xffff; e.weak = 0xffff;
	if (sc(29, fd, EVIOCSFF, (long)&e, 0) < 0) sc(93, 2, 0, 0, 0);
	struct iev ev = { 0, 0, EV_FF, (unsigned short)e.id, 1 };
	if (sc(64, fd, (long)&ev, sizeof(ev), 0) != sizeof(ev)) sc(93, 3, 0, 0, 0);
	long ts[2] = { (ms + 100) / 1000, ((ms + 100) % 1000) * 1000000L };
	sc(101, (long)ts, 0, 0, 0);
	ev.value = 0; sc(64, fd, (long)&ev, sizeof(ev), 0);
	sc(29, fd, EVIOCRMFF, (long)e.id, 0);
	sc(57, fd, 0, 0, 0);
	sc(93, 0, 0, 0, 0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
