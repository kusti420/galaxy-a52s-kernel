/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Kernel API that changed between 5.4 (msm-5.4 QGKI) and the Qualcomm 6.12
 * BSP under the A52s camera techpack. Force-included into every camera
 * source file by Kbuild. What cannot be expressed here is done by
 * port612.py.
 */
#ifndef CAM_COMPAT_612_H
#define CAM_COMPAT_612_H

#include <linux/version.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/time.h>
#include <linux/ktime.h>
#include <linux/timekeeping.h>
#include <linux/pinctrl/consumer.h>
#include <linux/platform_device.h>
#include <linux/of_platform.h>
#include <linux/dma-map-ops.h>
#include <linux/io.h>
#include <linux/gpio.h>
#include <linux/of_gpio.h>
#include <linux/interconnect.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/iosys-map.h>
#include <linux/list_sort.h>
#include <linux/timer.h>
#include <linux/qcom-iommu-util.h>
#include <soc/qcom/of_common.h>

/* strlcpy() was removed in 6.8; no caller here uses its return value */
#define strlcpy(d, s, n) strscpy(d, s, n)

/* struct timeval is gone from kernel code; used only in driver-private structs */
#define timeval __kernel_old_timeval

/* v4l2 */
#define VFL_TYPE_GRABBER VFL_TYPE_VIDEO
#ifndef V4L2_SUBDEV_NAME_SIZE
#define V4L2_SUBDEV_NAME_SIZE 32
#endif

/* msm-only register accessors that never went upstream */
#define writel_relaxed_no_log(v, a) writel_relaxed(v, a)
#define readl_relaxed_no_log(a) readl_relaxed(a)
#define __raw_writel_no_log(v, a) __raw_writel(v, a)
#define __raw_readl_no_log(a) __raw_readl(a)

/* of_gpio: of_get_gpio()/of_gpio_count()/gpio_free_array() were removed */
#define of_get_gpio(np, index) of_get_named_gpio(np, "gpios", index)
#define of_gpio_count(np) of_count_phandle_with_args(np, "gpios", "#gpio-cells")
static inline void cam_gpio_free_array(const struct gpio *array, size_t num)
{
	while (num--)
		gpio_free((array++)->gpio);
}
#define gpio_free_array(a, n) cam_gpio_free_array(a, n)

#define kzfree(p) kfree_sensitive(p)

/* qcom IOMMU fault ids got a prefix */
#define iommu_fault_ids qcom_iommu_fault_ids
#define iommu_get_fault_ids(domain, ids) qcom_iommu_get_fault_ids(domain, ids)

/*
 * 5.4 icc_get(dev, src_id, dst_id) is gone. The ids always came from the
 * "interconnects" pair of a known DT node (port612.py records that node in
 * cam_soc_bus_client_common_data.icc_np), so take the path from the node.
 * of_icc_get_by_index() is not exported, hence the throw-away device.
 */
static inline void cam_icc_dev_release(struct device *dev)
{
	kfree(dev);
}

static inline struct icc_path *cam_icc_get_np(struct device_node *np)
{
	struct device *dev;
	struct icc_path *path;

	if (!np)
		return ERR_PTR(-ENODEV);
	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return ERR_PTR(-ENOMEM);
	device_initialize(dev);
	dev->release = cam_icc_dev_release;
	dev->of_node = np;
	dev_set_name(dev, "cam-icc-%pOFn", np);
	path = of_icc_get(dev, NULL);
	put_device(dev);
	return path;
}

/*
 * ION: the in-kernel ion_alloc() face is provided by the project's
 * modules/ioncompat (heap-id mask + flags -> DMA-BUF heap), so cam_mem_mgr
 * keeps its 5.4 allocation code and the heap policy lives in one place
 * together with /dev/ion. Headers: compat/ioncompat-include (copied).
 */
#include <linux/msm_ion.h>
#include <linux/ion.h>

/* dma_buf_vmap() fills an iosys_map and needs the reservation lock */
static inline void *cam_dma_buf_vmap(struct dma_buf *buf)
{
	struct iosys_map map;

	if (dma_buf_vmap_unlocked(buf, &map))
		return NULL;
	return map.vaddr;
}

static inline void cam_dma_buf_vunmap(struct dma_buf *buf, void *vaddr)
{
	struct iosys_map map = IOSYS_MAP_INIT_VADDR(vaddr);

	dma_buf_vunmap_unlocked(buf, &map);
}

/*
 * The A52s has an AMOLED panel and no SPMI WLED; the flash is the SM5714.
 * The 6.12 WLED driver does not offer wled_flash_led_prepare() to modules.
 */
#define wled_flash_led_prepare(trigger, options, max_current) (-ENODEV)

/* timers: timer_setup()/del_timer*() are unchanged on 6.12; nothing to do. */

#endif
