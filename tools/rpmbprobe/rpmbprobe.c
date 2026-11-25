// SPDX-License-Identifier: GPL-2.0
// rpmbprobe: read-only UFS RPMB check over the RPMB well-known LU bsg node (as qseecomd's librpmb does).
// Sends only READ requests (write counter, data read); prints the response type, result code, write counter,
// block count. Never prints block data or MACs. Usage: rpmbprobe [/dev/0:0:0:49476] [nblocks]
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/bsg.h>
#include <scsi/sg.h>
#define FR 512
static int sgio(int fd, int out, unsigned char *buf, unsigned len) {
	unsigned char cdb[12] = { out ? 0xb5 : 0xa2, 0xec, 0x00, 0x01, 0, 0, len >> 24, len >> 16, len >> 8, len, 0, 0 };
	unsigned char sense[32] = { 0 };
	struct sg_io_v4 io; memset(&io, 0, sizeof(io));
	io.guard = 'Q'; io.protocol = BSG_PROTOCOL_SCSI; io.subprotocol = BSG_SUB_PROTOCOL_SCSI_CMD;
	io.request_len = sizeof(cdb); io.request = (unsigned long)cdb;
	io.max_response_len = sizeof(sense); io.response = (unsigned long)sense; io.timeout = 10000;
	if (out) { io.dout_xfer_len = len; io.dout_xferp = (unsigned long)buf; }
	else { io.din_xfer_len = len; io.din_xferp = (unsigned long)buf; }
	int r = ioctl(fd, SG_IO, &io);
	printf("  SG_IO %s len=%u -> ret=%d dev_status=0x%x transport=0x%x driver=0x%x info=0x%x resid=%d sense=%02x/%02x/%02x\n",
		out ? "OUT" : "IN ", len, r, io.device_status, io.transport_status, io.driver_status, io.info,
		out ? io.dout_resid : io.din_resid, sense[0], sense[2] & 0xf, sense[12]);
	return r;
}
static int sgio_q(int fd, int out, unsigned char *buf, unsigned len) {
	unsigned char cdb[12] = { out ? 0xb5 : 0xa2, 0xec, 0x00, 0x01, 0, 0, len >> 24, len >> 16, len >> 8, len, 0, 0 };
	unsigned char sense[32] = { 0 };
	struct sg_io_v4 io; memset(&io, 0, sizeof(io));
	io.guard = 'Q'; io.protocol = BSG_PROTOCOL_SCSI; io.subprotocol = BSG_SUB_PROTOCOL_SCSI_CMD;
	io.request_len = sizeof(cdb); io.request = (unsigned long)cdb;
	io.max_response_len = sizeof(sense); io.response = (unsigned long)sense; io.timeout = 10000;
	if (out) { io.dout_xfer_len = len; io.dout_xferp = (unsigned long)buf; } else { io.din_xfer_len = len; io.din_xferp = (unsigned long)buf; }
	int r = ioctl(fd, SG_IO, &io);
	return r || io.device_status || io.transport_status || io.driver_status;
}
static void show(const char *what, unsigned char *f, int n) {
	for (int i = 0; i < n; i++) {
		unsigned char *p = f + i * FR;
		unsigned long long h = 1469598103934665603ULL; for (int k = 0; k < FR; k++) { h ^= p[k]; h *= 1099511628211ULL; }
		unsigned long long hd = 1469598103934665603ULL; for (int k = 228; k < 484; k++) { hd ^= p[k]; hd *= 1099511628211ULL; }
		printf("  %s frame %d: data-fnv64=%016llx bytes500-503=%02x%02x%02x%02x\n", what, i, hd, p[500], p[501], p[502], p[503]);
		int nzm = 0, nzd = 0, nzn = 0; for (int k = 196; k < 228; k++) nzm += !!p[k]; for (int k = 228; k < 484; k++) nzd += !!p[k];
		for (int k = 484; k < 500; k++) nzn += !!p[k];
		printf("  %s frame %d: nonzero mac=%d/32 data=%d/256 nonce=%d/16 fnv64=%016llx resp=0x%04x result=0x%04x wcnt=%u addr=%u blocks=%u\n",
			what, i, nzm, nzd, nzn, h, p[510] << 8 | p[511], p[508] << 8 | p[509],
			(unsigned)p[500] << 24 | p[501] << 16 | p[502] << 8 | p[503], p[504] << 8 | p[505], p[506] << 8 | p[507]);
	}
}
/* scan mode: read-only sweep of the whole RPMB data area, one hash line per 256 blocks (data fields only) */
static int scan(int fd, int total, int step) {
	static unsigned char req[FR], rsp[FR * 64];
	unsigned long long all = 1469598103934665603ULL, h = 1469598103934665603ULL; int bad = 0, nz = 0;
	for (int a = 0; a < total; a += step) {
		memset(req, 0, FR); req[511] = 0x04; req[504] = a >> 8; req[505] = a; req[506] = step >> 8; req[507] = step;
		for (int i = 0; i < 16; i++) req[484 + i] = 0x3c ^ i;
		if (sgio_q(fd, 1, req, FR) || sgio_q(fd, 0, rsp, FR * step)) { printf("scan: SG_IO failed at %d\n", a); return 1; }
		for (int f = 0; f < step; f++) {
			unsigned char *p = rsp + f * FR; int res = p[508] << 8 | p[509];
			if (res) { bad++; if (bad < 4) printf("scan: addr %d frame %d result 0x%04x\n", a, f, res); }
			for (int k = 228; k < 484; k++) { h ^= p[k]; h *= 1099511628211ULL; all ^= p[k]; all *= 1099511628211ULL; nz += !!p[k]; }
			if (p[500] | p[501] | p[502] | p[503]) nz += 0;
		}
		if ((a + step) % 256 == 0) { printf("scan: blocks %5d-%5d fnv64=%016llx\n", a + step - 256, a + step - 1, h); h = 1469598103934665603ULL; }
	}
	printf("scan: total %d blocks, bad results %d, nonzero data bytes %d, all-fnv64=%016llx\n", total, bad, nz, all);
	return 0;
}
int main(int c, char **v) {
	const char *dev = c > 1 ? v[1] : "/dev/0:0:0:49476"; int nb = c > 2 ? atoi(v[2]) : 2;
	int fd = open(dev, O_RDWR | O_SYNC); if (fd < 0) { perror(dev); return 1; }
	if (c > 3 && !strcmp(v[3], "scan")) return scan(fd, c > 4 ? atoi(v[4]) : 16384, nb);
	static unsigned char req[FR], rsp[FR * 8];
	printf("read write counter:\n");
	memset(req, 0, FR); req[511] = 0x02; for (int i = 0; i < 16; i++) req[484 + i] = 0x5a ^ i;
	sgio(fd, 1, req, FR); memset(rsp, 0, sizeof(rsp)); sgio(fd, 0, rsp, FR); show("counter", rsp, 1);
	printf("read %d block(s) at 0:\n", nb);
	memset(req, 0, FR); req[511] = 0x04; req[506] = nb >> 8; req[507] = nb; for (int i = 0; i < 16; i++) req[484 + i] = 0xa5 ^ i;
	sgio(fd, 1, req, FR); memset(rsp, 0, sizeof(rsp)); sgio(fd, 0, rsp, FR * nb); show("read", rsp, nb);
	close(fd); return 0;
}
