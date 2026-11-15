// SPDX-License-Identifier: GPL-2.0
/* epssdump: READ-ONLY dump of the yupik EPSS voting registers (L3 domain 0 at 0x18590000 and
 * the three CPU domains at +0x1000/+0x2000/+0x3000) plus the CPUCP/RIMPS shared SRAM areas, to
 * find which voter holds the L3 at 1190.4 MHz on 6.12 (drivers612/busdcvs/L3-MEMLAT.md).
 * It never writes a register: ioremap only (no request_mem_region, the region stays owned by
 * qcom-dcvs/cpufreq-hw/cpucp), readl only.
 *
 * Output: kmsg at load ("epssdump:" lines, `samples` x `interval_ms`), and /proc/epssdump
 * (every read takes a fresh sample, so it can be read again at screen-off without reloading).
 * Params: samples (default 3), interval_ms (default 200), full (0: only the named offsets
 * below; 1: additionally every word of 0x000-0x3fc of each domain and 0x900-0x9fc of domain 0:
 * unnamed offsets, opt-in), sram (1: SCMI shmem, PMU cache and CPUCP log areas; default 1).
 *
 * Register meaning (sources): 0x020 PSTATE_STATUS bits 7:0 = current L-val (cpufreq-hw
 * reg_domain_state; L-val x 19.2 MHz = the running clock), 0x090 + 4n votes (5.4 epss-l3.c:31:
 * domain 0 = AP shared L3 vote, domain d = per-CPU L3 votes of that cluster), 0x100 LUT,
 * 0x320 PERF_STATE (HLOS cpufreq vote; domain 0: unknown), 0x340 CPUCP vote (CPUCP firmware
 * writes the memlat L3 index to 0x18590340 and per-domain values to 0x340 + d*0x1000; 5.4
 * rimps_memlat.c:1463 wrote it to max "until RIMPS takes over"), 0x3c4 cycle counter,
 * 0x01c/0x0bc EPSS debug status/SRB (cpufreq-hw-debug), 0x30c CPUCP->HLOS irq status
 * (qcom_cpucp.c), 0x920 = where the old yupik.dtsi qcom,shared-offset made 6.12 write. */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/bitfield.h>

#define EPSS_BASE	0x18590000UL
#define EPSS_SIZE	0x4000
#define DOM(d)		((d) * 0x1000)
#define LUT_OFF		0x100
#define LUT_MAX		40
#define XO_KHZ		19200
#define LUT_SRC		GENMASK(31, 30)
#define LUT_LVAL	GENMASK(7, 0)

static unsigned int samples = 3;
module_param(samples, uint, 0444);
static unsigned int interval_ms = 200;
module_param(interval_ms, uint, 0444);
static bool full;
module_param(full, bool, 0444);
static bool sram = true;
module_param(sram, bool, 0444);

static const struct { u32 off; const char *name; } regs[] = {
	{ 0x000, "ENABLE" }, { 0x01c, "DBG_STATUS" }, { 0x020, "PSTATE_STATUS" },
	{ 0x090, "VOTE0" }, { 0x094, "VOTE1" }, { 0x098, "VOTE2" }, { 0x09c, "VOTE3" },
	{ 0x0b0, "DCVS_CTRL" }, { 0x0bc, "DBG_SRB" }, { 0x30c, "IRQ_STATUS" },
	{ 0x320, "PERF_STATE" }, { 0x340, "CPUCP_VOTE" }, { 0x3c4, "CYCLE_CNTR" },
};
static const char *const domname[4] = { "L3", "silver", "gold", "prime" };

static const struct { unsigned long pa; u32 size; const char *name; } areas[] = {
	{ 0x18509400, 0x80, "scmi-shmem" },	/* yupik.dtsi cpu_scmi_lpri */
	{ 0x185098e0, 0x320, "pmu-cache" },	/* 5.4 rimps pmu-base: per-CPU counters */
	{ 0x18509c00, 0x400, "cpucp-log" },	/* 5.4 rimps_log / 6.12 cpucp_log */
};

static void __iomem *base;
static u32 lut[4][LUT_MAX];
static unsigned int lutn[4];

static u32 lut_khz(u32 v)
{
	return FIELD_GET(LUT_SRC, v) ? FIELD_GET(LUT_LVAL, v) * XO_KHZ : 300000;
}

static void read_luts(void)
{
	unsigned int d, i;

	for (d = 0; d < 4; d++) {
		u32 prev = 0;

		for (i = 0; i < LUT_MAX; i++) {
			u32 khz = lut_khz(readl(base + DOM(d) + LUT_OFF + i * 4));

			if (i && khz == prev)	/* same end-of-table rule as dcvs_epss.c */
				break;
			lut[d][i] = khz;
			prev = khz;
		}
		lutn[d] = i;
	}
}

static u32 idx_khz(unsigned int d, u32 idx)
{
	idx &= 0x3f;
	return idx < lutn[d] ? lut[d][idx] : 0;
}

