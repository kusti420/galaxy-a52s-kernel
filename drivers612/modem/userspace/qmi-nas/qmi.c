// SPDX-License-Identifier: GPL-2.0-only
/*
 * qmi-nas: QMI codec + DMS/NAS response printers (see qmi.h). Field layouts follow libqmi's
 * data/qmi-service-dms.json / qmi-service-nas.json (message ids, TLV ids, field order and
 * sizes; "string" = u8 length + bytes unless fixed-size) and the enum values of
 * qmi-enums-{dms,nas}.h / qmi-errors.h. Our own code; nothing is copied from libqmi.
 */
#include "qmi.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = v >> 8; }

/* ---------------------------------------------------------------- codec */

int qmi_parse(const uint8_t *b, size_t n, struct qmi_msg *m, char *err, size_t el)
{
	size_t off, end;

	memset(m, 0, sizeof(*m));
	if (err && el)
		err[0] = 0;
	if (n < QMI_HDR_LEN) {
		snprintf(err, el, "short message: %zu bytes (QMI header is 7)", n);
		return -1;
	}
	m->type = b[0];
	m->txn = le16(b + 1);
	m->msg_id = le16(b + 3);
	m->len = le16(b + 5);
	if ((size_t)m->len + QMI_HDR_LEN > n) {
		snprintf(err, el, "header length %u > %zu bytes after the header", m->len, n - QMI_HDR_LEN);
		return -1;
	}
	m->trailing = n - QMI_HDR_LEN - m->len;
	off = QMI_HDR_LEN;
	end = QMI_HDR_LEN + (size_t)m->len;
	while (off < end) {
		uint16_t l;

		if (end - off < 3) {
			snprintf(err, el, "truncated TLV header at offset %zu", off);
			return -1;
		}
		l = le16(b + off + 1);
		if (off + 3 + l > end) {
			snprintf(err, el, "TLV 0x%02x at offset %zu: length %u exceeds the message", b[off], off, l);
			return -1;
		}
		if (m->ntlv == QMI_MAX_TLV) {
			snprintf(err, el, "more than %d TLVs", QMI_MAX_TLV);
			return -1;
		}
		m->tlv[m->ntlv].type = b[off];
		m->tlv[m->ntlv].len = l;
		m->tlv[m->ntlv].val = b + off + 3;
		m->ntlv++;
		off += 3 + (size_t)l;
	}
	return 0;
}

const struct qmi_tlv *qmi_find(const struct qmi_msg *m, uint8_t type)
{
	for (int i = 0; i < m->ntlv; i++)
		if (m->tlv[i].type == type)
			return &m->tlv[i];
	return NULL;
}

int qmi_result(const struct qmi_msg *m, uint16_t *result, uint16_t *error)
{
	const struct qmi_tlv *t = qmi_find(m, 0x02);

	if (!t || t->len != 4)
		return -1;
	*result = le16(t->val);
	*error = le16(t->val + 2);
	return 0;
}

void qmi_begin(struct qmi_builder *q, uint8_t *buf, size_t cap, uint8_t type, uint16_t txn, uint16_t msg_id)
{
	q->buf = buf;
	q->cap = cap;
	q->len = 0;
	q->err = cap < QMI_HDR_LEN;
	if (q->err)
		return;
	buf[0] = type;
	put16(buf + 1, txn);
	put16(buf + 3, msg_id);
	put16(buf + 5, 0);
	q->len = QMI_HDR_LEN;
}

void qmi_add_tlv(struct qmi_builder *q, uint8_t type, const void *val, uint16_t len)
{
	if (q->err || q->len + 3 + (size_t)len > q->cap || q->len - QMI_HDR_LEN + 3 + (size_t)len > 0xffff) {
		q->err = 1;
		return;
	}
	q->buf[q->len] = type;
	put16(q->buf + q->len + 1, len);
	if (len)
		memcpy(q->buf + q->len + 3, val, len);
	q->len += 3 + (size_t)len;
}

void qmi_add_u8(struct qmi_builder *q, uint8_t type, uint8_t v) { qmi_add_tlv(q, type, &v, 1); }
static void put32(uint8_t *p, uint32_t v) { p[0] = v & 0xff; p[1] = v >> 8 & 0xff; p[2] = v >> 16 & 0xff; p[3] = v >> 24; }
void qmi_add_u32(struct qmi_builder *q, uint8_t type, uint32_t v)
{
	uint8_t b[4];

	put32(b, v);
	qmi_add_tlv(q, type, b, 4);
}
void qmi_add_ep(struct qmi_builder *q, uint8_t type, uint32_t ep_type, uint32_t iface)
{
	uint8_t b[8];

	put32(b, ep_type), put32(b + 4, iface);
	qmi_add_tlv(q, type, b, 8);
}

void dpm_add_open_port(struct qmi_builder *q, const char *ctl_name, uint32_t ep_type, uint32_t iface,
		       uint32_t rx_ep, uint32_t tx_ep)
{
	uint8_t b[300];

	if (ctl_name) {
		size_t l = strlen(ctl_name);

		if (l > 255) {
			q->err = 1;
			return;
		}
		b[0] = 1;			/* one control port */
		b[1] = (uint8_t)l;		/* string with u8 length, no NUL */
		memcpy(b + 2, ctl_name, l);
		put32(b + 2 + l, ep_type), put32(b + 6 + l, iface);
		qmi_add_tlv(q, 0x10, b, (uint16_t)(10 + l));
	}
	b[0] = 1;				/* one hardware data port */
	put32(b + 1, ep_type), put32(b + 5, iface), put32(b + 9, rx_ep), put32(b + 13, tx_ep);
	qmi_add_tlv(q, 0x11, b, 17);
}

void wda_parse_format(const struct qmi_msg *m, struct wda_format *f)
{
	static const struct { uint8_t t; unsigned bit; size_t off; } d[] = {
		{0x11, 1, offsetof(struct wda_format, llp)}, {0x12, 2, offsetof(struct wda_format, ul)},
		{0x13, 4, offsetof(struct wda_format, dl)}, {0x15, 8, offsetof(struct wda_format, dl_dg)},
		{0x16, 16, offsetof(struct wda_format, dl_sz)}, {0x17, 32, offsetof(struct wda_format, ul_dg)},
		{0x18, 64, offsetof(struct wda_format, ul_sz)}};

	memset(f, 0, sizeof(*f));
	for (size_t i = 0; i < sizeof(d) / sizeof(d[0]); i++) {
		const struct qmi_tlv *t = qmi_find(m, d[i].t);

		if (t && t->len == 4) {
			*(uint32_t *)((char *)f + d[i].off) = le32(t->val);
			f->have |= d[i].bit;
		}
	}
}

int qmi_finish(struct qmi_builder *q)
{
	if (q->err)
		return -1;
	put16(q->buf + 5, (uint16_t)(q->len - QMI_HDR_LEN));
	return (int)q->len;
}

void qmi_hex(FILE *o, const uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++)
		fprintf(o, "%s%02x", i ? " " : "", p[i]);
}

long qmi_unhex(const char *s, uint8_t *out, size_t cap)
{
	size_t n = 0;
	int hi = -1;

	while (*s) {
		int c = (unsigned char)*s++, v;

		if (c == '0' && (*s == 'x' || *s == 'X') && hi < 0) {
			s++;
			continue;
		}
		if (isspace(c) || c == ',' || c == ':' || c == '-')
			continue;
		if (c >= '0' && c <= '9')
			v = c - '0';
		else if (c >= 'a' && c <= 'f')
			v = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			v = c - 'A' + 10;
		else
			return -1;
		if (hi < 0) {
			hi = v;
			continue;
		}
		if (n == cap)
			return -1;
		out[n++] = (uint8_t)(hi << 4 | v);
		hi = -1;
	}
	return hi < 0 ? (long)n : -1;
}

