// SPDX-License-Identifier: GPL-2.0-only
/*
 * QEMU-only stand-in for drivers612/conn/subsys_compat (loaded with yield_to=msub_fakeowner): registers the
 * msm_subsys bus with one device, to prove that a52sxq_msm_subsys hands the
 * bus over before this module's init runs and takes it back after rmmod.
 * Never ship this.
 */
#include <linux/device.h>
#include <linux/module.h>

static const struct bus_type fake_bus = { .name = "msm_subsys" };
static struct device fake_dev;

static void fake_release(struct device *dev)
{
}

static int __init fake_init(void)
{
	int ret = bus_register(&fake_bus);

	pr_info("msub_fakeowner: bus_register %d\n", ret);
	if (ret)
		return ret;
	fake_dev.bus = &fake_bus;
	fake_dev.release = fake_release;
	dev_set_name(&fake_dev, "subsys99");
	ret = device_register(&fake_dev);
	pr_info("msub_fakeowner: device_register %d\n", ret);
	if (ret) {
		put_device(&fake_dev);
		bus_unregister(&fake_bus);
	}
	return ret;
}

static void __exit fake_exit(void)
{
	device_unregister(&fake_dev);
	bus_unregister(&fake_bus);
}

module_init(fake_init);
module_exit(fake_exit);
MODULE_DESCRIPTION("QEMU test stand-in for subsys_compat");
MODULE_LICENSE("GPL");
