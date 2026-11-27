/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef _SEC_WCD_SYSFS_CB_H
#define _SEC_WCD_SYSFS_CB_H

struct snd_soc_component;

void register_mbhc_jack_cb(struct snd_soc_component *component);
void unregister_mbhc_jack_cb(void);

#endif /* _SEC_WCD_SYSFS_CB_H */