int qrtr_parse_ctrl(const void *buf, size_t n, uint32_t *cmd, struct qrtr_server_info *s)
{
	const uint8_t *b = buf;
	uint32_t inst;

	if (n < 20)
		return -1;
	*cmd = le32(b);
	s->service = le32(b + 4);
	inst = le32(b + 8);
	s->node = le32(b + 12);
	s->port = le32(b + 16);
	s->version = inst & 0xff;	/* the name service packs instance << 8 | version */
	s->instance = inst >> 8;
	if (*cmd != 4 /* QRTR_TYPE_NEW_SERVER */)
		return -1;
	if (!s->service && !inst && !s->node && !s->port)
		return 0;
	return 1;
}

/* ---------------------------------------------------------------- names */

struct name { int v; const char *n; };
static const char *lookup(const struct name *t, int v)
{
	for (; t->n; t++)
		if (t->v == v)
			return t->n;
	return "?";
}

static const struct name qmi_errors[] = {
	{0, "none"}, {1, "malformed-message"}, {2, "no-memory"}, {3, "internal"}, {4, "aborted"},
	{5, "client-ids-exhausted"}, {6, "unabortable-transaction"}, {7, "invalid-client-id"},
	{9, "invalid-handle"}, {13, "no-network-found"}, {14, "call-failed"}, {16, "not-provisioned"},
	{17, "missing-argument"}, {19, "argument-too-long"}, {22, "invalid-transaction-id"},
	{23, "device-in-use"}, {24, "network-unsupported"}, {25, "device-unsupported"}, {26, "no-effect"},
	{37, "uim-uninitialized"}, {46, "general-error"}, {47, "unknown-error"}, {48, "invalid-argument"},
	{49, "invalid-index"}, {50, "no-entry"}, {52, "device-not-ready"}, {53, "network-not-ready"},
	{60, "invalid-transition"}, {68, "insufficient-resources"}, {69, "disabled"},
	{70, "invalid-operation"}, {71, "invalid-qmi-command"}, {74, "information-unavailable"},
	{82, "access-denied"}, {83, "hardware-restricted"}, {90, "incompatible-state"},
	{93, "no-radio"}, {94, "not-supported"}, {95, "no-subscription"}, {97, "network-aborted"},
	{102, "no-sim"}, {0, NULL}};
const char *qmi_error_name(uint16_t e) { return lookup(qmi_errors, e); }

static const struct name dms_modes[] = {
	{0, "online"}, {1, "low-power"}, {2, "factory-test"}, {3, "offline"}, {4, "reset"},
	{5, "shutting-down"}, {6, "persistent-low-power"}, {7, "mode-only-low-power"},
	{8, "net-test-gw"}, {0xff, "unknown"}, {0, NULL}};
const char *dms_mode_name(unsigned v) { return lookup(dms_modes, (int)v); }

static const struct name radios[] = {
	{-1, "unknown"}, {0, "none"}, {1, "cdma-1x"}, {2, "cdma-1xevdo"}, {3, "amps"}, {4, "gsm"},
	{5, "umts"}, {8, "lte"}, {9, "td-scdma"}, {0x0c, "5gnr"}, {0, NULL}};
const char *nas_radio_name(int v) { return lookup(radios, v); }

static const struct name svc_status[] = {
	{0, "none"}, {1, "limited"}, {2, "available"}, {3, "limited-regional"}, {4, "power-save"}, {0, NULL}};
static const struct name domains[] = {
	{0, "none"}, {1, "cs"}, {2, "ps"}, {3, "cs-ps"}, {4, "camped"}, {0, NULL}};
static const struct name reg_states[] = {
	{0, "not-registered"}, {1, "registered"}, {2, "not-registered-searching"},
	{3, "registration-denied"}, {4, "unknown"}, {0, NULL}};
static const struct name attach_states[] = {{0, "unknown"}, {1, "attached"}, {2, "detached"}, {0, NULL}};
static const struct name net_types[] = {{0, "unknown"}, {1, "3gpp2"}, {2, "3gpp"}, {0, NULL}};
static const struct name roaming_status[] = {
	{0, "off"}, {1, "on"}, {2, "blink"}, {3, "out-of-neighborhood"}, {4, "out-of-building"},
	{5, "preferred-system"}, {6, "available-system"}, {7, "alliance-partner"},
	{8, "premium-partner"}, {9, "full-service"}, {10, "partial-service"}, {11, "banner-on"},
	{12, "banner-off"}, {0, NULL}};
static const struct name roam_ind[] = {{0, "roaming"}, {1, "home"}, {2, "flashing"}, {0, NULL}};
static const struct name data_caps[] = {
	{0, "none"}, {1, "gprs"}, {2, "edge"}, {3, "hsdpa"}, {4, "hsupa"}, {5, "wcdma"}, {6, "cdma"},
	{7, "evdo-rev0"}, {8, "evdo-reva"}, {9, "gsm"}, {10, "evdo-revb"}, {11, "lte"},
	{12, "hsdpa+"}, {13, "dc-hsdpa+"}, {0, NULL}};
static const struct name sim_reject[] = {
	{0, "sim-unavailable"}, {1, "sim-available"}, {2, "sim-cs-invalid"}, {3, "sim-ps-invalid"},
	{4, "sim-cs-ps-invalid"}, {0, NULL}};
static const struct name lte_voice_domain[] = {{0, "none"}, {1, "ims"}, {2, "1x"}, {3, "3gpp"}, {0, NULL}};
static const struct name scan_results[] = {{0, "success"}, {1, "abort"}, {2, "radio-link-failure"}, {0, NULL}};
static const struct name dl_bw[] = {
	{0, "1.4MHz"}, {1, "3MHz"}, {2, "5MHz"}, {3, "10MHz"}, {4, "15MHz"}, {5, "20MHz"},
	{6, "nr-5MHz"}, {7, "nr-10MHz"}, {8, "nr-15MHz"}, {9, "nr-20MHz"}, {10, "nr-25MHz"},
	{11, "nr-30MHz"}, {12, "nr-40MHz"}, {13, "nr-50MHz"}, {14, "nr-60MHz"}, {15, "nr-80MHz"},
	{16, "nr-90MHz"}, {17, "nr-100MHz"}, {18, "nr-200MHz"}, {19, "nr-400MHz"}, {20, "gsm-0.2MHz"},
	{21, "tdscdma-1.6MHz"}, {22, "wcdma-5MHz"}, {23, "wcdma-10MHz"}, {24, "nr-70MHz"},
	{0xff, "unknown"}, {0, NULL}};
/* QmiNasActiveBand: E-UTRA and NR band numbers are not contiguous in the enum */
static const struct { uint16_t v, band; } eutran[] = {
	{120, 1}, {121, 2}, {122, 3}, {123, 4}, {124, 5}, {125, 6}, {126, 7}, {127, 8}, {128, 9},
	{129, 10}, {130, 11}, {131, 12}, {132, 13}, {133, 14}, {134, 17}, {135, 33}, {136, 34},
	{137, 35}, {138, 36}, {139, 37}, {140, 38}, {141, 39}, {142, 40}, {143, 18}, {144, 19},
	{145, 20}, {146, 21}, {147, 24}, {148, 25}, {149, 41}, {150, 42}, {151, 43}, {152, 23},
	{153, 26}, {154, 32}, {155, 125}, {156, 126}, {157, 127}, {158, 28}, {159, 29}, {160, 30},
	{161, 66}, {162, 250}, {163, 46}, {164, 27}, {165, 31}, {166, 47}, {167, 48}, {168, 71}};
