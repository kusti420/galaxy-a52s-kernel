// SPDX-License-Identifier: GPL-2.0
/* seaprobe: log the physical page behind every synchronous external abort taken from user
 * space (SIGBUS BUS_OBJERR). A kprobe on do_sea() translates the faulting address with
 * AT S1E0R in the faulting task's own context and prints PA, folio order and page flags.
 * Debug aid for the 6.12 bring-up (SystemUI/system_server dying on SEA instruction fetches). */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/ratelimit.h>
#include <asm/sysreg.h>

static DEFINE_RATELIMIT_STATE(rs, HZ, 20);

static int pre(struct kprobe *p, struct pt_regs *kregs)
{
	unsigned long far = kregs->regs[0], esr = kregs->regs[1];
	struct pt_regs *uregs = (struct pt_regs *)kregs->regs[2];
	u64 par, pa;
	unsigned long flags;

	if (!uregs || !user_mode(uregs) || !__ratelimit(&rs))
		return 0;
	local_irq_save(flags);
	asm volatile("at s1e0r, %0" :: "r"(far));
	isb();
	par = read_sysreg(par_el1);
	local_irq_restore(flags);
	if (par & 1) {
		pr_info("seaprobe: %s[%d] far %lx esr %lx: AT fault par %llx\n",
			current->comm, current->pid, far, esr, par);
		return 0;
	}
	pa = (par & GENMASK_ULL(47, 12)) | (far & 0xfff);
	if (pfn_valid(PHYS_PFN(pa))) {
		struct page *pg = pfn_to_page(PHYS_PFN(pa));
		struct folio *f = page_folio(pg);

		pr_info("seaprobe: %s[%d] far %lx esr %lx pa %llx folio pfn %lx order %u flags %lx mapcount %d ref %d %s\n",
			current->comm, current->pid, far, esr, pa, folio_pfn(f), folio_order(f),
			f->flags, folio_mapcount(f), folio_ref_count(f),
			folio_test_anon(f) ? "anon" : (f->mapping ? "file" : "nomapping"));
	} else {
		pr_info("seaprobe: %s[%d] far %lx esr %lx pa %llx (no struct page)\n",
			current->comm, current->pid, far, esr, pa);
	}
	return 0;
}

/* Memory handed to other VMs/subsystems through SCM. A page that goes back to the buddy
 * allocator while still assigned away is the suspected cause of the SEAs, so every call is
 * logged with its caller. qcom_scm_assign_mem(phys, size, u64 *srcvm, newvm[], dest_cnt);
 * qcom_scm_assign_mem_regions(struct {u64 addr, size} *regions, size_t regions_bytes, ...). */
struct vmperm { int vmid; int perm; };
static int pre_assign(struct kprobe *p, struct pt_regs *r)
{
	const struct vmperm *nv = (const struct vmperm *)r->regs[3];
	u64 *src = (u64 *)r->regs[2];
	unsigned int n = r->regs[4], i;
	char d[64]; int o = 0;

	for (i = 0; nv && i < n && i < 4; i++)
		o += scnprintf(d + o, sizeof(d) - o, " %d:%x", nv[i].vmid, nv[i].perm);
	pr_info("seaprobe: assign_mem %llx+%llx src %llx ->%s by %pS\n", (u64)r->regs[0],
		(u64)r->regs[1], src ? *src : 0, d, (void *)r->regs[30]);
	return 0;
}
static int pre_regions(struct kprobe *p, struct pt_regs *r)
{
	const u64 *m = (const u64 *)r->regs[0];
	size_t n = r->regs[1] / 16, i;
	u64 lo = ~0ULL, hi = 0, tot = 0;

	for (i = 0; m && i < n; i++) {
		lo = min(lo, m[2 * i]); hi = max(hi, m[2 * i] + m[2 * i + 1]); tot += m[2 * i + 1];
	}
	pr_info("seaprobe: assign_regions n %zu span %llx-%llx total %llx newvms %zu by %pS\n",
		n, lo, hi, tot, (size_t)r->regs[5] / 8, (void *)r->regs[30]);
	return 0;
}
static int pre_share(struct kprobe *p, struct pt_regs *r)
{
	pr_info("seaprobe: %s by %pS\n", p->symbol_name, (void *)r->regs[30]);
	return 0;
}

static struct kprobe kps[] = {
	{ .symbol_name = "do_sea", .pre_handler = pre },
	{ .symbol_name = "qcom_scm_assign_mem", .pre_handler = pre_assign },
	{ .symbol_name = "qcom_scm_assign_mem_regions", .pre_handler = pre_regions },
	{ .symbol_name = "gunyah_rm_mem_share", .pre_handler = pre_share },
	{ .symbol_name = "gunyah_rm_mem_reclaim", .pre_handler = pre_share },
};
static bool on[ARRAY_SIZE(kps)];

static int __init seaprobe_init(void)
{
	int i, r;

	for (i = 0; i < ARRAY_SIZE(kps); i++) {
		r = register_kprobe(&kps[i]);
		on[i] = !r;
		pr_info("seaprobe: kprobe on %s: %d\n", kps[i].symbol_name, r);
	}
	return on[0] ? 0 : -ENOENT;
}
static void __exit seaprobe_exit(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(kps); i++)
		if (on[i])
			unregister_kprobe(&kps[i]);
}
module_init(seaprobe_init);
module_exit(seaprobe_exit);
MODULE_LICENSE("GPL");
