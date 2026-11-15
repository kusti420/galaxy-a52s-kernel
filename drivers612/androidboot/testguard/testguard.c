// SPDX-License-Identifier: GPL-2.0
/*
 * Safety net for booting an installed ROM's Android userspace on the 6.12 test kernel of the
 * A52s. Adapted from donors/redwood-6.12/modules/testguard (same idea, Samsung specifics):
 * - userdata is claimed exclusively and set read-only at the block layer: no filesystem mount,
 *   no dm-default-key table and no raw write can reach it from this kernel;
 * - every partition in ro= (misc, metadata, efs, ...) is set read-only at the block layer, so
 *   Android cannot leave a wipe command in misc, reformat metadata (it holds the userdata
 *   key: losing it loses the user's data) or change the EFS;
 * - "reboot recovery" becomes "reboot download": the recovery partition holds THIS test image
 *   and the harness leaves Download mode by itself (heimdall print-pit);
 * - without a52.androidtest=1 on the command line, or if userdata/misc are not guarded
 *   DEADLINE_MS after load, it restarts into Download mode before Android can mount anything.
 * Must be the FIRST line of modules.load.
 */
#include <linux/blkdev.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/reboot.h>
#include <linux/sched/task_stack.h>
#include <linux/string.h>

#define SCAN_MINORS	1024
#define MAX_RO		32

static char ro[512] = "misc,metadata,efs,sec_efs,persist,cache,param,steady,persistent,keydata,keyrefuge,modemst1,modemst2,fsg,fsc";
module_param_string(ro, ro, sizeof(ro), 0444);
MODULE_PARM_DESC(ro, "comma separated GPT partition names made read-only (misc is mandatory)");
static unsigned int deadline_ms = 30000;
module_param(deadline_ms, uint, 0444);
static char target[16] = "download";
module_param_string(target, target, sizeof(target), 0444);

static struct file *userdata;
static struct file *ro_file[MAX_RO];
static char *ro_name[MAX_RO];
static int nro;
static int holder;
static struct task_struct *guard_task;

static struct file *open_part(const char *name, bool claim)
{
	static const unsigned int majors[] = { 8, 259 };
	struct file *f;
	int i, m;

	for (i = 0; i < ARRAY_SIZE(majors); i++) {
		for (m = 0; m < SCAN_MINORS; m++) {
			f = bdev_file_open_by_dev(MKDEV(majors[i], m), BLK_OPEN_READ, NULL, NULL);
			if (IS_ERR(f))
				continue;
			if (file_bdev(f)->bd_meta_info &&
			    !strcmp(file_bdev(f)->bd_meta_info->volname, name)) {
				dev_t devt = file_bdev(f)->bd_dev;

				if (!claim)
					return f;
				fput(f);
				return bdev_file_open_by_dev(devt, BLK_OPEN_READ, &holder, NULL);
			}
			fput(f);
		}
	}
	return NULL;
}

static int guard_reboot(struct notifier_block *nb, unsigned long action, void *data)
{
	char *cmd = data;

	if (action != SYS_RESTART || !cmd || !strstr(cmd, "recovery"))
		return NOTIFY_DONE;
	/* the reboot syscall copies the argument into a 256 byte buffer on its stack */
	if (object_is_on_stack(cmd) && strlen(target) < 255) {
		pr_emerg("testguard: reboot \"%s\" turned into \"%s\"\n", cmd, target);
		strscpy(cmd, target, 255);
	} else {
		pr_emerg("testguard: can't redirect reboot \"%s\"\n", cmd);
	}
	return NOTIFY_DONE;
}

static struct notifier_block guard_nb = {
	.notifier_call = guard_reboot,
	.priority = INT_MAX,
};

static void bail(const char *why)
{
	pr_emerg("testguard: %s, restarting into %s\n", why, target);
	msleep(500);
	kernel_restart(target);
}

static int guard_thread(void *unused)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(deadline_ms);
	bool misc_ok = false, warned = false;
	struct file *f;
	int i, left;

	for (;;) {
		if (!userdata) {
			f = open_part("userdata", true);
			if (IS_ERR(f)) {
				bail("can't claim userdata");
				return 0;
			}
			if (f) {
				bdev_set_flag(file_bdev(f), BD_READ_ONLY);
				userdata = f;
				pr_info("testguard: holding %pg (userdata) exclusively, read-only\n",
					file_bdev(f));
			}
		}
		left = 0;
		for (i = 0; i < nro; i++) {
			if (ro_file[i])
				continue;
			f = open_part(ro_name[i], false);
			if (IS_ERR_OR_NULL(f)) {
				left++;
				continue;
			}
			bdev_set_flag(file_bdev(f), BD_READ_ONLY);
			ro_file[i] = f;
			if (!strcmp(ro_name[i], "misc"))
				misc_ok = true;
			pr_info("testguard: %pg (%s) read-only\n", file_bdev(f), ro_name[i]);
		}
		if (userdata && misc_ok && !left)
			break;
		if (time_after(jiffies, deadline)) {
			if (!userdata || !misc_ok) {
				bail("userdata or misc not found in time");
				return 0;
			}
			if (!warned) {
				/* optional names that this partition table does not have */
				for (i = 0; i < nro; i++)
					if (!ro_file[i])
						pr_warn("testguard: no partition \"%s\"\n", ro_name[i]);
				warned = true;
			}
			break;
		}
		if (kthread_should_stop())
			return 0;
		msleep_interruptible(50);
	}
	pr_info("testguard: armed (userdata held, %d partitions read-only)\n", nro - left);
	while (!kthread_should_stop())
		msleep_interruptible(1000);
	return 0;
}

static int __init testguard_init(void)
{
	const char *args = NULL;
	char *p = ro, *tok;

	if (of_chosen)
		of_property_read_string(of_chosen, "bootargs", &args);
	if (!args || !strstr(args, "a52.androidtest=1")) {
		bail("a52.androidtest=1 is not on the command line");
		return -EPERM;
	}
	while ((tok = strsep(&p, ",")) && nro < MAX_RO)
		if (*tok)
			ro_name[nro++] = tok;
	register_reboot_notifier(&guard_nb);
	guard_task = kthread_run(guard_thread, NULL, "testguard");
	if (IS_ERR(guard_task)) {
		bail("no guard thread");
		return PTR_ERR(guard_task);
	}
	return 0;
}

/* No module_exit on purpose: the guard cannot be unloaded. */
module_init(testguard_init);
MODULE_DESCRIPTION("Keep userdata, misc, metadata and EFS safe while testing Android on the A52s 6.12 kernel");
MODULE_LICENSE("GPL");