static const struct { uint16_t v, band; } nr5g[] = {
	{250, 1}, {251, 2}, {252, 3}, {253, 5}, {254, 7}, {255, 8}, {256, 20}, {257, 28}, {258, 38},
	{259, 41}, {260, 50}, {261, 51}, {262, 66}, {263, 70}, {264, 71}, {265, 74}, {266, 75},
	{267, 76}, {268, 77}, {269, 78}, {270, 79}, {271, 80}, {272, 81}, {273, 82}, {274, 83},
	{275, 84}, {276, 85}, {277, 257}, {278, 258}, {279, 259}, {280, 260}, {281, 261}, {282, 12},
	{283, 25}, {284, 34}, {285, 39}, {286, 40}, {287, 65}, {288, 86}, {289, 48}, {290, 14},
	{291, 13}, {292, 18}, {293, 26}, {294, 30}, {295, 29}, {296, 53}, {297, 46}, {298, 91},
	{299, 92}, {300, 93}, {301, 94}, {315, 100}, {316, 101}};
static const struct name gsm_wcdma_bands[] = {
	{40, "gsm-450"}, {41, "gsm-480"}, {42, "gsm-750"}, {43, "gsm-850"}, {44, "gsm-900-ext"},
	{45, "gsm-900-primary"}, {46, "gsm-900-railways"}, {47, "gsm-dcs-1800"}, {48, "gsm-pcs-1900"},
	{80, "wcdma-2100"}, {81, "wcdma-pcs-1900"}, {82, "wcdma-dcs-1800"}, {83, "wcdma-1700-us"},
	{84, "wcdma-850"}, {85, "wcdma-800"}, {86, "wcdma-2600"}, {87, "wcdma-900"},
	{88, "wcdma-1700-japan"}, {90, "wcdma-1500-japan"}, {91, "wcdma-850-japan"},
	{200, "tdscdma-a"}, {201, "tdscdma-b"}, {202, "tdscdma-c"}, {203, "tdscdma-d"},
	{204, "tdscdma-e"}, {205, "tdscdma-f"}, {0, NULL}};

static void band_name(char *s, size_t n, unsigned v)
{
	size_t i;

	if (v <= 19) {
		snprintf(s, n, "cdma-bc%u", v);
		return;
	}
	for (i = 0; i < sizeof(eutran) / sizeof(eutran[0]); i++)
		if (eutran[i].v == v) {
			snprintf(s, n, "lte-b%u", eutran[i].band);
			return;
		}
	for (i = 0; i < sizeof(nr5g) / sizeof(nr5g[0]); i++)
		if (nr5g[i].v == v) {
			snprintf(s, n, "nr-n%u", nr5g[i].band);
			return;
		}
	snprintf(s, n, "%s", lookup(gsm_wcdma_bands, (int)v));
}

/* ---------------------------------------------------------------- reader */

struct rd {
	const uint8_t *p;
	size_t n;
	int bad;
};
static int need(struct rd *r, size_t k)
{
	if (r->bad || r->n < k) {
		r->bad = 1;
		return 0;
	}
	return 1;
}
static unsigned u8(struct rd *r)
{
	unsigned v;

	if (!need(r, 1))
		return 0;
	v = r->p[0];
	r->p++, r->n--;
	return v;
}
static unsigned u16(struct rd *r)
{
	unsigned v;

	if (!need(r, 2))
		return 0;
	v = le16(r->p);
	r->p += 2, r->n -= 2;
	return v;
}
static uint32_t u32(struct rd *r)
{
	uint32_t v;

	if (!need(r, 4))
		return 0;
	v = le32(r->p);
	r->p += 4, r->n -= 4;
	return v;
}
static int s8(struct rd *r) { return (int8_t)u8(r); }
static int s16(struct rd *r) { return (int16_t)u16(r); }
static int32_t s32(struct rd *r) { return (int32_t)u32(r); }
/* bytes as printable text: s gets up to len chars, non-printables as \xNN, 0xff padding dropped */
static void text(struct rd *r, size_t len, char *s, size_t sn)
{
	size_t o = 0;

	s[0] = 0;
	if (!need(r, len))
		return;
	for (size_t i = 0; i < len; i++) {
		unsigned c = r->p[i];

		if (c == 0xff || c == 0)
			continue;
		if (o + 5 >= sn)
			break;
		if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\')
			s[o++] = (char)c;
		else
			o += (size_t)snprintf(s + o, sn - o, "\\x%02x", c);
	}
	s[o] = 0;
	r->p += len, r->n -= len;
}
static void str8(struct rd *r, char *s, size_t sn) { text(r, u8(r), s, sn); }

/* ---------------------------------------------------------------- TLV decoders */

typedef void (*tlv_fn)(FILE *o, struct rd *r);
struct tlv_desc {
	uint8_t type;
	const char *name;
	tlv_fn fn;
};

static const char *yesno(unsigned v) { return v ? "yes" : "no"; }

/* DMS */
static void d_opmode(FILE *o, struct rd *r) { unsigned v = u8(r); fprintf(o, "mode=%u (%s)", v, dms_mode_name(v)); }
static void d_offline_reason(FILE *o, struct rd *r)
{
	unsigned v = u16(r);

	fprintf(o, "0x%04x%s%s%s%s", v, v & 1 ? " host-image-misconfiguration" : "",
		v & 2 ? " pri-image-misconfiguration" : "", v & 4 ? " pri-version-incompatible" : "",
		v & 8 ? " device-memory-full" : "");
}
static void d_bool(FILE *o, struct rd *r) { fprintf(o, "%s", yesno(u8(r))); }
static void d_u8(FILE *o, struct rd *r) { fprintf(o, "%u", u8(r)); }
static void d_u16(FILE *o, struct rd *r) { fprintf(o, "%u", u16(r)); }
static void d_u32(FILE *o, struct rd *r) { fprintf(o, "%u", (unsigned)u32(r)); }
static void d_s8(FILE *o, struct rd *r) { fprintf(o, "%d", s8(r)); }

/* NAS signal info (rssi/rsrp/rscp dBm; ecio in -0.5 dB steps; LTE/5G SNR in 0.1 dB) */
static void ecio(FILE *o, int v) { fprintf(o, " ecio=%d (%.1fdB)", v, v * -0.5); }
static void d_sig_cdma(FILE *o, struct rd *r) { fprintf(o, "rssi=%ddBm", s8(r)); ecio(o, s16(r)); }
static void d_sig_hdr(FILE *o, struct rd *r)
{
	int rssi = s8(r), e = s16(r);
	unsigned sinr = u8(r);
	int32_t io = s32(r);

	fprintf(o, "rssi=%ddBm", rssi);
	ecio(o, e);
	fprintf(o, " sinr-level=%u io=%ddBm", sinr, (int)io);
}
static void d_sig_gsm(FILE *o, struct rd *r) { fprintf(o, "rssi=%ddBm", s8(r)); }
static void d_sig_lte(FILE *o, struct rd *r)
{
	int rssi = s8(r), rsrq = s8(r), rsrp = s16(r), snr = s16(r);

	fprintf(o, "rssi=%ddBm rsrq=%ddB rsrp=%ddBm snr=%.1fdB", rssi, rsrq, rsrp, snr / 10.0);
}
static void d_sig_tdma(FILE *o, struct rd *r) { fprintf(o, "rscp=%ddBm", s8(r)); }
static void d_sig_tdma_ext(FILE *o, struct rd *r)
{
	int32_t a = s32(r), b = s32(r), c = s32(r), d = s32(r);

	fprintf(o, "rssi=%d rscp=%d ecio=%d sinr=%d (raw)", (int)a, (int)b, (int)c, (int)d);
}
static void d_sig_5g(FILE *o, struct rd *r)
{
	int rsrp = s16(r), snr = s16(r);

	fprintf(o, "rsrp=%ddBm snr=%.1fdB", rsrp, snr / 10.0);
}
static void d_sig_5g_rsrq(FILE *o, struct rd *r) { fprintf(o, "rsrq=%ddB", s16(r)); }
static void d_sig_wcdma_rscp(FILE *o, struct rd *r) { fprintf(o, "rscp=%ddBm", s16(r)); }

