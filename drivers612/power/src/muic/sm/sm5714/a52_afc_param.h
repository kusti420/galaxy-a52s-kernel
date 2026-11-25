/* SPDX-License-Identifier: GPL-2.0 */
/*
 * a52sxq 6.12: keep the "Fast charging" off switch (afc_disable) across reboots.
 *
 * 5.4 (built-in): sm5714_muic_set_afc_disable() -> sec_set_param(param_index_afc_disable, '0'/'1')
 * (drivers/samsung/sec_param.c) stores it as a u32 in struct sec_param_data of the "param" partition
 * (struct at CONFIG_SEC_PARAM_SIZE 0xA00000 - 0x100000, afc_disable right after
 * wireless_charging_mode); the bootloader hands it back as bits 8..15 of
 * "sec_mparam.charging_mode=" (0x3000 = on, 0x3100 = off), read by get_afc_mode().
 * 6.12 has no sec_param (IS_BUILTIN branch compiled out), so the switch was lost at every reboot.
 *
 * Here: only that one u32 is written, from a kworker like 5.4, and only if all of this holds:
 *  - the bootloader states where the struct is: "androidboot.cm.param.offset=" (offset of
 *    wireless_charging_mode, 9437632 = 0x9001C0 on A528BXXU5FWK4); afc_disable = that + 4
 *  - the struct starts with a Samsung debug level (0x4f4c LOW, 0x494d MID, 0x4948 HIGH)
 *  - the field currently holds 0, '0' or '1'
 * Anything else: nothing is written, one log line.
 * OFF by default (unproven raw write to the param partition): enable at run time with
 *   echo 1 > /sys/module/muic_sm5714/parameters/a52_afc_param_write
 * or at load with "muic_sm5714 a52_afc_param_write=1" in modules.options.
 */
#ifndef A52_AFC_PARAM_H
#define A52_AFC_PARAM_H
#include <linux/fs.h>
#include <linux/of.h>
#include <linux/string.h>
#include <linux/workqueue.h>

#define A52_PARAM_CM_FIELD	448	/* offsetof(struct sec_param_data, wireless_charging_mode) */

static bool a52_afc_param_write;	/* off until proven on a test phone */
module_param(a52_afc_param_write, bool, 0644);

static void a52_afc_param_work_fn(struct work_struct *work);
static DECLARE_WORK(a52_afc_param_work, a52_afc_param_work_fn);
static atomic_t a52_afc_param_val = ATOMIC_INIT(-1);

static long a52_afc_param_cm_offset(void)
{
	static const char word[] = "androidboot.cm.param.offset=";
	const char *args = NULL, *p;
	char num[16];
	long off;

	if (!of_chosen || of_property_read_string(of_chosen, "bootargs", &args) || !args)
		return -ENOENT;
	p = strstr(args, word);
	if (!p || (p != args && p[-1] != ' '))
		return -ENOENT;
	strscpy(num, p + sizeof(word) - 1, sizeof(num));
	*strchrnul(num, ' ') = '\0';
	if (kstrtol(num, 0, &off) || off < A52_PARAM_CM_FIELD || off > (64L << 20))
		return -EINVAL;
	return off;
}

static void a52_afc_param_work_fn(struct work_struct *work)
{
	static const char * const names[] = {
		"/dev/block/bootdevice/by-name/param", "/dev/block/by-name/param" };
	int v = atomic_xchg(&a52_afc_param_val, -1);
	long cm = a52_afc_param_cm_offset();
	struct file *f = ERR_PTR(-ENOENT);
	__le32 lvl = 0, cur = 0, new;
	loff_t pos;
	ssize_t r;
	int i;

	if (v != '0' && v != '1')
		return;
	if (cm < 0) {
		pr_err("a52_afc_param: no androidboot.cm.param.offset (%ld), not stored\n", cm);
		return;
	}
	for (i = 0; i < ARRAY_SIZE(names) && IS_ERR(f); i++)
		f = filp_open(names[i], O_RDWR | O_SYNC, 0);
	if (IS_ERR(f)) {
		pr_err("a52_afc_param: open param failed (%ld), not stored\n", PTR_ERR(f));
		return;
	}
	pos = cm - A52_PARAM_CM_FIELD;
	r = kernel_read(f, &lvl, sizeof(lvl), &pos);
	pos = cm + 4;
	if (r == sizeof(lvl))
		r = kernel_read(f, &cur, sizeof(cur), &pos);
	if (r != sizeof(cur) ||
	    (le32_to_cpu(lvl) != 0x4f4c && le32_to_cpu(lvl) != 0x494d && le32_to_cpu(lvl) != 0x4948) ||
	    (le32_to_cpu(cur) != 0 && le32_to_cpu(cur) != '0' && le32_to_cpu(cur) != '1')) {
		pr_err("a52_afc_param: unexpected param contents (r %zd, level 0x%x, afc 0x%x), not stored\n",
		       r, le32_to_cpu(lvl), le32_to_cpu(cur));
		goto out;
	}
	if (le32_to_cpu(cur) == v) {
		pr_info("a52_afc_param: afc_disable already '%c'\n", v);
		goto out;
	}
	new = cpu_to_le32(v);
	pos = cm + 4;
	r = kernel_write(f, &new, sizeof(new), &pos);
	pr_info("a52_afc_param: afc_disable '%c' -> param+0x%lx (%zd)\n", v, cm + 4, r);
out:
	filp_close(f, NULL);
}

static inline void a52_afc_param_store(bool afc_disable)
{
	if (!a52_afc_param_write)
		return;
	atomic_set(&a52_afc_param_val, afc_disable ? '1' : '0');
	schedule_work(&a52_afc_param_work);
}
#endif
