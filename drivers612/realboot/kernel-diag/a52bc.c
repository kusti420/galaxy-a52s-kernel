// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52bc: boot breadcrumbs and a RAM early console for the first REAL (bootloader) boots of the
 * Qualcomm 6.12 GKI kernel on the Samsung A52s (a52sxq-mainline, drivers612/realboot DIAG
 * builds). It is compiled ONLY into the diagnostic Image made by
 * drivers612/realboot/kernel-diag/build-diag-kernel.sh (out of tree build dir, source tree
 * restored afterwards), never into bsp612/out/dist.
 *
 * Why: rb4/rb5 (2026-11-14) were started by the ABL, showed the boot logo and were reset by
 * "Warm Reset by Watchdog Bite" every ~56 s, and the kernel left NOTHING in ramoops, i.e. it
 * died (or never ran) before ramoops probes (~0.1 s). The Samsung ABL removes earlycon= from
 * the command line, and the phone has no UART. So this file writes progress into RAM that
 * survives the reset and that the 6.18 harness on `recovery` already reads:
 *
 *   area 0xf0be0000, 128 KiB (/reserved-memory/a52ram@f0be0000, compatible "a52,ramcon",
 *   no-map; the harness prints it as /proc/a52ram, NUL bytes skipped)
 *     0x00000..0x0ffff  console head: every printk from the first one, written once
 *     0x10000..0x1efff  console tail: circular, the LAST 60 KiB of printk output
 *                       (keep_bootcon keeps this console after the real consoles register)
 *     0x1f000..0x1ffff  breadcrumb page, ASCII:
 *                       "A52BC1 attempt=N" (N counts boots that reached setup_arch, kept
 *                       across warm resets), one line per stage reached (setup_arch entry,
 *                       fdt, param, paging, setup_end, every initcall level) with the
 *                       counter time and the hypervisor watchdog state, at +0xc00 a
 *                       heartbeat line rewritten every second (uptime, watchdog, modules,
 *                       pid 1), at +0xff0 "T<tail write offset>"
 *
 * The first breadcrumb (setup_arch entry) is written before anything checks the device tree;
 * that page is not in use by anyone at that point of a boot. Everything after it only runs if
 * the flat device tree has the "a52,ramcon" reservation (the DIAG tree), so a diag Image
 * started with another tree stops writing there.
 *
 * Hypervisor watchdog (Gunyah/QHEE virtual watchdog, vendor-hyp SMC 0x86000006 = STATUS, as in
 * modules/hhwdt): only READ here (a0 = return, a1 bit 0 = enabled, bit 31 = expired, a2 = time
 * since the last pet). a52bc.wdt=off on the command line disables it (CONTROL 2) at the param
 * stage, logged before and after; default is observe only, so the failure mode is unchanged.
 * The calls are skipped (a0=-99) when the kernel does not run at EL1 (QEMU smoke test at EL2).
 */
#include <linux/arm-smccc.h>
#include <linux/console.h>
#include <linux/init.h>
#include <linux/initrd.h>
#include <linux/io.h>
#include <linux/libfdt.h>
#include <linux/memblock.h>
#include <linux/module.h>
#include <linux/of_fdt.h>
#include <linux/pid.h>
#include <linux/pid_namespace.h>
#include <linux/rculist.h>
#include <linux/sched.h>
#include <linux/serial_core.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/workqueue.h>
#include <asm/fixmap.h>
#include <asm/memory.h>
#include <asm/sections.h>
#include <asm/setup.h>
#include <asm/sysreg.h>
#include "a52bc.h"

#define A52_BASE	0xf0be0000UL
#define A52_SIZE	0x20000
#define A52_HEAD	0x10000			/* console head, written once */
#define A52_LOGEND	0x1f000			/* tail: A52_HEAD..A52_LOGEND, circular */
#define A52_BC		0x1f000			/* breadcrumb page */
#define A52_HB		(A52_BC + 0xc00)	/* heartbeat line */
#define A52_HBLEN	0x300
#define A52_TP		(A52_BC + 0xff0)	/* "T%08x\n": tail write offset */
#define A52_BCLIM	(A52_HB - 1)

