// SPDX-License-Identifier: GPL-2.0
/* epssvote: TEST-ONLY one-shot write of ONE EPSS L3 vote register, for the L3 floor test of
 * drivers612/busdcvs/L3-MEMLAT.md ("RIMPS/CPUCP L3 floor"). Not part of any build or ramdisk.
 * Load only after epssdump has shown which register holds the 1190.4 MHz index.
 *
 *   insmod epssvote.ko off=0x340 idx=0     # write idx to 0x18590000 + off, log before/after
 *   rmmod epssvote                         # writes the value read at load back (A/B, same boot)
 *
 * Allowed offsets only: 0x340 (CPUCP/RIMPS L3 vote; 5.4 rimps_memlat.c:1464 writes it from the
 * AP too) and the per-CPU L3 vote registers 0x1090-0x109c, 0x2090-0x2098, 0x3090 (5.4
 * epss-l3.c:36, domain d cpu n = d*0x1000 + 0x90 + 4n). idx must be < the L3 LUT length.
 * keep=1: do not restore on unload. */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/bitfield.h>

#define EPSS_BASE	0x18590000UL
#define EPSS_SIZE	0x4000

static unsigned int off;
module_param(off, uint, 0444);
static int idx = -1;
module_param(idx, int, 0444);
static bool keep;
module_param(keep, bool, 0444);

static void __iomem *base;
static u32 orig;

static bool off_allowed(u32 o)
{
	if (o == 0x340)
		return true;
	return (o >= 0x1090 && o <= 0x109c && !(o & 3)) ||
	       (o >= 0x2090 && o <= 0x2098 && !(o & 3)) || o == 0x3090;
}

static unsigned int l3_lut_len(void)
{
	unsigned int i;
	u32 prev = 0;

	for (i = 0; i < 40; i++) {
		u32 v = readl(base + 0x100 + i * 4);
		u32 khz = FIELD_GET(GENMASK(31, 30), v) ? (v & 0xff) * 19200 : 300000;

		if (i && khz == prev)
			break;
		prev = khz;
	}
	return i;
}

static int __init epssvote_init(void)
{
	unsigned int n;

	if (!off_allowed(off) || idx < 0) {
		pr_err("epssvote: refused: off=0x%x idx=%d (allowed off 0x340, 0x1090-0x109c, 0x2090-0x2098, 0x3090)\n",
		       off, idx);
		return -EINVAL;
	}
	base = ioremap(EPSS_BASE, EPSS_SIZE);
	if (!base)
		return -ENOMEM;
	n = l3_lut_len();
	if (idx >= n) {
		pr_err("epssvote: refused: idx %d >= L3 LUT length %u\n", idx, n);
		iounmap(base);
		return -EINVAL;
	}
	orig = readl(base + off);
	pr_info("epssvote: +0x%x was 0x%08x, running L-val %u; writing %d\n", off, orig,
		readl(base + 0x20) & 0xff, idx);
	writel(idx, base + off);
	pr_info("epssvote: +0x%x now 0x%08x, running L-val %u (x 19.2 MHz)\n", off,
		readl(base + off), readl(base + 0x20) & 0xff);
	return 0;
}

static void __exit epssvote_exit(void)
{
	if (!keep) {
		writel(orig, base + off);
		pr_info("epssvote: +0x%x restored to 0x%08x, running L-val %u\n", off,
			readl(base + off), readl(base + 0x20) & 0xff);
	}
	iounmap(base);
}

module_init(epssvote_init);
module_exit(epssvote_exit);
MODULE_DESCRIPTION("TEST ONLY: write one yupik EPSS L3 vote register (CPUCP floor test)");
MODULE_LICENSE("GPL");
