/* SPDX-License-Identifier: GPL-2.0-only */
/* Samsung /sys/wifi interface for macloader (from the SM-A528B 5.4 icnss2). */
#ifndef _ICNSS_SEC_WIFI_SYSFS_H
#define _ICNSS_SEC_WIFI_SYSFS_H

struct icnss_priv;

#ifdef CONFIG_SEC_SS_CNSS_FEATURE_SYSFS
int sec_create_wifi_sysfs(struct icnss_priv *priv);
void sec_remove_wifi_sysfs(struct icnss_priv *priv);
void sec_wifi_wait_macloader(void);
int sec_wifi_ant_info(void);
#else
static inline int sec_create_wifi_sysfs(struct icnss_priv *priv) { return 0; }
static inline void sec_remove_wifi_sysfs(struct icnss_priv *priv) { }
static inline void sec_wifi_wait_macloader(void) { }
static inline int sec_wifi_ant_info(void) { return 0; }
#endif

#endif
