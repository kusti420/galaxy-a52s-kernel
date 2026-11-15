/* a52sxq 6.12: stub. sec_battery.c includes this unconditionally; its only user
 * (secdbg_exin_set_batt) is under CONFIG_SEC_DEBUG_EXTRA_INFO, which is off here. */
#ifndef __A52SXQ_SEC_DEBUG_STUB_H__
#define __A52SXQ_SEC_DEBUG_STUB_H__
/* 5.4: drivers/samsung/debug/sec_hw_param.c (last battery values for the reset-reason
 * hardware-parameter dump). Not ported: no-op. */
static inline void battery_last_dcvs(int cap, int volt, int temp, int curr) {}
#endif