#define WDT_FN(n) ARM_SMCCC_CALL_VAL(ARM_SMCCC_FAST_CALL, ARM_SMCCC_SMC_32, ARM_SMCCC_OWNER_VENDOR_HYP, n)

extern struct list_head modules;	/* kernel/module/main.c */

static bool a52_on = true;		/* false: a tree without the reservation, stop writing */
static char *a52_va;			/* memremap of the area, from the first initcall on */
static void __iomem *a52_fixva;
static unsigned int a52_fixpage = ~0U;
static unsigned int a52_head, a52_tail = A52_HEAD, a52_wraps;
static unsigned int a52_bcpos;
static bool a52_wdt_off __initdata;

/* --- raw access: fixmap slot of the early console before the first initcall, memremap after */
static void a52_map(unsigned int page)
{
	if (page == a52_fixpage)
		return;
	if (a52_fixpage != ~0U)
		clear_fixmap(FIX_EARLYCON_MEM_BASE);	/* break before make: re-pointing a live entry */
	set_fixmap_io(FIX_EARLYCON_MEM_BASE, A52_BASE + page * PAGE_SIZE);
	a52_fixva = (void __iomem *)fix_to_virt(FIX_EARLYCON_MEM_BASE);
	a52_fixpage = page;
}

static void a52_put(unsigned int off, char c)
{
	if (a52_va) {
		WRITE_ONCE(a52_va[off], c);
		return;
	}
	a52_map(off / PAGE_SIZE);
	writeb(c, a52_fixva + off % PAGE_SIZE);
}

static char __init a52_get(unsigned int off)
{
	a52_map(off / PAGE_SIZE);
	return readb(a52_fixva + off % PAGE_SIZE);
}

static void a52_puts_at(unsigned int off, const char *s, unsigned int n)
{
	while (n--)
		a52_put(off++, *s ? *s : ' '), s++;
}

static void a52_hex8_at(unsigned int off, char tag, unsigned int v)
{
	static const char hx[] = "0123456789abcdef";
	char b[10];
	int i;

	b[0] = tag;
	for (i = 0; i < 8; i++)
		b[1 + i] = hx[(v >> (28 - 4 * i)) & 0xf];
	b[9] = '\n';
	a52_puts_at(off, b, sizeof(b));
}

/* --- breadcrumb lines */
static void __init a52_bc(const char *fmt, ...)
{
	char buf[192];
	va_list ap;
	int n;

	if (!a52_on)
		return;
	va_start(ap, fmt);
	n = vscnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (a52_bcpos + n > A52_BCLIM - A52_BC)
		n = A52_BCLIM - A52_BC - a52_bcpos;
	a52_puts_at(A52_BC + a52_bcpos, buf, n);
	a52_bcpos += n;
}

/* the vendor-hyp calls only make sense in a guest of the Qualcomm hypervisor (EL1); a kernel
 * at EL2 (the QEMU smoke test, kernel-diag/qemu-test.sh) has nobody to answer them */
static bool a52_guest(void)
{
	return (read_sysreg(CurrentEL) >> 2) == 1;
}

static void a52_wdt_status(struct arm_smccc_res *res)
{
	if (!a52_guest()) {
		res->a0 = (unsigned long)-99;
		res->a1 = res->a2 = res->a3 = 0;
		return;
	}
	arm_smccc_1_1_smc(WDT_FN(0x0006), 0, res);
}

static u64 a52_ms(void)
{
	return read_sysreg(cntvct_el0) / 19200;	/* 19.2 MHz arch timer */
}

static void __init a52_bc_wdt(const char *what)
{
	struct arm_smccc_res res;

	/* written before the call: a hang inside it leaves "wdt? <what>" as the last word */
	a52_bc("wdt? %s ", what);
	a52_wdt_status(&res);
	a52_bc("a0=%ld a1=%#lx a2=%lu\n", (long)res.a0, res.a1, res.a2);
}

