// SPDX-License-Identifier: GPL-2.0-only
/*
 * Host test of qmi-nas's data / data-probe control flow without a modem: qmi-nas.c is compiled
 * with -include fake-modem.h, which renames the socket/ioctl calls to the fakes below. The fake
 * "modem" answers the QRTR name service and the DMS/WDS/WDA/DPM requests; FAKE_MODE picks which
 * data-port setup it accepts:
 *   ctl   DPM open_port with control port + hardware port on pipes rx 2 / tx 16 (netmgrd recipe)
 *   hw    DPM open_port with the hardware port only (a control port TLV -> invalid-argument)
 *   none  nothing works (WDA/WDS answer invalid-operation / internal as on 2026-11-14)
 * WDA/WDS work only on a client (socket) that opened the port; a closed socket drops it.
 * rtnetlink and the rmnet_ipa ioctls always succeed (GET_EP_PAIR 2/16). Run by userspace/build.sh.
 */
#include <errno.h>
#include <linux/netlink.h>
#include <linux/qrtr.h>
#include <net/if.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define NSOCK 64
#define BASE 1000
static struct fs {
	int used, family, dpm_ok, wda_ok;
	uint8_t q[8][1024];
	size_t ql[8];
	uint32_t qport[8];
	int qn;
} fs[NSOCK];

static const char *mode(void) { const char *m = getenv("FAKE_MODE"); return m ? m : "ctl"; }
static struct fs *F(int fd) { return fd >= BASE && fd < BASE + NSOCK && fs[fd - BASE].used ? &fs[fd - BASE] : NULL; }
static void push(struct fs *f, uint32_t port, const void *b, size_t n)
{
	if (f->qn < 8) {
		memcpy(f->q[f->qn], b, n), f->ql[f->qn] = n, f->qport[f->qn] = port, f->qn++;
	}
}

int fake_socket(int family, int type, int proto)
{
	(void)type, (void)proto;
	for (int i = 0; i < NSOCK; i++)
		if (!fs[i].used) {
			memset(&fs[i], 0, sizeof(fs[i]));
			fs[i].used = 1, fs[i].family = family;
			return BASE + i;
		}
	errno = EMFILE;
	return -1;
}

int fake_close(int fd)
{
	struct fs *f = F(fd);

	if (f)
		f->used = 0;
	return 0;
}

int fake_getsockname(int fd, struct sockaddr *a, socklen_t *l)
{
	struct sockaddr_qrtr *q = (struct sockaddr_qrtr *)a;

	(void)fd;
	memset(q, 0, sizeof(*q));
	q->sq_family = AF_QIPCRTR, q->sq_node = 1, q->sq_port = 77;
	*l = sizeof(*q);
	return 0;
}

static void le16(uint8_t *p, unsigned v) { p[0] = v & 0xff, p[1] = v >> 8 & 0xff; }
static void le32(uint8_t *p, uint32_t v) { le16(p, v & 0xffff), le16(p + 2, v >> 16); }
static uint32_t g32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* find TLV t in a request; NULL if absent */
static const uint8_t *tlv(const uint8_t *b, size_t n, uint8_t t, unsigned *len)
{
	for (size_t o = 7; o + 3 <= n;) {
		unsigned l = b[o + 1] | b[o + 2] << 8;

		if (b[o] == t) {
			*len = l;
			return b + o + 3;
		}
		o += 3 + l;
	}
	return NULL;
}

static void respond(struct fs *f, uint32_t port, const uint8_t *rq, uint16_t err, const uint8_t *extra, size_t el)
{
	uint8_t r[256];
	size_t n = 7;

	r[0] = 2, r[1] = rq[1], r[2] = rq[2], r[3] = rq[3], r[4] = rq[4];
	r[n++] = 2, le16(r + n, 4), n += 2, le16(r + n, err ? 1 : 0), le16(r + n + 2, err), n += 4;
	if (el)
		memcpy(r + n, extra, el), n += el;
	le16(r + 5, (unsigned)(n - 7));
	push(f, port, r, n);
}