/* NAS serving system */
static void d_ss(FILE *o, struct rd *r)
{
	unsigned reg = u8(r), cs = u8(r), ps = u8(r), net = u8(r), n = u8(r);

	fprintf(o, "registration=%u (%s) cs=%s ps=%s selected-network=%s radio-interfaces=", reg,
		lookup(reg_states, (int)reg), lookup(attach_states, (int)cs), lookup(attach_states, (int)ps),
		lookup(net_types, (int)net));
	if (!n)
		fprintf(o, "none");
	for (unsigned i = 0; i < n && !r->bad; i++) {
		int v = s8(r);

		fprintf(o, "%s%s", i ? "," : "", nas_radio_name(v));
	}
}
static void d_roam_ind(FILE *o, struct rd *r) { unsigned v = u8(r); fprintf(o, "%u (%s)", v, lookup(roam_ind, (int)v)); }
static void d_data_caps(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	if (!n)
		fprintf(o, "none");
	for (unsigned i = 0; i < n && !r->bad; i++) {
		unsigned v = u8(r);

		fprintf(o, "%s%s", i ? "," : "", lookup(data_caps, (int)v));
	}
}
static void d_plmn(FILE *o, struct rd *r)
{
	char d[200];
	unsigned mcc = u16(r), mnc = u16(r);

	str8(r, d, sizeof(d));
	fprintf(o, "mcc=%03u mnc=%02u description=\"%s\"", mcc, mnc, d);
}
static void d_roam_list(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	for (unsigned i = 0; i < n && !r->bad; i++) {
		unsigned ri = u8(r), ro = u8(r);

		fprintf(o, "%s%s:%s", i ? " " : "", nas_radio_name((int8_t)ri), lookup(roam_ind, (int)ro));
	}
}
static void d_detailed_status(FILE *o, struct rd *r)
{
	unsigned st = u8(r), cap = u8(r), hst = u8(r), hyb = u8(r), forb = u8(r);

	fprintf(o, "status=%s capability=%s hdr-status=%s hdr-hybrid=%s forbidden=%s",
		lookup(svc_status, (int)st), lookup(domains, (int)cap), lookup(svc_status, (int)hst), yesno(hyb), yesno(forb));
}
static void d_call_barring(FILE *o, struct rd *r)
{
	int32_t cs = s32(r), ps = s32(r);

	fprintf(o, "cs=%d ps=%d", (int)cs, (int)ps);
}
static void d_mnc_pcs(FILE *o, struct rd *r)
{
	unsigned mcc = u16(r), mnc = u16(r), pcs = u8(r);

	fprintf(o, "mcc=%03u mnc=%u pcs-digit=%s", mcc, mnc, yesno(pcs));
}

/* NAS system info */
static void d_svc2(FILE *o, struct rd *r)
{
	unsigned st = u8(r), pref = u8(r);

	fprintf(o, "status=%s preferred-data-path=%s", lookup(svc_status, (int)st), yesno(pref));
}
static void d_svc3(FILE *o, struct rd *r)
{
	unsigned st = u8(r), tst = u8(r), pref = u8(r);

	fprintf(o, "status=%s true-status=%s preferred-data-path=%s", lookup(svc_status, (int)st),
		lookup(svc_status, (int)tst), yesno(pref));
}
/* the common head of GSM/WCDMA/LTE/TD-SCDMA/NR5G "System Info v2"; only valid fields printed */
static void sysinfo_head(FILE *o, struct rd *r)
{
	unsigned dv = u8(r), dom = u8(r), cv = u8(r), cap = u8(r), rv = u8(r), roam = u8(r);
	unsigned fv = u8(r), forb = u8(r), lv = u8(r), lac = u16(r), civ = u8(r);
	uint32_t cid = u32(r);
	unsigned rrv = u8(r), rrd = u8(r), rrc = u8(r), nv = u8(r);
	char mcc[16], mnc[16];

	text(r, 3, mcc, sizeof(mcc));
	text(r, 3, mnc, sizeof(mnc));
	if (dv)
		fprintf(o, "domain=%s ", lookup(domains, (int)dom));
	if (cv)
		fprintf(o, "capability=%s ", lookup(domains, (int)cap));
	if (rv)
		fprintf(o, "roaming=%s ", lookup(roaming_status, (int)roam));
	if (fv)
		fprintf(o, "forbidden=%s ", yesno(forb));
	if (lv)
		fprintf(o, "lac=%u ", lac);
	if (civ)
		fprintf(o, "cid=%u ", (unsigned)cid);
	if (rrv)
		fprintf(o, "reject-domain=%s reject-cause=%u ", lookup(domains, (int)rrd), rrc);
	if (nv)
		fprintf(o, "mcc=%s mnc=%s ", mcc, mnc);
	if (!(dv | cv | rv | fv | lv | civ | rrv | nv))
		fprintf(o, "(no valid fields) ");
}
static void d_sys_gsm(FILE *o, struct rd *r)
{
	unsigned ev, e, dv, d;

	sysinfo_head(o, r);
	ev = u8(r), e = u8(r), dv = u8(r), d = u8(r);
	if (ev)
		fprintf(o, "egprs=%s ", yesno(e));
	if (dv)
		fprintf(o, "dtm=%s ", yesno(d));
}
static void d_sys_wcdma(FILE *o, struct rd *r)
{
	unsigned hcv, hc, hsv, hs, pv, psc;

	sysinfo_head(o, r);
	hcv = u8(r), hc = u8(r), hsv = u8(r), hs = u8(r), pv = u8(r), psc = u16(r);
	if (hcv)
		fprintf(o, "hs-call=%u ", hc);
	if (hsv)
		fprintf(o, "hs-service=%u ", hs);
	if (pv)
		fprintf(o, "psc=%u ", psc);
}
static void d_sys_tac(FILE *o, struct rd *r)
{
	unsigned tv, tac;

	sysinfo_head(o, r);
	tv = u8(r), tac = u16(r);
	if (tv)
		fprintf(o, "tac=%u ", tac);
}
static void d_sim_reject(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(sim_reject, (int)v)); }
static void d_lte_voice_domain(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(lte_voice_domain, (int)v)); }
static void d_tac24(FILE *o, struct rd *r)
{
	unsigned a = u8(r), b = u8(r), c = u8(r);

	fprintf(o, "%u (%02x %02x %02x)", a << 16 | b << 8 | c, a, b, c);
}

/* NAS RF band info */
static void d_rf_list(FILE *o, struct rd *r, int ext)
{
	unsigned n = u8(r);
	char b[32];

	if (!n)
		fprintf(o, "none");
	for (unsigned i = 0; i < n && !r->bad; i++) {
		int ri = s8(r);
		unsigned band = u16(r);
		uint32_t ch = ext ? u32(r) : u16(r);

		band_name(b, sizeof(b), band);
		fprintf(o, "%s[%s band=%u (%s) channel=%u]", i ? " " : "", nas_radio_name(ri), band, b, (unsigned)ch);
	}
}
static void d_rf(FILE *o, struct rd *r) { d_rf_list(o, r, 0); }
static void d_rf_ext(FILE *o, struct rd *r) { d_rf_list(o, r, 1); }
static void d_rf_bw(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	if (!n)
		fprintf(o, "none");
	for (unsigned i = 0; i < n && !r->bad; i++) {
		int ri = s8(r);
		uint32_t bw = u32(r);

		fprintf(o, "%s[%s %s]", i ? " " : "", nas_radio_name(ri), lookup(dl_bw, (int)bw));
	}
}

