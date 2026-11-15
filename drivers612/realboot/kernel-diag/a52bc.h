/* SPDX-License-Identifier: GPL-2.0-only */
/* a52bc: boot breadcrumbs for the first real boot of 6.12 on the A52s (see a52bc.c) */
#ifndef __A52BC_H
#define __A52BC_H
#include <linux/types.h>

enum a52bc_stage {
	A52BC_ENTRY,		/* setup_arch(): fixmap ready, before setup_machine_fdt() */
	A52BC_FDT,		/* setup_machine_fdt() returned: FDT valid, cmdline copied */
	A52BC_PARAM,		/* parse_early_param() done; the RAM console starts here */
	A52BC_PAGING,		/* arm64_memblock_init() + paging_init() done */
	A52BC_SETUP_END,	/* end of setup_arch() */
};

void __init a52bc_stage(enum a52bc_stage stage, phys_addr_t fdt_phys);

#endif
