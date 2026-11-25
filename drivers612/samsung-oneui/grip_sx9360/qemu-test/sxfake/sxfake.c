// SPDX-License-Identifier: GPL-2.0
/*
 * QEMU-only test helper for sx9360.ko (never shipped): a plain-I2C adapter bound to a DT node
 * "a52sxq,sxfake-i2c" whose children are instantiated by the i2c core, and a 256-byte register
 * file at 0x28 that answers like an SX9360 (WHOAMI 0xFA = whoami param). Lets the real probe,
 * sysfs/input ABI and remove paths run without hardware.
 */
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

static int whoami = 0x60;
module_param(whoami, int, 0444);

struct sxfake {
	struct i2c_adapter adap;
	u8 regs[256];
	u8 ptr;
	unsigned int xfers;
};

static int sxfake_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
	struct sxfake *f = i2c_get_adapdata(adap);
	int i, j;

	for (i = 0; i < num; i++) {
		struct i2c_msg *m = &msgs[i];

		if (m->addr != 0x28)
			return -ENXIO;
		f->xfers++;
		if (m->flags & I2C_M_RD) {
			for (j = 0; j < m->len; j++)
				m->buf[j] = f->regs[(u8)(f->ptr + j)];
		} else if (m->len) {
			f->ptr = m->buf[0];
			for (j = 1; j < m->len; j++) {
				if (f->ptr == 0xFA)	/* WHOAMI is read-only */
					continue;
				f->regs[(u8)(f->ptr + j - 1)] = m->buf[j];
			}
		}
	}
	return num;
}

static u32 sxfake_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm sxfake_algo = {
	.master_xfer = sxfake_xfer,
	.functionality = sxfake_func,
};

static int sxfake_probe(struct platform_device *pdev)
{
	struct sxfake *f = devm_kzalloc(&pdev->dev, sizeof(*f), GFP_KERNEL);

	if (!f)
		return -ENOMEM;
	f->regs[0xFA] = whoami;
	f->adap.owner = THIS_MODULE;
	f->adap.algo = &sxfake_algo;
	f->adap.dev.parent = &pdev->dev;
	f->adap.dev.of_node = pdev->dev.of_node;
	strscpy(f->adap.name, "sxfake", sizeof(f->adap.name));
	i2c_set_adapdata(&f->adap, f);
	platform_set_drvdata(pdev, f);
	return i2c_add_adapter(&f->adap);
}

static void sxfake_remove(struct platform_device *pdev)
{
	struct sxfake *f = platform_get_drvdata(pdev);

	pr_info("sxfake: %u transfers\n", f->xfers);
	i2c_del_adapter(&f->adap);
}

static const struct of_device_id sxfake_of[] = {
	{ .compatible = "a52sxq,sxfake-i2c" },
	{ }
};
MODULE_DEVICE_TABLE(of, sxfake_of);

static struct platform_driver sxfake_drv = {
	.probe = sxfake_probe,
	.remove_new = sxfake_remove,
	.driver = { .name = "sxfake-i2c", .of_match_table = sxfake_of },
};
module_platform_driver(sxfake_drv);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("QEMU test: fake SX9360 behind a fake I2C adapter");
