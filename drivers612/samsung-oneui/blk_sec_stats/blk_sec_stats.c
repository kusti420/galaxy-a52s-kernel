// SPDX-License-Identifier: GPL-2.0
/*
 *  Samsung Block Statistics
 *
 *  Copyright (C) 2021 Manjong Lee
 *  Copyright (C) 2021 Junho Kim
 *  Copyright (C) 2021 Changheun Lee
 *
 * a52sxq: Samsung 5.4 block/blk-sec-stats.c (SM-A528B kernel, module blk_sec_stats, shipped as
 * /vendor/lib/modules/blk-sec-stats.ko by the stock ROM) ported to the 6.12 GKI as a module.
 * Nodes, modes and print formats are those of 5.4:
 *
 *   /sys/kernel/blk_sec_stats/diskios           0444  "ReadC":"..","ReadKB":"..",...,"Hours":".."\n
 *   /sys/kernel/blk_sec_stats/pios              0444  "<tgid> <readKB> <writeKB> <comm>\n" lines
 *   /sys/kernel/blk_sec_stats/pios_enable       0644  "%d\n" (default 0)
 *   /sys/kernel/blk_sec_stats/pios_duration_ms  0644  "%u\n" (default 5000, max 10000)
 *
 * What differs from 5.4 (all internal, formats unchanged):
 *  - diskios: same part_stat counters of the internal disk's whole-disk device (first of the
 *    `disks` parameter that exists, default "sda,mmcblk0" as 5.4's blk_lookup_devt order), read
 *    as deltas since the previous read. The disk is found through sysfs (/sys/class/block/<name>,
 *    kernfs link -> device), since blk_lookup_devt/block_class are not exported by the GKI, and
 *    it is held by a device reference instead of an open blkdev_get_by_dev(). No disk ->
 *    -ENODEV (5.4: -1) and one log line, not one per read.
 *  - pios: 5.4 was called by its SSG I/O scheduler's prepare_request hook (first bio of each new
 *    request on the internal UFS only). 6.12 has no SSG hook, so this module uses the GKI's
 *    exported block_bio_queue tracepoint (every bio submitted to the internal disk, attributed to
 *    the submitting thread group as on 5.4, so merged bios are counted too). Only bios of the
 *    internal disk count (also its partitions; loop/dm/zram bios are counted when they reach it).
 *  - pios bookkeeping: hashed by tgid (5.4 walked a list of up to 10000 nodes in the I/O path),
 *    one irq-safe spinlock held for O(1) work, GFP_NOWAIT allocation, at most MAX_PIO_NODE_NUM
 *    nodes (the rest goes to the "others" line, as on 5.4), pio_cnt updated under the lock.
 *    Accounting stops pios_duration_ms after the last pios read / pios_enable write (5.4).
 *  - init never fails: any missing piece is logged once and the rest still loads.
 */
#define pr_fmt(fmt) "blk_sec_stats: " fmt
#include <linux/blk_types.h>
#include <linux/blkdev.h>
#include <linux/device.h>
#include <linux/hashtable.h>
#include <linux/jiffies.h>
#include <linux/kernfs.h>
#include <linux/kobject.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/part_stat.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/time64.h>
#include <linux/timekeeping.h>
#include <linux/types.h>
#include <trace/events/block.h>

#define NAME_LEN 16
#define MAX_PIO_NODE_NUM 10000
#define SORT_PIO_NODE_NUM 100
#define PIO_HASH_BITS 8

static char *disks = "sda,mmcblk0";
module_param(disks, charp, 0444);
MODULE_PARM_DESC(disks, "internal storage candidates, first existing whole disk wins (5.4: sda, mmcblk0)");

struct accumulated_stats {
	struct timespec64 uptime;
	unsigned long sectors[3];       /* READ, WRITE, DISCARD */
	unsigned long ios[3];
	unsigned long iot;
};

struct pio_node {
	struct list_head list;
	struct hlist_node hnode;
	pid_t tgid;
	char name[NAME_LEN];
	u64 real_start_time;
	unsigned long long bytes[REQ_OP_DISCARD + 1];
};

