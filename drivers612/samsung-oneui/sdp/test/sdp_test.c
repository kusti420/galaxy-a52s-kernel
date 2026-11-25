// SPDX-License-Identifier: GPL-2.0-only
/*
 * sdp_test: userspace side of the SDP QEMU smoke test (static, musl). Plays system_server (uid 1000:
 * engine events on /dev/dek_evt, DEK requests on /dev/dek_req, log reader on /dev/dek_log) and the
 * public-key crypto daemon on netlink 29 (answers the kernel's ECDH shared-secret requests with a
 * fixed fake secret), plus the fs-handler listener on netlink 28.
 * Lines "SDT: ok ..." / "SDT: FAIL ..."; exit code = number of failures.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <linux/netlink.h>
#include <linux/audit.h>

/* include/sdp/dek_common.h, dek_ioctl.h, pub_crypto_emul.h, fs_handler.h of the 5.4 A52s kernel */
#define DEK_MAXLEN 400
#define KEK_MAXLEN (2048 / 4 + 4)
#define DH_MAXLEN 256
#define KEK_SS_LEN 32
typedef struct { unsigned int type, len; unsigned char buf[DEK_MAXLEN]; } dek_t;
typedef struct { unsigned int type, len; unsigned char buf[KEK_MAXLEN]; } kek_t;
typedef struct { unsigned int len; unsigned char buf[KEK_SS_LEN]; } __attribute__((packed)) ssk_t;
typedef struct { unsigned int type, len; unsigned char buf[DH_MAXLEN]; } __attribute__((packed)) dhk_t;
typedef struct { dhk_t dh; ssk_t ss; } __attribute__((packed)) ss_payload;
enum { DEK_TYPE_PLAIN = 0, DEK_TYPE_AES_ENC = 2, DEK_TYPE_ECDH256_ENC = 6, DEK_TYPE_DUMMY = 7 };
enum { KEK_TYPE_SYM = 10, KEK_TYPE_RSA_PUB, KEK_TYPE_RSA_PRIV, KEK_TYPE_DH_PUB, KEK_TYPE_DH_PRIV,
       KEK_TYPE_ECDH256_PUB, KEK_TYPE_ECDH256_PRIV };
typedef struct { int engine_id; dek_t dek; } dek_arg_generate_dek;
typedef struct { int engine_id; dek_t plain_dek; dek_t enc_dek; } dek_arg_crypt_dek;
typedef struct { int engine_id, kek_type, ret; } dek_arg_is_kek_avail;
typedef struct { int engine_id, user_id; kek_t SDPK_Rpub, SDPK_Dpub, SDPK_EDpub; } dek_arg_on_boot;
typedef struct { int engine_id, user_id; } dek_arg_ids;
typedef struct { int engine_id; kek_t SDPK_Rpri, SDPK_Dpri, SDPK_EDpri, SDPK_sym; } dek_arg_on_device_unlocked;
#define __DEKIOC 0x77
#define DEK_ON_BOOT            _IOW(__DEKIOC, 0, unsigned int)
#define DEK_GENERATE_DEK       _IOW(__DEKIOC, 1, unsigned int)
#define DEK_ENCRYPT_DEK        _IOW(__DEKIOC, 2, unsigned int)
#define DEK_DECRYPT_DEK        _IOR(__DEKIOC, 3, unsigned int)
#define DEK_ON_DEVICE_LOCKED   _IOW(__DEKIOC, 4, unsigned int)
#define DEK_ON_DEVICE_UNLOCKED _IOW(__DEKIOC, 5, unsigned int)
#define DEK_ON_USER_ADDED      _IOW(__DEKIOC, 6, unsigned int)
#define DEK_ON_USER_REMOVED    _IOW(__DEKIOC, 7, unsigned int)
#define DEK_ON_CHANGE_PASSWORD _IOW(__DEKIOC, 8, unsigned int)
#define DEK_DISK_CACHE_CLEANUP _IOW(__DEKIOC, 10, unsigned int)
#define DEK_IS_KEK_AVAIL       _IOW(__DEKIOC, 11, unsigned int)
#define NL_FS 28
#define NL_CRYPTO 29
#define NL_PID_SET 3001
#define NL_RESULT 3002
#define OP_ECDH_REQ_SS 16
typedef struct { unsigned int request_id; unsigned char opcode; dek_t in; kek_t key; } cipher_param_t;
typedef struct { unsigned int request_id; unsigned char opcode; short ret; dek_t dek; } crypto_result_t;
typedef struct { unsigned int request_id; unsigned char opcode; short ret; } fs_result_t;

#define ENGINE 105
#define USERID 150
static int fails;

static void res(int ok, const char *fmt, ...)
{
	va_list ap;

	printf("SDT: %s ", ok ? "ok  " : "FAIL");
	va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
	printf("\n");
	fflush(stdout);
	if (!ok)
		fails++;
}

