// SPDX-License-Identifier: GPL-2.0-only
/*
 * qmi-nas: a small QMI client over AF_QIPCRTR for the kernel-only modem test (README sections
 * 10-12). No glib, no libqmi, no libqrtr: service lookup through the in-kernel QRTR name service
 * (QRTR_TYPE_NEW_LOOKUP on the control port, as qrtr-lookup does), requests/responses with the
 * codec in qmi.c. Static aarch64 musl build (userspace/build.sh).
 *
 * Safety: nothing here writes any storage. --online makes the modem transmit (cell search,
 * attach attempts / emergency-only scanning without a SIM): normal phone behaviour. UIM is
 * read only (GET_CARD_STATUS); this tool sends nothing that changes the SIM. The data path
 * (DPM open_port, WDA data format, WDS bind/call) only changes the modem's RAM state for the
 * lifetime of this QMI client; the IPA/rmnet ioctls only change kernel state of this boot.
 */
#include "qmi.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/qrtr.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef AF_QIPCRTR
#define AF_QIPCRTR 42
#endif

static int verbose, quiet, timeout_s = -1;
static long want_node = -1;
static int qsock = -1;
static uint32_t local_node;
static uint16_t next_txn = 1;
static uint8_t rsp[65536];
static size_t rsplen;
static struct qmi_msg rmsg;
static volatile sig_atomic_t got_signal;
/* QMI error of the last call(): 0 success, >0 the QMI error code, -1 no/bad response, -2 not sent */
static int last_err = -2;

struct svc {
	int id;
	const char *name;
	int found;
	struct qrtr_server_info srv;
};
static struct svc svcs[] = {
	{QMI_SVC_DMS, "DMS", 0, {0}}, {QMI_SVC_NAS, "NAS", 0, {0}}, {QMI_SVC_UIM, "UIM", 0, {0}},
	{QMI_SVC_WDS, "WDS", 0, {0}}, {QMI_SVC_WDA, "WDA", 0, {0}}, {QMI_SVC_DPM, "DPM", 0, {0}}};
#define NSVC ((int)(sizeof(svcs) / sizeof(svcs[0])))

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static struct svc *svc_get(int id)
{
	for (int i = 0; i < NSVC; i++)
		if (svcs[i].id == id)
			return &svcs[i];
	return NULL;
}

/* ---------------------------------------------------------------- QRTR */

static int ns_lookup(uint32_t service, struct qrtr_server_info *out, int max)
{
	struct sockaddr_qrtr sq;
	socklen_t sl = sizeof(sq);
	struct qrtr_ctrl_pkt pkt;
	uint8_t buf[64];
	int s, n = 0;

	s = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
	if (s < 0) {
		fprintf(stdout, "qmi-nas: socket(AF_QIPCRTR): %s (qrtr.ko not loaded?)\n", strerror(errno));
		return -1;
	}
	if (getsockname(s, (struct sockaddr *)&sq, &sl) || sq.sq_family != AF_QIPCRTR) {
		fprintf(stdout, "qmi-nas: getsockname: %s\n", strerror(errno));
		close(s);
		return -1;
	}
	local_node = sq.sq_node;
	sq.sq_port = QRTR_PORT_CTRL;
	memset(&pkt, 0, sizeof(pkt));
	pkt.cmd = QRTR_TYPE_NEW_LOOKUP;	/* little-endian host */
	pkt.server.service = service;
	pkt.server.instance = 0;	/* ns: instance 0 without filter = every instance */
	if (sendto(s, &pkt, sizeof(pkt), 0, (struct sockaddr *)&sq, sizeof(sq)) < 0) {
		fprintf(stdout, "qmi-nas: name service lookup: sendto: %s\n", strerror(errno));
		close(s);
		return -1;
	}
	for (;;) {
		struct pollfd p = {s, POLLIN, 0};
		struct qrtr_server_info si;
		uint32_t cmd;
		ssize_t l;
		int r;

		r = poll(&p, 1, 2000);
		if (r <= 0) {
			if (r < 0 && errno == EINTR)
				continue;
			fprintf(stdout, "qmi-nas: name service: no end-of-list marker within 2 s (%d servers so far)\n", n);
			break;
		}
		l = recv(s, buf, sizeof(buf), 0);
		if (l < 0) {
			fprintf(stdout, "qmi-nas: name service recv: %s\n", strerror(errno));
			break;
		}
		r = qrtr_parse_ctrl(buf, (size_t)l, &cmd, &si);
		if (r == 0)
			break;
		if (r == 1 && n < max)
			out[n++] = si;
	}
	close(s);
	return n;
}

static void lookup_all(void)
{
	for (int i = 0; i < NSVC; i++) {
		struct qrtr_server_info l[16];
		int n = ns_lookup((uint32_t)svcs[i].id, l, 16), pick = -1;

		for (int k = 0; k < n; k++) {
			if (verbose || n > 1)
				printf("qmi-nas: %s server: node %u port %u version %u instance %u\n", svcs[i].name,
				       l[k].node, l[k].port, l[k].version, l[k].instance);
			if (want_node >= 0) {
				if (l[k].node == (uint32_t)want_node && pick < 0)
					pick = k;
			} else if (pick < 0 || (l[pick].node == local_node && l[k].node != local_node)) {
				pick = k;
			}
		}
		if (pick >= 0) {
			svcs[i].found = 1;
			svcs[i].srv = l[pick];
		}
	}
	printf("qmi-nas: local node %u;", local_node);
	for (int i = 0; i < NSVC; i++) {
		if (svcs[i].found)
			printf(" %s(%d)=node %u port %u v%u", svcs[i].name, svcs[i].id, svcs[i].srv.node, svcs[i].srv.port,
			       svcs[i].srv.version);
		else
			printf(" %s(%d)=NOT REGISTERED", svcs[i].name, svcs[i].id);
	}
	printf("\n");
}

static int need(int id, const char *what)
{
	struct svc *s = svc_get(id);

	if (s && s->found)
		return 1;
	printf("%s: service %d is NOT registered on QRTR (modem not up, or this modem build has no %s): %s not possible\n",
	       s ? s->name : "QMI", id, s ? s->name : "?", what);
	return 0;
}

/*
 * Send one request, wait for its response (matching txn + msg id from the server's node/port).
 * The response is printed and left in rsp/rmsg. Returns 0 success, 1 QMI failure, 2 no/bad
 * response, 3 transport error.
 */
