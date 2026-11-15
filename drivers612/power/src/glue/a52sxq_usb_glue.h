/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __A52SXQ_USB_GLUE_H__
#define __A52SXQ_USB_GLUE_H__
#include <linux/types.h>
/* The four hooks Samsung patched into dwc3-msm on 5.4 (and on S26); here they drive an
 * extcon device that the unmodified BSP dwc3-msm listens to. */
int dwc_msm_id_event(bool enable);
int dwc_msm_vbus_event(bool enable);
int is_dwc3_msm_probe_done(void);
void dwc3_max_speed_setting(int speed);
int gadget_speed(void);
/* CC orientation for the SuperSpeed PHY lane select: 0 = CC1 (normal), 1 = CC2 (flipped). */
void a52sxq_usb_glue_set_orientation(int flipped);
#endif
