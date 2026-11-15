/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * The part of the phone's 5.4 include/linux/mfd/sm/sm5714/sm5714.h the camera
 * flash code uses. Provider on 6.12: the SM5714 flash LED driver
 * (leds-sm5714-fled.c, drivers612/power), which must export
 * sm5714_fled_mode_ctrl(), sm5714_store() and sm5714_show().
 */
#ifndef CAM_COMPAT_SM5714_H
#define CAM_COMPAT_SM5714_H
#include <linux/types.h>

enum sm5714_fled_mode {
	SM5714_FLED_MODE_OFF = 1,
	SM5714_FLED_MODE_MAIN_FLASH,
	SM5714_FLED_MODE_TORCH_FLASH,
	SM5714_FLED_MODE_PREPARE_FLASH,
	SM5714_FLED_MODE_CLOSE_FLASH,
	SM5714_FLED_MODE_PRE_FLASH,
};

enum {
	FLED_MODE_OFF       = 0x0,
	FLED_MODE_TORCH     = 0x1,
	FLED_MODE_FLASH     = 0x2,
	FLED_MODE_EXTERNAL  = 0x3,
};

extern int32_t sm5714_fled_mode_ctrl(int state, uint32_t brightness);
#endif