/* NAS network scan: the per-network lines are printed by scan_summary() */
static void d_scan_info(FILE *o, struct rd *r)
{
	unsigned n = u16(r);
	char d[200];

	for (unsigned i = 0; i < n && !r->bad; i++) {
		u16(r), u16(r), u8(r);
		str8(r, d, sizeof(d));
	}
	fprintf(o, "%u networks", n);
}
static void d_scan_rat(FILE *o, struct rd *r)
{
	unsigned n = u16(r);

	for (unsigned i = 0; i < n && !r->bad; i++)
		u16(r), u16(r), u8(r);
	fprintf(o, "%u entries", n);
}
static void d_scan_result(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(scan_results, (int)v)); }

static const struct tlv_desc t_dms_get_mode[] = {
	{0x01, "mode", d_opmode}, {0x10, "offline-reason", d_offline_reason},
	{0x11, "hardware-restricted", d_bool}, {0, NULL, NULL}};
static const struct tlv_desc t_none[] = {{0, NULL, NULL}};
static const struct tlv_desc t_signal[] = {
	{0x10, "cdma", d_sig_cdma}, {0x11, "hdr", d_sig_hdr}, {0x12, "gsm", d_sig_gsm},
	{0x13, "wcdma", d_sig_cdma}, {0x14, "lte", d_sig_lte}, {0x15, "tdma", d_sig_tdma},
	{0x16, "tdma-ext", d_sig_tdma_ext}, {0x17, "5g", d_sig_5g}, {0x18, "5g-ext", d_sig_5g_rsrq},
	{0x19, "wcdma-rscp", d_sig_wcdma_rscp}, {0, NULL, NULL}};
static const struct tlv_desc t_serving[] = {
	{0x01, "serving-system", d_ss}, {0x10, "roaming-indicator", d_roam_ind},
	{0x11, "data-service-capability", d_data_caps}, {0x12, "current-plmn", d_plmn},
	{0x15, "roaming-indicator-list", d_roam_list}, {0x16, "default-roaming-indicator", d_roam_ind},
	{0x1a, "time-zone-3gpp(15min)", d_s8}, {0x1b, "dst-adjustment-3gpp", d_u8},
	{0x1c, "lac", d_u16}, {0x1d, "cid", d_u32}, {0x20, "dtm-support", d_bool},
	{0x21, "detailed-service-status", d_detailed_status}, {0x24, "lte-tac", d_u16},
	{0x25, "call-barring", d_call_barring}, {0x26, "umts-psc", d_u16},
	{0x27, "mnc-pcs-digit", d_mnc_pcs}, {0x29, "network-name-source", d_u32}, {0, NULL, NULL}};
static const struct tlv_desc t_sysinfo[] = {
	{0x10, "cdma-service", d_svc2}, {0x11, "hdr-service", d_svc2}, {0x12, "gsm-service", d_svc3},
	{0x13, "wcdma-service", d_svc3}, {0x14, "lte-service", d_svc3},
	{0x17, "gsm-system", d_sys_gsm}, {0x18, "wcdma-system", d_sys_wcdma},
	{0x19, "lte-system", d_sys_tac}, {0x21, "lte-voice-support", d_bool},
	{0x24, "tdscdma-service", d_svc3}, {0x26, "lte-embms-coverage", d_bool},
	{0x27, "sim-reject-info", d_sim_reject}, {0x29, "ims-voice-support", d_bool},
	{0x2a, "lte-voice-domain", d_lte_voice_domain}, {0x2c, "gsm-rac", d_u8}, {0x2d, "wcdma-rac", d_u8},
	{0x2f, "registration-restriction", d_u32}, {0x31, "lte-registration-domain", d_u32},
	{0x34, "lte-embms-trace-id", d_u16}, {0x44, "lte-cell-access", d_u32},
	{0x4a, "nr5g-service", d_svc3}, {0x4b, "nr5g-system", d_sys_tac},
	{0x4e, "eutra-with-nr5g", d_bool}, {0x4f, "dcnr-restriction", d_bool},
	{0x50, "nr5g-tac", d_tac24}, {0, NULL, NULL}};
static const struct tlv_desc t_rfband[] = {
	{0x01, "bands", d_rf}, {0x11, "bands-ext", d_rf_ext}, {0x12, "bandwidth", d_rf_bw}, {0, NULL, NULL}};
static const struct tlv_desc t_scan[] = {
	{0x10, "network-information", d_scan_info}, {0x11, "radio-access-technology", d_scan_rat},
	{0x12, "mnc-pcs-digit", d_scan_rat}, {0x13, "scan-result", d_scan_result}, {0, NULL, NULL}};

/* UIM */
static const struct name uim_card_states[] = {{0, "absent"}, {1, "present"}, {2, "error"}, {0, NULL}};
static const struct name uim_pin_states[] = {
	{0, "not-initialized"}, {1, "enabled-not-verified"}, {2, "enabled-verified"}, {3, "disabled"},
	{4, "blocked"}, {5, "permanently-blocked"}, {0, NULL}};
static const struct name uim_app_states[] = {
	{0, "unknown"}, {1, "detected"}, {2, "pin1-or-upin-required"}, {3, "puk1-or-upin-puk-required"},
	{4, "check-personalization"}, {5, "pin1-blocked"}, {6, "illegal"}, {7, "ready"}, {0, NULL}};
static const struct name uim_app_types[] = {
	{0, "unknown"}, {1, "sim"}, {2, "usim"}, {3, "ruim"}, {4, "csim"}, {5, "isim"}, {0, NULL}};
static const struct name uim_card_errors[] = {
	{0, "unknown"}, {1, "power-down"}, {2, "poll"}, {3, "no-atr"}, {4, "voltage-mismatch"},
	{5, "parity"}, {6, "possibly-removed"}, {7, "technical"}, {0, NULL}};
static const struct name uim_perso[] = {
	{0, "unknown"}, {1, "in-progress"}, {2, "ready"}, {3, "code-required"}, {4, "puk-code-required"},
	{5, "permanently-blocked"}, {0, NULL}};
const char *uim_pin_state_name(unsigned v) { return lookup(uim_pin_states, (int)v); }
const char *uim_app_state_name(unsigned v) { return lookup(uim_app_states, (int)v); }
const char *uim_card_state_name(unsigned v) { return lookup(uim_card_states, (int)v); }