static int nl_open(int proto)
{
	struct sockaddr_nl a = { .nl_family = AF_NETLINK };
	int s = socket(AF_NETLINK, SOCK_RAW, proto);

	if (s < 0)
		return -errno;
	a.nl_pid = getpid();
	if (bind(s, (struct sockaddr *)&a, sizeof(a)))
		return -errno;
	return s;
}

static int nl_send(int s, int type, const void *payload, int len)
{
	struct { struct nlmsghdr h; char d[1200]; } m;
	struct sockaddr_nl k = { .nl_family = AF_NETLINK };

	memset(&m, 0, sizeof(m));
	m.h.nlmsg_len = NLMSG_LENGTH(len);
	m.h.nlmsg_type = type;
	m.h.nlmsg_pid = getpid();
	memcpy(m.d, payload, len);
	return sendto(s, &m, m.h.nlmsg_len, 0, (struct sockaddr *)&k, sizeof(k)) < 0 ? -errno : 0;
}

static int nl_pid_set(int s)
{
	struct audit_status st;

	memset(&st, 0, sizeof(st));
	st.pid = getpid();
	return nl_send(s, NL_PID_SET, &st, sizeof(st));
}

/* the crypto daemon: every ECDH_REQ_SS gets the same 32-byte "shared secret" */
static void crypto_daemon(int ready_fd)
{
	static const unsigned char secret[KEK_SS_LEN] = "0123456789abcdef0123456789abcde";
	struct { struct nlmsghdr h; cipher_param_t p; char pad[64]; } m;
	crypto_result_t r;
	int s = nl_open(NL_CRYPTO), n;
	char c = s >= 0 && nl_pid_set(s) == 0 ? 'R' : 'E';

	prctl(PR_SET_PDEATHSIG, SIGKILL);

	write(ready_fd, &c, 1);
	for (;;) {
		n = recv(s, &m, sizeof(m), 0);
		if (n < (int)NLMSG_LENGTH(sizeof(m.p)))
			continue;
		memset(&r, 0, sizeof(r));
		r.request_id = m.p.request_id;
		r.opcode = m.p.opcode;
		if (m.p.opcode != OP_ECDH_REQ_SS) {
			r.ret = -1;
		} else if (m.p.in.type == DEK_TYPE_DUMMY) {	/* encrypt: new data key pair + secret */
			ss_payload sp;

			memset(&sp, 0, sizeof(sp));
			sp.dh.type = DEK_TYPE_ECDH256_ENC; sp.dh.len = 65; memset(sp.dh.buf, 0x44, 65);
			sp.ss.len = KEK_SS_LEN; memcpy(sp.ss.buf, secret, KEK_SS_LEN);
			r.dek.len = sizeof(sp); memcpy(r.dek.buf, &sp, sizeof(sp));
		} else {					/* decrypt: secret from DataK.pub + device key */
			ssk_t ss;

			ss.len = KEK_SS_LEN; memcpy(ss.buf, secret, KEK_SS_LEN);
			r.dek.len = sizeof(ss); memcpy(r.dek.buf, &ss, sizeof(ss));
		}
		nl_send(s, NL_RESULT, &r, sizeof(r));
	}
}

static void set_kek(kek_t *k, int type, int len, int fill)
{
	k->type = type; k->len = len; memset(k->buf, fill, len);
}

static int read_log(int fd, char *buf, int sz)
{
	struct pollfd p = { .fd = fd, .events = POLLIN };
	int n;

	(void)p;
	n = read(fd, buf, sz - 1);
	buf[n > 0 ? n : 0] = 0;
	return n;
}

