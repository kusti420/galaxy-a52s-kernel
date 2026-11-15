// SPDX-License-Identifier: GPL-2.0-only
/*
 * qseetest - first on-device check of the TrustZone-facing nodes, talking to them exactly as
 * the 5.4 vendor blobs do: raw ioctl numbers and structures of the phone's 5.4 UAPI, typed
 * out here so the test does not depend on any kernel header generation.
 * Static, kernel nolibc; built for arm64 and for 32-bit arm (the compat path of every node).
 *
 *   ./qseetest [-a <ta name>]...
 *
 *   1. /dev/qseecom: QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ -> prints the QSEE version
 *      (the 5.4 kernel on this phone reports it in dmesg as "qseecom.qsee_version = 0x...").
 *   2. the three ioctls the 6.12 driver dropped (PERF_ENABLE, PERF_DISABLE on a fresh handle
 *      must behave as on 5.4: enable = 0, disable = -EINVAL for a GENERIC handle).
 *   3. QSEECOM_IOCTL_APP_LOADED_QUERY_REQ for each -a name (read-only: asks QSEE whether a
 *      trusted app is loaded; nothing is loaded or unloaded by this test).
 *   4. /dev/smcinvoke: open, then SMCINVOKE_IOCTL_INVOKE_REQ in the 5.4 layout with a wrong
 *      argsize: the driver must answer -EINVAL (legacy number recognised), not -ENOTTY.
 *   5. /dev/qce: open only.
 * Exit status: number of failed checks.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* include/uapi/linux/qseecom.h (5.4), magic 0x97 */
struct qseecom_qseos_version_req {
	unsigned int qseos_version;
};

struct qseecom_qseos_app_load_query {
	char app_name[64];
	__u32 app_id;
	__u32 app_arch;
};

#define QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ	_IOWR(0x97, 10, struct qseecom_qseos_version_req)
#define QSEECOM_IOCTL_PERF_ENABLE_REQ		_IO(0x97, 11)
#define QSEECOM_IOCTL_PERF_DISABLE_REQ		_IO(0x97, 12)
#define QSEECOM_IOCTL_APP_LOADED_QUERY_REQ	_IOWR(0x97, 15, struct qseecom_qseos_app_load_query)

/* include/uapi/linux/smcinvoke.h (5.4), magic 0x98 */
struct smcinvoke_cmd_req_54 {
	__u32 op;
	__u32 counts;
	__s32 result;
	__u32 argsize;
	__u64 args;
};
#define SMCINVOKE_IOCTL_INVOKE_REQ_54		_IOWR(0x98, 1, struct smcinvoke_cmd_req_54)

_Static_assert(QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ == 0xc004970a, "abi");
_Static_assert(QSEECOM_IOCTL_APP_LOADED_QUERY_REQ == 0xc048970f, "abi");
_Static_assert(SMCINVOKE_IOCTL_INVOKE_REQ_54 == 0xc0189801, "abi");

static int failed;

static void result(int ok, const char *what)
{
	if (!ok)
		failed++;
	printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
}

int main(int argc, char **argv)
{
	struct qseecom_qseos_version_req ver = { 0 };
	struct smcinvoke_cmd_req_54 inv;
	int fd, ret, i, e;

	printf("qseetest: %d-bit caller\n", (int)(sizeof(void *) * 8));

	fd = open("/dev/qseecom", O_RDWR);
	if (fd < 0) {
		printf("FAIL  open /dev/qseecom: errno %d%s\n", errno,
		       errno == ENXIO ? " (driver not READY: qseecom probe did not finish)" : "");
		failed++;
	} else {
		result(1, "open /dev/qseecom");

		ret = ioctl(fd, QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ, &ver);
		e = errno;
		printf("      GET_QSEOS_VERSION ret %d errno %d: QSEE version 0x%x (%u.%u.%u)\n",
		       ret, ret ? e : 0, ver.qseos_version, (ver.qseos_version >> 22) & 0x3ff,
		       (ver.qseos_version >> 12) & 0x3ff, ver.qseos_version & 0xfff);
		result(ret == 0 && ver.qseos_version != 0, "QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ");

		ret = ioctl(fd, QSEECOM_IOCTL_PERF_ENABLE_REQ, 0);
		e = errno;
		printf("      PERF_ENABLE ret %d errno %d\n", ret, ret ? e : 0);
		result(ret == 0, "QSEECOM_IOCTL_PERF_ENABLE_REQ (5.4 ioctl kept, no-op)");

		ret = ioctl(fd, QSEECOM_IOCTL_PERF_DISABLE_REQ, 0);
		e = errno;
		printf("      PERF_DISABLE ret %d errno %d\n", ret, ret ? e : 0);
		result(ret < 0 && e == EINVAL,
		       "QSEECOM_IOCTL_PERF_DISABLE_REQ on a GENERIC handle is -EINVAL as on 5.4");

		for (i = 1; i + 1 < argc; i += 2) {
			struct qseecom_qseos_app_load_query q;

			if (strcmp(argv[i], "-a"))
				break;
			memset(&q, 0, sizeof(q));
			strncpy(q.app_name, argv[i + 1], sizeof(q.app_name) - 1);
			ret = ioctl(fd, QSEECOM_IOCTL_APP_LOADED_QUERY_REQ, &q);
			e = errno;
			/* 5.4 and 6.12: -EEXIST = loaded (app_id filled in), 0 = not loaded */
			printf("      APP_LOADED_QUERY %s: ret %d errno %d app_id %u arch %u => %s\n",
			       q.app_name, ret, ret ? e : 0, q.app_id, q.app_arch,
			       ret < 0 && e == EEXIST ? "loaded" : ret == 0 ? "not loaded" : "error");
			result(ret == 0 || e == EEXIST, "QSEECOM_IOCTL_APP_LOADED_QUERY_REQ");
		}
		close(fd);
	}

	fd = open("/dev/smcinvoke", O_RDWR);
	if (fd < 0) {
		printf("FAIL  open /dev/smcinvoke: errno %d\n", errno);
		failed++;
	} else {
		result(1, "open /dev/smcinvoke");
		memset(&inv, 0, sizeof(inv));
		inv.argsize = 1;	/* invalid on purpose: must be refused before any SMC */
		ret = ioctl(fd, SMCINVOKE_IOCTL_INVOKE_REQ_54, &inv);
		e = errno;
		printf("      INVOKE_REQ (5.4 layout, bad argsize) ret %d errno %d\n", ret, ret ? e : 0);
		result(ret < 0 && e == EINVAL, "5.4 SMCINVOKE_IOCTL_INVOKE_REQ number is recognised");
		close(fd);
	}

	fd = open("/dev/qce", O_RDWR);
	if (fd < 0) {
		printf("FAIL  open /dev/qce: errno %d\n", errno);
		failed++;
	} else {
		result(1, "open /dev/qce");
		close(fd);
	}

	printf("qseetest: %d failed\n", failed);
	return failed;
}