#define OUT(s, fmt, ...) do { if (s) seq_printf(s, fmt "\n", ##__VA_ARGS__); \
			      else pr_info("epssdump: " fmt "\n", ##__VA_ARGS__); } while (0)

static void dump_luts(struct seq_file *s)
{
	unsigned int d, i;
	char line[LUT_MAX * 9 + 1];

	for (d = 0; d < 4; d++) {
		int n = 0;

		for (i = 0; i < lutn[d]; i++)
			n += scnprintf(line + n, sizeof(line) - n, " %u", lut[d][i]);
		OUT(s, "lut d%u(%s) %u rows kHz:%s", d, domname[d], lutn[d], line);
	}
}

static void dump_once(struct seq_file *s, unsigned int nr)
{
	unsigned int d, i;
	u32 c0, c1;

	for (d = 0; d < 4; d++) {
		u32 ps = readl(base + DOM(d) + 0x020);

		OUT(s, "[%u] d%u(%s) running L-val %u = %u kHz", nr, d, domname[d],
		    ps & 0xff, (ps & 0xff) * XO_KHZ);
		for (i = 0; i < ARRAY_SIZE(regs); i++) {
			u32 v = readl(base + DOM(d) + regs[i].off);
			bool isidx = regs[i].off == 0x320 || regs[i].off == 0x340 ||
				     (regs[i].off >= 0x090 && regs[i].off <= 0x09c);

			if (isidx)
				OUT(s, "[%u] d%u %-13s +0x%03x = 0x%08x (idx %u -> %u kHz)", nr, d,
				    regs[i].name, regs[i].off, v, v & 0x3f, idx_khz(d, v));
			else
				OUT(s, "[%u] d%u %-13s +0x%03x = 0x%08x", nr, d, regs[i].name,
				    regs[i].off, v);
		}
	}
	{
		u32 v = readl(base + 0x920);

		OUT(s, "[%u] d0 OLD_DT_0x920  +0x920 = 0x%08x (idx %u -> %u kHz)", nr, v,
		    v & 0x3f, idx_khz(0, v));
	}
	c0 = readl(base + 0x3c4);
	udelay(1000);
	c1 = readl(base + 0x3c4);
	OUT(s, "[%u] d0 cycle counter delta over 1 ms = %u (if it counts L3 cycles: %u kHz)",
	    nr, c1 - c0, c1 - c0);

	if (full) {
		for (d = 0; d < 4; d++)
			for (i = 0; i < 0x400; i += 16)
				OUT(s, "[%u] full d%u +0x%03x: %08x %08x %08x %08x", nr, d, i,
				    readl(base + DOM(d) + i), readl(base + DOM(d) + i + 4),
				    readl(base + DOM(d) + i + 8), readl(base + DOM(d) + i + 12));
		for (i = 0x900; i < 0xa00; i += 16)
			OUT(s, "[%u] full d0 +0x%03x: %08x %08x %08x %08x", nr, i,
			    readl(base + i), readl(base + i + 4), readl(base + i + 8),
			    readl(base + i + 12));
	}
}

static void dump_sram(struct seq_file *s)
{
	unsigned int a, i;

	for (a = 0; a < ARRAY_SIZE(areas); a++) {
		void __iomem *p = ioremap(areas[a].pa, areas[a].size);

		if (!p) {
			OUT(s, "sram %s: ioremap failed", areas[a].name);
			continue;
		}
		for (i = 0; i < areas[a].size; i += 32)
			OUT(s, "sram %s 0x%08lx: %08x %08x %08x %08x %08x %08x %08x %08x",
			    areas[a].name, areas[a].pa + i, readl(p + i), readl(p + i + 4),
			    readl(p + i + 8), readl(p + i + 12), readl(p + i + 16),
			    readl(p + i + 20), readl(p + i + 24), readl(p + i + 28));
		iounmap(p);
	}
}

static int epss_show(struct seq_file *s, void *v)
{
	dump_luts(s);
	dump_once(s, 0);
	if (sram)
		dump_sram(s);
	return 0;
}

static struct proc_dir_entry *pde;

static int __init epssdump_init(void)
{
	unsigned int n;

	base = ioremap(EPSS_BASE, EPSS_SIZE);
	if (!base)
		return -ENOMEM;
	read_luts();
	dump_luts(NULL);
	for (n = 0; n < samples; n++) {
		if (n)
			msleep(interval_ms);
		dump_once(NULL, n);
	}
	if (sram)
		dump_sram(NULL);
	pde = proc_create_single("epssdump", 0400, NULL, epss_show);
	pr_info("epssdump: done (read-only); /proc/epssdump re-samples\n");
	return 0;
}

static void __exit epssdump_exit(void)
{
	proc_remove(pde);
	iounmap(base);
}

module_init(epssdump_init);
module_exit(epssdump_exit);
MODULE_DESCRIPTION("Read-only dump of yupik EPSS L3/CPU voting registers and CPUCP shared SRAM");
MODULE_LICENSE("GPL");