ssize_t fake_sendto(int fd, const void *buf, size_t n, int fl, const struct sockaddr *to, socklen_t tl)
{
	struct fs *f = F(fd);
	const uint8_t *b = buf;
	const struct sockaddr_qrtr *sq = (const struct sockaddr_qrtr *)to;
	uint8_t x[64];
	unsigned l;
	const uint8_t *v;
	uint16_t msg;
	uint32_t svc;

	(void)fl, (void)tl;
	if (!f)
		return -1;
	if (f->family == AF_NETLINK) {	/* rtnetlink: ack with error 0 */
		struct { struct nlmsghdr h; struct nlmsgerr e; } a;

		memset(&a, 0, sizeof(a));
		a.h.nlmsg_type = NLMSG_ERROR, a.h.nlmsg_len = sizeof(a);
		push(f, 0, &a, sizeof(a));
		return (ssize_t)n;
	}
	if (sq->sq_port == QRTR_PORT_CTRL) {	/* name service lookup: one server on node 0, port 100+svc */
		uint8_t s[20] = {0}, e[20] = {0};

		svc = g32(b + 4);
		le32(s, QRTR_TYPE_NEW_SERVER), le32(s + 4, svc), le32(s + 8, 1), le32(s + 12, 0), le32(s + 16, 100 + svc);
		le32(e, QRTR_TYPE_NEW_SERVER);
		push(f, QRTR_PORT_CTRL, s, 20), push(f, QRTR_PORT_CTRL, e, 20);
		return (ssize_t)n;
	}
	svc = sq->sq_port - 100, msg = (uint16_t)(b[3] | b[4] << 8);
	if (svc == 0x2f && msg == 0x20) {	/* DPM open port */
		const uint8_t *hw = tlv(b, n, 0x11, &l);
		int ctl = tlv(b, n, 0x10, &l) != NULL, pipes = hw && g32(hw + 9) == 2 && g32(hw + 13) == 16 && g32(hw + 1) == 4 && g32(hw + 5) == 1;

		if (!strcmp(mode(), "ctl") && ctl && pipes)
			f->dpm_ok = 1, respond(f, sq->sq_port, b, 0, NULL, 0);
		else if (!strcmp(mode(), "hw") && !ctl && pipes)
			f->dpm_ok = 1, respond(f, sq->sq_port, b, 0, NULL, 0);
		else
			respond(f, sq->sq_port, b, 0x30, NULL, 0);
	} else if (svc == 0x1a && msg == 0x20) {	/* WDA set data format */
		v = tlv(b, n, 0x17, &l);
		if (f->dpm_ok && v && g32(v) == 4 && g32(v + 4) == 1) {
			const uint8_t *ul = tlv(b, n, 0x12, &l);

			x[0] = 0x11, le16(x + 1, 4), le32(x + 3, 2);
			x[7] = 0x12, le16(x + 8, 4), le32(x + 10, g32(ul));
			x[14] = 0x13, le16(x + 15, 4), le32(x + 17, g32(ul));
			f->wda_ok = 1, respond(f, sq->sq_port, b, 0, x, 21);
		} else {
			respond(f, sq->sq_port, b, 0x46, NULL, 0);
		}
	} else if (svc == 1 && msg == 0xa2) {	/* bind mux */
		respond(f, sq->sq_port, b, f->dpm_ok ? 0 : 3, NULL, 0);
	} else if (svc == 1 && msg == 0x4d) {
		respond(f, sq->sq_port, b, 0, NULL, 0);
	} else if (svc == 1 && msg == 0x20) {	/* start network */
		if (f->dpm_ok && f->wda_ok) {
			x[0] = 1, le16(x + 1, 4), le32(x + 3, 0x1234abcd);
			respond(f, sq->sq_port, b, 0, x, 7);
		} else {
			x[0] = 1, le16(x + 1, 4), le32(x + 3, 0);
			respond(f, sq->sq_port, b, 0x46, x, 7);
		}
	} else if (svc == 1 && msg == 0x2d) {	/* current settings: 10.0.0.2 */
		x[0] = 0x1e, le16(x + 1, 4), le32(x + 3, 0x0a000002);
		respond(f, sq->sq_port, b, 0, x, 7);
	} else {
		respond(f, sq->sq_port, b, 0, NULL, 0);
	}
	return (ssize_t)n;
}

int fake_poll(struct pollfd *p, nfds_t n, int t)
{
	struct fs *f = F(p[0].fd);

	(void)n, (void)t;
	p[0].revents = f && f->qn ? POLLIN : 0;
	return f && f->qn ? 1 : 0;
}

ssize_t fake_recvfrom(int fd, void *buf, size_t n, int fl, struct sockaddr *from, socklen_t *fl2)
{
	struct fs *f = F(fd);
	size_t k;

	(void)fl;
	if (!f || !f->qn) {
		errno = EAGAIN;
		return -1;
	}
	k = f->ql[0] < n ? f->ql[0] : n;
	memcpy(buf, f->q[0], k);
	if (from) {
		struct sockaddr_qrtr *q = (struct sockaddr_qrtr *)from;

		memset(q, 0, sizeof(*q));
		q->sq_family = AF_QIPCRTR, q->sq_node = 0, q->sq_port = f->qport[0];
		*fl2 = sizeof(*q);
	}
	memmove(f->q[0], f->q[1], sizeof(f->q[0]) * 7), memmove(f->ql, f->ql + 1, sizeof(f->ql[0]) * 7);
	memmove(f->qport, f->qport + 1, sizeof(f->qport[0]) * 7);
	f->qn--;
	return (ssize_t)k;
}

ssize_t fake_recv(int fd, void *buf, size_t n, int fl) { return fake_recvfrom(fd, buf, n, fl, NULL, NULL); }

int fake_ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	struct ifreq *ifr;
	uint32_t *e;

	(void)fd, (void)req;
	va_start(ap, req);
	ifr = va_arg(ap, struct ifreq *);
	va_end(ap);
	e = (uint32_t *)ifr->ifr_data;
	if (e[0] == 0x10)
		e[1] = 2, e[2] = 16;
	else if (e[0] == 3)
		e[1] = 1;
	return 0;
}

unsigned fake_if_nametoindex(const char *n) { (void)n; return 5; }
int fake_usleep(unsigned u) { (void)u; return 0; }
