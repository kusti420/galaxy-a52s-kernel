// SPDX-License-Identifier: GPL-2.0-only
/*
 * esfptest: first on-device check of /dev/esfp0 (drivers612/fingerprint, Egis ET713).
 * Issues exactly the ioctls Samsung's libbauthserver.so / libegis_fp_normal_sensor_test.so
 * use on the kernel side (the sensor data path is in TrustZone and is not touched here).
 *
 *   esfptest info          FP_MODEL_INFO              -> prints the 10-byte model ("A528")
 *   esfptest on | off      FP_POWER_CONTROL 1 | 0     -> L3C 3.3 V + TLMM 35 high / both off
 *   esfptest reset         FP_SENSOR_RESET            -> TLMM 35 low 1 ms, high
 *   esfptest clk <hz>      FP_SET_SPI_CLOCK           -> takes the et7xx wakeup source
 *   esfptest noclk         FP_DISABLE_SPI_CLOCK       -> drops it
 *   esfptest type <n>      FP_SET_SENSOR_TYPE         -> type_check shows min(n,1) for n > 0
 *   esfptest bad           wrong magic + unknown op   -> expect ENOTTY and EFAULT (as on 5.4)
 *
 * Static, kernel nolibc (no NDK): runs in the busybox test ramdisk and under Android.
 * The ioctl ABI below is copied from the phone's 5.4 drivers/fingerprint/et7xx.h.
 */
#include <linux/ioctl.h>
#include <linux/types.h>

#define FP_SENSOR_RESET		0x04
#define FP_POWER_CONTROL	0x05
#define FP_SET_SPI_CLOCK	0x06
#define FP_DISABLE_SPI_CLOCK	0x10
#define FP_SET_SENSOR_TYPE	0x14
#define FP_MODEL_INFO		0x1f

struct egis_ioc_transfer {
	__u8 *tx_buf;
	__u8 *rx_buf;
	__u32 len;
	__u32 speed_hz;
	__u16 delay_usecs;
	__u8 bits_per_word;
	__u8 cs_change;
	__u8 opcode;
	__u8 pad[3];
};

#define EGIS_IOC_MAGIC		'k'
#define EGIS_IOC_MESSAGE(N)	_IOW(EGIS_IOC_MAGIC, 0, char[(N) * sizeof(struct egis_ioc_transfer)])

_Static_assert(sizeof(struct egis_ioc_transfer) == 32, "5.4 arm64 layout");

static int xfer(int fd, unsigned long cmd, __u8 op, __u32 len, __u32 hz, __u8 *rx)
{
	struct egis_ioc_transfer t;
	int r;

	memset(&t, 0, sizeof(t));
	t.opcode = op;
	t.len = len;
	t.speed_hz = hz;
	t.rx_buf = rx;
	r = ioctl(fd, cmd, &t);
	printf("ioctl op 0x%02x len %u -> %d (errno %d)\n", op, len, r, r < 0 ? errno : 0);
	return r;
}

static __u32 num(const char *s)
{
	__u32 v = 0;

	while (*s >= '0' && *s <= '9')
		v = v * 10 + (__u32)(*s++ - '0');
	return v;
}

int main(int argc, char **argv)
{
	unsigned long msg = EGIS_IOC_MESSAGE(1);
	const char *c = argc > 1 ? argv[1] : "info";
	__u8 mi[11];
	int fd, r = 0;

	fd = open("/dev/esfp0", O_RDWR);
	if (fd < 0) {
		printf("open /dev/esfp0 failed: errno %d\n", errno);
		return 1;
	}
	if (!strcmp(c, "info")) {
		memset(mi, 0, sizeof(mi));
		r = xfer(fd, msg, FP_MODEL_INFO, 0, 0, mi);
		printf("model info: \"%s\"\n", (char *)mi);
	} else if (!strcmp(c, "on")) {
		r = xfer(fd, msg, FP_POWER_CONTROL, 1, 0, 0);
	} else if (!strcmp(c, "off")) {
		r = xfer(fd, msg, FP_POWER_CONTROL, 0, 0, 0);
	} else if (!strcmp(c, "reset")) {
		r = xfer(fd, msg, FP_SENSOR_RESET, 0, 0, 0);
	} else if (!strcmp(c, "clk") && argc > 2) {
		r = xfer(fd, msg, FP_SET_SPI_CLOCK, 0, num(argv[2]), 0);
	} else if (!strcmp(c, "noclk")) {
		r = xfer(fd, msg, FP_DISABLE_SPI_CLOCK, 0, 0, 0);
	} else if (!strcmp(c, "type") && argc > 2) {
		r = xfer(fd, msg, FP_SET_SENSOR_TYPE, num(argv[2]), 0, 0);
	} else if (!strcmp(c, "bad")) {
		/* wrong magic: ENOTTY; right magic, unknown opcode: EFAULT (5.4 behaviour) */
		xfer(fd, _IOW('x', 0, char[32]), FP_MODEL_INFO, 0, 0, 0);
		xfer(fd, msg, 0xee, 0, 0, 0);
	} else {
		printf("usage: esfptest info|on|off|reset|clk <hz>|noclk|type <n>|bad\n");
		r = -1;
	}
	close(fd);
	return r < 0 ? 1 : 0;
}
