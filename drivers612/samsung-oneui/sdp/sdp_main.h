/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SDP_MAIN_H_
#define SDP_MAIN_H_
struct device;
int dek_init(void);
void dek_exit(void);
void dek_log_purge(void);
void kek_pack_exit(void);
void dek_remove_sysfs(struct device *req, struct device *log);
int pub_crypto_mod_init(void);
void pub_crypto_mod_exit(void);
int sdp_fs_handler_mod_init(void);
void sdp_fs_handler_mod_exit(void);
#endif