int main(int argc, char **argv)
{
	static dek_arg_on_boot boot;
	static dek_arg_on_device_unlocked un;
	static dek_arg_generate_dek gen;
	static dek_arg_crypt_dek enc, dec;
	dek_arg_is_kek_avail av;
	dek_arg_ids ids = { ENGINE, USERID };
	char log[1100];
	int evt, req, lg, r, s28, pfd[2];
	pid_t d;
	char c = 0;

	if (argc > 1 && !strcmp(argv[1], "absent")) {
		r = socket(AF_NETLINK, SOCK_RAW, NL_FS);
		res(r < 0 && errno == EPROTONOSUPPORT, "no module: netlink 28 socket() = %d errno %d", r, errno);
		r = open("/dev/dek_evt", O_RDWR);
		res(r < 0 && errno == ENOENT, "no module: /dev/dek_evt open = %d errno %d", r, errno);
		return fails;
	}

	evt = open("/dev/dek_evt", O_RDWR); req = open("/dev/dek_req", O_RDWR); lg = open("/dev/dek_log", O_RDONLY);
	res(evt >= 0 && req >= 0 && lg >= 0, "open /dev/dek_evt %d /dev/dek_req %d /dev/dek_log %d", evt, req, lg);
	if (evt < 0 || req < 0 || lg < 0)
		return fails;
	r = read_log(lg, log, sizeof(log));
	res(r > 0 && strstr(log, "|0|Initialized"), "dek_log first record: %s", r > 0 ? strtok(log, "\n") : "(none)");

	r = ioctl(evt, DEK_ON_USER_ADDED, &boot);
	res(r < 0 && errno == EACCES, "dek_evt ioctl as uid 0 refused (r=%d errno %d, EACCES %d)", r, errno, EACCES);
	read_log(lg, log, sizeof(log));		/* "Access denied to evt device" */

	/* netlink listeners while still root-owned children: fs handler + crypto daemon */
	s28 = nl_open(NL_FS);
	res(s28 >= 0 && nl_pid_set(s28) == 0, "netlink 28 (SDP fs handler): socket + PID_SET (%d)", s28);
	{
		fs_result_t fr = { 12345, 10, 0 };

		res(nl_send(s28, NL_RESULT, &fr, sizeof(fr)) == 0, "netlink 28: RESULT for an unknown request accepted");
	}
	if (pipe(pfd))
		return 99;
	d = fork();
	if (d == 0)
		crypto_daemon(pfd[1]);
	read(pfd[0], &c, 1);
	res(c == 'R', "netlink 29 (pub crypto): daemon socket + PID_SET");

	/* the driver looks at the real uid: 1000 for events, an app of the engine's user for DEK requests */
#define AS_SYS() setresuid(1000, 0, 0)
#define AS_APP() setresuid(USERID * 100000 + 10001, 0, 0)
	res(AS_SYS() == 0, "real uid 1000 (system)");

	/* new engine with its public keys */
	boot.engine_id = ENGINE; boot.user_id = USERID;
	set_kek(&boot.SDPK_Rpub, KEK_TYPE_RSA_PUB, 64, 0x11);
	set_kek(&boot.SDPK_Dpub, KEK_TYPE_DH_PUB, 64, 0x22);
	set_kek(&boot.SDPK_EDpub, KEK_TYPE_ECDH256_PUB, 65, 0x33);
	r = ioctl(evt, DEK_ON_USER_ADDED, &boot);
	res(r == 0, "DEK_ON_USER_ADDED engine %d user %d (r=%d errno %d)", ENGINE, USERID, r, r ? errno : 0);
	r = read_log(lg, log, sizeof(log));
	res(r > 0 && strstr(log, "|105|Added user"), "dek_log: %s", r > 0 ? strtok(log, "\n") : "(none)");
	r = ioctl(evt, DEK_ON_BOOT, &boot);
	res(r == 0, "DEK_ON_BOOT for an existing engine (r=%d)", r);
	read_log(lg, log, sizeof(log));

	gen.engine_id = ENGINE;
	enc.engine_id = ENGINE; enc.plain_dek.type = DEK_TYPE_PLAIN; enc.plain_dek.len = 32;
	r = ioctl(req, DEK_ENCRYPT_DEK, &enc);
	res(r < 0 && errno == EACCES, "DEK_ENCRYPT_DEK from another Android user than the engine's -> EACCES (r=%d errno %d)", r, errno);
	AS_APP();

	av.engine_id = ENGINE; av.kek_type = KEK_TYPE_ECDH256_PUB; av.ret = -1;
	r = ioctl(req, DEK_IS_KEK_AVAIL, &av);
	res(r == 0 && av.ret == 1, "DEK_IS_KEK_AVAIL ECDH256_PUB = %d (r=%d)", av.ret, r);
	av.kek_type = KEK_TYPE_SYM; av.ret = -1;
	r = ioctl(req, DEK_IS_KEK_AVAIL, &av);
	res(r == 0 && av.ret == 0, "DEK_IS_KEK_AVAIL SYM while locked = %d (r=%d)", av.ret, r);

	gen.engine_id = ENGINE;
	r = ioctl(req, DEK_GENERATE_DEK, &gen);
	res(r == 0 && gen.dek.len == 32, "DEK_GENERATE_DEK len %u (r=%d)", gen.dek.len, r);

	/* locked: encrypt goes the public-key way (ECDH shared secret from the daemon, AES-GCM in the kernel) */
	enc.engine_id = ENGINE; enc.plain_dek = gen.dek; enc.plain_dek.type = DEK_TYPE_PLAIN;
	r = ioctl(req, DEK_ENCRYPT_DEK, &enc);
	res(r == 0 && enc.enc_dek.type == DEK_TYPE_ECDH256_ENC && enc.enc_dek.len == sizeof(dhk_t) + 12 + 32 + 16,
	    "locked: DEK_ENCRYPT_DEK -> type %u (ECDH256_ENC %d) len %u (r=%d errno %d)", enc.enc_dek.type,
	    DEK_TYPE_ECDH256_ENC, enc.enc_dek.len, r, r ? errno : 0);
	dec.engine_id = ENGINE; dec.enc_dek = enc.enc_dek;
	r = ioctl(req, DEK_DECRYPT_DEK, &dec);
	res(r < 0 && errno == EIO, "locked: DEK_DECRYPT_DEK refused (r=%d errno %d, EIO %d)", r, errno, EIO);

	/* unlock: private keys + symmetric master key arrive */
	AS_SYS();
	un.engine_id = ENGINE;
	set_kek(&un.SDPK_Rpri, KEK_TYPE_RSA_PRIV, 64, 0x55);
	set_kek(&un.SDPK_Dpri, KEK_TYPE_DH_PRIV, 64, 0x66);
	set_kek(&un.SDPK_EDpri, KEK_TYPE_ECDH256_PRIV, 32, 0x77);
	set_kek(&un.SDPK_sym, KEK_TYPE_SYM, 32, 0x88);
	r = ioctl(evt, DEK_ON_DEVICE_UNLOCKED, &un);
	res(r == 0, "DEK_ON_DEVICE_UNLOCKED (r=%d)", r);
	AS_APP();
	r = ioctl(req, DEK_DECRYPT_DEK, &dec);
	res(r == 0 && dec.plain_dek.len == 32 && !memcmp(dec.plain_dek.buf, gen.dek.buf, 32),
	    "unlocked: ECDH-wrapped DEK decrypts to the original (r=%d len %u)", r, dec.plain_dek.len);

	memset(&enc.enc_dek, 0, sizeof(enc.enc_dek));
	r = ioctl(req, DEK_ENCRYPT_DEK, &enc);
	res(r == 0 && enc.enc_dek.type == DEK_TYPE_AES_ENC && enc.enc_dek.len == 12 + 32 + 16,
	    "unlocked: DEK_ENCRYPT_DEK -> type %u (AES_ENC %d) len %u (r=%d)", enc.enc_dek.type, DEK_TYPE_AES_ENC,
	    enc.enc_dek.len, r);
	memset(&dec, 0, sizeof(dec));
	dec.engine_id = ENGINE; dec.enc_dek = enc.enc_dek;
	r = ioctl(req, DEK_DECRYPT_DEK, &dec);
	res(r == 0 && dec.plain_dek.len == 32 && !memcmp(dec.plain_dek.buf, gen.dek.buf, 32),
	    "unlocked: AES-GCM-wrapped DEK decrypts to the original (r=%d)", r);
	dec.enc_dek.buf[20] ^= 1;
	r = ioctl(req, DEK_DECRYPT_DEK, &dec);
	res(r < 0, "unlocked: a tampered blob is refused (r=%d errno %d)", r, errno);
	dec.enc_dek.buf[20] ^= 1;

	r = ioctl(evt, DEK_ON_DEVICE_LOCKED, &ids);
	res(r < 0 && errno == EACCES, "dek_evt ioctl from an app refused (r=%d errno %d)", r, errno);
	AS_SYS();
	r = ioctl(evt, DEK_ON_DEVICE_LOCKED, &ids);
	res(r == 0, "DEK_ON_DEVICE_LOCKED (r=%d)", r);
	AS_APP();
	r = ioctl(req, DEK_DECRYPT_DEK, &dec);
	res(r < 0 && errno == EIO, "locked again: AES-wrapped DEK refused (r=%d errno %d)", r, errno);

	AS_SYS();
	r = ioctl(evt, DEK_DISK_CACHE_CLEANUP, &ids);
	res(r == 0, "DEK_DISK_CACHE_CLEANUP accepted (r=%d)", r);
	r = ioctl(evt, DEK_ON_CHANGE_PASSWORD, &ids);
	res(r == 0, "DEK_ON_CHANGE_PASSWORD (deprecated) accepted (r=%d)", r);
	r = ioctl(evt, DEK_ON_USER_REMOVED, &ids);
	av.kek_type = KEK_TYPE_ECDH256_PUB; av.ret = -1;
	ioctl(req, DEK_IS_KEK_AVAIL, &av);
	res(r == 0 && av.ret == 0, "DEK_ON_USER_REMOVED, keys gone (r=%d avail %d)", r, av.ret);
	r = ioctl(evt, 0x12345678, &ids);
	res(r < 0 && errno == EINVAL, "unknown evt ioctl -> EINVAL (r=%d errno %d)", r, errno);

	setresuid(0, 0, 0);
	kill(d, SIGKILL);
	waitpid(d, NULL, 0);
	printf("SDT: END fails=%d\n", fails);
	return fails;
}
