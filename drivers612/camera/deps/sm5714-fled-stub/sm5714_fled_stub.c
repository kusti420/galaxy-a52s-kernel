// SPDX-License-Identifier: GPL-2.0-only
/*
 * Stand-in for the three symbols camera.ko imports from the SM5714 flash LED
 * driver (leds-sm5714-fled.c). For camera bring-up without the SM5714
 * charger/MFD stack ONLY: flash and torch do nothing and say so. Never load
 * it together with the real driver (drivers612/power, src/leds54).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sysfs.h>
#include <linux/types.h>

int32_t sm5714_fled_mode_ctrl(int state, uint32_t brightness);
ssize_t sm5714_store(const char *buf);
ssize_t sm5714_show(char *buf);

int32_t sm5714_fled_mode_ctrl(int state, uint32_t brightness)
{
	pr_warn_ratelimited("sm5714-fled-stub: mode %d brightness %u ignored\n",
			    state, brightness);
	return -ENODEV;
}
EXPORT_SYMBOL_GPL(sm5714_fled_mode_ctrl);

ssize_t sm5714_store(const char *buf)
{
	return -ENODEV;
}
EXPORT_SYMBOL(sm5714_store);

ssize_t sm5714_show(char *buf)
{
	return sysfs_emit(buf, "0\n");
}
EXPORT_SYMBOL(sm5714_show);

MODULE_DESCRIPTION("SM5714 flash LED stub for camera bring-up");
MODULE_LICENSE("GPL");