static int call(int id, struct qmi_builder *q, uint16_t txn, uint16_t msg, int tmo)
{
	struct svc *sv = svc_get(id);
	struct sockaddr_qrtr to = {0};
	const char *nm = qmi_msg_name(id, msg);
	double t0 = now(), dl = t0 + tmo;
	int len = qmi_finish(q);

	last_err = -1;
	if (len < 0) {
		printf("%s %s: request too large\n", sv->name, nm);
		return 3;
	}
	if (verbose) {
		printf("%s %s: request -> node %u port %u: ", sv->name, nm, sv->srv.node, sv->srv.port);
		qmi_hex(stdout, q->buf, (size_t)len);
		printf("\n");
	}
	to.sq_family = AF_QIPCRTR;
	to.sq_node = sv->srv.node;
	to.sq_port = sv->srv.port;
	if (sendto(qsock, q->buf, (size_t)len, 0, (struct sockaddr *)&to, sizeof(to)) < 0) {
		printf("%s %s: sendto: %s\n", sv->name, nm, strerror(errno));
		return 3;
	}
	for (;;) {
		struct sockaddr_qrtr from;
		socklen_t fl = sizeof(from);
		struct pollfd p = {qsock, POLLIN, 0};
		double left = dl - now();
		ssize_t l;
		int r;

		if (got_signal) {
			printf("%s %s: interrupted by a signal while waiting\n", sv->name, nm);
			return 2;
		}
		if (left <= 0) {
			printf("%s %s: NO RESPONSE within %d s\n", sv->name, nm, tmo);
			return 2;
		}
		r = poll(&p, 1, left > 1 ? 1000 : (int)(left * 1000) + 1);
		if (r < 0 && errno != EINTR) {
			printf("%s %s: poll: %s\n", sv->name, nm, strerror(errno));
			return 3;
		}
		if (r <= 0)
			continue;
		l = recvfrom(qsock, rsp, sizeof(rsp), 0, (struct sockaddr *)&from, &fl);
		if (l < 0) {
			if (errno == EINTR || errno == EAGAIN)
				continue;
			printf("%s %s: recvfrom: %s%s\n", sv->name, nm, strerror(errno),
			       errno == ENETRESET ? " (modem went down: SSR?)" : "");
			return 3;
		}
		if (from.sq_port == QRTR_PORT_CTRL) {
			struct qrtr_server_info si;
			uint32_t cmd = 0;

			qrtr_parse_ctrl(rsp, (size_t)l, &cmd, &si);
			printf("%s %s: QRTR control packet cmd=%u while waiting\n", sv->name, nm, cmd);
			continue;
		}
		if (from.sq_node != sv->srv.node || from.sq_port != sv->srv.port || l < QMI_HDR_LEN) {
			if (verbose)
				printf("%s %s: ignoring %zd bytes from node %u port %u\n", sv->name, nm, l, from.sq_node, from.sq_port);
			continue;
		}
		if (rsp[0] == QMI_RESPONSE && (rsp[1] | rsp[2] << 8) == txn && (rsp[3] | rsp[4] << 8) == msg) {
			char err[160];
			uint16_t res, e;
			int rc;

			rsplen = (size_t)l;
			if (now() - t0 > 2)
				printf("%s %s: response after %.1f s\n", sv->name, nm, now() - t0);
			if (qmi_parse(rsp, rsplen, &rmsg, err, sizeof(err))) {
				qmi_print(stdout, id, rsp, rsplen, verbose);
				return 2;
			}
			rc = qmi_result(&rmsg, &res, &e) ? 2 : res || e ? 1 : 0;
			last_err = rc == 1 ? e : rc == 0 ? 0 : -1;
			if (quiet)
				return rc;
			qmi_print(stdout, id, rsp, rsplen, verbose);
			/* a failure: also what was asked (requests carry no SIM data; UIM excluded anyway) */
			if (rc == 1 && id != QMI_SVC_UIM && !verbose) {
				printf("%s %s: failed request was: ", sv->name, nm);
				qmi_hex(stdout, q->buf, (size_t)len);
				printf("\n");
			}
			return rc;
		}
		/* indications (we register for none, but print what comes) and stale responses */
		printf("%s (unsolicited, while waiting for %s):\n", sv->name, nm);
		qmi_print(stdout, id, rsp, (size_t)l, verbose);
	}
}

static int simple(int id, uint16_t msg, int tmo)
{
	uint8_t buf[64];
	struct qmi_builder q;
	uint16_t txn = next_txn++;

	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, msg);
	return call(id, &q, txn, msg, tmo);
}

static int tmo(int dflt) { return timeout_s > 0 ? timeout_s : dflt; }

/* ---------------------------------------------------------------- commands */

static int get_mode(void)
{
	const struct qmi_tlv *t;
	int rc;

	if (!need(QMI_SVC_DMS, "reading the operating mode"))
		return 2;
	rc = simple(QMI_SVC_DMS, DMS_GET_OPERATING_MODE, tmo(10));
	if (rc == 0 && (t = qmi_find(&rmsg, 0x01)) && t->len == 1)
		printf("DMS summary: operating mode %u (%s)\n", t->val[0], dms_mode_name(t->val[0]));
	return rc;
}

static int set_mode(unsigned mode)
{
	uint8_t buf[64];
	struct qmi_builder q;
	uint16_t txn = next_txn++;
	int rc;

	if (!need(QMI_SVC_DMS, "setting the operating mode"))
		return 2;
	printf("DMS set_operating_mode: -> %u (%s)%s\n", mode, dms_mode_name(mode),
	       mode == DMS_MODE_ONLINE ? " (the radio starts transmitting: cell search / attach)" : "");
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, DMS_SET_OPERATING_MODE);
	qmi_add_u8(&q, 0x01, (uint8_t)mode);
	rc = call(QMI_SVC_DMS, &q, txn, DMS_SET_OPERATING_MODE, tmo(15));
	if (rc == 0) {
		/* the mode change is asynchronous in the modem: read it back for up to 5 s */
		for (int i = 0; i < 10; i++) {
			const struct qmi_tlv *t;

			if (simple(QMI_SVC_DMS, DMS_GET_OPERATING_MODE, tmo(10)) != 0)
				break;
			t = qmi_find(&rmsg, 0x01);
			if (t && t->len == 1 && t->val[0] == mode) {
				printf("DMS summary: operating mode is now %u (%s)\n", mode, dms_mode_name(mode));
				return 0;
			}
			usleep(500000);
		}
		printf("DMS summary: set accepted but the mode did not read back as %u within 5 s\n", mode);
		return 1;
	}
	return rc;
}

static int card_status(struct uim_status *st, int print)
{
	int rc;

	if (!need(QMI_SVC_UIM, "reading the card status"))
		return 2;
	rc = simple(QMI_SVC_UIM, UIM_GET_CARD_STATUS, tmo(10));
	if (rc)
		return rc;
	if (uim_parse_card_status(&rmsg, st)) {
		printf("UIM summary: card status TLV 0x10 missing or malformed (raw above)\n");
		return 2;
	}
	if (print) {
		if (!st->have_app)
			printf("UIM summary: cards=%u card0=%s: no GW (3GPP) provisioning application%s\n", st->ncards,
			       st->ncards ? uim_card_state_name(st->card_state) : "none",
			       st->ncards && st->card_state == 0 ? " (no SIM inserted)" : "");
		else
			printf("UIM summary: card=%s app-type=%u app=%s pin1=%s pin1-retries=%u puk1-retries=%u upin-replaces-pin1=%u\n",
			       uim_card_state_name(st->card_state), st->app_type, uim_app_state_name(st->app_state),
			       uim_pin_state_name(st->pin1_state), st->pin1_retries, st->puk1_retries, st->upin_replaces_pin1);
	}
	return 0;
}

static int info(void)
{
	int bad = 0, rc;
	struct uim_status st;

	printf("== qmi-nas info\n");
	if (svc_get(QMI_SVC_DMS)->found)
		bad |= get_mode();
	else
		need(QMI_SVC_DMS, "operating mode"), bad |= 2;
	if (svc_get(QMI_SVC_UIM)->found)
		bad |= card_status(&st, 1);
	if (!need(QMI_SVC_NAS, "signal/serving system/system info/RF band"))
		return bad | 2;
	static const uint16_t m[] = {NAS_GET_SIGNAL_INFO, NAS_GET_SERVING_SYSTEM, NAS_GET_SYSTEM_INFO, NAS_GET_RF_BAND_INFO};
	for (size_t i = 0; i < sizeof(m) / sizeof(m[0]); i++) {
		rc = simple(QMI_SVC_NAS, m[i], tmo(10));
		bad |= rc;
	}
	return bad > 3 ? 3 : bad;
}

static int scan(unsigned mask)
{
	uint8_t buf[64];
	struct qmi_builder q;
	uint16_t txn = next_txn++;
	int t = tmo(180), rc;

	if (!need(QMI_SVC_NAS, "network scan"))
		return 2;
	printf("NAS network_scan: started (rat mask 0x%02x%s, timeout %d s; the modem answers when the scan is done)\n",
	       mask, mask ? "" : " = all supported", t);
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, NAS_NETWORK_SCAN);
	if (mask)
		qmi_add_u8(&q, 0x10, (uint8_t)mask);
	rc = call(QMI_SVC_NAS, &q, txn, NAS_NETWORK_SCAN, t);
	return rc;
}

/* poll GET_SERVING_SYSTEM until registered (+ PS attached) or secs */
static int wait_registered(int secs)
{
	double t0 = now();
	int last = -1, reg = 0, ps = 0;

	if (!need(QMI_SVC_NAS, "registration wait"))
		return 2;
	printf("NAS wait-registered: polling serving system every 3 s for up to %d s\n", secs);
	for (;;) {
		const struct qmi_tlv *t;
		int rc, key;

		/* poll quietly: a poll's response is printed only when the state changes */
		quiet = 1;
		rc = simple(QMI_SVC_NAS, NAS_GET_SERVING_SYSTEM, 10);
		quiet = 0;
		t = rc == 0 ? qmi_find(&rmsg, 0x01) : NULL;
		reg = t && t->len >= 4 ? t->val[0] : -1;
		ps = t && t->len >= 4 ? t->val[2] : -1;
		key = rc << 16 | (reg & 0xff) << 8 | (ps & 0xff);
		if (key != last) {
			printf("NAS wait-registered: t=%.0fs\n", now() - t0);
			if (rc == 0 || rc == 1)
				qmi_print(stdout, QMI_SVC_NAS, rsp, rsplen, 0);
			last = key;
		}
		if (reg == 1 && ps == 1)
			break;
		if (got_signal || now() - t0 + 3 > secs)
			break;
		sleep(3);
	}
	printf("NAS wait-registered: %s after %.0f s (registration=%d ps-attach=%d)\n",
	       reg == 1 ? (ps == 1 ? "REGISTERED, PS attached" : "registered, PS NOT attached") : "NOT registered",
	       now() - t0, reg, ps);
	return reg == 1 ? 0 : 4;
}

