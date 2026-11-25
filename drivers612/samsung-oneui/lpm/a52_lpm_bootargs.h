/* SPDX-License-Identifier: GPL-2.0 */
/*
 * a52sxq 6.12: power-off charging ("lpm") detection for code built as modules.
 *
 * 5.4 gets it from built-in code: sec_mparam.c (module_param lpcharge -> "sec_mparam.lpcharge=1")
 * and early_param("androidboot.mode") == "charger" (sec_debug_user_reset.c:91, sec_log_buf.c:58,
 * pdic_param.c). Neither works in a loadable module (early_param is compiled out, the static
 * lpcharge of sec-battery / sm5714_fuelgauge is only set by a "<module>.lpcharge=" word that
 * this bootloader does not write), so read the words from /chosen/bootargs (what the ABL
 * handed over). Same method as usb/typec/common/pdic_param.c is_lpcharge_pdic_param().
 */
#ifndef A52_LPM_BOOTARGS_H
#define A52_LPM_BOOTARGS_H
#include <linux/of.h>
#include <linux/string.h>

/* true for "<word>" at the start of the cmdline or after a space */
static inline bool a52_bootargs_has(const char *args, const char *word)
{
	size_t n = strlen(word);
	const char *p = args;

	while ((p = strstr(p, word))) {
		if ((p == args || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0' || p[n] == '\n'))
			return true;
		p += n;
	}
	return false;
}

static inline bool a52_bootargs_lpm(void)
{
	const char *args = NULL;

	if (!of_chosen || of_property_read_string(of_chosen, "bootargs", &args) || !args)
		return false;
	return a52_bootargs_has(args, "androidboot.mode=charger") ||
	       a52_bootargs_has(args, "sec_mparam.lpcharge=1") ||
	       a52_bootargs_has(args, "sec-battery.lpcharge=1") ||
	       a52_bootargs_has(args, "sec_battery.lpcharge=1") ||
	       a52_bootargs_has(args, "lpcharge=1");
}
#endif
