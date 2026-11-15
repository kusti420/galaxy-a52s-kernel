// SPDX-License-Identifier: GPL-2.0-only
/*
 * efsdump: copy the modem's four EFS partitions (modemst1, modemst2, fsg, fsc) into RAM files for
 * the a52sxq kernel-only modem test M2-K, and check afterwards that the partitions are unchanged.
 *
 *   efsdump copy   <dir>   dir must be on tmpfs/ramfs and must not contain the files yet
 *   efsdump verify <dir>   re-read the partitions and compare them with the copies
 *
 * Output files (the names rmtfs looks up under -o <dir>): modem_fs1 modem_fs2 modem_fsg modem_fsc.
 *
 * SAFETY (these partitions hold the phone's IMEI and RF calibration):
 * - a block device is opened in exactly one place, open_blk_ro(), with O_RDONLY. Nothing in this
 *   program opens a block device for writing, and the only write() calls go to files created
 *   with O_CREAT|O_EXCL|O_NOFOLLOW in a directory that is verified to be tmpfs/ramfs. O_EXCL
 *   also means an existing node (a device node, a symlink) is never written through.
 * - only the four partition names above, found by PARTNAME in /sys/class/block among UFS
 *   partitions (sdXN; mmcblk* = the microSD card is skipped and refused: HARD RULE), exactly one match
 *   each, and /dev/<name> must be a block device whose dev_t equals the sysfs one.
 * - before reading, the kernel's read-only flag is set on each of the four partitions
 *   (BLKROSET, in-memory, cleared by the next boot): after that the kernel refuses every new
 *   open for writing (EACCES) by anyone, for the rest of this boot.
 */
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>

#define TMPFS_MAGIC_ 0x01021994
#define RAMFS_MAGIC_ 0x858458f6
#define MAX_PART (64u << 20)

static const struct { const char *part, *file; } efs[] = {
	{ "modemst1", "modem_fs1" },
	{ "modemst2", "modem_fs2" },
	{ "fsg",      "modem_fsg" },
	{ "fsc",      "modem_fsc" },
};

static uint64_t fnv64(const unsigned char *p, size_t n)
{
	uint64_t h = 0xcbf29ce484222325ull;

	while (n--) {
		h ^= *p++;
		h *= 0x100000001b3ull;
	}
	return h;
}

static int on_ram_fs(int fd)
{
	struct statfs s;

	return fstatfs(fd, &s) == 0 && (s.f_type == TMPFS_MAGIC_ || s.f_type == RAMFS_MAGIC_);
}

/*
 * UFS partitions only: "sd" + letters + digits (sda29, sdf4). HARD RULE:
 * the microSD card (mmcblk*) is never opened, read or written by anything in the test packs.
 */
static int ufs_part_name(const char *n)
{
	const char *p = n + 2;

	if (!strncmp(n, "mmcblk", 6))
		return 0;
	if (strncmp(n, "sd", 2) || !(*p >= 'a' && *p <= 'z'))
		return 0;
	while (*p >= 'a' && *p <= 'z')
		p++;
	if (!(*p >= '0' && *p <= '9'))
		return 0;
	while (*p >= '0' && *p <= '9')
		p++;
	return *p == 0;
}

/* find /sys/class/block/<x> with PARTNAME=<part>; exactly one; fills devname + dev_t */
static int find_part(const char *part, char *devname, size_t dnlen, dev_t *dev)
{
	char path[512], line[256], dn[64];
	unsigned maj, min;
	struct dirent *de;
	int found = 0;
	DIR *d;
	FILE *f;

	d = opendir("/sys/class/block");
	if (!d)
		return -1;
	while ((de = readdir(d))) {
		int match = 0, hm = 0, hn = 0;

		if (de->d_name[0] == '.')
			continue;
		if (!ufs_part_name(de->d_name)) {
			if (!strncmp(de->d_name, "mmcblk", 6))
				fprintf(stderr, "efsdump: %s: microSD/eMMC device, never used: skipped\n", de->d_name);
			continue;
		}
		snprintf(path, sizeof(path), "/sys/class/block/%s/uevent", de->d_name);
		f = fopen(path, "re");
		if (!f)
			continue;
		dn[0] = 0;
		while (fgets(line, sizeof(line), f)) {
			line[strcspn(line, "\n")] = 0;
			if (!strncmp(line, "PARTNAME=", 9) && !strcmp(line + 9, part))
				match = 1;
			else if (!strncmp(line, "DEVNAME=", 8))
				snprintf(dn, sizeof(dn), "%s", line + 8);
			else if (!strncmp(line, "MAJOR=", 6))
				hm = sscanf(line + 6, "%u", &maj) == 1;
			else if (!strncmp(line, "MINOR=", 6))
				hn = sscanf(line + 6, "%u", &min) == 1;
		}
		fclose(f);
		if (!match)
			continue;
		if (!dn[0] || !hm || !hn || strchr(dn, '/') || !ufs_part_name(dn)) {
			fprintf(stderr, "efsdump: %s: incomplete uevent for %s\n", part, de->d_name);
			closedir(d);
			return -1;
		}
		found++;
		snprintf(devname, dnlen, "%s", dn);
		*dev = makedev(maj, min);
	}
	closedir(d);
	if (found != 1) {
		fprintf(stderr, "efsdump: partition %s found %d times (need exactly 1): refusing\n", part, found);
		return -1;
	}
	return 0;
}

