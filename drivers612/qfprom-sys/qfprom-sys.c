// SPDX-License-Identifier: GPL-2.0-only

#include <linux/device.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/io.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/arm-smccc.h>
#include <linux/string.h>

/*
 * a52sxq DEBUG builds only (androidboot.a52sxq.debug=1): one READ-ONLY look at the hypervisor's
 * virtual watchdog (vendor-hyp STATUS, the call modules/hhwdt and the a52bc diag kernel use), so
 * a phone without root can show in the kernel log (a52kmsg) whether its bootloader hands the
 * kernel an ARMED watchdog (a1 bit 0) before WDT=1 is considered for it (2026-11-19). Arms,
 * pets and changes nothing. This module is used because it is a small first-stage module that
 * every real-boot build already loads.
 */
#define A52_VWDT_STATUS ARM_SMCCC_CALL_VAL(ARM_SMCCC_FAST_CALL, ARM_SMCCC_SMC_32, \
					   ARM_SMCCC_OWNER_VENDOR_HYP, 0x0006)
static void a52_vwdt_status_once(void)
{
	static bool done;
	const char *args = NULL;
	struct arm_smccc_res res;

	if (done)
		return;
	done = true;
	if (!of_chosen || of_property_read_string(of_chosen, "bootargs", &args) || !args ||
	    !strstr(args, "androidboot.a52sxq.debug=1"))
		return;
	arm_smccc_1_1_smc(A52_VWDT_STATUS, 0, &res);
	pr_info("a52 vwdt STATUS (read only): a0=%ld a1=0x%lx a2=%lu a3=%lu (a1 bit0 = enabled, bit31 = expired)\n",
		(long)res.a0, res.a1, res.a2, res.a3);
}

struct qfprom_sys {
	int cell_count;
	struct nvmem_cell **cells;
	struct bin_attribute **attrs;
};

static ssize_t qfprom_sys_cell_read(struct file *filp, struct kobject *kobj,
				struct bin_attribute *attr,
				char *buf, loff_t pos, size_t count)
{
	struct nvmem_cell *cell;
	size_t len;
	u8 *data;

	cell = attr->private;
	if (!cell)
		return -EINVAL;

	data = nvmem_cell_read(cell, &len);
	if (IS_ERR(data))
		return -EINVAL;

	len = min(len, count);
	memcpy(buf, data, len);
	kfree(data);
	return len;
}

static int qfprom_sys_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct qfprom_sys *priv;
	struct nvmem_cell *cell;
	int cell_count;
	int i, ret;
	const char **cells;

	a52_vwdt_status_once();

	cell_count = of_property_count_strings(dev->of_node, "nvmem-cell-names");
	if (cell_count <= 0)
		return -EINVAL;

	priv = devm_kzalloc(dev, sizeof(struct qfprom_sys), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->cells = devm_kzalloc(dev,
				cell_count * sizeof(struct nvmem_cell *),
				GFP_KERNEL);
	if (!priv->cells)
		return -ENOMEM;

	cells = devm_kzalloc(dev, cell_count * sizeof(char *), GFP_KERNEL);
	if (!cells)
		return -ENOMEM;

	priv->attrs = devm_kzalloc(dev,
			cell_count * sizeof(struct bin_attribute *),
			GFP_KERNEL);
	if (!priv->attrs)
		return -ENOMEM;

	ret = of_property_read_string_array(dev->of_node, "nvmem-cell-names",
						cells, cell_count);

	for (i = 0; i < cell_count; i++) {
		cell = nvmem_cell_get(dev, cells[i]);
		if (IS_ERR_OR_NULL(cell)) {
			ret = PTR_ERR(cell);
			dev_err(dev, "cell corresponding to %s not found\n",
					cells[i]);
			goto remove_cells;
		}

		priv->attrs[i] = devm_kzalloc(dev, sizeof(struct bin_attribute),
						GFP_KERNEL);
		if (!priv->attrs[i]) {
			ret = -ENOMEM;
			nvmem_cell_put(cell);
			goto remove_cells;
		}

		priv->cells[i] = cell;
		sysfs_bin_attr_init(priv->attrs[i]);
		priv->attrs[i]->attr.name = cells[i];
		priv->attrs[i]->attr.mode = 0444;
		priv->attrs[i]->private = cell;
		priv->attrs[i]->size = 4;
		priv->attrs[i]->read = qfprom_sys_cell_read;
		ret = sysfs_create_bin_file(&dev->kobj, priv->attrs[i]);
		if (ret) {
			dev_err(dev, "cell corresponding to %s\n", cells[i]);
			nvmem_cell_put(cell);
			goto remove_cells;
		}
	}

	priv->cell_count = cell_count;
	platform_set_drvdata(pdev, priv);
	return 0;

remove_cells:
	for (; i > 0; i--) {
		sysfs_remove_bin_file(&dev->kobj, priv->attrs[i-1]);
		nvmem_cell_put(priv->cells[i-1]);
	}
	priv->cell_count = 0;
	return ret;
}

static void qfprom_sys_remove(struct platform_device *pdev)
{
	struct qfprom_sys *priv;
	int i;

	priv = platform_get_drvdata(pdev);
	for (i = 0; i < priv->cell_count; i++) {
		nvmem_cell_put(priv->cells[i]);
		sysfs_remove_bin_file(&pdev->dev.kobj, priv->attrs[i]);
	}

}

static const struct of_device_id qfprom_sys_of_match[] = {
	{ .compatible = "qcom,qfprom-sys",},
	{},
};

MODULE_DEVICE_TABLE(of, qfprom_sys_of_match);

static struct platform_driver qfprom_sys_driver = {
	.probe = qfprom_sys_probe,
	.remove = qfprom_sys_remove,
	.driver = {
		.name = "qcom,qfprom-sys",
		.of_match_table = qfprom_sys_of_match,
	},
};

module_platform_driver(qfprom_sys_driver);
MODULE_DESCRIPTION("Qualcomm Technologies, Inc. QFPROM_SYS driver");
MODULE_LICENSE("GPL v2");
