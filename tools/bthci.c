/* bthci [hci#] [seconds]: minimal Bluetooth controller test over a raw HCI user channel (no BlueZ in
 * the bring-up ramdisk). Static, no libc. Binding HCI_CHANNEL_USER opens the device in the kernel
 * (hci_qca runs its setup: power-on, firmware + NVM download) and gives this program the raw HCI
 * link, so it works on an "unconfigured" controller (no public address from DT) as well.
 * Steps: HCI_Reset, Read_Local_Version, Read_BD_ADDR, then a classic inquiry (10.24 s, results with
 * RSSI) and a PASSIVE LE scan for <seconds> (default 10; nothing is transmitted in LE), printing each
 * device once. Nothing is paired or connected. Exit 0 = controller answered (device counts printed),
 * 1 socket/bind, 2 no command answer.
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector \
 *          -fuse-ld=lld -o tools/bthci tools/bthci.c */
static long sc6(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e, x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}
#define sc(n, a, b, c) sc6(n, (long)(a), (long)(b), (long)(c), 0, 0, 0)
void *memset(void *p, int v, unsigned long n) { volatile char *c = p; while (n--) *c++ = (char)v; return p; }
void *memcpy(void *d, const void *s, unsigned long n) { volatile char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
static void outn(const char *s, long n) { sc(64, 1, s, n); }
static void out(const char *s) { long n = 0; while (s[n]) n++; outn(s, n); }
static void num(long v) { char b[24]; int i = 23; b[i] = 0; int neg = v < 0; unsigned long u = neg ? -v : v; do { b[--i] = '0' + u % 10; u /= 10; } while (u); if (neg) b[--i] = '-'; out(b + i); }
static void hx(unsigned long v, int digits) { char b[20]; int i = 19; b[i] = 0; while (digits--) { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } out(b + i); }
static void bda(const unsigned char *a) { for (int i = 5; i >= 0; i--) { hx(a[i], 2); if (i) out(":"); } }
static void quit(int c) { sc(93, c, 0, 0); for (;;); }

static int fd;
static unsigned char ev[1100];
static long now_ms(void) { long ts[2]; sc(113, 1, ts, 0); return ts[0] * 1000 + ts[1] / 1000000; }

static void cmd(unsigned short op, const void *p, int len) {
	unsigned char b[64] = { 0x01, op & 0xff, op >> 8, (unsigned char)len };
	memcpy(b + 4, p, len);
	if (sc(64, fd, b, 4 + len) != 4 + len) { out("bthci: write failed\n"); quit(1); }
}
/* next event packet into ev (ev[0] = 0x04, ev[1] = code, ev[2] = len); 0 on timeout */
static int next_event(void) {
	for (;;) {
		long n = sc(63, fd, ev, sizeof(ev));
		if (n < 0) return 0;
		if (n >= 3 && ev[0] == 0x04) return 1;
	}
}
/* send a command and wait for its Command Complete; returns pointer to the return params */
static unsigned char *cmd_wait(unsigned short op, const void *p, int len, const char *what) {
	cmd(op, p, len);
	long end = now_ms() + 5000;
	while (now_ms() < end) {
		if (!next_event()) continue;
		if (ev[1] == 0x0e && (ev[4] | ev[5] << 8) == op) return ev + 6;
		if (ev[1] == 0x0f && (ev[5] | ev[6] << 8) == op) { if (ev[3]) { out("bthci: "); out(what); out(" status 0x"); hx(ev[3], 2); out("\n"); } return ev + 3; }
	}
	out("bthci: no answer to "); out(what); out("\n");
	quit(2);
	return 0;
}

static unsigned char seen[128][7]; static int nseen;
static int add_seen(const unsigned char *a, int le) {
	for (int i = 0; i < nseen; i++) { int k = 0; while (k < 6 && seen[i][k] == a[k]) k++; if (k == 6 && seen[i][6] == le) return 0; }
	if (nseen < 128) { memcpy(seen[nseen], a, 6); seen[nseen][6] = le; nseen++; }
	return 1;
}

__attribute__((used)) void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	int argc = (int)sp[0], dev = 0, secs = 10;
	if (argc > 1) dev = argv[1][0] - '0';
	if (argc > 2) { secs = 0; for (char *c = argv[2]; *c; c++) secs = secs * 10 + (*c - '0'); }
	fd = (int)sc(198, 31 /* AF_BLUETOOTH */, 3 /* SOCK_RAW */, 1 /* BTPROTO_HCI */);
	if (fd < 0) { out("bthci: socket failed "); num(fd); out("\n"); quit(1); }
	unsigned short sa[3] = { 31, (unsigned short)dev, 1 /* HCI_CHANNEL_USER */ };
	long t0 = now_ms();
	long r = sc(200, fd, sa, sizeof(sa));
	if (r < 0) { out("bthci: bind user channel hci"); num(dev); out(" failed "); num(r); out("\n"); quit(1); }
	out("bthci: hci"); num(dev); out(" open (setup incl. firmware download) took "); num(now_ms() - t0); out(" ms\n");
	struct { long s, us; } tv = { 1, 0 };
	sc6(208, fd, 1 /* SOL_SOCKET */, 20 /* SO_RCVTIMEO */, (long)&tv, sizeof(tv), 0);
	unsigned char *p = cmd_wait(0x0c03, 0, 0, "HCI_Reset");
	out("bthci: reset status 0x"); hx(p[0], 2); out("\n");
	p = cmd_wait(0x1001, 0, 0, "Read_Local_Version");
	out("bthci: HCI version "); num(p[1]); out(" rev 0x"); hx(p[2] | p[3] << 8, 4); out(" LMP "); num(p[4]);
	out(" manufacturer 0x"); hx(p[5] | p[6] << 8, 4); out(" subver 0x"); hx(p[7] | p[8] << 8, 4); out("\n");
	p = cmd_wait(0x1009, 0, 0, "Read_BD_ADDR");
	out("bthci: BD_ADDR "); bda(p + 1); out("\n");
	/* classic inquiry, results with RSSI (inquiry mode 1) */
	unsigned char mode = 1; cmd_wait(0x0c45, &mode, 1, "Write_Inquiry_Mode");
	unsigned char inq[5] = { 0x33, 0x8b, 0x9e, 0x08, 0x00 };
	cmd(0x0401, inq, 5);
	int nbr = 0; long end = now_ms() + 15000;
	while (now_ms() < end) {
		if (!next_event()) continue;
		if (ev[1] == 0x0f && (ev[5] | ev[6] << 8) == 0x0401 && ev[3]) { out("bthci: inquiry refused 0x"); hx(ev[3], 2); out("\n"); break; }
		if (ev[1] == 0x01) break;                                   /* Inquiry Complete */
		if (ev[1] == 0x02 || ev[1] == 0x22 || ev[1] == 0x2f) {      /* results (std / RSSI / extended) */
			int nr = ev[1] == 0x2f ? 1 : ev[3];
			for (int i = 0; i < nr; i++) {
				/* 14-byte records (BlueZ inquiry_info / _with_rssi layout); RSSI at +13 */
				const unsigned char *a = ev + 4 + 14 * i;
				if (add_seen(a, 0)) {
					nbr++; out("br  "); bda(a);
					if (ev[1] != 0x02) { out(" rssi "); num((signed char)a[13]); }
					out("\n");
				}
			}
		}
	}
	out("bthci: classic inquiry: "); num(nbr); out(" device(s)\n");
	/* passive LE scan */
	unsigned char prm[7] = { 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00 };
	cmd_wait(0x200b, prm, 7, "LE_Set_Scan_Parameters");
	unsigned char en[2] = { 0x01, 0x01 };
	cmd_wait(0x200c, en, 2, "LE_Set_Scan_Enable");
	int nle = 0; end = now_ms() + secs * 1000L;
	while (now_ms() < end) {
		if (!next_event()) continue;
		if (ev[1] == 0x3e && ev[3] == 0x02) {                      /* LE Advertising Report */
			int nr = ev[4]; const unsigned char *q = ev + 5;
			for (int i = 0; i < nr && q < ev + 3 + ev[2]; i++) {
				int dl = q[8];
				if (add_seen(q + 2, 1)) { nle++; out("le  "); bda(q + 2); out(q[1] ? " random" : " public"); out(" rssi "); num((signed char)q[9 + dl]); out("\n"); }
				q += 10 + dl;
			}
		}
	}
	en[0] = 0; cmd_wait(0x200c, en, 2, "LE_Set_Scan_Enable(off)");
	out("bthci: passive LE scan "); num(secs); out(" s: "); num(nle); out(" device(s)\n");
	out("bthci: done, classic "); num(nbr); out(", LE "); num(nle); out("\n");
	quit(0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