/* --- the RAM console ("a52ram" earlycon, started by a52bc_stage(A52BC_PARAM)) */
static void a52ram_write(struct console *con, const char *s, unsigned int n)
{
	if (!a52_on)
		return;
	while (n--) {
		char c = *s ? *s : ' ';	/* never a NUL: the reader skips them */

		s++;
		if (a52_head < A52_HEAD) {
			a52_put(a52_head++, c);
			continue;
		}
		a52_put(a52_tail++, c);
		if (a52_tail == A52_LOGEND) {
			a52_tail = A52_HEAD;
			a52_wraps++;
		}
	}
	if (a52_head >= A52_HEAD)
		a52_hex8_at(A52_TP, 'T', a52_tail | (min(a52_wraps, 0xfffU) << 20));
}

static int __init a52ram_setup(struct earlycon_device *device, const char *opt)
{
	unsigned int i;

	if (device->port.mapbase != A52_BASE)
		return -ENODEV;
	a52_fixpage = ~0U;	/* register_earlycon() re-pointed the slot itself */
	clear_fixmap(FIX_EARLYCON_MEM_BASE);
	for (i = 0; i < A52_LOGEND; i++)
		a52_put(i, 0);
	device->con->write = a52ram_write;
	return 0;
}
EARLYCON_DECLARE(a52ram, a52ram_setup);

static int __init a52bc_wdt_param(char *s)
{
	a52_wdt_off = s && !strcmp(s, "off");
	return 0;
}
early_param("a52bc.wdt", a52bc_wdt_param);

void __init a52bc_stage(enum a52bc_stage stage, phys_addr_t fdt_phys)
{
	static char opt[] __initdata = "a52ram,0xf0be0000";
	unsigned int attempt = 1, i;
	char prev[24];
	int ret;

	switch (stage) {
	case A52BC_ENTRY:
		/* "\nA52BC1 attempt=N": the newline separates the page from the console text in
		 * the NUL-stripped /proc/a52ram output */
		for (i = 0; i < sizeof(prev) - 1; i++)
			prev[i] = a52_get(A52_BC + i);
		prev[i] = 0;
		if (!strncmp(prev, "\nA52BC1 attempt=", 16))
			attempt = simple_strtoul(prev + 16, NULL, 10) + 1;
		for (i = 0; i < PAGE_SIZE; i++)
			a52_put(A52_BC + i, 0);
		a52_bc("\nA52BC1 attempt=%u\n", attempt);
		a52_bc("entry t=%llums el=%llu text=%#llx kaslr=%#lx fdt=%#llx\n", a52_ms(),
		       read_sysreg(CurrentEL) >> 2, (u64)__pa_symbol(_text), kaslr_offset(), (u64)fdt_phys);
		a52_bc_wdt("entry");
		break;
	case A52BC_FDT:
		ret = fdt_node_offset_by_compatible(initial_boot_params, -1, "a52,ramcon");
		a52_bc("fdt t=%llums size=%u ramcon=%d cmdline=%zu\n", a52_ms(),
		       initial_boot_params ? fdt_totalsize(initial_boot_params) : 0, ret >= 0,
		       strlen(boot_command_line));
		if (ret < 0) {
			a52_bc("no a52,ramcon node in the tree: breadcrumbs stop here\n");
			a52_on = false;
		}
		break;
	case A52BC_PARAM:
		if (!a52_on)
			break;
		if (a52_wdt_off && a52_guest()) {
			struct arm_smccc_res res;

			a52_bc_wdt("before-off");
			arm_smccc_1_1_smc(WDT_FN(0x0005), 2, 0, &res);	/* CONTROL: disable */
			a52_bc("wdt CONTROL(2) a0=%ld\n", (long)res.a0);
			a52_bc_wdt("after-off");
		}
		/* register_earlycon() maps page 0 into the same slot with set_fixmap_io(): clear first */
		if (a52_fixpage != ~0U)
			clear_fixmap(FIX_EARLYCON_MEM_BASE);
		a52_fixpage = ~0U;
		ret = setup_earlycon(opt);
		a52_bc("param t=%llums earlycon=%d\n", a52_ms(), ret);
		break;
	case A52BC_PAGING:
		a52_bc("paging t=%llums dram=%#llx-%#llx mem=%#llx memstart=%#llx initrd=%#llx+%#lx\n",
		       a52_ms(), (u64)memblock_start_of_DRAM(), (u64)memblock_end_of_DRAM(),
		       (u64)memblock_phys_mem_size(), (u64)memstart_addr,
		       (u64)phys_initrd_start, phys_initrd_size);
		break;
	case A52BC_SETUP_END:
		a52_bc("setup_end t=%llums\n", a52_ms());
		a52_bc_wdt("setup_end");
		break;
	}
}

