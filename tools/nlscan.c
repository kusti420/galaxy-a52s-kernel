/* nlscan: minimal nl80211 client for the bring-up ramdisk (no iw/libnl there). Static, no libc.
 *   nlscan dev            = `iw dev`: every wireless interface (name, ifindex, type, MAC, wiphy)
 *   nlscan scan <ifname>  = `iw <if> scan` (the interface must be up): TRIGGER_SCAN, waits up to
 *                           20 s for NEW_SCAN_RESULTS on the "scan" multicast group, then dumps
 *                           GET_SCAN: one line per BSS (bssid, MHz, dBm, SSID) + a count.
 * Passive use only: nothing is joined, no credentials exist. Exit 0 ok, 1 netlink, 2 no family,
 * 3 trigger refused, 4 scan aborted / timeout, 5 no interface.
 * Build (headers from `make headers_install`):
 *   clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector \
 *     -fuse-ld=lld -I out-ml/hdr/include -o tools/nlscan tools/nlscan.c */
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nl80211.h>
#define AF_NETLINK 16

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
static void hx2(unsigned char v) { char b[3] = { "0123456789abcdef"[v >> 4], "0123456789abcdef"[v & 15], 0 }; out(b); }
static void mac(const unsigned char *m) { for (int i = 0; i < 6; i++) { if (i) out(":"); hx2(m[i]); } }
static void quit(int c) { sc(93, c, 0, 0); for (;;); }
static int streq(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return *a == *b; }

static int fd, fam, grp_scan;
static unsigned seq = 1;
static unsigned char buf[65536], req[512];

/* request: nlmsghdr + genlmsghdr + attributes appended by put() */
static unsigned rlen;
static void start(int type, int flags, int cmd) {
	memset(req, 0, sizeof(req));
	struct nlmsghdr *h = (void *)req;
	h->nlmsg_type = type; h->nlmsg_flags = NLM_F_REQUEST | flags; h->nlmsg_seq = ++seq;
	struct genlmsghdr *g = (void *)(req + NLMSG_HDRLEN);
	g->cmd = cmd; g->version = 1;
	rlen = NLMSG_HDRLEN + GENL_HDRLEN;
}
static void put(int type, const void *data, int len) {
	struct nlattr *a = (void *)(req + rlen);
	a->nla_type = type; a->nla_len = NLA_HDRLEN + len;
	memcpy(req + rlen + NLA_HDRLEN, data, len);
	rlen += NLA_ALIGN(a->nla_len);
}
static void send(void) {
	((struct nlmsghdr *)req)->nlmsg_len = rlen;
	struct sockaddr_nl k = { .nl_family = AF_NETLINK };
	if (sc6(206, fd, (long)req, rlen, 0, (long)&k, sizeof(k)) < 0) { out("nlscan: send failed\n"); quit(1); }
}
/* iterate attributes of a payload */
#define FOR_ATTR(a, p, len) for (struct nlattr *a = (void *)(p); (char *)a + NLA_HDRLEN <= (char *)(p) + (len) && a->nla_len >= NLA_HDRLEN; a = (void *)((char *)a + NLA_ALIGN(a->nla_len)))
#define ADATA(a) ((unsigned char *)(a) + NLA_HDRLEN)
#define ALEN(a) ((a)->nla_len - NLA_HDRLEN)
#define ATYPE(a) ((a)->nla_type & NLA_TYPE_MASK)

/* receive until DONE / ACK; cb per genl message; returns 0 or -errno */
static int nbss;
static void (*cb)(struct genlmsghdr *g, unsigned char *attrs, int len);
static int recv_all(int dump) {
	for (;;) {
		long n = sc6(207, fd, (long)buf, sizeof(buf), 0, 0, 0);
		if (n < 0) return (int)n;
		for (struct nlmsghdr *h = (void *)buf; NLMSG_OK(h, n); h = NLMSG_NEXT(h, n)) {
			if (h->nlmsg_type == NLMSG_DONE) return 0;
			if (h->nlmsg_type == NLMSG_ERROR) { int e = ((struct nlmsgerr *)NLMSG_DATA(h))->error; if (e || !dump) return e; continue; }
			struct genlmsghdr *g = NLMSG_DATA(h);
			if (cb) cb(g, (unsigned char *)g + GENL_HDRLEN, h->nlmsg_len - NLMSG_HDRLEN - GENL_HDRLEN);
			if (!dump && !(h->nlmsg_flags & NLM_F_MULTI)) return 0;
		}
	}
}

