// SPDX-License-Identifier: GPL-2.0
/* mdpdump: READ-ONLY look at the display engine the bootloader left running (a52sxq, SM7325):
 * which SSPP fetches from which address, and whether the DSI0 interface timing engine runs
 * (frame counter advancing). Used on the mainline track to show that the simple-framebuffer at
 * 0xe1000000 is what the panel scans out. readl only, no request_mem_region (simpledrm / a later
 * DPU driver may own the range). Offsets: drivers/gpu/drm/msm/disp/dpu1/catalog/dpu_7_2_sc7280.h
 * (bases relative to the "mdp" region 0x0ae01000), dpu_hw_sspp.c, dpu_hw_intf.c.
 * Only load it while the display clocks are on (clk_ignore_unused + simpledrm holding them). */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/delay.h>

#define MDP_BASE	0x0ae01000UL
#define MDP_SIZE	0x40000

static const struct { u32 base; const char *name; } sspp[] = {
	{ 0x4000, "VIG0" }, { 0x24000, "DMA0" }, { 0x26000, "DMA1" }, { 0x28000, "DMA2" },
};
static const struct { u32 base; const char *name; } intf[] = {
	{ 0x34000, "INTF0(DP)" }, { 0x35000, "INTF1(DSI0)" }, { 0x39000, "INTF5(eDP)" },
};

static int __init mdpdump_init(void)
{
	void __iomem *b = ioremap(MDP_BASE, MDP_SIZE);
	int i;

	if (!b)
		return -ENOMEM;
	pr_info("mdpdump: MDP HW_VERSION %#x\n", readl(b + 0x0));
	for (i = 0; i < ARRAY_SIZE(sspp); i++) {
		void __iomem *s = b + sspp[i].base;
		u32 size = readl(s + 0x00);

		pr_info("mdpdump: %-5s src %ux%u addr %#x ystride %u format %#x op %#x\n", sspp[i].name,
			size & 0xffff, size >> 16, readl(s + 0x14), readl(s + 0x24) & 0xffff,
			readl(s + 0x30), readl(s + 0x38));
	}
	for (i = 0; i < ARRAY_SIZE(intf); i++) {
		void __iomem *f = b + intf[i].base;
		u32 en = readl(f + 0x000), fc0 = readl(f + 0x0ac), fc1;

		msleep(50);
		fc1 = readl(f + 0x0ac);
		pr_info("mdpdump: %-11s timing engine %u frame count %u -> %u in 50 ms (line %u)\n",
			intf[i].name, en, fc0, fc1, readl(f + 0x0b0));
	}
	iounmap(b);
	return -EAGAIN;	/* nothing to keep loaded: report and go */
}
module_init(mdpdump_init);
MODULE_DESCRIPTION("read-only DPU scanout state dump (a52sxq bring-up)");
MODULE_LICENSE("GPL");
