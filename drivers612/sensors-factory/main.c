// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq 6.12: Samsung's adsp_factory (netlink protocol 23 for factory_ssc / the sensor HAL,
 * /sys/class/sensors) as ONE module. The 5.4 kernel had these files built in; their initcalls
 * run here in the 5.4 order (subsys: sensors_core; device: Makefile order). A failing sensor
 * file does not undo the others (as built in).
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/printk.h>

#define A52_OBJS(X) X(sensors_core) X(adsp_factory) X(ssc_core) X(lsm6dso_accel) X(lsm6dso_gyro) \
	X(stk31610_light) X(ak09918_mag) X(flip_cover_detector)
#define DECL(n) int a52_init_##n(void);
A52_OBJS(DECL)

static int __init a52_adsp_factory_init(void)
{
	int ret;

	ret = a52_init_sensors_core();
	if (ret) { pr_err("adsp_factory: sensors_core init %d\n", ret); return ret; }
	ret = a52_init_adsp_factory();
	if (ret) {
		/* stay loaded: the class exists and cannot be torn down from init (exit code is __exit) */
		pr_err("adsp_factory: netlink init %d, sensor files not registered\n", ret);
		return 0;
	}
#define CALL(n) do { int r = a52_init_##n(); if (r) pr_err("adsp_factory: " #n " init %d\n", r); } while (0);
	CALL(ssc_core) CALL(lsm6dso_accel) CALL(lsm6dso_gyro) CALL(stk31610_light) CALL(ak09918_mag) CALL(flip_cover_detector)
	pr_info("adsp_factory: a52sxq 6.12 port loaded (netlink 23, class sensors)\n");
	return 0;
}
/* no module_exit: built in on 5.4, never unloaded (several files keep work items and notifiers) */
module_init(a52_adsp_factory_init);
MODULE_DESCRIPTION("Samsung adsp_factory for a52sxq on 6.12");
MODULE_LICENSE("GPL");