/* walks TLV 0x10; prints when o != NULL, fills s (GW primary app) when s != NULL */
static void card_status_walk(FILE *o, struct rd *r, struct uim_status *s)
{
	unsigned gw = u16(r), x1 = u16(r), gw2 = u16(r), x2 = u16(r), nc = u8(r);

	if (s) {
		memset(s, 0, sizeof(*s));
		s->ncards = nc;
	}
	if (o)
		fprintf(o, "index-gw-primary=0x%04x index-1x-primary=0x%04x index-gw-secondary=0x%04x index-1x-secondary=0x%04x cards=%u",
			gw, x1, gw2, x2, nc);
	for (unsigned c = 0; c < nc && !r->bad; c++) {
		unsigned cs = u8(r), ups = u8(r), upr = u8(r), upk = u8(r), err = u8(r), na = u8(r);

		if (o)
			fprintf(o, " | card[%u] state=%s upin=%s upin-retries=%u upuk-retries=%u error=%s apps=%u", c,
				lookup(uim_card_states, (int)cs), lookup(uim_pin_states, (int)ups), upr, upk,
				lookup(uim_card_errors, (int)err), na);
		for (unsigned a = 0; a < na && !r->bad; a++) {
			unsigned ty = u8(r), st = u8(r), ps = u8(r), pf = u8(r), pr = u8(r), pu = u8(r), al = u8(r);
			unsigned rep, p1, p1r, k1r, p2, p2r, k2r;

			if (o)
				fprintf(o, " | card[%u].app[%u] type=%s state=%s perso=%s perso-feature=%u perso-retries=%u/%u aid=",
					c, a, lookup(uim_app_types, (int)ty), lookup(uim_app_states, (int)st),
					lookup(uim_perso, (int)ps), pf, pr, pu);
			for (unsigned i = 0; i < al && !r->bad; i++) {
				unsigned b = u8(r);

				if (o)
					fprintf(o, "%02x", b);
			}
			rep = u8(r), p1 = u8(r), p1r = u8(r), k1r = u8(r), p2 = u8(r), p2r = u8(r), k2r = u8(r);
			if (o)
				fprintf(o, " upin-replaces-pin1=%s pin1=%s pin1-retries=%u puk1-retries=%u pin2=%s pin2-retries=%u puk2-retries=%u",
					yesno(rep), lookup(uim_pin_states, (int)p1), p1r, k1r, lookup(uim_pin_states, (int)p2), p2r, k2r);
			if (s && !r->bad && gw != 0xffff && (gw >> 8) == c && (gw & 0xff) == a) {
				s->have_app = 1;
				s->card_state = cs, s->card_error = err;
				s->upin_state = ups, s->upin_retries = upr, s->upuk_retries = upk;
				s->app_type = ty, s->app_state = st, s->perso_state = ps, s->upin_replaces_pin1 = rep;
				s->pin1_state = p1, s->pin1_retries = p1r, s->puk1_retries = k1r;
			}
			if (s && !r->bad && gw == 0xffff && c == 0)
				s->card_state = cs, s->card_error = err;
		}
		if (s && !r->bad && c == 0 && !s->have_app)
			s->card_state = cs, s->card_error = err;
	}
}
static void d_card_status(FILE *o, struct rd *r) { card_status_walk(o, r, NULL); }

int uim_parse_card_status(const struct qmi_msg *m, struct uim_status *s)
{
	const struct qmi_tlv *t = qmi_find(m, 0x10);
	struct rd r;

	if (!t)
		return -1;
	r = (struct rd){t->val, t->len, 0};
	card_status_walk(NULL, &r, s);
	return r.bad || r.n ? -1 : 0;
}
/* WDS */
void ipv4_str(uint32_t v, char *s, size_t n)
{
	snprintf(s, n, "%u.%u.%u.%u", v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}
static void d_ipv4(FILE *o, struct rd *r)
{
	char s[20];

	ipv4_str(u32(r), s, sizeof(s));
	fprintf(o, "%s", s);
}
static void d_str_all(FILE *o, struct rd *r)	/* top-level string TLV: the whole value */
{
	char s[300];

	text(r, r->n, s, sizeof(s));
	fprintf(o, "\"%s\"", s);
}
static void d_hex32(FILE *o, struct rd *r) { fprintf(o, "0x%08x", (unsigned)u32(r)); }
static const struct name wds_end_types[] = {
	{1, "mip"}, {2, "internal"}, {3, "call-manager"}, {6, "3gpp"}, {7, "ppp"}, {8, "ehrpd"}, {9, "ipv6"}, {0, NULL}};
static void d_verbose_end(FILE *o, struct rd *r)
{
	unsigned ty = u16(r);
	int re = s16(r);

	fprintf(o, "type=%u (%s) reason=%d", ty, lookup(wds_end_types, (int)ty), re);
}
static const struct name ip_families[] = {{0, "unknown"}, {4, "ipv4"}, {6, "ipv6"}, {8, "unspecified"}, {12, "ethernet"}, {0, NULL}};
static void d_ip_family(FILE *o, struct rd *r) { unsigned v = u8(r); fprintf(o, "%u (%s)", v, lookup(ip_families, (int)v)); }
static void d_profile_id(FILE *o, struct rd *r)
{
	unsigned t = u8(r), i = u8(r);

	fprintf(o, "type=%u (%s) index=%u", t, t == 0 ? "3gpp" : t == 1 ? "3gpp2" : "?", i);
}
static void d_mask(FILE *o, struct rd *r)
{
	uint32_t v = u32(r);
	char s[20];
	int p = 0;

	ipv4_str(v, s, sizeof(s));
	while (p < 32 && (v & (0x80000000u >> p)))
		p++;
	fprintf(o, "%s (/%d)", s, p);
}
static const struct name conn_status[] = {
	{0, "unknown"}, {1, "disconnected"}, {2, "connected"}, {3, "suspended"}, {4, "authenticating"}, {0, NULL}};
static void d_conn_status(FILE *o, struct rd *r) { unsigned v = u8(r); fprintf(o, "%u (%s)", v, lookup(conn_status, (int)v)); }

int wds_parse_settings(const struct qmi_msg *m, struct wds_settings *s)
{
	static const struct { uint8_t t; unsigned bit; size_t off; } f[] = {
		{0x1e, 1, offsetof(struct wds_settings, ip)}, {0x20, 2, offsetof(struct wds_settings, gw)},
		{0x21, 4, offsetof(struct wds_settings, mask)}, {0x15, 8, offsetof(struct wds_settings, dns1)},
		{0x16, 16, offsetof(struct wds_settings, dns2)}, {0x29, 32, offsetof(struct wds_settings, mtu)}};

	memset(s, 0, sizeof(*s));
	for (size_t i = 0; i < sizeof(f) / sizeof(f[0]); i++) {
		const struct qmi_tlv *t = qmi_find(m, f[i].t);

		if (t && t->len == 4) {
			*(uint32_t *)((char *)s + f[i].off) = le32(t->val);
			s->have |= f[i].bit;
		}
	}
	return s->have & 1 ? 0 : -1;
}

/* WDA */
static const struct name wda_llp[] = {{0, "unknown"}, {1, "802.3"}, {2, "raw-ip"}, {3, "ethernet-pdu"}, {0, NULL}};
static const struct name wda_agg[] = {
	{0, "disabled"}, {1, "tlp"}, {2, "qc-ncm"}, {3, "mbim"}, {4, "rndis"}, {5, "qmap"}, {6, "qmapv2"},
	{7, "qmapv3"}, {8, "qmapv4"}, {9, "qmapv5"}, {0, NULL}};
static void d_llp(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(wda_llp, (int)v)); }
static void d_agg(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(wda_agg, (int)v)); }
static void d_ep(FILE *o, struct rd *r)
{
	uint32_t t = u32(r), i = u32(r);

	fprintf(o, "type=%u iface=%u", (unsigned)t, (unsigned)i);
}

static const struct name ep_types[] = {
	{0, "undefined"}, {1, "hsic"}, {2, "hsusb"}, {3, "pcie"}, {4, "embedded"}, {5, "bam-dmux"}, {0, NULL}};