static void cb_family(struct genlmsghdr *g, unsigned char *p, int len) {
	(void)g;
	FOR_ATTR(a, p, len) {
		if (ATYPE(a) == CTRL_ATTR_FAMILY_ID) fam = *(unsigned short *)ADATA(a);
		if (ATYPE(a) == CTRL_ATTR_MCAST_GROUPS) FOR_ATTR(gr, ADATA(a), ALEN(a)) {
			const char *name = 0; unsigned id = 0;
			FOR_ATTR(f, ADATA(gr), ALEN(gr)) {
				if (ATYPE(f) == CTRL_ATTR_MCAST_GRP_NAME) name = (const char *)ADATA(f);
				if (ATYPE(f) == CTRL_ATTR_MCAST_GRP_ID) id = *(unsigned *)ADATA(f);
			}
			if (name && streq(name, "scan")) grp_scan = id;
		}
	}
}
static int ndev;
static void cb_dev(struct genlmsghdr *g, unsigned char *p, int len) {
	(void)g; ndev++;
	out("dev");
	FOR_ATTR(a, p, len) switch (ATYPE(a)) {
	case NL80211_ATTR_IFNAME: out(" "); out((const char *)ADATA(a)); break;
	case NL80211_ATTR_IFINDEX: out(" ifindex "); num(*(unsigned *)ADATA(a)); break;
	case NL80211_ATTR_WIPHY: out(" phy#"); num(*(unsigned *)ADATA(a)); break;
	case NL80211_ATTR_IFTYPE: { unsigned t = *(unsigned *)ADATA(a); out(" type "); out(t == NL80211_IFTYPE_STATION ? "managed" : t == NL80211_IFTYPE_AP ? "AP" : t == NL80211_IFTYPE_P2P_DEVICE ? "P2P-device" : "other"); out("("); num(t); out(")"); break; }
	case NL80211_ATTR_MAC: out(" addr "); mac(ADATA(a)); break;
	}
	out("\n");
}
static int scan_done;
static void cb_event(struct genlmsghdr *g, unsigned char *p, int len) {
	(void)p; (void)len;
	if (g->cmd == NL80211_CMD_NEW_SCAN_RESULTS) scan_done = 1;
	if (g->cmd == NL80211_CMD_SCAN_ABORTED) scan_done = 2;
}
static void cb_bss(struct genlmsghdr *g, unsigned char *p, int len) {
	(void)g;
	FOR_ATTR(a, p, len) if (ATYPE(a) == NL80211_ATTR_BSS) {
		unsigned char *bssid = 0, *ie = 0; int ielen = 0, freq = 0, sig = 0;
		FOR_ATTR(b, ADATA(a), ALEN(a)) switch (ATYPE(b)) {
		case NL80211_BSS_BSSID: bssid = ADATA(b); break;
		case NL80211_BSS_FREQUENCY: freq = *(unsigned *)ADATA(b); break;
		case NL80211_BSS_SIGNAL_MBM: sig = *(int *)ADATA(b); break;
		case NL80211_BSS_INFORMATION_ELEMENTS: if (!ie) { ie = ADATA(b); ielen = ALEN(b); } break;
		case NL80211_BSS_BEACON_IES: if (!ie) { ie = ADATA(b); ielen = ALEN(b); } break;
		}
		nbss++;
		out("bss "); if (bssid) mac(bssid); out(" freq "); num(freq); out(" signal "); num(sig / 100); out(" dBm ssid \"");
		for (int i = 0; ie && i + 2 <= ielen; i += 2 + ie[i + 1]) if (ie[i] == 0) {
			for (int j = 0; j < ie[i + 1] && i + 2 + j < ielen; j++) { unsigned char c = ie[i + 2 + j]; if (c >= 32 && c < 127) outn((const char *)&c, 1); else out("?"); }
			break;
		}
		out("\"\n");
	}
}