static struct pio_node others = {
	.list = LIST_HEAD_INIT(others.list),
	.tgid = 99999,
	.name = "others",
	.real_start_time = 9999999,
	.bytes = {0, 0, 0, 0},
};

/* protects pio_list, pio_hash, pio_cnt and others.bytes; taken irq-safe, O(1) work only */
static DEFINE_SPINLOCK(pio_lock);
static LIST_HEAD(pio_list);
static DEFINE_HASHTABLE(pio_hash, PIO_HASH_BITS);
static int pio_cnt;
static int pio_enabled;
static unsigned int pio_duration_ms = 5000;
static unsigned long pio_timeout;
static struct kmem_cache *pio_cache;
static bool probe_registered;

/* internal disk: found in process context under disk_lock, then only read */
static DEFINE_MUTEX(disk_lock);
static struct device *internal_dev;		/* holds a reference */
static struct gendisk *internal_disk;		/* READ_ONCE in the I/O path */
static bool disk_missing_logged;
static struct accumulated_stats old, new;	/* under disk_lock */

static struct kobject *blk_sec_stats_kobj;
static bool group_created;

static struct kernfs_node *kn_parent(struct kernfs_node *kn)
{
	return kn->parent;
}

/* /sys/class/block/<name> -> struct device of a whole disk, with a reference, or NULL */
static struct device *find_disk_dev(struct kernfs_node *blk, const char *name)
{
	struct kernfs_node *kn, *tgt;
	struct device *dev = NULL;

	kn = kernfs_find_and_get(blk, name);
	if (!kn)
		return NULL;
	if (kernfs_type(kn) == KERNFS_LINK) {
		tgt = kn->symlink.target_kn;
		if (tgt && kernfs_type(tgt) == KERNFS_DIR && tgt->priv) {
			struct device *d = kobj_to_dev(tgt->priv);

			if (d->type && d->type->name && !strcmp(d->type->name, "disk"))
				dev = get_device(d);
		}
	}
	kernfs_put(kn);
	return dev;
}

/* caller holds disk_lock; process context */
static struct gendisk *get_internal_gendisk(void)
{
	struct kernfs_node *root, *cls, *blk;
	char list[64], *p, *name;
	struct device *dev = NULL;

	if (internal_disk)
		return internal_disk;
	if (!kernel_kobj || !kernel_kobj->sd)
		return NULL;
	for (root = kernel_kobj->sd; kn_parent(root); root = kn_parent(root))
		;
	cls = kernfs_find_and_get(root, "class");
	if (!cls)
		return NULL;
	blk = kernfs_find_and_get(cls, "block");
	kernfs_put(cls);
	if (!blk)
		return NULL;

	strscpy(list, disks ? disks : "", sizeof(list));
	p = list;
	/* Assume that internal storage is not removed */
	while (!dev && (name = strsep(&p, ",")) != NULL)
		if (*name)
			dev = find_disk_dev(blk, name);
	kernfs_put(blk);

	if (!dev) {
		if (!disk_missing_logged)
			pr_warn("no internal disk (%s) yet\n", disks);
		disk_missing_logged = true;
		return NULL;
	}
	internal_dev = dev;
	WRITE_ONCE(internal_disk, dev_to_disk(dev));
	pr_info("internal disk %s\n", dev_name(dev));
	return internal_disk;
}

#define UNSIGNED_DIFF(n, o) (((n) >= (o)) ? ((n) - (o)) : ((n) + (0 - (o))))
#define SECTORS2KB(x) ((x) / 2)