/* ---------------------------------------------------------------- WDS data call */

/*
 * The embedded (IPA) data path, as the ROM's netmgrd sets it up (its netmgr_config.xml,
 * listitem "lahaina": qmi_dpm_enabled 1, single_qmux_ch_name DATA5_CNTL, phys_net_dev
 * rmnet_ipa0, wda_data_format_enabled 1, QMAPv5 both ways):
 *   1. DPM OPEN_PORT: tell the modem's data port mapper that the data port exists: control port
 *      DATA5_CNTL and the hardware data port endpoint embedded:1 (rmnet_ipa's GET_EPID is the
 *      constant 1) on the IPA pipes of GET_EP_PAIR. Without it the modem has no such port and
 *      WDA/WDS answer invalid-operation / internal (run kx-m2data-p1-p1-215702).
 *   2. WDA SET_DATA_FORMAT on that endpoint (raw IP, QMAP/QMAPv5, DL aggregation limits); the
 *      response carries what the modem applied.
 *   3. rmnet_ipa0 WAN pipes (RMNET_IOCTL_EXTENDED ingress/egress) for that protocol, the rmnet
 *      link (mux id) and RMNET_IOCTL_ADD_MUX_CHANNEL.
 *   4. WDS BIND_MUX_DATA_PORT (endpoint + mux id), SET_IP_FAMILY ipv4, START_NETWORK.
 * All of it on ONE QRTR socket: the modem keys QMI clients by (node, port) and releases a
 * client's state (DPM ports, bindings, calls) when its socket closes.
 */
struct data_opts {
	const char *apn;	/* NULL/"" = the modem's default profile */
	int profile;		/* 3GPP profile index, 0 = not sent */
	int mux;		/* >0: WDS BIND_MUX_DATA_PORT before the call */
	int have_ep;
	uint32_t ep_type, ep_iface;
	int wda;		/* WDA SET_DATA_FORMAT before the call */
	uint32_t wda_llp, wda_ul, wda_dl, wda_dl_dg, wda_dl_sz;
	int dpm;		/* DPM OPEN_PORT first: 0 no, 1 hardware data port only, 2 + control port */
	const char *dpm_ctl;	/* control port name */
	int dpm_swap;		/* hardware port rx/tx = producer/consumer pipe (default consumer/producer) */
	int have_pipes;
	uint32_t pipe_cons, pipe_prod;	/* IPA pipes: GET_EP_PAIR of ipa_dev, or --dpm-pipes */
	int ipfam;		/* WDS SET_IP_FAMILY ipv4 before the call */
	const char *ipa_dev;	/* rmnet_ipa0: WAN pipes set up in this process (once), for the WDA result */
	const char *rmnet;	/* rmnet link created on ipa_dev after the pipes, mux id = mux */
	uint32_t ipa_agg_size, ipa_agg_count;
	const char *apn_fallback;	/* call-failed with the default profile: once more with this APN */
	const char *run;	/* shell command run while the call is up */
	int hold;		/* seconds to keep the call up when no --run */
	int call_tmo;
};

/* what the process configured once (IPA pipes cannot be set up twice) */
static struct {
	int ipa_done, ipa_rc, rmnet_done;
	uint32_t ipa_proto, rmnet_flags;
} dst;

static int rmnet_add(const char *real, const char *name, int mux, uint32_t flags);
static int ipa_setup(const char *dev, uint32_t agg_size, uint32_t agg_count, uint32_t in_flags, uint32_t eg_flags);
static int ipa_ep_pair(const char *dev, uint32_t *cons, uint32_t *prod, int print);
static int ipa_add_mux(const char *dev, int mux, const char *name);

static const char *proto_name(uint32_t p) { return p == WDA_AGG_QMAP ? "qmap" : p == WDA_AGG_QMAPV5 ? "qmapv5" : "?"; }

static void err_str(int e, char *s, size_t n)
{
	if (e == 0)
		snprintf(s, n, "ok");
	else if (e == -1)
		snprintf(s, n, "no-response");
	else if (e == -2)
		snprintf(s, n, "-");
	else
		snprintf(s, n, "0x%02x(%s)", e, qmi_error_name((uint16_t)e));
}

static int dpm_open(const struct data_opts *o)
{
	uint8_t buf[512];
	struct qmi_builder q;
	uint16_t txn = next_txn++;
	uint32_t et = o->have_ep ? o->ep_type : QMI_EP_EMBEDDED, ei = o->have_ep ? o->ep_iface : 1, rx, tx;

	last_err = -1;
	if (!need(QMI_SVC_DPM, "opening the data port"))
		return 2;
	if (!o->have_pipes) {
		printf("DPM open_port: no IPA pipe numbers (GET_EP_PAIR of --ipa failed and no --dpm-pipes): not sent\n");
		return 2;
	}
	rx = o->dpm_swap ? o->pipe_prod : o->pipe_cons;
	tx = o->dpm_swap ? o->pipe_cons : o->pipe_prod;
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, DPM_OPEN_PORT);
	dpm_add_open_port(&q, o->dpm == 2 ? o->dpm_ctl : NULL, et, ei, rx, tx);
	printf("DPM open_port: control port %s%s%s, hardware data port endpoint %u:%u rx-ep %u tx-ep %u (IPA consumer pipe %u, producer pipe %u%s)\n",
	       o->dpm == 2 ? "\"" : "", o->dpm == 2 ? o->dpm_ctl : "(none)", o->dpm == 2 ? "\"" : "", et, ei, rx, tx,
	       o->pipe_cons, o->pipe_prod, o->dpm_swap ? ", swapped" : "");
	return call(QMI_SVC_DPM, &q, txn, DPM_OPEN_PORT, tmo(10));
}

static int wda_set_format(const struct data_opts *o, struct wda_format *got)
{
	uint8_t buf[128];
	struct qmi_builder q;
	uint16_t txn = next_txn++;
	int rc;

	memset(got, 0, sizeof(*got));
	last_err = -1;
	if (!need(QMI_SVC_WDA, "setting the data format"))
		return 2;
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDA_SET_DATA_FORMAT);
	qmi_add_u32(&q, 0x11, o->wda_llp);
	qmi_add_u32(&q, 0x12, o->wda_ul);
	qmi_add_u32(&q, 0x13, o->wda_dl);
	if (o->wda_dl_dg)
		qmi_add_u32(&q, 0x15, o->wda_dl_dg);
	if (o->wda_dl_sz)
		qmi_add_u32(&q, 0x16, o->wda_dl_sz);
	if (o->have_ep)
		qmi_add_ep(&q, 0x17, o->ep_type, o->ep_iface);
	printf("WDA set_data_format: link-layer=%u ul-agg=%u dl-agg=%u dl-max-datagrams=%u dl-max-size=%u endpoint=%s%u:%u\n",
	       o->wda_llp, o->wda_ul, o->wda_dl, o->wda_dl_dg, o->wda_dl_sz, o->have_ep ? "" : "(none) ", o->ep_type, o->ep_iface);
	rc = call(QMI_SVC_WDA, &q, txn, WDA_SET_DATA_FORMAT, tmo(10));
	if (rc == 0) {
		wda_parse_format(&rmsg, got);
		printf("WDA summary: the modem applied link-layer=%d ul-agg=%d dl-agg=%d dl-max %d datagrams / %d bytes, ul-max %d / %d (-1 = not reported)\n",
		       got->have & 1 ? (int)got->llp : -1, got->have & 2 ? (int)got->ul : -1, got->have & 4 ? (int)got->dl : -1,
		       got->have & 8 ? (int)got->dl_dg : -1, got->have & 16 ? (int)got->dl_sz : -1,
		       got->have & 32 ? (int)got->ul_dg : -1, got->have & 64 ? (int)got->ul_sz : -1);
	}
	return rc;
}

