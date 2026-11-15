// SPDX-License-Identifier: GPL-2.0-only
/*
 * Watchdog on the Qualcomm "Haven" hypervisor's virtual watchdog (SM7325 / A52s), for the
 * bring-up kernels of the a52sxq-mainline project. The hardware watchdog at 0x17c10000 belongs
 * to the hypervisor; the guest gets this one through vendor-hypervisor SMC calls.
 *
 * Interface taken from the phone's 5.4 kernel, drivers/virt/haven/hh_virt_wdt.c:
 *   0x0005 CONTROL   arg 3 = enable, 2 = disable (bit 1 must always be set)
 *   0x0007 PET
 *   0x0008 SET_TIME  (bark, bite), u16 each, 0xFFFF = no change; in milliseconds of busy
 *                    time (see hhwdt_set)
 * A return value of 0 in x0 is success. The bite resets the phone.
 */
#include <linux/arm-smccc.h>
#include <linux/module.h>
#include <linux/watchdog.h>

#define VIRT_WDT_FN(n) \
	ARM_SMCCC_CALL_VAL(ARM_SMCCC_FAST_CALL, ARM_SMCCC_SMC_32, ARM_SMCCC_OWNER_VENDOR_HYP, n)
#define VIRT_WDT_CONTROL	VIRT_WDT_FN(0x0005)
#define VIRT_WDT_STATUS		VIRT_WDT_FN(0x0006)
#define VIRT_WDT_PET		VIRT_WDT_FN(0x0007)
#define VIRT_WDT_SET_TIME	VIRT_WDT_FN(0x0008)

#define VIRT_WDT_NO_CHANGE	0xFFFF

#define HHWDT_MAX_TIMEOUT	60
#define HHWDT_BITE_AFTER_BARK	5000	/* ms from bark to the reset */

static int hhwdt_call(u32 fn, unsigned long a1, unsigned long a2)
{
	struct arm_smccc_res res;

	arm_smccc_1_1_smc(fn, a1, a2, &res);
	return res.a0 ? -EIO : 0;
}

static int hhwdt_set(struct watchdog_device *wdd)
{
	/*
	 * Units are MILLISECONDS (u16: at most 65 s), counted from the last pet, and the counter
	 * only advances while the CPUs are busy: the hypervisor's virtual watchdog rides on the
	 * SoC watchdog, which stops in idle power collapse. Measured 2026-11-12:
	 *  - 60/65 on an idle shell: no bite in 90 s; the same values across a kexec: "Warm Reset
	 *    by Watchdog Bite" a few seconds later, the new kernel dead within ~65 ms of boot work;
	 *  - 20/25 and 8/12: bite within 0.1 s; 1000/2000 and more on an idle system: nothing in 60 s.
	 * (Earlier readings of "seconds" and of "instant bite through the driver" were this: 30 or
	 * 35 meant 30 ms.) So a timeout only bounds BUSY time; a kernel that hangs with idle CPUs
	 * is not caught. Timeouts above 60 s cannot be programmed.
	 */
	u32 bark = min_t(u32, wdd->timeout * 1000, 60000);
	u32 bite = bark + HHWDT_BITE_AFTER_BARK;
	int ret;

	/* as the 5.4 driver does it: one call per value, the other left unchanged */
	ret = hhwdt_call(VIRT_WDT_SET_TIME, bark, VIRT_WDT_NO_CHANGE);
	if (ret)
		return ret;
	return hhwdt_call(VIRT_WDT_SET_TIME, VIRT_WDT_NO_CHANGE, bite);
}

/* /sys/module/hhwdt/parameters/status: raw answer of the STATUS call (5.4 prints a1 bit 0 =
 * enabled, a2 = time since the last pet, a1 bit 31 = expired). */
static int hhwdt_status_get(char *buf, const struct kernel_param *kp)
{
	struct arm_smccc_res res;

	arm_smccc_1_1_smc(VIRT_WDT_STATUS, 0, &res);
	return sysfs_emit(buf, "a0=%ld a1=0x%lx a2=%lu a3=%lu\n", (long)res.a0, res.a1, res.a2, res.a3);
}
static const struct kernel_param_ops hhwdt_status_ops = { .get = hhwdt_status_get };
module_param_cb(status, &hhwdt_status_ops, NULL, 0444);

/* /sys/module/hhwdt/parameters/raw: write "fn a1 a2" (hex) to issue one call; result in dmesg */
static int hhwdt_raw_set(const char *val, const struct kernel_param *kp)
{
	unsigned int fn, a1, a2;
	struct arm_smccc_res res;

	if (sscanf(val, "%x %x %x", &fn, &a1, &a2) != 3 || fn < 5 || fn > 8)
		return -EINVAL;
	arm_smccc_1_1_smc(VIRT_WDT_FN(fn), a1, a2, &res);
	pr_info("hhwdt: fn %u(%#x, %#x) -> a0=%ld a1=%#lx a2=%lu\n", fn, a1, a2, (long)res.a0, res.a1, res.a2);
	return 0;
}
static const struct kernel_param_ops hhwdt_raw_ops = { .set = hhwdt_raw_set };
module_param_cb(raw, &hhwdt_raw_ops, NULL, 0200);

static int hhwdt_start(struct watchdog_device *wdd)
{
	int ret = hhwdt_set(wdd);

	if (ret)
		return ret;
	return hhwdt_call(VIRT_WDT_CONTROL, 3, 0);
}

static int hhwdt_stop(struct watchdog_device *wdd)
{
	return hhwdt_call(VIRT_WDT_CONTROL, 2, 0);
}

static int hhwdt_ping(struct watchdog_device *wdd)
{
	return hhwdt_call(VIRT_WDT_PET, 0, 0);
}

static int hhwdt_set_timeout(struct watchdog_device *wdd, unsigned int t)
{
	int ret;

	wdd->timeout = t;
	if (!watchdog_active(wdd))
		return 0;
	/*
	 * Never reprogram the times of a running watchdog: every boot in which they were changed
	 * while it was enabled ended in an immediate bite (2026-11-11). Stop, set, start, pet.
	 */
	hhwdt_call(VIRT_WDT_CONTROL, 2, 0);
	ret = hhwdt_set(wdd);
	if (ret)
		return ret;
	ret = hhwdt_call(VIRT_WDT_CONTROL, 3, 0);
	if (ret)
		return ret;
	return hhwdt_call(VIRT_WDT_PET, 0, 0);
}

static const struct watchdog_info hhwdt_info = {
	.options = WDIOF_SETTIMEOUT | WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE,
	.identity = "haven-virt-wdt",
};

static const struct watchdog_ops hhwdt_ops = {
	.owner = THIS_MODULE,
	.start = hhwdt_start,
	.stop = hhwdt_stop,
	.ping = hhwdt_ping,
	.set_timeout = hhwdt_set_timeout,
};

static struct watchdog_device hhwdt_dev = {
	.info = &hhwdt_info,
	.ops = &hhwdt_ops,
	.min_timeout = 5,
	.max_timeout = HHWDT_MAX_TIMEOUT,
	.timeout = 30,
};

static int __init hhwdt_init(void)
{
	watchdog_set_nowayout(&hhwdt_dev, false);
	return watchdog_register_device(&hhwdt_dev);
}

static void __exit hhwdt_exit(void)
{
	watchdog_unregister_device(&hhwdt_dev);
}

module_init(hhwdt_init);
module_exit(hhwdt_exit);
MODULE_DESCRIPTION("Haven hypervisor virtual watchdog (a52sxq bring-up)");
MODULE_LICENSE("GPL");