static ssize_t diskios_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct block_device *hd;
	struct gendisk *disk;
	long hours;
	int ret;

	mutex_lock(&disk_lock);
	disk = get_internal_gendisk();
	if (!disk) {
		mutex_unlock(&disk_lock);
		return -ENODEV;
	}

	hd = disk->part0;

	new.ios[STAT_READ] = part_stat_read(hd, ios[STAT_READ]);
	new.ios[STAT_WRITE] = part_stat_read(hd, ios[STAT_WRITE]);
	new.ios[STAT_DISCARD] = part_stat_read(hd, ios[STAT_DISCARD]);
	new.sectors[STAT_READ] = part_stat_read(hd, sectors[STAT_READ]);
	new.sectors[STAT_WRITE] = part_stat_read(hd, sectors[STAT_WRITE]);
	new.sectors[STAT_DISCARD] = part_stat_read(hd, sectors[STAT_DISCARD]);
	new.iot = jiffies_to_msecs(part_stat_read(hd, io_ticks)) / 1000;

	ktime_get_boottime_ts64(&new.uptime);
	hours = (new.uptime.tv_sec - old.uptime.tv_sec) / 60;
	hours = (hours + 30) / 60;

	ret = sprintf(buf, "\"ReadC\":\"%lu\",\"ReadKB\":\"%lu\","
			"\"WriteC\":\"%lu\",\"WriteKB\":\"%lu\","
			"\"DiscardC\":\"%lu\",\"DiscardKB\":\"%lu\","
			"\"IOT\":\"%lu\","
			"\"Hours\":\"%ld\"\n",
			UNSIGNED_DIFF(new.ios[STAT_READ], old.ios[STAT_READ]),
			SECTORS2KB(UNSIGNED_DIFF(new.sectors[STAT_READ], old.sectors[STAT_READ])),
			UNSIGNED_DIFF(new.ios[STAT_WRITE], old.ios[STAT_WRITE]),
			SECTORS2KB(UNSIGNED_DIFF(new.sectors[STAT_WRITE], old.sectors[STAT_WRITE])),
			UNSIGNED_DIFF(new.ios[STAT_DISCARD], old.ios[STAT_DISCARD]),
			SECTORS2KB(UNSIGNED_DIFF(new.sectors[STAT_DISCARD], old.sectors[STAT_DISCARD])),
			UNSIGNED_DIFF(new.iot, old.iot),
			hours);

	old = new;
	mutex_unlock(&disk_lock);

	return ret;
}

/* caller holds pio_lock */
static void add_bytes(struct pio_node *pio, int op, unsigned long size)
{
	pio->bytes[op] += size;
}

/* block_bio_queue probe: submitter context, preemption off; never sleeps */
static void blk_sec_account_process_IO(void *data, struct bio *bio)
{
	struct task_struct *gleader;
	struct gendisk *disk;
	struct pio_node *node;
	unsigned long size, flags;
	pid_t tgid;
	u64 start;
	int op;

	if (!READ_ONCE(pio_enabled))
		return;
	if (time_after(jiffies, READ_ONCE(pio_timeout)))
		return;
	op = bio_op(bio);
	if (op > REQ_OP_DISCARD)
		return;
	disk = READ_ONCE(internal_disk);
	if (!disk || !bio->bi_bdev || bio->bi_bdev->bd_disk != disk)
		return;

	size = (op == REQ_OP_FLUSH) ? 1 : bio->bi_iter.bi_size;

	spin_lock_irqsave(&pio_lock, flags);
	if (!in_task()) {
		add_bytes(&others, op, size);
		goto out;
	}
	gleader = current->group_leader;
	tgid = task_tgid_nr(gleader);
	start = gleader->start_boottime;

	hash_for_each_possible(pio_hash, node, hnode, tgid) {
		if (node->tgid == tgid && node->real_start_time == start) {
			add_bytes(node, op, size);
			goto out;
		}
	}

	node = NULL;
	if (pio_cnt < MAX_PIO_NODE_NUM)
		node = kmem_cache_alloc(pio_cache, GFP_NOWAIT | __GFP_NOWARN);
	if (!node) {
		add_bytes(&others, op, size);
		goto out;
	}
	memset(node->bytes, 0, sizeof(node->bytes));
	node->tgid = tgid;
	strscpy(node->name, gleader->comm, NAME_LEN);
	node->real_start_time = start;
	node->bytes[op] = size;
	list_add(&node->list, &pio_list);
	hash_add(pio_hash, &node->hnode, tgid);
	pio_cnt++;
out:
	spin_unlock_irqrestore(&pio_lock, flags);
}

