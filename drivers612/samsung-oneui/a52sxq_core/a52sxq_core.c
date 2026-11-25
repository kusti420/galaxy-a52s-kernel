// SPDX-License-Identifier: GPL-2.0
/*
 * a52sxq.ko: the one runtime switch "which userspace runs on this kernel".
 *
 *   a52sxq.userspace=samsung|aosp|auto   kernel command line (read by modprobe/libmodprobe as a
 *                                        module option AND by this module itself from
 *                                        /chosen/bootargs, so it works with a plain insmod too)
 *   /sys/module/a52sxq/parameters/userspace   rw at runtime (root): the ROM's 6.x mode writes
 *                                        "samsung" in early init; reads back the EFFECTIVE value
 *   /sys/module/a52sxq/parameters/source      ro: default | cmdline | sysfs | hint:<why>
 *
 * auto (the default) = AOSP behaviour until a driver reports a Samsung-only userspace action
 * through a52sxq_userspace_hint(). Accepted words: samsung, oneui, stock = Samsung; aosp,
 * lineage, ichthys = AOSP; auto. See include/linux/a52sxq_userspace.h and
 * drivers612/SPEC/05-lineage-vs-stock-5.4-diffs.md.
 */
#define pr_fmt(fmt) "a52sxq: " fmt
#define A52SXQ_CORE_ITSELF

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/string.h>
#include <linux/a52sxq_userspace.h>

static DEFINE_MUTEX(us_lock);
static BLOCKING_NOTIFIER_HEAD(us_chain);
static int us_setting = A52SXQ_US_AUTO;		/* what was asked for */
static int us_effective = A52SXQ_US_AOSP;	/* what drivers get */
static char us_source[48] = "default";
static bool us_init_done;

static const char *us_name(int us)
{
	switch (us) {
	case A52SXQ_US_SAMSUNG: return "samsung";
	case A52SXQ_US_AOSP: return "aosp";
	default: return "auto";
	}
}

static int us_parse(const char *s, size_t len)
{
	static const struct { const char *w; int us; } words[] = {
		{ "samsung", A52SXQ_US_SAMSUNG }, { "oneui", A52SXQ_US_SAMSUNG },
		{ "stock", A52SXQ_US_SAMSUNG }, { "aosp", A52SXQ_US_AOSP },
		{ "lineage", A52SXQ_US_AOSP }, { "ichthys", A52SXQ_US_AOSP },
		{ "auto", A52SXQ_US_AUTO },
	};
	int i;

	while (len && (s[len - 1] == '\n' || s[len - 1] == ' '))
		len--;
	for (i = 0; i < ARRAY_SIZE(words); i++)
		if (strlen(words[i].w) == len && !strncmp(s, words[i].w, len))
			return words[i].us;
	return -EINVAL;
}

/* us_lock held */
static void us_apply(int setting, int effective, const char *source)
{
	bool changed = effective != us_effective;

	us_setting = setting;
	strscpy(us_source, source, sizeof(us_source));
	WRITE_ONCE(us_effective, effective);
	pr_info("userspace = %s (setting %s, source %s)%s\n", us_name(effective), us_name(setting),
		us_source, changed ? "" : ", unchanged");
	if (changed)
		blocking_notifier_call_chain(&us_chain, effective, NULL);
}

int a52sxq_userspace_get(void)
{
	return READ_ONCE(us_effective);
}
EXPORT_SYMBOL_GPL(a52sxq_userspace_get);

void a52sxq_userspace_hint(int us, const char *why)
{
	char src[sizeof(us_source)];

	if (us != A52SXQ_US_SAMSUNG && us != A52SXQ_US_AOSP)
		return;
	mutex_lock(&us_lock);
	/* only in auto mode, and the first hint wins: no flapping between the two */
	if (us_setting == A52SXQ_US_AUTO && !strncmp(us_source, "default", 7)) {
		snprintf(src, sizeof(src), "hint:%s", why ? why : "?");
		us_apply(A52SXQ_US_AUTO, us, src);
	}
	mutex_unlock(&us_lock);
}
EXPORT_SYMBOL_GPL(a52sxq_userspace_hint);

int a52sxq_userspace_register_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_register(&us_chain, nb);
}
EXPORT_SYMBOL_GPL(a52sxq_userspace_register_notifier);

int a52sxq_userspace_unregister_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_unregister(&us_chain, nb);
}
EXPORT_SYMBOL_GPL(a52sxq_userspace_unregister_notifier);

static int us_param_set(const char *val, const struct kernel_param *kp)
{
	int us = us_parse(val, strlen(val));

	if (us < 0)
		return us;
	mutex_lock(&us_lock);
	/* before module init = module option (modprobe passes a52sxq.userspace= from the cmdline) */
	us_apply(us, us == A52SXQ_US_SAMSUNG ? A52SXQ_US_SAMSUNG : A52SXQ_US_AOSP,
		 us == A52SXQ_US_AUTO ? "default" : us_init_done ? "sysfs" : "cmdline");
	mutex_unlock(&us_lock);
	return 0;
}

static int us_param_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%s\n", us_name(READ_ONCE(us_effective)));
}

static const struct kernel_param_ops us_param_ops = {
	.set = us_param_set,
	.get = us_param_get,
};
module_param_cb(userspace, &us_param_ops, NULL, 0644);
MODULE_PARM_DESC(userspace, "samsung | aosp | auto: which userspace the drivers serve (reads back the effective value)");

static int us_source_get(char *buf, const struct kernel_param *kp)
{
	int n;

	mutex_lock(&us_lock);
	n = sysfs_emit(buf, "%s\n", us_source);
	mutex_unlock(&us_lock);
	return n;
}

static const struct kernel_param_ops us_source_ops = { .get = us_source_get };
module_param_cb(source, &us_source_ops, NULL, 0444);
MODULE_PARM_DESC(source, "where the userspace value came from: default | cmdline | sysfs | hint:<why>");

/* "a52sxq.userspace=<word>" in /chosen/bootargs, for loaders that do not pass module options */
static void us_from_bootargs(void)
{
	static const char key[] = "a52sxq.userspace=";
	const char *args = NULL, *p, *e;
	int us;

	if (!of_chosen || of_property_read_string(of_chosen, "bootargs", &args) || !args)
		return;
	for (p = strstr(args, key); p; p = strstr(p + 1, key)) {
		if (p != args && p[-1] != ' ')
			continue;
		p += sizeof(key) - 1;
		e = strchrnul(p, ' ');
		us = us_parse(p, e - p);
		if (us < 0) {
			pr_warn("bad a52sxq.userspace value on the command line, ignored\n");
			return;
		}
		if (us != A52SXQ_US_AUTO)
			us_apply(us, us, "cmdline");
		return;
	}
}

static int __init a52sxq_core_init(void)
{
	mutex_lock(&us_lock);
	if (!strncmp(us_source, "default", 7))
		us_from_bootargs();
	us_init_done = true;
	pr_info("loaded: userspace = %s (source %s)\n", us_name(us_effective), us_source);
	mutex_unlock(&us_lock);
	return 0;
}
module_init(a52sxq_core_init);
/* no module_exit: consumers keep function pointers obtained with symbol_get() */

MODULE_DESCRIPTION("Galaxy A52s: userspace flavour switch (Samsung One UI vs AOSP) for the ported drivers");
MODULE_LICENSE("GPL");
