/* SPDX-License-Identifier: GPL-2.0 */
/* sb_oneui_attrs.h: battery/pass_through + battery/sub_bat_temp_raw (One UI 9 port parity, see sb_oneui_attrs.c) */
#ifndef __SB_ONEUI_ATTRS_H
#define __SB_ONEUI_ATTRS_H

struct sec_battery_info;

void sb_oneui_attrs_init(struct sec_battery_info *battery);
bool sb_oneui_pass_through(void);
bool sb_oneui_pass_through_hold(struct sec_battery_info *battery);
void sb_oneui_pass_through_cable_removed(struct sec_battery_info *battery);

#endif /* __SB_ONEUI_ATTRS_H */