/* THE ONLY place a block device is opened: read-only, verified, kernel ro flag set */
static int open_blk_ro(const char *part, char *node, size_t nlen, uint64_t *size)
{
	char devname[64];
	struct stat st;
	int one = 1, ro = 0;
	dev_t dev;
	int fd;

	if (find_part(part, devname, sizeof(devname), &dev))
		return -1;
	snprintf(node, nlen, "/dev/%s", devname);
	if (!ufs_part_name(devname) || strstr(node, "mmcblk")) {	/* belt and braces: find_part already refused */
		fprintf(stderr, "efsdump: %s is not a UFS partition (sdXN): refusing\n", node);
		return -1;
	}
	fd = open(node, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) {
		fprintf(stderr, "efsdump: open %s (O_RDONLY): %s\n", node, strerror(errno));
		return -1;
	}
	if (fstat(fd, &st) || !S_ISBLK(st.st_mode) || st.st_rdev != dev) {
		fprintf(stderr, "efsdump: %s is not the block device %u:%u of %s: refusing\n",
			node, major(dev), minor(dev), part);
		close(fd);
		return -1;
	}
	if (ioctl(fd, BLKROSET, &one) || ioctl(fd, BLKROGET, &ro) || ro != 1) {
		fprintf(stderr, "efsdump: %s: cannot set the kernel read-only flag (%s): refusing\n",
			node, strerror(errno));
		close(fd);
		return -1;
	}
	if (ioctl(fd, BLKGETSIZE64, size) || *size == 0 || *size > MAX_PART) {
		fprintf(stderr, "efsdump: %s: size %llu out of range: refusing\n", node,
			(unsigned long long)*size);
		close(fd);
		return -1;
	}
	return fd;
}

static unsigned char *read_all(int fd, size_t len)
{
	unsigned char *buf = malloc(len);
	size_t got = 0;
	ssize_t n;

	if (!buf)
		return NULL;
	while (got < len) {
		n = pread(fd, buf + got, len - got, got);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			free(buf);
			return NULL;
		}
		got += n;
	}
	return buf;
}

static int open_dir_ram(const char *dir)
{
	int dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);

	if (dfd < 0) {
		fprintf(stderr, "efsdump: %s: %s\n", dir, strerror(errno));
		return -1;
	}
	if (!on_ram_fs(dfd)) {
		fprintf(stderr, "efsdump: %s is not on tmpfs/ramfs: refusing\n", dir);
		close(dfd);
		return -1;
	}
	return dfd;
}

static int do_copy(const char *dir)
{
	int dfd = open_dir_ram(dir), rc = 0;
	unsigned i;

	if (dfd < 0)
		return 1;
	for (i = 0; i < sizeof(efs) / sizeof(efs[0]); i++) {
		char node[96];
		uint64_t size;
		unsigned char *buf;
		size_t off = 0;
		ssize_t n;
		int bfd, ofd;

		bfd = open_blk_ro(efs[i].part, node, sizeof(node), &size);
		if (bfd < 0)
			return 1;
		buf = read_all(bfd, size);
		close(bfd);
		if (!buf) {
			fprintf(stderr, "efsdump: read %s failed\n", node);
			return 1;
		}
		ofd = openat(dfd, efs[i].file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
		if (ofd < 0) {
			fprintf(stderr, "efsdump: create %s/%s (must not exist): %s\n", dir, efs[i].file,
				strerror(errno));
			free(buf);
			return 1;
		}
		while (off < size) {
			n = write(ofd, buf + off, size - off);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0) {
				fprintf(stderr, "efsdump: write %s/%s: %s\n", dir, efs[i].file, strerror(errno));
				rc = 1;
				break;
			}
			off += n;
		}
		close(ofd);
		printf("efsdump: %-8s %s (kernel ro) %llu bytes fnv64=%016llx -> %s/%s\n", efs[i].part, node,
		       (unsigned long long)size, (unsigned long long)fnv64(buf, size), dir, efs[i].file);
		free(buf);
		if (rc)
			return rc;
	}
	close(dfd);
	printf("efsdump: copy done: 4 of 4 partitions in RAM, partitions opened O_RDONLY only\n");
	return 0;
}

static int do_verify(const char *dir)
{
	int dfd = open_dir_ram(dir), bad = 0;
	unsigned i;

	if (dfd < 0)
		return 1;
	for (i = 0; i < sizeof(efs) / sizeof(efs[0]); i++) {
		char node[96];
		uint64_t size;
		unsigned char *a, *b;
		struct stat st;
		int bfd, cfd;

		bfd = open_blk_ro(efs[i].part, node, sizeof(node), &size);
		if (bfd < 0)
			return 1;
		a = read_all(bfd, size);
		close(bfd);
		cfd = openat(dfd, efs[i].file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
		if (!a || cfd < 0 || fstat(cfd, &st) || !S_ISREG(st.st_mode) || (uint64_t)st.st_size != size) {
			fprintf(stderr, "efsdump: verify %s: cannot compare with %s/%s\n", node, dir, efs[i].file);
			return 1;
		}
		b = read_all(cfd, size);
		close(cfd);
		if (!b)
			return 1;
		printf("efsdump: verify %-8s partition fnv64=%016llx copy fnv64=%016llx %s\n", efs[i].part,
		       (unsigned long long)fnv64(a, size), (unsigned long long)fnv64(b, size),
		       memcmp(a, b, size) ? "DIFFERENT" : "identical");
		bad += !!memcmp(a, b, size);
		free(a);
		free(b);
	}
	close(dfd);
	printf("efsdump: verify done: %s\n", bad ? "PARTITION AND COPY DIFFER" : "all 4 partitions unchanged");
	return bad ? 2 : 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 3 && !strcmp(argv[1], "copy"))
		return do_copy(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "verify"))
		return do_verify(argv[2]);
	fprintf(stderr, "usage: efsdump copy|verify <dir on tmpfs>\n");
	return 1;
}
