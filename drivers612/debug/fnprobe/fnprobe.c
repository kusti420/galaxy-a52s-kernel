// SPDX-License-Identifier: GPL-2.0
/* fnprobe: print every call of the listed functions to the kernel log (and thus to the
 * pstore console), with the first four arguments and the caller. For finding the last step
 * before a silent hardware reset.
 *   insmod fnprobe.ko syms=fastrpc_device_ioctl,fastrpc_session_alloc_locked,...
 * dump=<one of syms> also hex-dumps (arg1, len arg2) of that function. Up to 32 symbols; module symbols resolve like any kallsyms name. Debug aid only. */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/slab.h>
#include <linux/string.h>

#define MAXP 32
static char *syms;
module_param(syms, charp, 0444);
/* dump=<symbol>: for that probe also hex-dump the buffer in arg 1 (length arg 2, max 128) */
static char *dump;
module_param(dump, charp, 0444);
static struct kprobe kps[MAXP];
static int n;

static int pre(struct kprobe *p, struct pt_regs *r)
{
	pr_info("fnprobe: %s(%llx, %llx, %llx, %llx) cpu%d %s[%d] from %pS\n", p->symbol_name,
		r->regs[0], r->regs[1], r->regs[2], r->regs[3], raw_smp_processor_id(),
		current->comm, current->pid, (void *)r->regs[30]);
	if (dump && !strcmp(dump, p->symbol_name) && r->regs[1] && r->regs[2] < 0x10000)
		print_hex_dump(KERN_INFO, "fnprobe: ", DUMP_PREFIX_OFFSET, 16, 8,
			       (void *)r->regs[1], min_t(u64, r->regs[2], 128), false);
	return 0;
}

static int __init fnprobe_init(void)
{
	char *s, *tok;

	if (!syms)
		return -EINVAL;
	s = kstrdup(syms, GFP_KERNEL);
	while (s && (tok = strsep(&s, ",")) && n < MAXP) {
		if (!*tok)
			continue;
		kps[n].symbol_name = tok;
		kps[n].pre_handler = pre;
		if (register_kprobe(&kps[n])) {
			pr_info("fnprobe: cannot probe %s\n", tok);
			memset(&kps[n], 0, sizeof(kps[n]));
			continue;
		}
		n++;
	}
	pr_info("fnprobe: %d probes\n", n);
	return 0;
}
static void __exit fnprobe_exit(void)
{
	while (n--)
		unregister_kprobe(&kps[n]);
}
module_init(fnprobe_init);
module_exit(fnprobe_exit);
MODULE_LICENSE("GPL");