/* moves every node to @dst and empties the table; returns the node count */
static int take_pio_nodes(struct list_head *dst, unsigned long long *others_bytes)
{
	unsigned long flags;
	int cnt;

	spin_lock_irqsave(&pio_lock, flags);
	list_replace_init(&pio_list, dst);
	hash_init(pio_hash);	/* the nodes' hnode links die with the nodes */
	cnt = pio_cnt;
	pio_cnt = 0;
	if (others_bytes)
		memcpy(others_bytes, others.bytes, sizeof(others.bytes));
	memset(others.bytes, 0, sizeof(others.bytes));
	spin_unlock_irqrestore(&pio_lock, flags);
	return cnt;
}

static void free_pio_node(struct list_head *remove_list)
{
	struct pio_node *node, *n;

	list_for_each_entry_safe(node, n, remove_list, list) {
		list_del(&node->list);
		kmem_cache_free(pio_cache, node);
	}
}

#define GET_PIO_PRIO(pio) \
	((pio)->bytes[REQ_OP_READ] + (pio)->bytes[REQ_OP_WRITE]*2)

static void sort_pios(struct list_head *remove_list)
{
	struct pio_node *max_node = NULL;
	struct pio_node *node;
	unsigned long long max = 0;
	LIST_HEAD(sorted_list);
	int i;

	for (i = 0; i < SORT_PIO_NODE_NUM; i++) {
		list_for_each_entry(node, remove_list, list) {
			if (GET_PIO_PRIO(node) > max) {
				max = GET_PIO_PRIO(node);
				max_node = node;
			}
		}
		if (max_node != NULL)
			list_move_tail(&max_node->list, &sorted_list);

		max = 0;
		max_node = NULL;
	}
	list_splice_init(&sorted_list, remove_list);
}

static ssize_t pio_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	unsigned long long ob[REQ_OP_DISCARD + 1];
	struct pio_node *node;
	LIST_HEAD(remove_list);
	int len = 0, cnt;

	cnt = take_pio_nodes(&remove_list, ob);

	if (cnt > SORT_PIO_NODE_NUM)
		sort_pios(&remove_list);

	list_for_each_entry(node, &remove_list, list) {
		if (PAGE_SIZE - len > 80) {
			/* pid read(KB) write(KB) comm printed */
			len += scnprintf(buf + len, PAGE_SIZE - len, "%d %llu %llu %s\n",
					node->tgid, node->bytes[REQ_OP_READ] / 1024,
					node->bytes[REQ_OP_WRITE] / 1024,  node->name);
		} else {
			ob[REQ_OP_READ] += node->bytes[REQ_OP_READ];
			ob[REQ_OP_WRITE] += node->bytes[REQ_OP_WRITE];
			ob[REQ_OP_FLUSH] += node->bytes[REQ_OP_FLUSH];
			ob[REQ_OP_DISCARD] += node->bytes[REQ_OP_DISCARD];
		}
	}

	if (ob[REQ_OP_READ] + ob[REQ_OP_WRITE])
		len += scnprintf(buf + len, PAGE_SIZE - len, "%d %llu %llu %s\n",
				others.tgid, ob[REQ_OP_READ] / 1024,
				ob[REQ_OP_WRITE] / 1024,  others.name);

	free_pio_node(&remove_list);

	WRITE_ONCE(pio_timeout, jiffies + msecs_to_jiffies(READ_ONCE(pio_duration_ms)));

	return len;
}

static ssize_t pio_enabled_store(struct kobject *kobj, struct kobj_attribute *attr,
		const char *buf, size_t count)
{
	int enable = 0;
	LIST_HEAD(remove_list);

	if (sscanf(buf, "%d", &enable) != 1)
		enable = 0;
	WRITE_ONCE(pio_enabled, (enable >= 1) ? 1 : 0);

	if (enable >= 1) {
		/* the disk may have appeared after module load */
		mutex_lock(&disk_lock);
		get_internal_gendisk();
		mutex_unlock(&disk_lock);
	}

	take_pio_nodes(&remove_list, NULL);
	free_pio_node(&remove_list);

	WRITE_ONCE(pio_timeout, jiffies + msecs_to_jiffies(READ_ONCE(pio_duration_ms)));

	return count;
}