static int wds_bind_mux(const struct data_opts *o)
{
	uint8_t buf[64];
	struct qmi_builder q;
	uint16_t txn = next_txn++;

	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDS_BIND_MUX_DATA_PORT);
	if (o->have_ep)
		qmi_add_ep(&q, 0x10, o->ep_type, o->ep_iface);
	qmi_add_u8(&q, 0x11, (uint8_t)o->mux);
	printf("WDS bind_mux_data_port: mux-id=%d endpoint=%s%u:%u\n", o->mux, o->have_ep ? "" : "(none) ", o->ep_type, o->ep_iface);
	return call(QMI_SVC_WDS, &q, txn, WDS_BIND_MUX_DATA_PORT, tmo(10));
}

static int wds_set_ipfam(void)
{
	uint8_t buf[32];
	struct qmi_builder q;
	uint16_t txn = next_txn++;

	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDS_SET_IP_FAMILY);
	qmi_add_u8(&q, 0x01, 4);
	printf("WDS set_ip_family: ipv4\n");
	return call(QMI_SVC_WDS, &q, txn, WDS_SET_IP_FAMILY, tmo(10));
}

/* rmnet_ipa0 WAN pipes + the rmnet link, for the aggregation protocol the modem applied (once) */
static int data_ipa_up(const struct data_opts *o, uint32_t proto)
{
	uint32_t in = 0x26, eg = 0, rf = 3;	/* qmap: ingress MAP|DEAGG|AGG_DATA, plain egress; rmnet deagg + MAP commands */
	int mux = o->mux > 0 ? o->mux : 1;

	if (!o->ipa_dev)
		return 0;
	if (dst.ipa_done) {
		if (proto != dst.ipa_proto)
			printf("qmi-nas data: WARNING: IPA pipes already set up for %s (%u), the modem now applied %u: the pipes cannot be set up twice\n",
			       proto_name(dst.ipa_proto), dst.ipa_proto, proto);
		return dst.ipa_rc;
	}
	if (proto == WDA_AGG_QMAPV5) {
		in |= 0x10;		/* RMNET_IOCTL_INGRESS_FORMAT_CHECKSUM: IPA >= v4.5 DL QMAPv5 csum header, hdr_len 8 */
		eg = 0x10;		/* RMNET_IOCTL_EGRESS_FORMAT_CHECKSUM: UL csum header, hdr_len 8 */
		rf |= 0x20 | 0x40;	/* Qualcomm rmnet_core RMNET_PRIV_FLAGS_{INGRESS,EGRESS}_MAP_CKSUMV5 */
	} else if (proto != WDA_AGG_QMAP) {
		printf("qmi-nas data: aggregation protocol %u is neither qmap (5) nor qmapv5 (9): pipes set up as qmap\n", proto);
	}
	dst.ipa_done = 1, dst.ipa_proto = proto, dst.rmnet_flags = rf;
	printf("qmi-nas data: IPA WAN pipes on %s for %s (%u): ingress 0x%x agg %u bytes / %u packets, egress 0x%x; rmnet flags 0x%x\n",
	       o->ipa_dev, proto_name(proto), proto, in, o->ipa_agg_size, o->ipa_agg_count, eg, rf);
	dst.ipa_rc = ipa_setup(o->ipa_dev, o->ipa_agg_size, o->ipa_agg_count, in, eg);
	if (o->rmnet && !dst.rmnet_done && rmnet_add(o->ipa_dev, o->rmnet, mux, rf) == 0) {
		dst.rmnet_done = 1;
		ipa_add_mux(o->ipa_dev, mux, o->rmnet);	/* as netmgrd; failure is not fatal */
	}
	return dst.ipa_rc;
}

static void on_signal(int s) { got_signal = s; }