static void d_ep_named(FILE *o, struct rd *r)
{
	uint32_t t = u32(r), i = u32(r);

	fprintf(o, "type=%u (%s) iface=%u", (unsigned)t, lookup(ep_types, (int)t), (unsigned)i);
}
/* DPM open port request lists (one u8 count each) */
static void d_dpm_ctl(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	for (unsigned i = 0; i < n && !r->bad; i++) {
		char s[300];

		str8(r, s, sizeof(s));
		fprintf(o, "%s[name=\"%s\" ", i ? " " : "", s);
		d_ep_named(o, r);
		fprintf(o, "]");
	}
}
static void d_dpm_hw(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	for (unsigned i = 0; i < n && !r->bad; i++) {
		uint32_t rx, tx;

		fprintf(o, "%s[", i ? " " : "");
		d_ep_named(o, r);
		rx = u32(r), tx = u32(r);
		fprintf(o, " rx-ep=%u tx-ep=%u]", (unsigned)rx, (unsigned)tx);
	}
}
static void d_dpm_sw(FILE *o, struct rd *r)
{
	unsigned n = u8(r);

	for (unsigned i = 0; i < n && !r->bad; i++) {
		char s[300];

		fprintf(o, "%s[", i ? " " : "");
		d_ep_named(o, r);
		str8(r, s, sizeof(s));
		fprintf(o, " name=\"%s\"]", s);
	}
}
static const struct name client_types[] = {{1, "tethered"}, {0xff, "unknown"}, {0, NULL}};
static void d_client_type(FILE *o, struct rd *r) { uint32_t v = u32(r); fprintf(o, "%u (%s)", (unsigned)v, lookup(client_types, (int)v)); }

static const struct tlv_desc t_dpm_open_req[] = {
	{0x10, "control-ports", d_dpm_ctl}, {0x11, "hardware-data-ports", d_dpm_hw},
	{0x12, "software-data-ports", d_dpm_sw}, {0, NULL, NULL}};
static const struct tlv_desc t_bind_req[] = {
	{0x10, "endpoint", d_ep_named}, {0x11, "mux-id", d_u8}, {0x12, "reversed", d_bool},
	{0x13, "client-type", d_client_type}, {0, NULL, NULL}};
static const struct tlv_desc t_ipfam_req[] = {{0x01, "preference", d_ip_family}, {0, NULL, NULL}};
static const struct tlv_desc t_start_req[] = {
	{0x14, "apn", d_str_all}, {0x19, "ip-family-preference", d_ip_family}, {0x31, "profile-index-3gpp", d_u8},
	{0, NULL, NULL}};
static const struct tlv_desc t_get_format_req[] = {{0x10, "endpoint", d_ep_named}, {0, NULL, NULL}};

static const struct tlv_desc t_card_status[] = {
	{0x10, "card-status", d_card_status}, {0, NULL, NULL}};
static const struct tlv_desc t_start_net[] = {
	{0x01, "packet-data-handle", d_hex32}, {0x10, "call-end-reason", d_u16},
	{0x11, "verbose-call-end-reason", d_verbose_end}, {0, NULL, NULL}};
static const struct tlv_desc t_settings[] = {
	{0x10, "profile-name", d_str_all}, {0x11, "pdp-type", d_u8}, {0x14, "apn", d_str_all},
	{0x15, "dns1", d_ipv4}, {0x16, "dns2", d_ipv4}, {0x1b, "username", d_str_all}, {0x1d, "auth", d_u8},
	{0x1e, "ipv4-address", d_ipv4}, {0x1f, "profile-id", d_profile_id}, {0x20, "ipv4-gateway", d_ipv4},
	{0x21, "ipv4-subnet-mask", d_mask}, {0x29, "mtu", d_u32}, {0x2b, "ip-family", d_ip_family},
	{0x2c, "imcn-flag", d_s8}, {0x2d, "extended-technology", d_u16}, {0, NULL, NULL}};
static const struct tlv_desc t_pkt_status[] = {{0x01, "connection-status", d_conn_status}, {0, NULL, NULL}};
static const struct tlv_desc t_data_format[] = {
	{0x10, "qos-format", d_bool}, {0x11, "link-layer-protocol", d_llp}, {0x12, "ul-aggregation", d_agg},
	{0x13, "dl-aggregation", d_agg}, {0x14, "ndp-signature", d_hex32}, {0x15, "dl-max-datagrams", d_u32},
	{0x16, "dl-max-size", d_u32}, {0x17, "ul-max-datagrams", d_u32}, {0x18, "ul-max-size", d_u32},
	{0x1a, "dl-min-padding", d_u32}, {0x1b, "flow-control", d_u8}, {0, NULL, NULL}};
static const struct tlv_desc t_data_format_req[] = {
	{0x11, "link-layer-protocol", d_llp}, {0x12, "ul-aggregation", d_agg}, {0x13, "dl-aggregation", d_agg},
	{0x15, "dl-max-datagrams", d_u32}, {0x16, "dl-max-size", d_u32}, {0x17, "endpoint", d_ep},
	{0x1b, "ul-max-datagrams", d_u32}, {0x1c, "ul-max-size", d_u32}, {0, NULL, NULL}};

static void scan_summary(FILE *o, const char *pfx, const struct qmi_msg *m);

static const struct msg_desc {
	int svc;
	uint16_t id;
	const char *name;
	const struct tlv_desc *tlvs;	/* responses / indications */
	void (*extra)(FILE *o, const char *pfx, const struct qmi_msg *m);
	const struct tlv_desc *req;	/* requests (NULL: same table) */
} msgs[] = {
	{QMI_SVC_DMS, DMS_GET_OPERATING_MODE, "get_operating_mode", t_dms_get_mode, NULL, NULL},
	{QMI_SVC_DMS, DMS_SET_OPERATING_MODE, "set_operating_mode", t_none, NULL, NULL},
	{QMI_SVC_NAS, NAS_NETWORK_SCAN, "network_scan", t_scan, scan_summary, NULL},
	{QMI_SVC_NAS, NAS_GET_SERVING_SYSTEM, "get_serving_system", t_serving, NULL, NULL},
	{QMI_SVC_NAS, NAS_GET_RF_BAND_INFO, "get_rf_band_info", t_rfband, NULL, NULL},
	{QMI_SVC_NAS, NAS_GET_SYSTEM_INFO, "get_system_info", t_sysinfo, NULL, NULL},
	{QMI_SVC_NAS, NAS_GET_SIGNAL_INFO, "get_signal_info", t_signal, NULL, NULL},
	{QMI_SVC_UIM, UIM_GET_CARD_STATUS, "get_card_status", t_card_status, NULL, NULL},
	{QMI_SVC_WDS, WDS_START_NETWORK, "start_network", t_start_net, NULL, t_start_req},
	{QMI_SVC_WDS, WDS_STOP_NETWORK, "stop_network", t_none, NULL, NULL},
	{QMI_SVC_WDS, WDS_GET_PACKET_SERVICE_STATUS, "get_packet_service_status", t_pkt_status, NULL, NULL},
	{QMI_SVC_WDS, WDS_GET_CURRENT_SETTINGS, "get_current_settings", t_settings, NULL, NULL},
	{QMI_SVC_WDS, WDS_SET_IP_FAMILY, "set_ip_family", t_none, NULL, t_ipfam_req},
	{QMI_SVC_WDS, WDS_BIND_MUX_DATA_PORT, "bind_mux_data_port", t_none, NULL, t_bind_req},
	{QMI_SVC_WDA, WDA_SET_DATA_FORMAT, "set_data_format", t_data_format, NULL, t_data_format_req},
	{QMI_SVC_WDA, WDA_GET_DATA_FORMAT, "get_data_format", t_data_format, NULL, t_get_format_req},
	{QMI_SVC_DPM, DPM_OPEN_PORT, "open_port", t_none, NULL, t_dpm_open_req},
	{QMI_SVC_DPM, DPM_CLOSE_PORT, "close_port", t_none, NULL, NULL},
	{0, 0, NULL, NULL, NULL, NULL}};

const char *qmi_svc_name(int service)
{
	return service == QMI_SVC_DMS ? "DMS" : service == QMI_SVC_NAS ? "NAS" : service == QMI_SVC_UIM ? "UIM"
		: service == QMI_SVC_WDS ? "WDS" : service == QMI_SVC_WDA ? "WDA" : service == QMI_SVC_DPM ? "DPM" : "QMI";
}

