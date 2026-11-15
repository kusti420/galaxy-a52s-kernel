/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * qmi-nas: QMI message codec (header + TLVs) and the DMS/NAS response printers.
 * Written from the published QMI message definitions (libqmi data/qmi-service-{dms,nas}.json,
 * qmi-enums-{dms,nas}.h); no libqmi code is used. Pure functions: no sockets, host-testable.
 *
 * QMI over QRTR carries no QMUX header: a datagram is the 7-byte service header
 *   u8 type (0 request, 2 response, 4 indication), u16 txn, u16 msg_id, u16 len (LE)
 * followed by len bytes of TLVs (u8 type, u16 len LE, value).
 */
#ifndef QMI_NAS_QMI_H
#define QMI_NAS_QMI_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define QMI_SVC_WDS 1
#define QMI_SVC_DMS 2
#define QMI_SVC_NAS 3
#define QMI_SVC_UIM 11
#define QMI_SVC_WDA 0x1A
#define QMI_SVC_DPM 0x2F	/* Data Port Mapper */

#define QMI_REQUEST 0
#define QMI_RESPONSE 2
#define QMI_INDICATION 4
#define QMI_HDR_LEN 7
#define QMI_MAX_TLV 160

#define DMS_GET_OPERATING_MODE 0x002D
#define DMS_SET_OPERATING_MODE 0x002E
#define NAS_NETWORK_SCAN 0x0021
#define NAS_GET_SERVING_SYSTEM 0x0024
#define NAS_GET_RF_BAND_INFO 0x0031
#define NAS_GET_SYSTEM_INFO 0x004D
#define NAS_GET_SIGNAL_INFO 0x004F

#define UIM_GET_CARD_STATUS 0x002F
#define WDS_START_NETWORK 0x0020
#define WDS_STOP_NETWORK 0x0021
#define WDS_GET_PACKET_SERVICE_STATUS 0x0022
#define WDS_GET_CURRENT_SETTINGS 0x002D
#define WDS_SET_IP_FAMILY 0x004D
#define WDS_BIND_MUX_DATA_PORT 0x00A2
#define WDA_SET_DATA_FORMAT 0x0020
#define WDA_GET_DATA_FORMAT 0x0021
#define DPM_OPEN_PORT 0x0020
#define DPM_CLOSE_PORT 0x0021

/* QmiDataEndpointType (= Qualcomm data_ep_type) */
#define QMI_EP_HSIC 1
#define QMI_EP_HSUSB 2
#define QMI_EP_PCIE 3
#define QMI_EP_EMBEDDED 4
#define QMI_EP_BAM_DMUX 5
/* QmiWdaDataAggregationProtocol */
#define WDA_AGG_QMAP 5
#define WDA_AGG_QMAPV5 9

#define DMS_MODE_ONLINE 0x00
#define DMS_MODE_LOW_POWER 0x01

struct qmi_tlv {
	uint8_t type;
	uint16_t len;
	const uint8_t *val;
};

struct qmi_msg {
	uint8_t type;
	uint16_t txn;
	uint16_t msg_id;
	uint16_t len;		/* header length field */
	size_t trailing;	/* bytes after header + len (ignored, reported) */
	int ntlv;
	struct qmi_tlv tlv[QMI_MAX_TLV];
};

/* parse a QMI message; 0 = ok, -1 = malformed (err explains, m->ntlv = TLVs parsed so far) */
int qmi_parse(const uint8_t *buf, size_t n, struct qmi_msg *m, char *err, size_t errlen);
const struct qmi_tlv *qmi_find(const struct qmi_msg *m, uint8_t type);
/* result TLV 0x02 (u16 result, u16 error); 0 = present, -1 = missing or wrong length */
int qmi_result(const struct qmi_msg *m, uint16_t *result, uint16_t *error);
const char *qmi_error_name(uint16_t error);

struct qmi_builder {
	uint8_t *buf;
	size_t cap;
	size_t len;
	int err;
};
void qmi_begin(struct qmi_builder *q, uint8_t *buf, size_t cap, uint8_t type, uint16_t txn, uint16_t msg_id);
void qmi_add_tlv(struct qmi_builder *q, uint8_t type, const void *val, uint16_t len);
void qmi_add_u8(struct qmi_builder *q, uint8_t type, uint8_t v);
int qmi_finish(struct qmi_builder *q);	/* total length, or -1 (overflow) */
void qmi_add_u32(struct qmi_builder *q, uint8_t type, uint32_t v);
/* endpoint info TLV {u32 endpoint type, u32 interface number} (WDA 0x17, WDS bind 0x10, WDA get 0x10) */
void qmi_add_ep(struct qmi_builder *q, uint8_t type, uint32_t ep_type, uint32_t iface);

