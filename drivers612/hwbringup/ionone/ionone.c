// SPDX-License-Identifier: GPL-2.0-only
/* ionone <heap mask hex> <flags hex> <len MiB> <hold s>: ONE /dev/ion allocation, held, then closed.
 * For narrowing the reset that iontest -s causes (hwbringup HARDWARE-LOG, hw3/hw5). nolibc, static. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "ion_abi.h"
static unsigned long hex(const char *s)
{
	unsigned long v = 0;
	for (; *s; s++)
		v = v * 16 + (*s >= 'a' ? *s - 'a' + 10 : *s - '0');
	return v;
}
int main(int argc, char **argv)
{
	struct t_ion_allocation_data d;
	int fd, r;
	if (argc < 5)
		return 1;
	fd = open("/dev/ion", O_RDONLY | O_CLOEXEC);
	if (fd < 0) { printf("open /dev/ion: errno %d\n", errno); return 2; }
	memset(&d, 0, sizeof(d));
	d.len = hex(argv[3]) << 20; d.heap_id_mask = hex(argv[1]); d.flags = hex(argv[2]); d.fd = 0xdeadbeef;
	r = ioctl(fd, T_ION_IOC_ALLOC, &d);
	printf("alloc mask 0x%x flags 0x%x len %lu: ret %d errno %d fd %d\n", (unsigned)d.heap_id_mask, (unsigned)d.flags, (unsigned long)d.len, r, r ? errno : 0, (int)d.fd);
	if (r) return 3;
	sleep(hex(argv[4]));
	printf("closing\n");
	close((int)d.fd);
	return 0;
}
