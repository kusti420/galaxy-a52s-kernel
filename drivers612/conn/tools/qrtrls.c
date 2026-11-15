// SPDX-License-Identifier: GPL-2.0
/*
 * qrtrls: list the QRTR services the name server knows (like qrtr-lookup),
 * for the bring-up ramdisk. Static, no libc (raw arm64 syscalls), same style
 * as tools/rb.c.
 *
 *   qrtrls            one line per server: service instance(version) node port [name]
 *   qrtrls -w <sec>   keep listening for NEW_SERVER/DEL_SERVER for <sec> seconds
 *
 * Sends QRTR_TYPE_NEW_LOOKUP {service 0, instance 0} to the control port of
 * the local node; the in-kernel name server answers with one NEW_SERVER per
 * known server and an all-zero NEW_SERVER as end marker.
 */
typedef unsigned int u32;
typedef unsigned short u16;

#define AF_QIPCRTR 42
#define SOCK_DGRAM 2
#define QRTR_PORT_CTRL 0xfffffffeu
#define QRTR_TYPE_NEW_SERVER 4
#define QRTR_TYPE_DEL_SERVER 5
#define QRTR_TYPE_NEW_LOOKUP 10

struct sockaddr_qrtr { u16 family; u32 node; u32 port; };
struct ctrl_pkt { u32 cmd; u32 service; u32 instance; u32 node; u32 port; };
struct pollfd { int fd; short events; short revents; };
struct timespec { long sec; long nsec; };

static long sc(long n, long a, long b, long c, long d, long e, long f)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a,
		x1 __asm__("x1") = b, x2 __asm__("x2") = c, x3 __asm__("x3") = d,
		x4 __asm__("x4") = e, x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2),
			 "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}

static char out[256];
static int outn;

static void flush(void)
{
	sc(64, 1, (long)out, outn, 0, 0, 0);
	outn = 0;
}

static void ps(const char *s)
{
	while (*s) {
		if (outn == sizeof(out))
			flush();
		out[outn++] = *s++;
	}
}

static void pu(unsigned long v)
{
	char b[24];
	int i = sizeof(b) - 1;

	b[i] = 0;
	do {
		b[--i] = '0' + v % 10;
		v /= 10;
	} while (v);
	ps(b + i);
}

/* QMI service ids worth naming at bring-up */
static const char *svc_name(u32 id)
{
	switch (id) {
	case 1: return "WDS (data)";
	case 2: return "DMS (device mgmt)";
	case 3: return "NAS (network)";
	case 4: return "QOS";
	case 5: return "WMS (SMS)";
	case 8: return "AT";
	case 9: return "VOICE";
	case 10: return "CAT";
	case 11: return "UIM (SIM)";
	case 12: return "PBM";
	case 14: return "RMTFS (remote storage: needs rmt_storage)";
	case 15: return "TEST (ping)";
	case 16: return "LOC (GNSS)";
	case 17: return "SAR";
	case 18: return "IMS settings";
	case 23: return "TS (thermal sensor)";
	case 24: return "TMD (thermal mitigation)";
	case 26: return "WDA (data admin)";
	case 36: return "PDC (mcfg)";
	case 41: return "RFRPE";
	case 43: return "SSCTL (subsystem control)";
	case 42: return "DSD (data system determination)";
	case 49: return "IPA (inst 1 = apps, registered by ipam.ko; inst 2 = modem)";
	case 64: return "service locator (pd-mapper)";
	case 66: return "service registry notifier (PDR)";
	case 69: return "WLFW (wlan firmware)";
	case 400: return "SNS client (SSC sensors)";
	case 4096: return "TFTP (served by tftp_server)";
	}
	return "";
}

static void line(const struct ctrl_pkt *p)
{
	const char *n = svc_name(p->service);

	ps(p->cmd == QRTR_TYPE_DEL_SERVER ? "DEL " : "    ");
	ps("service "); pu(p->service);
	ps(" ver "); pu(p->instance & 0xff);
	ps(" inst "); pu(p->instance >> 8);
	ps(" node "); pu(p->node);
	ps(" port "); pu(p->port);
	if (*n) {
		ps("  "); ps(n);
	}
	ps("\n");
	flush();
}

void start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	struct sockaddr_qrtr sq = { 0 };
	struct ctrl_pkt pkt = { .cmd = QRTR_TYPE_NEW_LOOKUP };
	struct pollfd pfd;
	struct timespec ts = { 2, 0 };
	long wait = 0, fd, n, len = sizeof(sq);
	int count = 0, done = 0;

	if (argc >= 3 && argv[1][0] == '-' && argv[1][1] == 'w') {
		const char *s = argv[2];

		while (*s >= '0' && *s <= '9')
			wait = wait * 10 + (*s++ - '0');
	}

	fd = sc(198, AF_QIPCRTR, SOCK_DGRAM, 0, 0, 0, 0);
	if (fd < 0) {
		ps("qrtrls: no AF_QIPCRTR socket (qrtr.ko loaded?) errno ");
		pu(-fd); ps("\n"); flush();
		sc(93, 1, 0, 0, 0, 0, 0);
	}
	n = sc(204, fd, (long)&sq, (long)&len, 0, 0, 0);	/* getsockname */
	if (n < 0) {
		ps("qrtrls: getsockname errno "); pu(-n); ps("\n"); flush();
		sc(93, 1, 0, 0, 0, 0, 0);
	}
	ps("local node "); pu(sq.node); ps("\n"); flush();
	sq.port = QRTR_PORT_CTRL;
	n = sc(206, fd, (long)&pkt, sizeof(pkt), 0, (long)&sq, sizeof(sq));
	if (n < 0) {
		ps("qrtrls: lookup sendto errno "); pu(-n); ps("\n"); flush();
		sc(93, 1, 0, 0, 0, 0, 0);
	}

	for (;;) {
		pfd.fd = fd;
		pfd.events = 1;		/* POLLIN */
		pfd.revents = 0;
		ts.sec = done ? wait : 2;
		ts.nsec = 0;
		n = sc(73, (long)&pfd, 1, (long)&ts, 0, 0, 0);	/* ppoll */
		if (n <= 0)
			break;
		n = sc(207, fd, (long)&pkt, sizeof(pkt), 0, 0, 0);
		if (n < (long)sizeof(pkt))
			continue;
		if (pkt.cmd != QRTR_TYPE_NEW_SERVER &&
		    pkt.cmd != QRTR_TYPE_DEL_SERVER)
			continue;
		if (!pkt.service && !pkt.instance && !pkt.node && !pkt.port) {
			done = 1;	/* end of the lookup answer */
			if (!wait)
				break;
			ps("-- end of list, watching --\n"); flush();
			continue;
		}
		count++;
		line(&pkt);
	}
	pu(count); ps(" server(s)\n"); flush();
	sc(93, count ? 0 : 3, 0, 0, 0, 0, 0);
}

__asm__(".globl _start\n_start:\n mov x0, sp\n bl start_c\n");