/*
 * DPM OPEN_PORT request TLVs (layout checked against libqmi 1.38's own decoder of
 * qmi-service-dpm.json): 0x10 control ports [u8 n]{string8 name, u32 ep type, u32 iface},
 * 0x11 hardware data ports [u8 n]{u32 ep type, u32 iface, u32 rx ep, u32 tx ep}.
 * ctl_name NULL = no control port TLV. One entry each.
 */
void dpm_add_open_port(struct qmi_builder *q, const char *ctl_name, uint32_t ep_type, uint32_t iface,
		       uint32_t rx_ep, uint32_t tx_ep);

/* WDA SET/GET_DATA_FORMAT response: the format the modem actually applied */
struct wda_format {
	unsigned have;		/* 1 llp, 2 ul, 4 dl, 8 dl-dg, 16 dl-sz, 32 ul-dg, 64 ul-sz */
	uint32_t llp, ul, dl, dl_dg, dl_sz, ul_dg, ul_sz;
};
void wda_parse_format(const struct qmi_msg *m, struct wda_format *f);

/*
 * Print a received message: one line "<SVC> <name>: result=..." and one line per TLV, all with
 * the prefix "<SVC> <name>: ". Known TLVs are decoded; unknown TLVs, and known ones whose
 * length does not match the definition, are printed as hex. verbose: hex for every TLV too.
 * A FAILURE response of any service except UIM also gets the hex of every TLV (result TLV
 * included); UIM TLVs are never dumped (SIM identifiers).
 * Returns 0 = QMI success, 1 = QMI failure result, 2 = no/invalid result TLV or malformed.
 */
int qmi_print(FILE *o, int service, const uint8_t *buf, size_t n, int verbose);
const char *qmi_msg_name(int service, uint16_t msg_id);
const char *qmi_svc_name(int service);	/* "DMS", "WDS", ... "QMI" */
void qmi_hex(FILE *o, const uint8_t *p, size_t n);

/* name helpers (also used by the tool's summary lines) */
const char *dms_mode_name(unsigned v);
const char *nas_radio_name(int v);

/* UIM card status, the primary GW provisioning application (index TLV 0x10 "Index GW Primary") */
struct uim_status {
	int have_app;		/* 0: no GW primary application (no SIM / not detected yet) */
	unsigned ncards, card_state, card_error;
	unsigned app_type, app_state, perso_state, upin_replaces_pin1;
	unsigned pin1_state, pin1_retries, puk1_retries;
	unsigned upin_state, upin_retries, upuk_retries;
};
/* 0 = TLV 0x10 parsed (s filled), -1 = missing/malformed */
int uim_parse_card_status(const struct qmi_msg *m, struct uim_status *s);
const char *uim_pin_state_name(unsigned v);
const char *uim_app_state_name(unsigned v);
const char *uim_card_state_name(unsigned v);

/* WDS current settings (IPv4 part); bit set in .have for each field present */
struct wds_settings {
	unsigned have;		/* 1 ip, 2 gw, 4 mask, 8 dns1, 16 dns2, 32 mtu */
	uint32_t ip, gw, mask, dns1, dns2, mtu;
};
int wds_parse_settings(const struct qmi_msg *m, struct wds_settings *s);
void ipv4_str(uint32_t v, char *s, size_t n);	/* QMI u32 0xC0A80001 -> "192.0.2.1" */

/* QRTR name-service reply (struct qrtr_ctrl_pkt, 20 bytes LE): 1 = server, 0 = end of list, -1 = other */
struct qrtr_server_info {
	uint32_t service, version, instance, node, port;
};
int qrtr_parse_ctrl(const void *buf, size_t n, uint32_t *cmd, struct qrtr_server_info *s);
/* hex text ("02 01 00 ...", "0x02,0x01", "020100") -> bytes; returns count or -1 */
long qmi_unhex(const char *s, uint8_t *out, size_t cap);
#endif