const char *qmi_msg_name(int service, uint16_t id)
{
	for (const struct msg_desc *d = msgs; d->name; d++)
		if (d->svc == service && d->id == id)
			return d->name;
	return NULL;
}

static void scan_summary(FILE *o, const char *pfx, const struct qmi_msg *m)
{
	const struct qmi_tlv *ti = qmi_find(m, 0x10), *tr = qmi_find(m, 0x11), *tp = qmi_find(m, 0x12);
	struct rd ri, rr = {0}, rp = {0};
	unsigned n, nr = 0, np = 0;

	if (!ti) {
		fprintf(o, "%snetworks found: none (no TLV 0x10)\n", pfx);
		return;
	}
	ri = (struct rd){ti->val, ti->len, 0};
	n = u16(&ri);
	if (tr) {
		rr = (struct rd){tr->val, tr->len, 0};
		nr = u16(&rr);
	}
	if (tp) {
		rp = (struct rd){tp->val, tp->len, 0};
		np = u16(&rp);
	}
	fprintf(o, "%snetworks found: %u\n", pfx, n);
	for (unsigned i = 0; i < n && !ri.bad; i++) {
		unsigned mcc = u16(&ri), mnc = u16(&ri), st = u8(&ri);
		char d[200], rat[64] = "?", mncs[8];
		int pcs = 0;

		str8(&ri, d, sizeof(d));
		if (ri.bad)
			break;
		/* 0x11/0x12 list the same networks in the same order; check mcc/mnc anyway */
		if (i < nr && !rr.bad) {
			unsigned a = u16(&rr), b = u16(&rr);
			int v = s8(&rr);

			if (!rr.bad)
				snprintf(rat, sizeof(rat), "%s%s", nas_radio_name(v), a == mcc && b == mnc ? "" : "(mcc/mnc mismatch)");
		}
		if (i < np && !rp.bad) {
			unsigned a = u16(&rp), b = u16(&rp), v = u8(&rp);

			pcs = !rp.bad && a == mcc && b == mnc && v;
		}
		snprintf(mncs, sizeof(mncs), pcs || mnc > 99 ? "%03u" : "%02u", mnc);
		fprintf(o, "%snet[%u] mcc=%03u mnc=%s rat=%s status=0x%02x", pfx, i, mcc, mncs, rat, st);
		fprintf(o, "%s%s%s%s%s%s%s%s", st & 1 ? " current-serving" : "", st & 2 ? " available" : "",
			st & 4 ? " home" : "", st & 8 ? " roaming" : "", st & 16 ? " forbidden" : "",
			st & 32 ? " not-forbidden" : "", st & 64 ? " preferred" : "", st & 128 ? " not-preferred" : "");
		fprintf(o, " description=\"%s\"\n", d);
	}
	if (ri.bad)
		fprintf(o, "%snetworks: TLV 0x10 truncated (raw above)\n", pfx);
}

int qmi_print(FILE *o, int service, const uint8_t *buf, size_t n, int verbose)
{
	static struct qmi_msg m;	/* large; not reentrant (single-threaded tool) */
	const struct msg_desc *d;
	const char *svc = qmi_svc_name(service);
	char err[160], pfx[96], name[32];
	uint16_t res, e;
	int rc, raw;

	if (qmi_parse(buf, n, &m, err, sizeof(err))) {
		fprintf(o, "%s: malformed message (%s): ", svc, err);
		qmi_hex(o, buf, n);
		fprintf(o, "\n");
		return 2;
	}
	for (d = msgs; d->name; d++)
		if (d->svc == service && d->id == m.msg_id)
			break;
	if (d->name)
		snprintf(name, sizeof(name), "%s", d->name);
	else
		snprintf(name, sizeof(name), "msg_0x%04x", m.msg_id);
	snprintf(pfx, sizeof(pfx), "%s %s: ", svc, name);
	fprintf(o, "%s%s txn=%u msg=0x%04x len=%u", pfx,
		m.type == QMI_RESPONSE ? "response" : m.type == QMI_INDICATION ? "indication" : m.type == QMI_REQUEST ? "request" : "type?",
		m.txn, m.msg_id, m.len);
	if (m.trailing)
		fprintf(o, " (+%zu trailing bytes ignored)", m.trailing);
	if (m.type != QMI_RESPONSE) {
		rc = 0;
	} else if (qmi_result(&m, &res, &e)) {
		const struct qmi_tlv *t = qmi_find(&m, 0x02);

		fprintf(o, " result TLV 0x02 %s", t ? "has a wrong length" : "MISSING");
		rc = 2;
	} else {
		fprintf(o, " result=%s", res == 0 ? "success" : res == 1 ? "FAILURE" : "?");
		if (res != 0 || e != 0)
			fprintf(o, " error=0x%04x (%s)", e, qmi_error_name(e));
		rc = res == 0 && e == 0 ? 0 : 1;
	}
	fprintf(o, "\n");
	/* a failure: every TLV also as hex, so nothing the modem said is lost (never for UIM) */
	raw = verbose || (rc == 1 && service != QMI_SVC_UIM);
	if (rc == 1 && service != QMI_SVC_UIM)
		fprintf(o, "%sfailure: %d TLV(s) in the response, all printed with raw bytes\n", pfx, m.ntlv);
	for (int i = 0; i < m.ntlv; i++) {
		const struct qmi_tlv *t = &m.tlv[i];
		const struct tlv_desc *td = NULL;

		if (t->type == 0x02 && m.type == QMI_RESPONSE && t->len == 4) {
			if (raw) {
				fprintf(o, "%stlv 0x02 result raw: ", pfx);
				qmi_hex(o, t->val, t->len);
				fprintf(o, "\n");
			}
			continue;
		}
		if (d->name) {
			const struct tlv_desc *tab = d->tlvs;

			if (m.type == QMI_REQUEST && d->req)
				tab = d->req;
			for (td = tab; td->name && td->type != t->type; td++)
				;
		}
		if (td && td->name) {
			struct rd r = {t->val, t->len, 0};
			char *s = NULL;
			size_t sl = 0;
			FILE *mo = open_memstream(&s, &sl);	/* decode first, print only if it fit */

			if (!mo)
				return 2;
			td->fn(mo, &r);
			fclose(mo);
			if (r.bad || r.n) {
				fprintf(o, "%stlv 0x%02x %s: PARSE ERROR (%s, %zu of %u bytes left)", pfx, t->type,
					td->name, r.bad ? "too short" : "longer than defined", r.bad ? (size_t)0 : r.n, t->len);
				if (service == QMI_SVC_UIM) {	/* SIM data: never raw */
					fprintf(o, " [UIM data not printed]\n");
				} else {
					fprintf(o, ", raw: ");
					qmi_hex(o, t->val, t->len);
					fprintf(o, "\n");
				}
			} else {
				fprintf(o, "%stlv 0x%02x %s: %s\n", pfx, t->type, td->name, s);
				if (raw && service != QMI_SVC_UIM) {
					fprintf(o, "%stlv 0x%02x raw: ", pfx, t->type);
					qmi_hex(o, t->val, t->len);
					fprintf(o, "\n");
				}
			}
			free(s);
		} else if (service == QMI_SVC_UIM) {
			/* UIM TLVs carry SIM identifiers (ICCID, IMSI, EF contents): never dump them raw */
			fprintf(o, "%stlv 0x%02x (not decoded) len=%u: [UIM data not printed]\n", pfx, t->type, t->len);
		} else {
			fprintf(o, "%stlv 0x%02x (not decoded) len=%u: ", pfx, t->type, t->len);
			qmi_hex(o, t->val, t->len);
			fprintf(o, "\n");
		}
	}
	if (d->name && d->extra && m.type == QMI_RESPONSE)
		d->extra(o, pfx, &m);
	return rc;
}
