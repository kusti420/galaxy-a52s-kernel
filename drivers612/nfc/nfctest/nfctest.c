// SPDX-License-Identifier: GPL-2.0-only
/*
 * nfctest: first on-device check of /dev/sec-nfc (drivers612/nfc, Samsung S3NRN4V).
 * Uses the kernel interface exactly as the open Samsung HAL does
 * (hardware/samsung_slsi/nfc/halimpl/src/device.cc: open O_RDWR|O_NOCTTY, ioctl
 * SEC_NFC_SET_MODE, write, select() for readable, read 4-byte bootloader header then payload).
 *
 *   nfctest bl        SET_MODE 2 (bootloader: VEN on, FIRM high), send the driver's own
 *                     "get bootloader info" frame (the one /sys/class/nfc_test/test sends for
 *                     bootloader_ver > 4), wait for the IRQ via poll(), read the answer, print
 *                     it, SET_MODE 0. No RF field: bootloader mode does not start the radio.
 *   nfctest modes     SET_MODE 2 -> 1 -> 0 (the HAL's open sequence, 5.4 dmesg "NFC mode is")
 *   nfctest bad       unknown ioctl -> expect errno 25 (ENOTTY), as on 5.4; read/write/poll
 *                     while OFF -> expect errno 19 (ENODEV)
 *
 * Static, kernel nolibc (no NDK): runs in the busybox test ramdisk and under Android (root;
 * stop the NFC HAL first, the driver allows only one opener in a non-OFF mode).
 * The ioctl ABI is copied from the phone's 5.4 drivers/nfc/sec_nfc.h.
 */
#include <linux/ioctl.h>
/* struct pollfd and POLLIN come from nolibc (types.h) */
#include <linux/types.h>

#define SEC_NFC_MAGIC		'S'
#define SEC_NFC_SET_MODE	_IOW(SEC_NFC_MAGIC, 1, unsigned int)
#define SEC_NFC_SLEEP		_IOW(SEC_NFC_MAGIC, 2, unsigned int)
#define SEC_NFC_WAKEUP		_IOW(SEC_NFC_MAGIC, 3, unsigned int)
#define SEC_NFC_SHUTDOWN	_IOW(SEC_NFC_MAGIC, 6, unsigned int)	/* newer HALs; not in 5.4 */

#define MODE_OFF	0
#define MODE_FW		1
#define MODE_BL		2

static int set_mode(int fd, unsigned long m)
{
	int r = ioctl(fd, SEC_NFC_SET_MODE, (void *)m);

	printf("SET_MODE %lu -> %d (errno %d)\n", m, r, r < 0 ? errno : 0);
	return r;
}

static void hex(const char *what, const __u8 *b, int n)
{
	int i;

	printf("%s(%d):", what, n);
	for (i = 0; i < n; i++)
		printf(" %02x", b[i]);
	printf("\n");
}

static int bl_info(int fd)
{
	/* sec_nfc.c test_show(), bootloader_ver > 4 (SEN4/SN4V/RN4V): header 00 01 05 00 + 5 bytes */
	static const __u8 cmd[9] = { 0x00, 0x01, 0x05, 0x00, 0x00, 0x14, 0x01, 0x00, 0x00 };
	struct pollfd p = { .fd = fd, .events = POLLIN };
	__u8 buf[260];
	int r, n;

	if (set_mode(fd, MODE_BL) < 0)
		return -1;
	r = write(fd, cmd, sizeof(cmd));
	printf("write %d -> %d (errno %d)\n", (int)sizeof(cmd), r, r < 0 ? errno : 0);
	if (r != (int)sizeof(cmd))
		goto off;
	r = poll(&p, 1, 1000);
	printf("poll -> %d revents 0x%x (1 = the chip raised its IRQ within 1 s)\n", r, p.revents);
	if (r <= 0)
		goto off;
	n = read(fd, buf, 4);
	if (n != 4) {
		printf("read header -> %d (errno %d)\n", n, n < 0 ? errno : 0);
		r = -1;
		goto off;
	}
	hex("header", buf, 4);
	if (buf[2]) {
		/* the HAL reads the payload right after the header, without a second select() */
		n = read(fd, buf + 4, buf[2]);
		printf("read payload %d -> %d (errno %d)\n", buf[2], n, n < 0 ? errno : 0);
		if (n > 0)
			hex("payload", buf + 4, n);
		/* HAL: payload[0..3] = bootloader version, [4..5] sector size, [6..7] page size */
		if (n >= 4)
			printf("BL ver: %02X.%02X.%02X.%02X\n", buf[4], buf[5], buf[6], buf[7]);
	}
	r = 0;
off:
	set_mode(fd, MODE_OFF);
	return r;
}

int main(int argc, char **argv)
{
	const char *c = argc > 1 ? argv[1] : "bl";
	struct pollfd p;
	__u8 b[4] = { 0 };
	int fd, r = 0;

	fd = open("/dev/sec-nfc", O_RDWR | O_NOCTTY);
	if (fd < 0) {
		printf("open /dev/sec-nfc failed: errno %d\n", errno);
		return 1;
	}
	if (!strcmp(c, "bl")) {
		r = bl_info(fd);
	} else if (!strcmp(c, "modes")) {
		r = set_mode(fd, MODE_BL);
		usleep(50000);
		r |= set_mode(fd, MODE_FW);
		usleep(50000);
		r |= set_mode(fd, MODE_OFF);
	} else if (!strcmp(c, "bad")) {
		r = ioctl(fd, SEC_NFC_SHUTDOWN, 0);
		printf("SHUTDOWN (unknown on 5.4) -> %d errno %d (expect 25)\n", r, errno);
		r = read(fd, b, sizeof(b));
		printf("read while OFF -> %d errno %d (expect 19)\n", r, errno);
		r = write(fd, b, sizeof(b));
		printf("write while OFF -> %d errno %d (expect 19)\n", r, errno);
		p.fd = fd;
		p.events = POLLIN;
		p.revents = 0;
		r = poll(&p, 1, 0);
		printf("poll while OFF -> %d revents 0x%x (5.4: -ENODEV as mask, all bits)\n",
		       r, p.revents);
		r = 0;
	} else {
		printf("usage: nfctest bl|modes|bad\n");
		r = -1;
	}
	close(fd);
	return r < 0 ? 1 : 0;
}