static int ifindex_of(const char *name) {
	char path[96] = "/sys/class/net/"; int i = 15; while (*name && i < 80) path[i++] = *name++;
	const char *t = "/ifindex"; while (*t) path[i++] = *t++; path[i] = 0;
	long f = sc6(56, -100, (long)path, 0, 0, 0, 0); if (f < 0) return -1;
	char b[16]; long n = sc(63, f, b, 15); sc(57, f, 0, 0); if (n <= 0) return -1;
	int v = 0; for (int k = 0; k < n && b[k] >= '0' && b[k] <= '9'; k++) v = v * 10 + b[k] - '0';
	return v;
}

__attribute__((used)) void start_c(long *sp) {
	char **argv = (char **)(sp + 1);
	int argc = (int)sp[0];
	fd = (int)sc(198, AF_NETLINK, 3 /* SOCK_RAW */, NETLINK_GENERIC);
	struct sockaddr_nl me = { .nl_family = AF_NETLINK };
	if (fd < 0 || sc(200, fd, &me, sizeof(me)) < 0) { out("nlscan: netlink socket failed\n"); quit(1); }
	struct { long s, us; } tv = { 25, 0 };
	sc6(208, fd, 1 /* SOL_SOCKET */, 20 /* SO_RCVTIMEO */, (long)&tv, sizeof(tv), 0);
	start(GENL_ID_CTRL, 0, CTRL_CMD_GETFAMILY); put(CTRL_ATTR_FAMILY_NAME, "nl80211", 8); send();
	cb = cb_family; recv_all(0);
	if (!fam) { out("nlscan: no nl80211 family\n"); quit(2); }
	if (argc < 2 || streq(argv[1], "dev")) {
		start(fam, NLM_F_DUMP, NL80211_CMD_GET_INTERFACE); send();
		cb = cb_dev; int e = recv_all(1);
		out("nlscan: "); num(ndev); out(" wireless interface(s)"); if (e) { out(", error "); num(e); } out("\n");
		quit(ndev ? 0 : 5);
	}
	if (streq(argv[1], "scan") && argc > 2) {
		int ifi = ifindex_of(argv[2]);
		if (ifi < 0) { out("nlscan: no interface "); out(argv[2]); out("\n"); quit(5); }
		if (grp_scan) sc6(208, fd, 270 /* SOL_NETLINK */, NETLINK_ADD_MEMBERSHIP, (long)&grp_scan, 4, 0);
		start(fam, NLM_F_ACK, NL80211_CMD_TRIGGER_SCAN); put(NL80211_ATTR_IFINDEX, &ifi, 4); send();
		cb = 0; int e = recv_all(0);
		if (e) { out("nlscan: trigger scan refused, error "); num(e); out("\n"); quit(3); }
		out("nlscan: scan triggered on "); out(argv[2]); out("\n");
		cb = cb_event;
		while (!scan_done) { long n = recv_all(0); if (n < 0 && n != 0) break; }
		if (scan_done != 1) { out(scan_done == 2 ? "nlscan: scan aborted\n" : "nlscan: no scan result event (timeout)\n"); quit(4); }
		start(fam, NLM_F_DUMP, NL80211_CMD_GET_SCAN); put(NL80211_ATTR_IFINDEX, &ifi, 4); send();
		cb = cb_bss; e = recv_all(1);
		out("nlscan: "); num(nbss); out(" BSS found"); if (e) { out(", error "); num(e); } out("\n");
		quit(nbss ? 0 : 4);
	}
	out("usage: nlscan dev | nlscan scan <ifname>\n");
	quit(1);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b start_c\n");
