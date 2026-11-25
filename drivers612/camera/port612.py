#!/usr/bin/env python3
"""Mechanical 5.4 -> 6.12 source edits for the A52s (Samsung SM7325) camera
techpack. Run by port.sh on a fresh copy of techpack/camera/drivers; nothing
is edited by hand, so the port can be regenerated from the Samsung source.
The rule set follows what the redwood SM7325 port found necessary
(donors/redwood-6.12/modules/camera54), re-implemented here and extended for
Samsung's additions. API changes that can be expressed as macros or inline
wrappers live in compat/cam_compat_612.h instead."""
import os, re, sys

root = sys.argv[1]
log = []

def walk(exts=(".c", ".h")):
    for d, _, fs in os.walk(root):
        for f in sorted(fs):
            if f.endswith(exts):
                yield os.path.join(d, f)

def read(p):
    return open(p, errors="replace").read()

def body_span(s, pos):
    """span of the {...} block that starts at or after pos"""
    a = s.index("{", pos)
    depth = 0
    for k in range(a, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if not depth:
                return a, k + 1
    raise ValueError("unbalanced")

def call_end(s, pos):
    """pos is just after the '(' of a call; returns (end, top-level commas)"""
    depth, commas, j = 1, 0, pos
    while depth:
        c = s[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 1:
            commas += 1
        j += 1
    return j, commas

def add_arg(s, fn, nargs, extra):
    out, i = [], 0
    for m in re.finditer(r"\b" + fn + r"\s*\(", s):
        if m.start() < i:
            continue
        j, commas = call_end(s, m.end())
        out.append(s[i:j - 1] + ", " + extra + ")" if commas + 1 == nargs else s[i:j])
        i = j
    out.append(s[i:])
    return "".join(out)

# driver callbacks whose prototypes changed
removes, i2c_probes = set(), set()
for p in walk((".c",)):
    t = read(p)
    removes |= set(re.findall(r"\.remove\s*=\s*(\w+)", t))
    i2c_probes |= set(re.findall(r"\.probe\s*=\s*(\w+)", t))

DEBUGFS = r"debugfs_create_(?:bool|u8|u16|u32|u64|x8|x16|x32|x64|size_t|atomic_t|ulong)"
n = 0
for p in walk():
    s = o = read(p)
    # headers that moved or went away
    s = s.replace("#include <linux/dma-contiguous.h>", "#include <linux/dma-map-ops.h>")
    s = s.replace("#include <linux/dma-iommu.h>", "")
    s = s.replace("#include <linux/ion_kernel.h>", "#include <linux/ion.h>")
    s = s.replace("#include <soc/qcom/scm.h>", "")
    s = s.replace("#include <mm/slab.h>", "#include <linux/slab.h>")
    # debugfs_create_<type>() return void
    s = re.sub(r"(?:[\w\->.\[\]]+)\s*=\s*(" + DEBUGFS + r"\s*\()", r"\1", s)
    # 64-bit time only
    s = re.sub(r"\bstruct timespec\b(?!64)", "struct timespec64", s)
    s = re.sub(r"\bktime_to_timespec\(", "ktime_to_timespec64(", s)
    s = re.sub(r"\bget_monotonic_boottime\(", "ktime_get_boottime_ts64(", s)
    s = re.sub(r"\bgetnstimeofday\(", "ktime_get_real_ts64(", s)
    # dma-buf: callers do not hold the reservation lock
    s = re.sub(r"\bdma_buf_map_attachment\(", "dma_buf_map_attachment_unlocked(", s)
    s = re.sub(r"\bdma_buf_unmap_attachment\(", "dma_buf_unmap_attachment_unlocked(", s)
    s = re.sub(r"\bdma_buf_vmap\(", "cam_dma_buf_vmap(", s)
    s = re.sub(r"\bdma_buf_vunmap\(", "cam_dma_buf_vunmap(", s)
    # iommu_map()/iommu_map_sg() take a gfp
    s = add_arg(s, "iommu_map", 5, "GFP_KERNEL")
    s = add_arg(s, "iommu_map_sg", 5, "GFP_KERNEL")
    # list_sort() comparators take const list heads
    s = re.sub(r"(int\s+\w+\s*\(\s*void\s*\*\s*\w+\s*,\s*)struct list_head\s*\*\s*(\w+)\s*,\s*struct list_head\s*\*\s*(\w+)\s*\)",
               r"\1const struct list_head *\2, const struct list_head *\3)", s)
    # platform/i2c/spi .remove return void
    for name in removes:
        pat = r"(?:static\s+)?(int|int32_t)\s+" + name + r"\s*\(\s*struct\s+(?:platform_device|i2c_client|spi_device)\s*\*\s*\w*\s*\)"
        for m in list(re.finditer(pat, s))[::-1]:
            head = re.sub(r"\b(int|int32_t)(\s+)" + name, r"void\2" + name, m.group(0), count=1)
            if s[m.end():m.end() + 40].lstrip().startswith("{"):
                a, b = body_span(s, m.end())
                s = s[:m.start()] + head + s[m.end():a] + re.sub(r"\b(int|int32_t)(\s+)rc(\s*=\s*0;)", r"\1\2rc __maybe_unused\3", re.sub(r"\breturn\s+[^;]+;", "return;", s[a:b])) + s[b:]
            else:
                s = s[:m.start()] + head + s[m.end():]
    # i2c .probe lost its id argument
    for name in i2c_probes:
        m = re.search(r"((?:static\s+)?(?:int|int32_t)\s+" + name + r"\s*\(\s*struct\s+i2c_client\s*\*\s*(\w+)\s*),\s*const\s+struct\s+i2c_device_id\s*\*\s*(\w+)\s*\)", s)
        if not m:
            continue
        a, b = body_span(s, m.end())
        body = s[a:b]
        if re.search(r"\b" + m.group(3) + r"\b", body):
            body = "{\n\tconst struct i2c_device_id *%s __maybe_unused = i2c_client_get_device_id(%s);\n" % (m.group(3), m.group(2)) + body[1:]
        s = s[:m.start()] + m.group(1) + ")" + s[m.end():a] + body + s[b:]
    # the force-included compat header pulls in printk.h before these
    s = re.sub(r"^#define pr_fmt\(", "#undef pr_fmt\n#define pr_fmt(", s, flags=re.M)
    # class_create() lost its module argument
    s = re.sub(r"\bclass_create\(\s*THIS_MODULE\s*,\s*", "class_create(", s)
    if s != o:
        open(p, "w").write(s)
        n += 1
log.append("generic rules changed %d files" % n)

def edit(rel, pairs, must=True):
    f = os.path.join(root, rel)
    t = read(f)
    for a, b in pairs:
        if a not in t:
            if must:
                raise SystemExit("port612.py: %s: anchor not found: %r" % (rel, a[:70]))
            log.append("SKIPPED (anchor missing) %s: %r" % (rel, a[:50]))
            continue
        t = t.replace(a, b)
    open(f, "w").write(t)

def resub(rel, pat, rep, flags=0):
    f = os.path.join(root, rel)
    t = read(f)
    t2, k = re.subn(pat, rep, t, flags=flags)
    open(f, "w").write(t2)
    log.append("%s: %d x %s" % (rel, k, pat[:50]))

# trace header location and __assign_str() (single argument since 6.10)
resub("cam_utils/cam_trace.h", r"#define TRACE_INCLUDE_PATH .*", "#define TRACE_INCLUDE_PATH .")
resub("cam_utils/cam_trace.h", r"#define TRACE_INCLUDE_FILE .*", "#define TRACE_INCLUDE_FILE cam_trace")
resub("cam_utils/cam_trace.h", r"__assign_str\((\w+),[^;]*\);", r"__assign_str(\1);")

# interconnect: 5.4 icc_get(dev, src_id, dst_id) is gone; take the path from
# the DT node the ids were read from.
edit("cam_utils/cam_soc_bus.h", [("\tuint32_t dst_id;\n\tint num_usecases;",
     "\tuint32_t dst_id;\n\tstruct device_node *icc_np;\n\tint num_usecases;")])
edit("cam_cpas/cam_cpas_soc.c", [
    ("\t\t\t\t\tcpas_core->axi_port[mnoc_idx].bus_client\n\t\t\t\t\t.common_data.dst_id = dst_args.args[0];",
     "\t\t\t\t\tcpas_core->axi_port[mnoc_idx].bus_client\n\t\t\t\t\t.common_data.dst_id = dst_args.args[0];\n\t\t\t\t\tcpas_core->axi_port[mnoc_idx].bus_client\n\t\t\t\t\t.common_data.icc_np = mnoc_node;"),
    ("\t\tcpas_core->ahb_bus_client.common_data.dst_id = dst_args.args[0];",
     "\t\tcpas_core->ahb_bus_client.common_data.dst_id = dst_args.args[0];\n\t\tcpas_core->ahb_bus_client.common_data.icc_np = of_node;"),
], must=False)
edit("cam_utils/cam_soc_icc.c", [("bus_client_data->icc_data = icc_get(&pdev->dev,\n\t\tbus_client->common_data->src_id,\n\t\tbus_client->common_data->dst_id);",
     "bus_client_data->icc_data = cam_icc_get_np(\n\t\tbus_client->common_data->icc_np);")], must=False)

# of_find_node_by_name(from, ..) searches every node AFTER `from`, not only its children: it
# only gives the right AXI port when level3-nodes come first in the tree (as in the phone's
# dtb). Our overlay keeps level0..3 order -> 36 nodes "found" a port, mnoc_idx passed
# CAM_CPAS_MAX_AXI_PORTS and the CPAS probe failed with a silent -EINVAL (run ab-s41).
resub("cam_cpas/cam_cpas_soc.c", r"of_find_node_by_name\(curr_node,\s*\"qcom,axi-port-mnoc\"\)",
      'of_get_child_by_name(curr_node, "qcom,axi-port-mnoc")')
resub("cam_cpas/cam_cpas_soc.c", r"of_find_node_by_name\(curr_node,\s*\"qcom,axi-port-camnoc\"\)",
      'of_get_child_by_name(curr_node, "qcom,axi-port-camnoc")')

# Same DT-order change, second victim: parents were linked in the same pass that parses
# the levels, which only works root-first (5.4: level3..level0). The fdtoverlay-merged
# 6.12 tree lists level0..level3, so tree_node[] of the parent was still NULL, every node
# got parent_node = NULL and cam_cpas_hw.c dropped every AXI/MNOC bandwidth vote without
# an error (audit 2026-11-18, x-dt-order). Link parents in a second pass instead.
edit("cam_cpas/cam_cpas_soc.c", [("""			parent_node = of_parse_phandle(curr_node,
				"parent-node", 0);
			if (parent_node) {
				of_property_read_u32(parent_node, "cell-index",
					&cell_idx);
				curr_node_ptr->parent_node =
					soc_private->tree_node[cell_idx];
			} else {
				CAM_DBG(CAM_CPAS,
					"no parent node at this level");
			}
		}
	}
	mutex_init(&cpas_core->tree_lock);
""", """		}
	}
	/*
	 * a52sxq: link parents only after every level is parsed. The 6.12
	 * board tree (fdtoverlay-merged) lists level0..level3, while 5.4
	 * listed level3..level0, so the parent's tree_node[] was still NULL
	 * and every AXI vote was dropped.
	 */
	for (i = 0; i < CAM_CPAS_MAX_TREE_NODES; i++) {
		curr_node_ptr = soc_private->tree_node[i];
		if (!curr_node_ptr)
			continue;
		parent_node = of_parse_phandle(curr_node_ptr->tree_dev_node,
			"parent-node", 0);
		if (!parent_node)
			continue;
		rc = of_property_read_u32(parent_node, "cell-index", &cell_idx);
		of_node_put(parent_node);
		if (rc || cell_idx >= CAM_CPAS_MAX_TREE_NODES ||
		    !soc_private->tree_node[cell_idx]) {
			CAM_ERR(CAM_CPAS, "%s: unresolved parent-node",
				curr_node_ptr->node_name);
			return -EINVAL;
		}
		curr_node_ptr->parent_node = soc_private->tree_node[cell_idx];
	}
	mutex_init(&cpas_core->tree_lock);
""")])

# SMMU: qcom domain attributes of 5.4 have no 6.12 equivalent (fault model is
# a DT property "qcom,iommu-faults" now; the discard region must be kept out
# with iommu-addresses / qcom,iommu-dma-addr-pool in the DT)
edit("cam_smmu/cam_smmu_api.c", [
    ("\t\tiommu_dma_enable_best_fit_algo(dev);\n", ""),
    ("\t\tif (cb->discard_iova_start)\n\t\t\tiommu_dma_reserve_iova(dev, cb->discard_iova_start,\n\t\t\t\tcb->discard_iova_len);\n", ""),
], must=False)
resub("cam_smmu/cam_smmu_api.c", r"iommu_domain_set_attr\(cb->domain,\s*DOMAIN_ATTR_\w+,\s*&\w+\)", "0")
# iommu_map_sg() walks the CPU scatterlist: orig_nents, not the dma_map_sg()
# merged count (redwood: the 1 MB secheap mapped only its first 64 KB)
f = os.path.join(root, "cam_smmu/cam_smmu_api.c")
t = read(f); out = []; i = 0; k = 0
for m in re.finditer(r"\biommu_map_sg\(", t):
    j, _ = call_end(t, m.end())
    seg = t[m.start():j]
    k += seg.count("table->nents")
    out.append(t[i:m.start()] + seg.replace("table->nents", "table->orig_nents")); i = j
out.append(t[i:]); open(f, "w").write("".join(out))
log.append("cam_smmu_api.c: %d iommu_map_sg nents -> orig_nents" % k)

# IRQs are not IORESOURCE_IRQ resources of DT platform devices any more
edit("cam_utils/cam_soc_util.c", [("""		soc_info->irq_line =
			platform_get_resource_byname(soc_info->pdev,
			IORESOURCE_IRQ, soc_info->irq_name);
		if (!soc_info->irq_line) {""", """		int irq = platform_get_irq_byname(soc_info->pdev,
			soc_info->irq_name);

		soc_info->irq_line = irq < 0 ? NULL :
			devm_kzalloc(&soc_info->pdev->dev,
				sizeof(*soc_info->irq_line), GFP_KERNEL);
		if (soc_info->irq_line) {
			soc_info->irq_line->start = irq;
			soc_info->irq_line->end = irq;
			soc_info->irq_line->flags = IORESOURCE_IRQ;
			soc_info->irq_line->name = soc_info->irq_name;
		}
		if (!soc_info->irq_line) {""")], must=False)

# fault model: was DOMAIN_ATTR_FAULT_MODEL_{NO_STALL,HUPCF} at run time; on
# 6.12 it is the DT property qcom,iommu-faults on each context bank
edit("cam_smmu/cam_smmu_api.c", [
    ("\tint32_t stall_disable = 1;", "\tint32_t stall_disable __maybe_unused = 1;"),
    ("\tint32_t hupcf = 1;", "\tint32_t hupcf __maybe_unused = 1;")], must=False)
# struct kmem_cache is opaque outside mm/ now
edit("cam_req_mgr/cam_req_mgr_dev.c", [("g_cam_req_mgr_timer_cachep->name", "\"crm_timer\"")], must=False)
# SOF-freeze watchdog as stock: the LineageOS 5.4 tree (our donor) has 1000 ms, the stock-derived 5.4 tree
# (kernel_a52sxq_bone techpack/camera/drivers/cam_req_mgr/cam_req_mgr_core.h:16) has 5000 ms (SPEC/05 P1-3).
edit("cam_req_mgr/cam_req_mgr_core.h", [("#define CAM_REQ_MGR_WATCHDOG_TIMEOUT          1000\n",
     "#define CAM_REQ_MGR_WATCHDOG_TIMEOUT          5000\n")])
# kstrtol() is __must_check; keep the behaviour (value untouched on error), add a log
resub("cam_sensor_module/cam_ois/cam_ois_mcu_stm32g.c", r"^(\t+)(kstrtol\([^;]*\));",
      r'\1if (\2)\n\1\tCAM_ERR(CAM_OIS, "gyro cal: bad number in efs data");', re.M)

# CAM_REQ_MGR_CACHE_OPS: 5.4 asked the ION buffer for ION_FLAG_CACHED through
# the dma_buf get_flags op. No DMA-BUF heap on 6.12 implements it (flags stay
# 0), which would turn every cache sync into a silent no-op. Sync always, as
# Qualcomm's own 6.12 camera-kernel does.
edit("cam_req_mgr/cam_mem_mgr.c", [("\tif (dmabuf_flag & ION_FLAG_CACHED) {\n\t\tswitch (cmd->mem_cache_ops) {",
     "\tif (1) { /* 6.12: see port612.py */\n\t\tswitch (cmd->mem_cache_ops) {")])

# GPIO request/free balance (2026-11-24, white cable oops after ~25 camera sessions): 6.12 gpiod_free() does
# module_put(gdev->owner) + gpio_device_put() even for a line that is not requested (5.4 only did it when the
# line really was freed). The driver frees its whole GPIO table at power-down although a request may have
# failed: gpio 523 (TLMM 11, CAM_VANA0 of the rear wide sensor = MCU_VANA of the OIS) is requested by both
# devices, the second request gets -EBUSY (cam_res_mgr reads "sharedgpios", the DT has "shared-gpios": not
# shared on 5.4 either), both free it -> every camera session leaked one pinctrl_yupik module reference and
# one gpio_device reference; at 0 every gpio_request returned -EPROBE_DEFER and the error path oopsed.
# Free only what this driver requested successfully.
A52_GPIO = r"""
/* a52sxq 6.12: free only GPIOs this driver requested successfully (see port612.py) */
#include <linux/moduleparam.h>
#define A52_GPIO_TRACK_MAX 96
int cam_a52_gpio_request_one(unsigned int gpio, unsigned long flags, const char *label);
void cam_a52_gpio_free(unsigned int gpio);
static DEFINE_MUTEX(a52_gpio_lock);
static unsigned int a52_gpio_req[A52_GPIO_TRACK_MAX];
static int a52_gpio_nreq;
static unsigned int a52_gpio_free_skipped;
module_param_named(a52_gpio_free_skipped, a52_gpio_free_skipped, uint, 0444);
module_param_named(a52_gpio_held, a52_gpio_nreq, int, 0444);

int cam_a52_gpio_request_one(unsigned int gpio, unsigned long flags, const char *label)
{
	int rc = gpio_request_one(gpio, flags, label);

	if (rc)
		return rc;
	mutex_lock(&a52_gpio_lock);
	if (a52_gpio_nreq < A52_GPIO_TRACK_MAX)
		a52_gpio_req[a52_gpio_nreq++] = gpio;
	else
		pr_warn_once("a52sxq-camera: gpio track table full, gpio %u stays requested\n", gpio);
	mutex_unlock(&a52_gpio_lock);
	return 0;
}

void cam_a52_gpio_free(unsigned int gpio)
{
	bool found = false;
	int i;

	mutex_lock(&a52_gpio_lock);
	for (i = 0; i < a52_gpio_nreq; i++) {
		if (a52_gpio_req[i] == gpio) {
			a52_gpio_req[i] = a52_gpio_req[--a52_gpio_nreq];
			found = true;
			break;
		}
	}
	if (!found)
		a52_gpio_free_skipped++;
	mutex_unlock(&a52_gpio_lock);
	if (found)
		(gpio_free)(gpio);	/* parenthesised: the edit below replaces the plain call text */
	else
		pr_info_once("a52sxq-camera: gpio %u not requested by the camera driver (request failed or freed twice): not freed\n", gpio);
}

"""
edit("cam_sensor_module/cam_res_mgr/cam_res_mgr.c", [
    ("int cam_res_mgr_gpio_request(struct device *dev, uint gpio,", A52_GPIO + "int cam_res_mgr_gpio_request(struct device *dev, uint gpio,"),
    ("\t\trc = gpio_request_one(gpio, flags, label);", "\t\trc = cam_a52_gpio_request_one(gpio, flags, label);"),
    ("\t\tgpio_free(gpio);", "\t\tcam_a52_gpio_free(gpio);")])
edit("cam_utils/cam_soc_util.c", [
    ("\t\t\trc = gpio_request_one(gpio_tbl[i].gpio,", "\t\t\textern int cam_a52_gpio_request_one(unsigned int gpio, unsigned long flags, const char *label);\n\t\t\trc = cam_a52_gpio_request_one(gpio_tbl[i].gpio,"),
    ("\t\tgpio_free_array(gpio_tbl, size);", "\t\textern void cam_a52_gpio_free(unsigned int gpio);\n\t\tfor (i = size - 1; i >= 0; i--)\n\t\t\tcam_a52_gpio_free(gpio_tbl[i].gpio);")])

open(os.path.join(root, "camera_main.c"), "a").write(
    "\nMODULE_IMPORT_NS(DMA_BUF);\n")
print("\n".join(log))
