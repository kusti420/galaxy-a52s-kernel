/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * /sys/class/sec for the Samsung board drivers of the Galaxy A52s 5G on kernel 6.12.
 *
 * Same three functions and the same sec_device_create() macro as the phone's 5.4 kernel
 * (include/linux/samsung/sec_class.h, drivers/samsung/sec_class.c), so Samsung drivers that
 * are carried forward include <linux/sec_class.h> and compile unchanged.
 */
#ifndef __SEC_CLASS_H__
#define __SEC_CLASS_H__

#include <linux/device.h>

struct device *sec_dev_get_by_name(const char *name);
void sec_device_destroy(dev_t devt);
struct device *___sec_device_create(void *drvdata, const char *fmt);

#define sec_device_create(__drvdata, __fmt)				\
	___sec_device_create(__drvdata, __fmt)

#endif /* __SEC_CLASS_H__ */