static int run_child(const char *cmd, const struct wds_settings *ws, uint32_t handle, int mux)
{
	char e[16][64];
	pid_t pid;
	int status = 0;

	fflush(stdout);
	pid = fork();
	if (pid < 0) {
		printf("qmi-nas data: fork: %s\n", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		const struct { const char *n; unsigned bit; uint32_t v; } f[] = {
			{"QMI_IP", 1, ws->ip}, {"QMI_GW", 2, ws->gw}, {"QMI_MASK", 4, ws->mask},
			{"QMI_DNS1", 8, ws->dns1}, {"QMI_DNS2", 16, ws->dns2}};
		int k = 0;

		for (size_t i = 0; i < sizeof(f) / sizeof(f[0]); i++) {
			char a[20];

			ipv4_str(f[i].v, a, sizeof(a));
			if (ws->have & f[i].bit)
				setenv(f[i].n, a, 1);
		}
		if (ws->have & 4) {
			int p = 0;

			while (p < 32 && (ws->mask & (0x80000000u >> p)))
				p++;
			snprintf(e[k], sizeof(e[k]), "%d", p), setenv("QMI_PREFIX", e[k++], 1);
		}
		if (ws->have & 32)
			snprintf(e[k], sizeof(e[k]), "%u", (unsigned)ws->mtu), setenv("QMI_MTU", e[k++], 1);
		snprintf(e[k], sizeof(e[k]), "0x%08x", (unsigned)handle), setenv("QMI_HANDLE", e[k++], 1);
		snprintf(e[k], sizeof(e[k]), "%d", mux), setenv("QMI_MUX", e[k++], 1);
		if (dst.ipa_done) {
			snprintf(e[k], sizeof(e[k]), "%s", proto_name(dst.ipa_proto)), setenv("QMI_QMAP", e[k++], 1);
			snprintf(e[k], sizeof(e[k]), "0x%x", dst.rmnet_flags), setenv("QMI_RMNET_FLAGS", e[k++], 1);
		}
		execl("/bin/busybox", "sh", "-c", cmd, (char *)NULL);
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	for (;;) {
		pid_t r = waitpid(pid, &status, 0);

		if (r == pid)
			break;
		if (r < 0 && errno == EINTR && got_signal) {
			kill(pid, SIGTERM);
			got_signal = 0;
			continue;
		}
		if (r < 0 && errno != EINTR)
			break;
	}
	printf("qmi-nas data: --run command exited with %d\n", WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

/* START_NETWORK; 0 + *handle = call up */
static int wds_start(const struct data_opts *o, const char *apn, uint32_t *handle)
{
	uint8_t buf[512];
	struct qmi_builder q;
	const struct qmi_tlv *t;
	uint16_t txn = next_txn++;
	int rc;

	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDS_START_NETWORK);
	if (apn && *apn)
		qmi_add_tlv(&q, 0x14, apn, (uint16_t)strlen(apn));	/* top-level string: no length prefix */
	qmi_add_u8(&q, 0x19, 4);	/* IP family IPv4 */
	if (o->profile > 0)
		qmi_add_u8(&q, 0x31, (uint8_t)o->profile);
	printf("WDS start_network: apn=%s%s%s ip-family=4 profile=%d (timeout %d s)\n", apn && *apn ? "\"" : "",
	       apn && *apn ? apn : "(modem default)", apn && *apn ? "\"" : "", o->profile, o->call_tmo);
	rc = call(QMI_SVC_WDS, &q, txn, WDS_START_NETWORK, o->call_tmo);
	if (rc != 0)
		return rc;
	t = qmi_find(&rmsg, 0x01);
	if (!t || t->len != 4) {
		printf("WDS summary: start_network succeeded but has no packet data handle (TLV 0x01)\n");
		last_err = -1;
		return 2;
	}
	*handle = (uint32_t)t->val[0] | (uint32_t)t->val[1] << 8 | (uint32_t)t->val[2] << 16 | (uint32_t)t->val[3] << 24;
	return 0;
}

/* call is up: settings, --run / --hold, STOP_NETWORK */
static int data_up(const struct data_opts *o, uint32_t handle)
{
	uint8_t buf[64];
	struct qmi_builder q;
	struct wds_settings ws;
	uint16_t txn;
	int rc, crc = 0;

	printf("WDS summary: data call UP, packet data handle 0x%08x\n", handle);
	txn = next_txn++;
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDS_GET_CURRENT_SETTINGS);
	qmi_add_u32(&q, 0x10, 0xA31F);	/* profile id+name, pdp type, apn, dns, ip, gateway, mtu, ip family */
	memset(&ws, 0, sizeof(ws));
	if (call(QMI_SVC_WDS, &q, txn, WDS_GET_CURRENT_SETTINGS, tmo(10)) == 0 && wds_parse_settings(&rmsg, &ws) == 0) {
		char a[20], g[20], d1[20], d2[20];

		ipv4_str(ws.ip, a, sizeof(a)), ipv4_str(ws.gw, g, sizeof(g));
		ipv4_str(ws.dns1, d1, sizeof(d1)), ipv4_str(ws.dns2, d2, sizeof(d2));
		printf("WDS summary: IPv4 %s gateway %s dns %s %s mtu %u\n", a, ws.have & 2 ? g : "-", ws.have & 8 ? d1 : "-",
		       ws.have & 16 ? d2 : "-", ws.have & 32 ? (unsigned)ws.mtu : 0);
	} else {
		printf("WDS summary: no IPv4 settings from get_current_settings\n");
	}
	simple(QMI_SVC_WDS, WDS_GET_PACKET_SERVICE_STATUS, tmo(10));

	if (o->run)
		crc = run_child(o->run, &ws, handle, o->mux);
	else if (o->hold > 0) {
		printf("qmi-nas data: holding the call for %d s\n", o->hold);
		for (int i = 0; i < o->hold && !got_signal; i++)
			sleep(1);
	}
	got_signal = 0;

	txn = next_txn++;
	qmi_begin(&q, buf, sizeof(buf), QMI_REQUEST, txn, WDS_STOP_NETWORK);
	qmi_add_u32(&q, 0x01, handle);
	printf("WDS stop_network: handle 0x%08x\n", handle);
	rc = call(QMI_SVC_WDS, &q, txn, WDS_STOP_NETWORK, tmo(15));
	printf("WDS summary: stop_network %s\n", rc == 0 ? "ok" : "FAILED (closing the QRTR socket ends the call anyway)");
	return crc ? 5 : rc;
}

/* per-stage outcome of one attempt (last_err values) */
struct attempt_res {
	int dpm, wda, bind, ipfam, start, up;
	uint32_t proto;
};

/* one full attempt on the current socket; 0 = call came up (and --run passed) */
static int data_attempt(const struct data_opts *o, struct attempt_res *ar)
{
	struct wda_format got;
	uint32_t handle = 0;
	int rc;

	*ar = (struct attempt_res){-2, -2, -2, -2, -2, 0, o->wda_dl};
	if (!need(QMI_SVC_WDS, "a data call"))
		return 2;
	if (o->dpm) {
		dpm_open(o);
		ar->dpm = last_err;
		if (ar->dpm)
			printf("qmi-nas data: DPM open_port failed: continuing\n");
	}
	if (o->wda) {
		rc = wda_set_format(o, &got);
		ar->wda = last_err;
		if (rc == 0) {
			uint32_t p = got.have & 4 ? got.dl : o->wda_dl;

			if ((got.have & 2) && got.ul != p)
				printf("qmi-nas data: the modem applied ul %u but dl %u: the IPA pipes follow dl\n", got.ul, p);
			ar->proto = p;
			data_ipa_up(o, p);
		} else {
			printf("qmi-nas data: WDA set_data_format failed: continuing (the call itself may still come up)\n");
		}
	}
	if (o->mux > 0) {
		wds_bind_mux(o);
		ar->bind = last_err;
		if (ar->bind)
			printf("qmi-nas data: WDS bind_mux_data_port failed: continuing\n");
	}
	if (o->ipfam) {
		wds_set_ipfam();
		ar->ipfam = last_err;
	}
	rc = wds_start(o, o->apn, &handle);
	if (rc == 1 && last_err == 14 && !(o->apn && *o->apn) && o->apn_fallback && *o->apn_fallback) {
		printf("qmi-nas data: call-failed with the modem's default profile: once more with apn \"%s\"\n", o->apn_fallback);
		rc = wds_start(o, o->apn_fallback, &handle);
	}
	ar->start = last_err;
	if (rc != 0) {
		printf("WDS summary: data call NOT established (rc=%d; call-end reason above if the modem sent one)\n", rc);
		return rc;
	}
	ar->up = 1;
	if (o->ipa_dev && !dst.ipa_done) {
		printf("qmi-nas data: call up without a WDA result: IPA pipes for the requested protocol\n");
		data_ipa_up(o, o->wda_dl ? o->wda_dl : WDA_AGG_QMAP);
	}
	return data_up(o, handle);
}

static void data_prepare(struct data_opts *o)
{
	if (o->ipa_dev && !o->have_pipes) {
		uint32_t c, p;

		if (ipa_ep_pair(o->ipa_dev, &c, &p, 1) == 0)
			o->have_pipes = 1, o->pipe_cons = c, o->pipe_prod = p;
	}
}

static int data_call(struct data_opts *o)
{
	struct attempt_res ar;

	data_prepare(o);
	return data_attempt(o, &ar);
}

/* a fresh QRTR socket = a new QMI client: the modem drops the old one's ports, bindings, calls */
static int reopen_qsock(void)
{
	if (qsock >= 0)
		close(qsock);
	usleep(500000);
	qsock = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
	if (qsock < 0) {
		printf("qmi-nas: socket(AF_QIPCRTR): %s\n", strerror(errno));
		return -1;
	}
	return 0;
}

/*
 * data-probe: the endpoint/port variants, one at a time, each on a fresh QMI client, until a
 * call comes up. Phase 1 runs them before the IPA pipes exist (the pipes are set up by the first
 * WDA success, for the protocol the modem applied). If no call came up and some variants ran
 * before the pipes existed, phase 2 sets the pipes up (requested protocol) and runs those again.
 */
struct variant {
	int dpm, swap, have_ep;
	int iface;		/* -1 = the IPA consumer pipe number */
	int alt_proto;		/* the other QMAP version than requested */
	const char *what;
};
static const struct variant variants[] = {
	{2, 0, 1, 1, 0, "netmgrd recipe: DPM control port + hardware data port, endpoint embedded:1 (GET_EPID)"},
	{2, 0, 1, 1, 1, "as 1 with the other QMAP version (the ROM's netmgr_config uses qmapv5 = 9)"},
	{1, 0, 1, 1, 0, "DPM hardware data port only (no control port), endpoint embedded:1"},
	{2, 1, 1, 1, 0, "as 1 with the hardware port's rx/tx pipes swapped"},
	{2, 0, 1, -1, 0, "endpoint embedded:<IPA consumer pipe> (iface = pipe number), DPM on the same"},
	{2, 0, 1, 0, 0, "endpoint embedded:0, DPM on the same"},
	{0, 0, 1, 1, 0, "no DPM, endpoint embedded:1 (the request that failed on 2026-11-14: baseline)"},
	{0, 0, 0, 0, 0, "no DPM, no endpoint TLVs (the modem's default port)"},
};
#define NVARIANT ((int)(sizeof(variants) / sizeof(variants[0])))

static int data_probe(struct data_opts *base, int budget)
{
	struct attempt_res res[2][NVARIANT];
	int tried[2][NVARIANT] = {{0}}, before_ipa[NVARIANT] = {0}, n = 0, rc = 2, won = 0;
	uint32_t req = base->wda_dl ? base->wda_dl : WDA_AGG_QMAP, alt = req == WDA_AGG_QMAPV5 ? WDA_AGG_QMAP : WDA_AGG_QMAPV5;
	double t0 = now();

	data_prepare(base);
	printf("== data-probe: %d variants, requested %s (%u), budget %d s, IPA %s, pipes %s%u/%u\n", NVARIANT, proto_name(req), req,
	       budget, base->ipa_dev ? base->ipa_dev : "(not configured here)", base->have_pipes ? "" : "UNKNOWN ",
	       base->pipe_cons, base->pipe_prod);
	for (int ph = 0; ph < 2 && !won; ph++) {
		if (ph == 1) {
			int any = 0;

			for (int i = 0; i < NVARIANT; i++)
				any |= tried[0][i] && before_ipa[i];
			if (!any || !base->ipa_dev)
				break;
			if (!dst.ipa_done) {
				printf("== data-probe: phase 2: IPA pipes first (requested %s), then the variants again\n", proto_name(req));
				data_ipa_up(base, req);
			} else {
				printf("== data-probe: phase 2: the variants that ran before the IPA pipes existed, again\n");
			}
		}
		for (int i = 0; i < NVARIANT && !won; i++) {
			const struct variant *v = &variants[i];
			struct data_opts o = *base;
			uint32_t want = v->alt_proto ? alt : req;

			if (ph == 1 && !(tried[0][i] && before_ipa[i]))
				continue;
			if (got_signal || now() - t0 > budget) {
				printf("== data-probe: %s: no further attempts\n", got_signal ? "signal" : "budget used up");
				ph = 2;
				break;
			}
			if (dst.ipa_done && want != dst.ipa_proto) {
				printf("== data-probe: attempt %d.%d skipped: IPA pipes are set up for %s, this variant asks %s\n", ph + 1, i + 1,
				       proto_name(dst.ipa_proto), proto_name(want));
				continue;
			}
			o.dpm = v->dpm, o.dpm_swap = v->swap, o.have_ep = v->have_ep, o.ep_type = QMI_EP_EMBEDDED;
			o.ep_iface = v->iface >= 0 ? (uint32_t)v->iface : o.pipe_cons;
			o.wda_ul = o.wda_dl = want;
			if (v->iface < 0 && !o.have_pipes) {
				printf("== data-probe: attempt %d.%d skipped: no IPA pipe numbers\n", ph + 1, i + 1);
				continue;
			}
			if (reopen_qsock())
				return 3;
			if (ph == 0)
				before_ipa[i] = !dst.ipa_done;
			printf("== data-probe: attempt %d.%d (t=%.0fs): %s [dpm=%s ep=%s%u:%u %s]\n", ph + 1, i + 1, now() - t0, v->what,
			       v->dpm == 2 ? "control+hw" : v->dpm == 1 ? "hw" : "none", o.have_ep ? "" : "none/", o.ep_type, o.ep_iface,
			       proto_name(want));
			rc = data_attempt(&o, &res[ph][i]);
			tried[ph][i] = 1;
			n++;
			won = res[ph][i].up;
			printf("== data-probe: attempt %d.%d %s\n", ph + 1, i + 1, won ? (rc == 0 ? "SUCCESS: call up, --run ok" : "call UP, --run failed") : "failed");
		}
	}
	printf("== data-probe summary (%d attempts, %.0f s): stage results ok / QMI error / no-response / - = not sent\n", n, now() - t0);
	for (int ph = 0; ph < 2; ph++)
		for (int i = 0; i < NVARIANT; i++) {
			const struct attempt_res *a = &res[ph][i];
			char d[40], w[40], b[40], f[40], s[40];

			if (!tried[ph][i])
				continue;
			err_str(a->dpm, d, sizeof(d)), err_str(a->wda, w, sizeof(w)), err_str(a->bind, b, sizeof(b));
			err_str(a->ipfam, f, sizeof(f)), err_str(a->start, s, sizeof(s));
			printf("== data-probe summary: %d.%d dpm=%s wda=%s bind=%s ip-family=%s start=%s%s | %s\n", ph + 1, i + 1, d, w, b, f, s,
			       a->up ? " CALL-UP" : "", variants[i].what);
		}
	if (!won)
		printf("== data-probe: NO variant brought a call up\n");
	return won ? rc : (rc ? rc : 2);
}

/* ---------------------------------------------------------------- rmnet links over rtnetlink */

static void nla_put(uint8_t *b, size_t *off, uint16_t type, const void *d, size_t l)
{
	struct nlattr *a = (struct nlattr *)(b + *off);

	a->nla_type = type;
	a->nla_len = (uint16_t)(NLA_HDRLEN + l);
	if (l)
		memcpy(b + *off + NLA_HDRLEN, d, l);
	*off += NLA_ALIGN(a->nla_len);
}

static int rtnl_send(void *msg, size_t len, const char *what)
{
	struct sockaddr_nl sa = {.nl_family = AF_NETLINK};
	uint8_t ack[1024];
	int s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	ssize_t r;

	if (s < 0) {
		printf("rmnet: netlink socket: %s\n", strerror(errno));
		return 3;
	}
	if (sendto(s, msg, len, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		printf("rmnet: %s: sendto: %s\n", what, strerror(errno));
		close(s);
		return 3;
	}
	r = recv(s, ack, sizeof(ack), 0);
	close(s);
	if (r >= (ssize_t)(NLMSG_HDRLEN + sizeof(int)) && ((struct nlmsghdr *)ack)->nlmsg_type == NLMSG_ERROR) {
		int e = *(int *)(ack + NLMSG_HDRLEN);

		printf("rmnet: %s: %s\n", what, e ? strerror(-e) : "ok");
		return e ? 1 : 0;
	}
	printf("rmnet: %s: no netlink ack\n", what);
	return 2;
}

/* ip link add link <real> name <name> type rmnet mux_id <id> (+ ingress/egress flags) */
static int rmnet_add(const char *real, const char *name, int mux, uint32_t flags)
{
	uint8_t b[512] = {0};
	struct nlmsghdr *h = (struct nlmsghdr *)b;
	struct ifinfomsg *ifi = (struct ifinfomsg *)(b + NLMSG_HDRLEN);
	size_t off = NLMSG_HDRLEN + NLMSG_ALIGN(sizeof(*ifi)), li, di;
	unsigned idx = if_nametoindex(real);
	uint16_t m = (uint16_t)mux;
	struct ifla_rmnet_flags fl = {flags, 0xffffffffu};
	char what[96];

	if (!idx) {
		printf("rmnet: no interface %s\n", real);
		return 2;
	}
	h->nlmsg_type = RTM_NEWLINK;
	h->nlmsg_flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL | NLM_F_ACK;
	h->nlmsg_seq = 1;
	ifi->ifi_family = AF_UNSPEC;
	nla_put(b, &off, IFLA_LINK, &idx, 4);
	nla_put(b, &off, IFLA_IFNAME, name, strlen(name) + 1);
	li = off;
	nla_put(b, &off, IFLA_LINKINFO, NULL, 0);
	nla_put(b, &off, IFLA_INFO_KIND, "rmnet", 6);
	di = off;
	nla_put(b, &off, IFLA_INFO_DATA, NULL, 0);
	nla_put(b, &off, IFLA_RMNET_MUX_ID, &m, 2);
	nla_put(b, &off, IFLA_RMNET_FLAGS, &fl, sizeof(fl));
	((struct nlattr *)(b + di))->nla_len = (uint16_t)(off - di);
	((struct nlattr *)(b + li))->nla_len = (uint16_t)(off - li);
	h->nlmsg_len = (uint32_t)off;
	snprintf(what, sizeof(what), "add %s on %s mux %d flags 0x%x", name, real, mux, flags);
	return rtnl_send(b, off, what);
}

static int rmnet_del(const char *name)
{
	uint8_t b[128] = {0};
	struct nlmsghdr *h = (struct nlmsghdr *)b;
	struct ifinfomsg *ifi = (struct ifinfomsg *)(b + NLMSG_HDRLEN);
	unsigned idx = if_nametoindex(name);
	char what[64];

	if (!idx) {
		printf("rmnet: no interface %s\n", name);
		return 2;
	}
	h->nlmsg_type = RTM_DELLINK;
	h->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	h->nlmsg_seq = 1;
	h->nlmsg_len = NLMSG_HDRLEN + NLMSG_ALIGN(sizeof(*ifi));
	ifi->ifi_family = AF_UNSPEC;
	ifi->ifi_index = (int)idx;
	snprintf(what, sizeof(what), "delete %s", name);
	return rtnl_send(b, h->nlmsg_len, what);
}

/* ---------------------------------------------------------------- rmnet_ipa0 data format ioctls */

/*
 * The IPA WAN netdev (rmnet_ipa0, ipam.ko rmnet_ipa.c) sets up its APPS_WAN pipes only when
 * userspace (netmgrd on Android) sends these RMNET_IOCTL_EXTENDED sub-commands; layout of
 * struct rmnet_ioctl_extended_s from msm_rmnet.h: u32 sub-command + 20-byte union (24 bytes).
 */
#define RMNET_IOCTL_EXTENDED_ 0x89FD
#define RMNET_GET_EPID_ 3
#define RMNET_ADD_MUX_CHANNEL_ 5
#define RMNET_SET_EGRESS_ 6
#define RMNET_SET_INGRESS_ 7
#define RMNET_GET_EP_PAIR_ 0x10
struct rmnet_ext_ {
	uint32_t cmd;
	uint32_t u[5];	/* data/__data @4, agg_size @8, agg_count @12; ep pair: consumer @4, producer @8;
			 * mux channel: mux_id @4, vchannel_name[16] @8 */
};
_Static_assert(sizeof(struct rmnet_ext_) == 24, "rmnet_ioctl_extended_s is 24 bytes");

static int rmnet_ext_ioctl(const char *dev, struct rmnet_ext_ *e, const char *what)
{
	struct ifreq ifr;
	int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0), r;

	if (fd < 0) {
		printf("ipa: socket: %s\n", strerror(errno));
		return 1;
	}
	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", dev);
	ifr.ifr_data = (void *)e;
	r = ioctl(fd, RMNET_IOCTL_EXTENDED_, &ifr);
	if (r < 0)
		printf("ipa: %s on %s: %s\n", what, dev, strerror(errno));
	close(fd);
	return r < 0;
}

/* GET_EP_PAIR: consumer = APPS_WAN_PROD (AP -> IPA), producer = APPS_WAN_CONS (IPA -> AP) */
static int ipa_ep_pair(const char *dev, uint32_t *cons, uint32_t *prod, int print)
{
	struct rmnet_ext_ e;

	memset(&e, 0, sizeof(e));
	e.cmd = RMNET_GET_EP_PAIR_;
	if (!if_nametoindex(dev)) {
		printf("ipa: no interface %s (ipam rmnet_ipa not probed?)\n", dev);
		return 2;
	}
	if (rmnet_ext_ioctl(dev, &e, "GET_EP_PAIR"))
		return 1;
	*cons = e.u[0], *prod = e.u[1];
	if (print)
		printf("ipa-setup: %s endpoint pair: consumer pipe %u producer pipe %u\n", dev, e.u[0], e.u[1]);
	memset(&e, 0, sizeof(e));
	e.cmd = RMNET_GET_EPID_;
	if (print && !rmnet_ext_ioctl(dev, &e, "GET_EPID"))
		printf("ipa-setup: %s endpoint id (GET_EPID, the iface number netmgrd uses): %u\n", dev, e.u[0]);
	return 0;
}

/* RMNET_IOCTL_ADD_MUX_CHANNEL: netmgrd registers every rmnet_data mux with the IPA WAN driver */
static int ipa_add_mux(const char *dev, int mux, const char *name)
{
	struct rmnet_ext_ e;
	int r;

	memset(&e, 0, sizeof(e));
	e.cmd = RMNET_ADD_MUX_CHANNEL_;
	e.u[0] = (uint32_t)mux;
	snprintf((char *)&e.u[1], 16, "%s", name);
	r = rmnet_ext_ioctl(dev, &e, "ADD_MUX_CHANNEL");
	printf("ipa-setup: %s ADD_MUX_CHANNEL mux %d \"%s\": %s\n", dev, mux, name, r ? "FAILED (continuing)" : "ok");
	return r;
}

static int ipa_setup(const char *dev, uint32_t agg_size, uint32_t agg_count, uint32_t in_flags, uint32_t eg_flags)
{
	struct rmnet_ext_ e;
	uint32_t c, p;
	int rc = 0;

	if (!if_nametoindex(dev)) {
		printf("ipa-setup: no interface %s (ipam rmnet_ipa not probed?)\n", dev);
		return 2;
	}
	memset(&e, 0, sizeof(e));
	e.cmd = RMNET_SET_EGRESS_;
	e.u[0] = eg_flags;
	rc |= rmnet_ext_ioctl(dev, &e, "SET_EGRESS_DATA_FORMAT");
	printf("ipa-setup: %s egress format 0x%x: %s\n", dev, eg_flags, rc ? "FAILED" : "ok");
	memset(&e, 0, sizeof(e));
	e.cmd = RMNET_SET_INGRESS_;
	e.u[0] = in_flags, e.u[1] = agg_size, e.u[2] = agg_count;
	if (rmnet_ext_ioctl(dev, &e, "SET_INGRESS_DATA_FORMAT"))
		rc |= 1;
	else
		printf("ipa-setup: %s ingress format 0x%x agg_size %u agg_count %u: ok\n", dev, in_flags, agg_size, agg_count);
	ipa_ep_pair(dev, &c, &p, 1);
	return rc;
}

/* ---------------------------------------------------------------- main */

static int svc_by_name(const char *s)
{
	static const struct { const char *n; int id; } t[] = {
		{"dms", QMI_SVC_DMS}, {"nas", QMI_SVC_NAS}, {"uim", QMI_SVC_UIM}, {"wds", QMI_SVC_WDS}, {"wda", QMI_SVC_WDA},
		{"dpm", QMI_SVC_DPM}};

	for (size_t i = 0; i < sizeof(t) / sizeof(t[0]); i++)
		if (!strcmp(s, t[i].n))
			return t[i].id;
	return (int)strtol(s, NULL, 0);
}

static void usage(void)
{
	printf("usage: qmi-nas [-v] [-t <s>] [-n <node>] <command>\n"
	       "  lookup                   QRTR servers of DMS 2, NAS 3, UIM 11, WDS 1, WDA 0x1A, DPM 0x2F\n"
	       "  info                     DMS operating mode, UIM card status, NAS signal info,\n"
	       "                           serving system, system info, RF band info\n"
	       "  mode                     DMS operating mode\n"
	       "  --online                 DMS set ONLINE (the radio transmits: cell search/attach)\n"
	       "  --low-power              DMS set LOW_POWER (radio off)\n"
	       "  wait-registered [<s>]    poll serving system until registered + PS attached (default 90 s)\n"
	       "  card                     UIM card status (read only)\n"
	       "  scan [gsm,umts,lte,tds,nr5g]  NAS network scan (default timeout 180 s)\n"
	       "  data [options]           one data call, all steps on one QMI client:\n"
	       "       [--dpm ctl|hw] [--dpm-ctl NAME] [--dpm-pipes CONS:PROD] [--dpm-swap]  DPM open_port first\n"
	       "       [--wda LLP:UL:DL:DLDG:DLSZ] [--ep TYPE:IFACE] [--mux N] [--ipfam]\n"
	       "       [--ipa DEV [--rmnet NAME] [--ipa-agg SIZE:COUNT]]  IPA pipes + rmnet link after WDA\n"
	       "       [--apn A] [--apn-fallback A] [--profile N] [--run CMD | --hold S] [--call-timeout S]\n"
	       "                           CMD runs with QMI_IP/QMI_GW/QMI_PREFIX/QMI_DNS1/QMI_MTU/QMI_MUX/QMI_QMAP set\n"
	       "  data-probe [data options] [--budget S]  the endpoint/port variants one at a time (fresh QMI\n"
	       "                           client each) until a call comes up; defaults: --wda 2:5:5:32:16384 --mux 1\n"
	       "                           --ipfam --apn-fallback internet --call-timeout 45 --budget 420\n"
	       "  wda LLP:UL:DL:DLDG:DLSZ [--ep TYPE:IFACE]  WDA set data format alone (e.g. 2:5:5:32:16384 --ep 4:1)\n"
	       "  ipa-setup <dev> [agg_size agg_count in_flags eg_flags]  rmnet_ipa0 WAN pipes: RMNET_IOCTL_EXTENDED\n"
	       "                           SET_EGRESS/SET_INGRESS_DATA_FORMAT (defaults 16384 32 0x26 0), GET_EP_PAIR, GET_EPID\n"
	       "  ipa-pair <dev>           GET_EP_PAIR + GET_EPID only (changes nothing)\n"
	       "  rmnet-add <real> <name> <mux> [flags]   rmnet link over rtnetlink (ip link ... type rmnet)\n"
	       "  rmnet-del <name>\n"
	       "  decode <dms|nas|uim|wds|wda|dpm> <hex>  offline: print a raw QMI message\n"
	       "exit: 0 ok, 1 QMI error result, 2 service missing / no response, 3 transport error,\n"
	       "      4 not registered, 5 --run command failed, 64 usage\n");
}

static int parse_pair(const char *s, uint32_t *a, uint32_t *b)
{
	unsigned x, y;

	if (sscanf(s, "%u:%u", &x, &y) != 2)
		return -1;
	*a = x, *b = y;
	return 0;
}

/* data / data-probe options; -1 = usage error */
static int parse_data_opts(int argc, char **argv, int i, struct data_opts *o, int *budget)
{
	for (; i < argc; i++) {
		const char *a = argv[i], *nx = i + 1 < argc ? argv[i + 1] : NULL;

		if (!strcmp(a, "--apn") && nx)
			o->apn = argv[++i];
		else if (!strcmp(a, "--apn-fallback") && nx)
			o->apn_fallback = argv[++i];
		else if (!strcmp(a, "--profile") && nx)
			o->profile = atoi(argv[++i]);
		else if (!strcmp(a, "--mux") && nx)
			o->mux = atoi(argv[++i]);
		else if (!strcmp(a, "--ep") && nx) {
			if (parse_pair(argv[++i], &o->ep_type, &o->ep_iface))
				return -1;
			o->have_ep = 1;
		} else if (!strcmp(a, "--wda") && nx) {
			unsigned a1, a2, a3, a4 = 0, a5 = 0;

			if (sscanf(argv[++i], "%u:%u:%u:%u:%u", &a1, &a2, &a3, &a4, &a5) < 3)
				return -1;
			o->wda = 1, o->wda_llp = a1, o->wda_ul = a2, o->wda_dl = a3, o->wda_dl_dg = a4, o->wda_dl_sz = a5;
		} else if (!strcmp(a, "--dpm") && nx) {
			i++;
			o->dpm = !strcmp(argv[i], "ctl") ? 2 : !strcmp(argv[i], "hw") ? 1 : -1;
			if (o->dpm < 0)
				return -1;
		} else if (!strcmp(a, "--dpm-ctl") && nx)
			o->dpm_ctl = argv[++i];
		else if (!strcmp(a, "--dpm-pipes") && nx) {
			if (parse_pair(argv[++i], &o->pipe_cons, &o->pipe_prod))
				return -1;
			o->have_pipes = 1;
		} else if (!strcmp(a, "--dpm-swap"))
			o->dpm_swap = 1;
		else if (!strcmp(a, "--ipfam"))
			o->ipfam = 1;
		else if (!strcmp(a, "--ipa") && nx)
			o->ipa_dev = argv[++i];
		else if (!strcmp(a, "--rmnet") && nx)
			o->rmnet = argv[++i];
		else if (!strcmp(a, "--ipa-agg") && nx) {
			if (parse_pair(argv[++i], &o->ipa_agg_size, &o->ipa_agg_count))
				return -1;
		} else if (!strcmp(a, "--run") && nx)
			o->run = argv[++i];
		else if (!strcmp(a, "--hold") && nx)
			o->hold = atoi(argv[++i]);
		else if (!strcmp(a, "--call-timeout") && nx)
			o->call_tmo = atoi(argv[++i]);
		else if (!strcmp(a, "--budget") && nx && budget)
			*budget = atoi(argv[++i]);
		else
			return -1;
	}
	if (o->rmnet && !o->ipa_dev)
		return -1;
	return 0;
}

int main(int argc, char **argv)
{
	struct sigaction sa;
	struct data_opts dopt = {.wda_llp = 2, .wda_ul = WDA_AGG_QMAP, .wda_dl = WDA_AGG_QMAP, .call_tmo = 60,
				 .dpm_ctl = "DATA5_CNTL", .ipa_agg_size = 16384, .ipa_agg_count = 32};
	int i = 1, rc, dcmd, probe, budget = 420;
	const char *cmd;

	setvbuf(stdout, NULL, _IOLBF, 0);
	for (; i < argc && argv[i][0] == '-' && strcmp(argv[i], "--online") && strcmp(argv[i], "--low-power"); i++) {
		if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!strcmp(argv[i], "-t") && i + 1 < argc)
			timeout_s = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-n") && i + 1 < argc)
			want_node = strtol(argv[++i], NULL, 0);
		else {
			usage();
			return 64;
		}
	}
	if (i >= argc) {
		usage();
		return 64;
	}
	cmd = argv[i++];

	if (!strcmp(cmd, "decode")) {
		static uint8_t b[65536];
		long n;

		if (i + 2 > argc) {
			usage();
			return 64;
		}
		n = qmi_unhex(argv[i + 1], b, sizeof(b));
		if (n < 0) {
			printf("decode: bad hex\n");
			return 64;
		}
		return qmi_print(stdout, svc_by_name(argv[i]), b, (size_t)n, verbose);
	}
	if (!strcmp(cmd, "rmnet-add")) {
		if (i + 3 > argc) {
			usage();
			return 64;
		}
		return rmnet_add(argv[i], argv[i + 1], atoi(argv[i + 2]), i + 3 < argc ? (uint32_t)strtoul(argv[i + 3], NULL, 0) : 0);
	}
	if (!strcmp(cmd, "ipa-setup")) {
		if (i + 1 > argc) {
			usage();
			return 64;
		}
		return ipa_setup(argv[i], i + 1 < argc ? (uint32_t)strtoul(argv[i + 1], NULL, 0) : 16384,
				 i + 2 < argc ? (uint32_t)strtoul(argv[i + 2], NULL, 0) : 32,
				 i + 3 < argc ? (uint32_t)strtoul(argv[i + 3], NULL, 0) : 0x26,
				 i + 4 < argc ? (uint32_t)strtoul(argv[i + 4], NULL, 0) : 0);
	}
	if (!strcmp(cmd, "ipa-pair")) {
		uint32_t c, p;

		if (i + 1 > argc) {
			usage();
			return 64;
		}
		return ipa_ep_pair(argv[i], &c, &p, 1);
	}
	if (!strcmp(cmd, "rmnet-del")) {
		if (i + 1 > argc) {
			usage();
			return 64;
		}
		return rmnet_del(argv[i]);
	}

	/* data options are checked before anything touches the modem */
	dcmd = !strcmp(cmd, "data") || !strcmp(cmd, "data-probe");
	probe = !strcmp(cmd, "data-probe");
	if (dcmd) {
		if (probe)
			dopt.wda = 1, dopt.wda_dl_dg = 32, dopt.wda_dl_sz = 16384, dopt.mux = 1, dopt.ipfam = 1,
			dopt.apn_fallback = "internet", dopt.call_tmo = 45;
		if (parse_data_opts(argc, argv, i, &dopt, &budget)) {
			usage();
			return 64;
		}
		if (dopt.dpm && !dopt.have_ep)
			dopt.have_ep = 1, dopt.ep_type = QMI_EP_EMBEDDED, dopt.ep_iface = 1;
	}

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;	/* no SA_RESTART: waits return EINTR, the call is still stopped */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	lookup_all();
	if (!strcmp(cmd, "lookup"))
		return 0;
	qsock = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
	if (qsock < 0) {
		printf("qmi-nas: socket(AF_QIPCRTR): %s\n", strerror(errno));
		return 3;
	}
	next_txn = (uint16_t)(1 + (getpid() & 0x3fff));

	if (!strcmp(cmd, "info"))
		rc = info();
	else if (!strcmp(cmd, "mode"))
		rc = get_mode();
	else if (!strcmp(cmd, "--online"))
		rc = set_mode(DMS_MODE_ONLINE);
	else if (!strcmp(cmd, "--low-power"))
		rc = set_mode(DMS_MODE_LOW_POWER);
	else if (!strcmp(cmd, "wait-registered"))
		rc = wait_registered(i < argc ? atoi(argv[i]) : 90);
	else if (!strcmp(cmd, "card")) {
		struct uim_status st;

		rc = card_status(&st, 1);
	} else if (!strcmp(cmd, "scan")) {
		unsigned mask = 0;

		if (i < argc) {
			char *s = strdup(argv[i]), *tok, *sp = NULL;

			for (tok = strtok_r(s, ",", &sp); tok; tok = strtok_r(NULL, ",", &sp))
				mask |= !strcmp(tok, "gsm") ? 1 : !strcmp(tok, "umts") ? 2 : !strcmp(tok, "lte") ? 4
					: !strcmp(tok, "tds") ? 8 : !strcmp(tok, "nr5g") ? 16 : 0;
			free(s);
		}
		rc = scan(mask);
	} else if (!strcmp(cmd, "wda")) {
		struct data_opts o = {0};
		struct wda_format got;
		unsigned a1, a2, a3, a4 = 0, a5 = 0;

		if (i >= argc || sscanf(argv[i], "%u:%u:%u:%u:%u", &a1, &a2, &a3, &a4, &a5) < 3) {
			usage();
			return 64;
		}
		o.wda_llp = a1, o.wda_ul = a2, o.wda_dl = a3, o.wda_dl_dg = a4, o.wda_dl_sz = a5;
		if (i + 2 < argc && !strcmp(argv[i + 1], "--ep") && parse_pair(argv[i + 2], &o.ep_type, &o.ep_iface) == 0)
			o.have_ep = 1;
		rc = wda_set_format(&o, &got);
	} else if (dcmd) {
		rc = probe ? data_probe(&dopt, budget) : data_call(&dopt);
	} else {
		usage();
		rc = 64;
	}
	close(qsock);
	return rc;
}