static ssize_t pio_enabled_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(pio_enabled));
}

static ssize_t pio_duration_ms_store(struct kobject *kobj, struct kobj_attribute *attr,
		const char *buf, size_t count)
{
	int v;

	/* 5.4: sscanf("%d") into the unsigned value: negative -> huge -> capped */
	if (sscanf(buf, "%d", &v) == 1) {
		unsigned int ms = (unsigned int)v;

		if (ms > 10000)
			ms = 10000;
		WRITE_ONCE(pio_duration_ms, ms);
	}

	return count;
}

static ssize_t pio_duration_ms_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", READ_ONCE(pio_duration_ms));
}

static struct kobj_attribute diskios_attr = __ATTR(diskios, 0444, diskios_show,  NULL);
static struct kobj_attribute pios_attr = __ATTR(pios, 0444, pio_show,  NULL);
static struct kobj_attribute pios_enable_attr = __ATTR(pios_enable, 0644,
		pio_enabled_show,  pio_enabled_store);
static struct kobj_attribute pios_duration_ms_attr = __ATTR(pios_duration_ms, 0644,
		pio_duration_ms_show, pio_duration_ms_store);

static struct attribute *blk_sec_stats_attrs[] = {
	&diskios_attr.attr,
	&pios_attr.attr,
	&pios_enable_attr.attr,
	&pios_duration_ms_attr.attr,
	NULL,
};

static const struct attribute_group blk_sec_stats_group = {
	.attrs = blk_sec_stats_attrs,
};

static int __init blk_sec_stats_init(void)
{
	struct kernfs_node *kn;
	int ret;

	mutex_lock(&disk_lock);
	get_internal_gendisk();
	mutex_unlock(&disk_lock);

	pio_cache = kmem_cache_create("blk_sec_pio_node", sizeof(struct pio_node), 0, 0, NULL);
	if (pio_cache) {
		ret = register_trace_block_bio_queue(blk_sec_account_process_IO, NULL);
		probe_registered = !ret;
		if (ret)
			pr_warn("block_bio_queue probe: %d, pios stays empty\n", ret);
	} else {
		pr_warn("no pio cache, pios stays empty\n");
	}

	if (!kernel_kobj || !kernel_kobj->sd)
		return 0;
	kn = kernfs_find_and_get(kernel_kobj->sd, "blk_sec_stats");
	if (kn) {
		kernfs_put(kn);
		pr_warn("/sys/kernel/blk_sec_stats already exists, nodes not created\n");
		return 0;
	}
	blk_sec_stats_kobj = kobject_create_and_add("blk_sec_stats", kernel_kobj);
	if (!blk_sec_stats_kobj) {
		pr_warn("no blk_sec_stats kobject\n");
		return 0;
	}
	ret = sysfs_create_group(blk_sec_stats_kobj, &blk_sec_stats_group);
	group_created = !ret;
	if (ret)
		pr_warn("sysfs group: %d\n", ret);

	return 0;
}

static void __exit blk_sec_stats_exit(void)
{
	LIST_HEAD(remove_list);

	if (blk_sec_stats_kobj) {
		if (group_created)
			sysfs_remove_group(blk_sec_stats_kobj, &blk_sec_stats_group);
		kobject_put(blk_sec_stats_kobj);
	}
	if (probe_registered) {
		unregister_trace_block_bio_queue(blk_sec_account_process_IO, NULL);
		tracepoint_synchronize_unregister();
	}
	if (pio_cache) {
		take_pio_nodes(&remove_list, NULL);
		free_pio_node(&remove_list);
		kmem_cache_destroy(pio_cache);
	}
	if (internal_dev)
		put_device(internal_dev);
}

module_init(blk_sec_stats_init);
module_exit(blk_sec_stats_exit);
MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("Manjong Lee <mj0123.lee@samsung.com>");
MODULE_DESCRIPTION("SEC Storage stats module for various purposes (a52sxq 6.12 port)");
MODULE_VERSION("0.1");
