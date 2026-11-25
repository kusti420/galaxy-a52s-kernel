/* SPDX-License-Identifier: GPL-2.0-only */
/* 5.4 -> 6.12 API names used by the Samsung SDP sources (force-included, see Kbuild) */
#ifndef SDP_COMPAT_H_
#define SDP_COMPAT_H_
#include <linux/slab.h>
#include <linux/timekeeping.h>
#define kzfree(p) kfree_sensitive(p)
#endif
