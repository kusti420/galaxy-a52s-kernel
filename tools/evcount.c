/* evcount <file> [max-lines]: decodes a capture of arm64 struct input_event records (24 bytes:
 * 8 sec, 8 usec, 2 type, 2 code, 4 value; e.g. `cat /dev/input/eventN > file`) and prints the
 * totals (events, BTN_TOUCH down/up, ABS_MT_POSITION_X/Y reports, X/Y range) and one line per
 * touch-down / touch-up of slot 0 with its position ("down x y" uses the position of the frame
 * that contains the down). Used by patches/mainline-7.3/m3touch.sh: busybox hexdump/awk mis-parse
 * these records. Static, no libc (as tools/i2cpoke.c).
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -o evcount evcount.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define AT_FDCWD -100
static char ob[4096];
static int on;
static void flush(void) { if (on) sc(64, 1, (long)ob, on, 0); on = 0; }
static void put(const char *s) { while (*s) { if (on == sizeof(ob)) flush(); ob[on++] = *s++; } }
static void num(long v) {
	char b[24]; int i = 23; int neg = v < 0;
	unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
	b[i] = 0;
	do { b[--i] = '0' + u % 10; u /= 10; } while (u);
	if (neg) b[--i] = '-';
	put(b + i);
}
static long dec(const char *s) { long v = 0; for (; *s >= '0' && *s <= '9'; s++) v = v * 10 + *s - '0'; return v; }

struct ev { long sec, usec; unsigned short type, code; int value; };

void _start_c(long *sp) {
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	static struct ev buf[256];
	long fd, n, total = 0, down = 0, up = 0, xs = 0, ys = 0, lines = 0, maxl = 40;
	int x = -1, y = -1, slot = 0, minx = 1 << 30, maxx = -1, miny = 1 << 30, maxy = -1;
	int pending = 0;	/* 1 = down, 2 = up, reported at the next SYN_REPORT */

	if (argc < 2) { put("usage: evcount <capture> [max-lines]\n"); flush(); sc(93, 1, 0, 0, 0); }
	if (argc > 2) maxl = dec(argv[2]);
	fd = sc(56, AT_FDCWD, (long)argv[1], 0, 0);
	if (fd < 0) { put("evcount: open failed\n"); flush(); sc(93, 1, 0, 0, 0); }
	while ((n = sc(63, fd, (long)buf, sizeof(buf), 0)) > 0) {
		for (long i = 0; i < n / (long)sizeof(struct ev); i++) {
			struct ev *e = &buf[i];
			total++;
			if (e->type == 3 && e->code == 47) slot = e->value;		/* ABS_MT_SLOT */
			if (e->type == 3 && e->code == 53) {				/* ABS_MT_POSITION_X */
				xs++; if (e->value < minx) minx = e->value; if (e->value > maxx) maxx = e->value;
				if (slot == 0) x = e->value;
			}
			if (e->type == 3 && e->code == 54) {				/* ABS_MT_POSITION_Y */
				ys++; if (e->value < miny) miny = e->value; if (e->value > maxy) maxy = e->value;
				if (slot == 0) y = e->value;
			}
			if (e->type == 1 && e->code == 330) {				/* BTN_TOUCH */
				if (e->value) down++; else up++;
				pending = e->value ? 1 : 2;
			}
			if (e->type == 0 && e->code == 0 && pending) {			/* SYN_REPORT */
				if (lines++ < maxl) {
					put(pending == 1 ? "down " : "up "); num(x); put(" "); num(y);
					put(" t="); num(e->sec); put("."); num(e->usec / 1000); put("\n");
				}
				pending = 0;
			}
		}
		/* records never straddle reads of a regular file read in 24-byte multiples */
	}
	put("evcount: "); num(total); put(" events, BTN_TOUCH down "); num(down); put(" up "); num(up);
	put(", MT X reports "); num(xs); put(" Y reports "); num(ys);
	if (maxx >= 0) { put(", X "); num(minx); put(".."); num(maxx); put(" Y "); num(miny); put(".."); num(maxy); }
	put("\n");
	flush();
	sc(93, 0, 0, 0, 0);
}

__asm__(".global _start\n_start:\n\tmov x0, sp\n\tb _start_c\n");