/* --- initcall levels: one line each (level granularity; initcall_debug has the rest) */
static void __init a52bc_ic(const char *lvl)
{
	struct arm_smccc_res res;

	if (!a52_on)
		return;
	a52_wdt_status(&res);
	a52_bc("ic:%s t=%llums up=%llums cpus=%u wdt=%#lx/%lu\n", lvl, a52_ms(),
	       ktime_get_ns() / NSEC_PER_MSEC, num_online_cpus(), res.a1, res.a2);
}

static int __init a52bc_ic_early(void)
{
	char *va;

	if (!a52_on)
		return 0;
	/* still one CPU: switch from the fixmap slot to a mapping of our own */
	va = memremap(A52_BASE, A52_SIZE, MEMREMAP_WC);
	if (va)
		WRITE_ONCE(a52_va, va);
	a52bc_ic(va ? "early" : "early(no memremap)");
	return 0;
}
early_initcall(a52bc_ic_early);

/* after the first initcall (SMP from here on) breadcrumbs need the private mapping */
#define A52BC_LEVEL(lvl, reg) \
	static int __init a52bc_ic_##lvl(void) { if (a52_va) a52bc_ic(#lvl); return 0; } reg(a52bc_ic_##lvl)
A52BC_LEVEL(core, core_initcall);
A52BC_LEVEL(postcore, postcore_initcall);
A52BC_LEVEL(arch, arch_initcall);
A52BC_LEVEL(subsys, subsys_initcall);
A52BC_LEVEL(fs, fs_initcall);
A52BC_LEVEL(rootfs, rootfs_initcall);
A52BC_LEVEL(device, device_initcall);
A52BC_LEVEL(late, late_initcall);

/* --- heartbeat: every second until the end, so the time of death and its state are known */
static void a52_hb_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(a52_hb, a52_hb_fn);
static unsigned int a52_hb_n;

static void a52_hb_fn(struct work_struct *w)
{
	char buf[A52_HBLEN], newest[MODULE_NAME_LEN] = "-", coming[MODULE_NAME_LEN] = "-";
	char pid1[TASK_COMM_LEN] = "-";
	struct arm_smccc_res res;
	struct task_struct *t;
	struct module *mod;
	unsigned int nmods = 0;
	int n;

	rcu_read_lock();
	list_for_each_entry_rcu(mod, &modules, list) {
		if (!nmods++)
			strscpy(newest, mod->name, sizeof(newest));
		if (mod->state == MODULE_STATE_COMING)
			strscpy(coming, mod->name, sizeof(coming));
	}
	t = find_task_by_pid_ns(1, &init_pid_ns);
	if (t)
		strscpy(pid1, t->comm, sizeof(pid1));
	rcu_read_unlock();
	a52_wdt_status(&res);
	n = scnprintf(buf, sizeof(buf),
		      "hb#%u t=%llums up=%llums state=%d cpus=%u wdt=%#lx/%lu mods=%u newest=%s coming=%s pid1=%s tail=%#x/%u",
		      ++a52_hb_n, a52_ms(), ktime_get_ns() / NSEC_PER_MSEC, system_state,
		      num_online_cpus(), res.a1, res.a2, nmods, newest, coming, pid1, a52_tail, a52_wraps);
	memset(buf + n, ' ', sizeof(buf) - n);
	buf[sizeof(buf) - 1] = '\n';
	a52_puts_at(A52_HB, buf, sizeof(buf));
	schedule_delayed_work(&a52_hb, HZ);
}

static int __init a52bc_ic_late_sync(void)
{
	if (!a52_va)
		return 0;
	a52bc_ic("late_sync");
	schedule_delayed_work(&a52_hb, 0);
	return 0;
}
late_initcall_sync(a52bc_ic_late_sync);
