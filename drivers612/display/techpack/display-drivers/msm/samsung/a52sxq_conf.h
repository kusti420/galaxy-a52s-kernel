/* SPDX-License-Identifier: GPL-2.0-only */
/* a52sxq: panel selection for the Samsung display framework (was Kconfig on 5.4). */
#define CONFIG_PANEL_S6E3FC3_AMS646YD01_LO_FHD 1
#define CONFIG_SEC_PANEL_NOTIFIER_V2 1

/*
 * mDNIe table row. The 5.4 tables were positional initialisers of struct dsi_cmd_desc with the
 * 5.4 layout of struct mipi_dsi_msg (channel, type, flags, ctrl, wait_ms, tx_len, tx_buf,
 * rx_len, rx_buf) followed by last_command, post_wait_ms, ss_txbuf. Both structs changed.
 */
#define MDNIE_CMD_LW(buf, last, wait) { \
	.msg = { .type = MIPI_DSI_DCS_LONG_WRITE, .tx_len = sizeof(buf), .tx_buf = buf }, \
	.last_command = last, .post_wait_ms = wait, .ss_txbuf = buf }
