/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung lock-screen USB restriction ("block USB connections while locked", usb_sl) at run time.
 *
 * The stock 5.4 kernel compiles it in, the LineageOS 5.4 tree sets
 * CONFIG_DISABLE_LOCKSCREEN_USB_RESTRICTION and drivers612/power/Kbuild copied that. In the three
 * usb_notify_layer sources every "#ifndef CONFIG_DISABLE_LOCKSCREEN_USB_RESTRICTION" block is now
 * compiled in and guarded by a52_usb_lockrestrict(): true only under a52sxq.userspace=samsung
 * (a52sxq.ko, soft binding: no depends entry). False (aosp, or no a52sxq.ko) = the branch the
 * LineageOS configuration compiled, statement for statement. See drivers612/SPEC/05 P1-2.
 */
#ifndef _A52_USB_LOCKRESTRICT_H
#define _A52_USB_LOCKRESTRICT_H

#undef CONFIG_DISABLE_LOCKSCREEN_USB_RESTRICTION	/* prototypes of <linux/usb_notify.h> */
#ifndef CONFIG_USE_USB_COMMUNICATIONS_CAPABLE
#define CONFIG_USE_USB_COMMUNICATIONS_CAPABLE 1		/* record NOTIFY_EVENT_PD_USB_COMM_CAPABLE (stock =y) */
#endif

#include <linux/a52sxq_userspace.h>

static inline bool a52_usb_lockrestrict(void)
{
	return a52sxq_userspace_is_samsung();
}

#endif
