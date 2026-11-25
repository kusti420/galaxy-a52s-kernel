/* SPDX-License-Identifier: GPL-2.0 */
/*
 * a52sxq: which userspace runs on this kernel.
 *
 * The 6.12 drivers were ported from the LineageOS/IchthysOS 5.4 tree, which changed Samsung
 * behaviour for AOSP userspace in a handful of places. One UI (stock Samsung vendor + framework)
 * needs the stock behaviour there. Where a driver cannot tell from what userspace does, it asks
 * this switch (module a52sxq.ko, drivers612/samsung-oneui/a52sxq_core):
 *
 *   kernel command line   a52sxq.userspace=samsung|aosp|auto      (One UI zips: samsung)
 *   runtime               /sys/module/a52sxq/parameters/userspace  (rw, same words)
 *
 * Drivers bind to it LATE and SOFT: a52sxq_userspace_is_samsung() looks the getter up with
 * symbol_get() on use, so a driver neither depends on a52sxq.ko in modules.dep nor cares about
 * load order, and with no a52sxq.ko loaded everything behaves as before (AOSP variant).
 * drivers612/SPEC/05-lineage-vs-stock-5.4-diffs.md lists every behaviour that hangs off it.
 */
#ifndef _LINUX_A52SXQ_USERSPACE_H
#define _LINUX_A52SXQ_USERSPACE_H

#include <linux/compiler.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/types.h>

enum a52sxq_userspace {
	A52SXQ_US_AUTO = 0,	/* setting only: resolve from hints, AOSP until one arrives */
	A52SXQ_US_AOSP = 1,	/* LineageOS, IchthysOS: open HALs, AOSP framework */
	A52SXQ_US_SAMSUNG = 2,	/* One UI: stock Samsung vendor + framework */
};

/* Effective value: A52SXQ_US_AOSP or A52SXQ_US_SAMSUNG, never AUTO. Any context. */
int a52sxq_userspace_get(void);
/*
 * A driver saw userspace do something only one of the two does (example: a non-zero
 * mask_brightness write with no 0 before it = One UI framework). Only used while the setting is
 * auto; an explicit command line / sysfs setting always wins. Process context.
 */
void a52sxq_userspace_hint(int us, const char *why);
/* Blocking chain, called with the new effective value on every change. */
int a52sxq_userspace_register_notifier(struct notifier_block *nb);
int a52sxq_userspace_unregister_notifier(struct notifier_block *nb);

#ifndef A52SXQ_CORE_ITSELF
/* Soft binding for consumers. Safe in atomic context (symbol_get only disables preemption). */
static inline bool a52sxq_userspace_is_samsung(void)
{
	static int (*a52sxq_us_get)(void);
	int (*get)(void) = READ_ONCE(a52sxq_us_get);

	if (unlikely(!get)) {
		get = symbol_get(a52sxq_userspace_get);
		if (!get)
			return false;	/* a52sxq.ko not loaded (yet): AOSP variant, as before */
		/* the module reference is kept for good: a52sxq.ko has no exit function */
		WRITE_ONCE(a52sxq_us_get, get);
	}
	return get() == A52SXQ_US_SAMSUNG;
}
#endif

#endif
