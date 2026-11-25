/* freestanding aarch64 uinput test driver for input_booster (QEMU only) */
typedef unsigned long u64; typedef long s64; typedef unsigned int u32; typedef int s32; typedef unsigned short u16;
static long sc(long n, long a, long b, long c, long d) {
	register long x8 asm("x8") = n, x0 asm("x0") = a, x1 asm("x1") = b, x2 asm("x2") = c, x3 asm("x3") = d;
	asm volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define AT_FDCWD -100
static int op(const char *p, int fl) { return sc(56, AT_FDCWD, (long)p, fl, 0); }
static long wr(int fd, const void *b, long n) { return sc(64, fd, (long)b, n, 0); }
static long rd(int fd, void *b, long n) { return sc(63, fd, (long)b, n, 0); }
static void cl(int fd) { sc(57, fd, 0, 0, 0); }
static long io(int fd, unsigned long r, long a) { return sc(29, fd, r, a, 0); }
static void msleep(long ms) { struct { s64 s, ns; } t = { ms / 1000, (ms % 1000) * 1000000 }; sc(101, (long)&t, 0, 0, 0); }
static unsigned long sl(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void ps(const char *s) { wr(1, s, sl(s)); }
static void pn(long v) { char b[24]; int i = 23; int neg = v < 0; if (neg) v = -v; b[i] = 0; do { b[--i] = '0' + v % 10; v /= 10; } while (v); if (neg) b[--i] = '-'; ps(b + i); }
static void *ms(void *d, int c, unsigned long n) { char *p = d; while (n--) *p++ = c; return d; }
void *memset(void *d, int c, unsigned long n) { return ms(d, c, n); }
void *memcpy(void *d, const void *s, unsigned long n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }

static long t0;
static long now_ms(void) { struct { s64 s, ns; } t; sc(113, 1, (long)&t, 0, 0); return t.s * 1000 + t.ns / 1000000; }
/* print the cflm line for id 1 (touch) */
static void probe(const char *tag) {
	char b[2048]; int fd = op("/sys/devices/system/cpu/cflm/info", 0); long n, i, s;
	ps("IBT "); pn(now_ms() - t0); ps("ms "); ps(tag); ps(": ");
	if (fd < 0) { ps("no cflm info\n"); return; }
	n = rd(fd, b, sizeof(b) - 1); cl(fd); if (n < 0) n = 0; b[n] = 0;
	for (i = 0; i < n; i++) {
		if (b[i] == '[' && b[i + 1] == '1' && b[i + 2] == ']') {
			for (s = i; s < n && b[s] != '\n'; s++)
				;
			wr(1, b + i, s - i); break;
		}
	}
	ps("\n");
}
struct ev { s64 sec, usec; u16 type, code; s32 value; };
static int ufd;
static void emit(int type, int code, int val) { struct ev e; ms(&e, 0, sizeof(e)); e.type = type; e.code = code; e.value = val; wr(ufd, &e, sizeof(e)); }
#define EV_SYN 0
#define EV_KEY 1
#define EV_ABS 3
#define BTN_TOUCH 0x14a
#define KEY_VOLUMEUP 115
#define ABS_X 0
#define ABS_Y 1
#define ABS_MT_SLOT 0x2f
#define ABS_MT_POSITION_X 0x35
#define ABS_MT_POSITION_Y 0x36
#define ABS_MT_TRACKING_ID 0x39
static void down(int slot, int id, int first) { emit(EV_ABS, ABS_MT_SLOT, slot); emit(EV_ABS, ABS_MT_TRACKING_ID, id); emit(EV_ABS, ABS_MT_POSITION_X, 100 + slot); emit(EV_ABS, ABS_MT_POSITION_Y, 200); if (first) emit(EV_KEY, BTN_TOUCH, 1); emit(EV_SYN, 0, 0); }
static void up(int slot, int last) { emit(EV_ABS, ABS_MT_SLOT, slot); emit(EV_ABS, ABS_MT_TRACKING_ID, -1); if (last) emit(EV_KEY, BTN_TOUCH, 0); emit(EV_SYN, 0, 0); }

struct uidev { char name[80]; u16 bus, vendor, product, version; u32 ff; s32 absmax[64], absmin[64], absfuzz[64], absflat[64]; };
void _start(void) {
	static struct uidev u; int i, evfd[16];
	ufd = op("/dev/uinput", 2);
	if (ufd < 0) { ps("IBT no uinput\n"); sc(93, 1, 0, 0, 0); }
	io(ufd, 0x40045564, EV_KEY); io(ufd, 0x40045564, EV_ABS); io(ufd, 0x40045564, EV_SYN);
	io(ufd, 0x40045565, BTN_TOUCH); io(ufd, 0x40045565, KEY_VOLUMEUP);
	int abs[] = { ABS_X, ABS_Y, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID };
	for (i = 0; i < 6; i++) io(ufd, 0x40045567, abs[i]);
	io(ufd, 0x4004556e, 1 /* INPUT_PROP_DIRECT */);
	memcpy(u.name, "ibtest-ts", 10); u.bus = 6; u.vendor = 1; u.product = 1;
	u.absmax[ABS_X] = 1079; u.absmax[ABS_Y] = 2399; u.absmax[ABS_MT_SLOT] = 9;
	u.absmax[ABS_MT_POSITION_X] = 1079; u.absmax[ABS_MT_POSITION_Y] = 2399; u.absmax[ABS_MT_TRACKING_ID] = 65535;
	wr(ufd, &u, sizeof(u));
	if (io(ufd, 0x5501, 0) < 0) { ps("IBT UI_DEV_CREATE failed\n"); sc(93, 1, 0, 0, 0); }
	ps("IBT created; waiting for the shell to mknod + open (users > 0)\n");
	msleep(4000);
	t0 = now_ms();
	probe("idle");
	/* 1: short tap: head 200 ms, tail 300 ms after head end */
	down(0, 7, 1); msleep(100); probe("tap +100 (head 1324800)");
	up(0, 1); msleep(150); probe("tap +250 (tail 1056000)");
	msleep(400); probe("tap +650 (released)");
	/* 2: long press 1 s */
	down(0, 8, 1); msleep(400); probe("long +400 (tail value while held)");
	msleep(600); up(0, 1); msleep(150); probe("long up+150 (tail)");
	msleep(300); probe("long up+450 (released)");
	/* 3: two fingers -> multitouch (head 2035200) */
	down(0, 9, 1); msleep(50); down(1, 10, 0); msleep(80); probe("2-finger +130 (2035200)");
	up(1, 0); up(0, 1); msleep(1200); probe("2-finger up+1200 (released)");
	/* 4: volume key: key booster head 500 tail 0 */
	emit(EV_KEY, KEY_VOLUMEUP, 1); emit(EV_SYN, 0, 0); msleep(100); probe("vol +100 (1324800)");
	emit(EV_KEY, KEY_VOLUMEUP, 0); emit(EV_SYN, 0, 0); msleep(600); probe("vol +700 (released)");
	/* 5: burst of 300 taps 2 ms apart (ring stress) */
	for (i = 0; i < 300; i++) { down(0, 100 + i, 1); up(0, 1); msleep(2); }
	msleep(1500); probe("burst +1500 (released)");
	ps("IBT done; now holding a touch and exiting (uinput destroy while boosted)\n");
	down(0, 999, 1); msleep(300); probe("held before exit");
	(void)evfd;
	sc(93, 0, 0, 0, 0);
}
