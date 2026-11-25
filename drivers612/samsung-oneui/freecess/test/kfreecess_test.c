// SPDX-License-Identifier: GPL-2.0-only
/*
 * kfreecess_test: userspace side of the freecess QEMU smoke test (static, musl). Plays the framework:
 * NETLINK_KFREECESS hello for every mod, then provokes each kernel report and checks the message.
 * Expects (set up by the test init): cgroup2 at /cg2 with a child "t", the v1 freezer at /dev/freezer
 * with a child "frozen" in state FROZEN, binderfs at /dev/binderfs, lo up.
 * Lines "KFT: ok ..." / "KFT: FAIL ..."; exit code = number of failures.
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
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <linux/netlink.h>
#include <linux/android/binder.h>

#define NETLINK_KFREECESS 27
#define KERNEL_ID_NETLINK 0x12341234
enum { LOOPBACK_MSG = 1, MSG_TO_KERN, MSG_TO_USER };
enum { MOD_BINDER = 1, MOD_SIG, MOD_PKG, MOD_CFB };
struct kfreecess_msg_data {
	int type, mod, src_portid, dst_portid;
	unsigned int version;
	int target_uid, flag, code;
	char rpcname[100];
	struct { int cmd; unsigned int uid; } pkg_info;
};
#define APP_UID 10123

static int nl, port, fails;

static void res(int ok, const char *fmt, ...)
{
	va_list ap;

	printf("KFT: %s ", ok ? "ok  " : "FAIL");
	va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
	printf("\n");
	fflush(stdout);
	if (!ok)
		fails++;
}

static int nl_send(int type, int mod, unsigned int version, int target_uid, int cmd, unsigned int uid)
{
	struct { struct nlmsghdr h; struct kfreecess_msg_data d; } m;
	struct sockaddr_nl k = { .nl_family = AF_NETLINK };

	memset(&m, 0, sizeof(m));
	m.h.nlmsg_len = NLMSG_LENGTH(sizeof(m.d));
	m.h.nlmsg_pid = port;
	m.d.type = type; m.d.mod = mod; m.d.src_portid = port; m.d.dst_portid = KERNEL_ID_NETLINK;
	m.d.version = version; m.d.target_uid = target_uid; m.d.pkg_info.cmd = cmd; m.d.pkg_info.uid = uid;
	return sendto(nl, &m, m.h.nlmsg_len, 0, (struct sockaddr *)&k, sizeof(k)) < 0 ? -errno : 0;
}

static int nl_recv(struct kfreecess_msg_data *d, int timeout_ms)
{
	struct { struct nlmsghdr h; struct kfreecess_msg_data d; char pad[64]; } m;
	struct pollfd p = { .fd = nl, .events = POLLIN };
	int n;

	if (poll(&p, 1, timeout_ms) <= 0)
		return 0;
	n = recv(nl, &m, sizeof(m), 0);
	if (n < (int)NLMSG_LENGTH(sizeof(m.d)))
		return -1;
	*d = m.d;
	return 1;
}

static void drain(void)
{
	struct kfreecess_msg_data d;

	while (nl_recv(&d, 50) > 0)
		printf("KFT: note drained type %d mod %d uid %d\n", d.type, d.mod, d.target_uid);
}

static int wr(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY), r;

	if (fd < 0)
		return -errno;
	r = write(fd, val, strlen(val)) < 0 ? -errno : 0;
	close(fd);
	return r;
}

static int wr_pid(const char *path, int pid)
{
	char b[16];

	snprintf(b, sizeof(b), "%d", pid);
	return wr(path, b);
}

static void hello(unsigned int version, int want_kver)
{
	struct kfreecess_msg_data d;
	int mod, r;

	for (mod = MOD_BINDER; mod <= MOD_CFB; mod++) {
		r = nl_send(LOOPBACK_MSG, mod, version, 0, 0, 0);
		r = r ? r : nl_recv(&d, 1000);
		res(r == 1 && d.type == LOOPBACK_MSG && d.mod == mod && d.src_portid == KERNEL_ID_NETLINK &&
		    d.dst_portid == port && (int)(d.version >> 28) == want_kver,
		    "hello mod %d word %#x: r=%d type %d mod %d src %#x dst %d kernel version %u (want %d)",
		    mod, version, r, d.type, d.mod, d.src_portid, d.dst_portid, d.version >> 28, want_kver);
	}
}

static pid_t app_child(void)
{
	pid_t p = fork();

	if (p == 0) {
		if (setresgid(APP_UID, APP_UID, APP_UID) || setresuid(APP_UID, APP_UID, APP_UID))
			_exit(9);
		for (;;)
			pause();
	}
	return p;
}

static void sig_test(const char *name, const char *freeze_procs, const char *thaw_procs, int v1)
{
	struct kfreecess_msg_data d;
	pid_t c = app_child();
	int r, st, alive;

	usleep(100000);
	r = wr_pid(freeze_procs, c);
	usleep(300000);
	kill(c, SIGKILL);
	r = r ? r : nl_recv(&d, 1000);
	res(r == 1 && d.type == MSG_TO_USER && d.mod == MOD_SIG && d.target_uid == APP_UID && d.flag == c,
	    "%s: SIGKILL to a frozen uid %d pid %d -> MOD_SIG r=%d uid %d flag(pid) %d", name, APP_UID, c, r,
	    d.target_uid, d.flag);
	usleep(300000);
	alive = waitpid(c, &st, WNOHANG) == 0;
	if (v1)
		res(alive, "%s: v1-frozen task survives SIGKILL until thawed (alive=%d)", name, alive);
	else
		res(!alive, "%s: v2-frozen task dies from SIGKILL at once (alive=%d)", name, alive);
	if (alive) {
		wr_pid(thaw_procs, c);
		usleep(300000);
		res(waitpid(c, &st, WNOHANG) == c, "%s: dies after the thaw", name);
	}
	/* a second fatal signal for the same pid must not be reported twice (last_kill_pid) */
	drain();
}

/* ---- binder ---- */
static int binder_open(void)
{
	int fd = open("/dev/binderfs/binder", O_RDWR | O_CLOEXEC);

	if (fd < 0)
		return -errno;
	if (mmap(NULL, 1 << 20, PROT_READ, MAP_PRIVATE, fd, 0) == MAP_FAILED)
		return -errno;
	return fd;
}

static pid_t binder_server(void)
{
	int pfd[2];
	char ok = 0;
	pid_t p;

	if (pipe(pfd))
		return -1;
	p = fork();
	if (p == 0) {
		int fd;

		close(pfd[0]);
		fd = binder_open();	/* binderfs nodes are 0600 root here; the kernel reads the task's live euid */
		if (setresgid(APP_UID, APP_UID, APP_UID) || setresuid(APP_UID, APP_UID, APP_UID))
			_exit(9);
		if (fd >= 0 && ioctl(fd, BINDER_SET_CONTEXT_MGR, 0) == 0)
			ok = 1;
		else
			printf("KFT: note binder server: fd %d errno %d\n", fd, errno);
		write(pfd[1], &ok, 1);
		for (;;)
			pause();	/* never reads: transactions stay queued */
	}
	close(pfd[1]);
	read(pfd[0], &ok, 1);
	close(pfd[0]);
	return ok ? p : -1;
}

/* forked sender: one transaction to the context manager; a sync one blocks until killed */
static pid_t binder_client(int oneway, unsigned int code, const char *token)
{
	pid_t p = fork();

	if (p == 0) {
		struct { __u32 cmd; struct binder_transaction_data tr; } __attribute__((packed)) w;
		struct binder_write_read bwr;
		unsigned char parcel[256];
		size_t i, len = strlen(token);
		int fd = binder_open();

		memset(parcel, 0, sizeof(parcel));
		/* writeInterfaceToken (R+): strict mode, work source, header 'SYST', string length */
		parcel[8] = 'S'; parcel[9] = 'Y'; parcel[10] = 'S'; parcel[11] = 'T';
		parcel[12] = len;
		for (i = 0; i < len; i++)
			parcel[16 + 2 * i] = token[i];
		memset(&w, 0, sizeof(w));
		w.cmd = BC_TRANSACTION;
		w.tr.target.handle = 0;
		w.tr.code = code;
		w.tr.flags = oneway ? TF_ONE_WAY : 0;
		w.tr.data_size = 16 + 2 * len + 4;
		w.tr.data.ptr.buffer = (binder_uintptr_t)(unsigned long)parcel;
		memset(&bwr, 0, sizeof(bwr));
		bwr.write_size = sizeof(w);
		bwr.write_buffer = (binder_uintptr_t)(unsigned long)&w;
		if (fd < 0 || ioctl(fd, BINDER_WRITE_READ, &bwr) < 0)
			printf("KFT: note binder client: fd %d errno %d\n", fd, errno);
		if (!oneway) {		/* wait for a reply that never comes */
			char rb[256];

			memset(&bwr, 0, sizeof(bwr));
			bwr.read_size = sizeof(rb);
			bwr.read_buffer = (binder_uintptr_t)(unsigned long)rb;
			for (;;) {
				ioctl(fd, BINDER_WRITE_READ, &bwr);
				bwr.read_consumed = 0;
				pause();
			}
		}
		_exit(0);
	}
	return p;
}

static void binder_test(const char *name, const char *freeze_procs, const char *thaw_procs)
{
	struct kfreecess_msg_data d;
	pid_t s = binder_server(), c1, c2;
	int r;

	res(s > 0, "%s: binder server (context manager, uid %d) pid %d", name, APP_UID, s);
	if (s <= 0)
		return;
	/* not frozen: a transaction must not be reported */
	c1 = binder_client(1, 3, "android.test.INotFrozen");
	r = nl_recv(&d, 400);
	res(r == 0, "%s: oneway to a running uid is not reported (r=%d)", name, r);
	waitpid(c1, NULL, 0);

	r = wr_pid(freeze_procs, s);
	usleep(300000);
	c1 = binder_client(1, 7, "android.test.IFreecess");
	r = r ? r : nl_recv(&d, 1000);
	d.rpcname[99] = 0;
	res(r == 1 && d.type == MSG_TO_USER && d.mod == MOD_BINDER && d.target_uid == APP_UID && d.code == 7 &&
	    d.flag == TF_ONE_WAY && !strcmp(d.rpcname, "android.test.IFreecess") && d.pkg_info.cmd == s &&
	    (int)d.version == c1,
	    "%s: oneway to frozen uid -> MOD_BINDER r=%d uid %d code %d flag %d rpcname '%s' target pid %d caller_pid %u (sender %d)",
	    name, r, d.target_uid, d.code, d.flag, d.rpcname, d.pkg_info.cmd, d.version, c1);
	waitpid(c1, NULL, 0);

	r = nl_send(MSG_TO_KERN, MOD_CFB, 0, APP_UID, 0, 0);
	r = r ? r : nl_recv(&d, 400);
	res(r == 0, "%s: CFB with only a oneway queued -> no report (r=%d)", name, r);

	c2 = binder_client(0, 9, "android.test.ISync");
	r = nl_recv(&d, 1000);
	d.rpcname[99] = 0;
	res(r == 1 && d.mod == MOD_BINDER && d.target_uid == APP_UID && d.code == 0 && d.flag == 0 &&
	    !strcmp(d.rpcname, "sync_binder") && d.pkg_info.cmd == s,
	    "%s: sync call to frozen uid -> MOD_BINDER r=%d uid %d code %d flag %d rpcname '%s'", name, r,
	    d.target_uid, d.code, d.flag, d.rpcname);
	usleep(100000);

	r = nl_send(MSG_TO_KERN, MOD_CFB, 0, APP_UID, 0, 0);
	r = r ? r : nl_recv(&d, 1000);
	res(r == 1 && d.type == MSG_TO_USER && d.mod == MOD_CFB && d.target_uid == APP_UID,
	    "%s: CFB with a sync call queued -> MOD_CFB r=%d uid %d", name, r, d.target_uid);
	r = nl_send(MSG_TO_KERN, MOD_CFB, 0, APP_UID + 1, 0, 0);
	r = r ? r : nl_recv(&d, 400);
	res(r == 0, "%s: CFB for another uid -> no report (r=%d)", name, r);

	kill(c2, SIGKILL);
	waitpid(c2, NULL, 0);
	wr_pid(thaw_procs, s);
	usleep(100000);
	kill(s, SIGKILL);
	waitpid(s, NULL, 0);
	drain();
}

/*
 * ---- MOD_PKG: TCP data for a recorded uid ----
 * The hook sees the socket only when early demux has set skb->sk, which never happens on lo (the skb
 * keeps its dst). So: a veth pair, the far end in its own netns with a client; the server (uid APP_UID)
 * listens in the init netns. The data segments of the established connection carry the socket.
 */
#include <sched.h>
#include <linux/rtnetlink.h>
#include <linux/if_link.h>
#include <linux/veth.h>
static int pkg_go[2], pkg_done[2];
static pid_t pkg_peer, pkg_srv;

static void *nla(void *buf, int *len, int type, const void *data, int dlen)
{
	struct rtattr *a = (struct rtattr *)((char *)buf + *len);

	a->rta_type = type;
	a->rta_len = RTA_LENGTH(dlen);
	if (dlen)
		memcpy(RTA_DATA(a), data, dlen);
	*len += RTA_ALIGN(a->rta_len);
	return a;
}

static int veth_add(pid_t peer_ns)
{
	struct { struct nlmsghdr h; struct ifinfomsg i; char b[256]; } m;
	struct sockaddr_nl k = { .nl_family = AF_NETLINK };
	struct ifinfomsg pi = { 0 };
	struct rtattr *li, *da, *pe;
	char ack[256];
	int len, s = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE), n;
	__u32 pid = peer_ns;

	memset(&m, 0, sizeof(m));
	m.h.nlmsg_type = RTM_NEWLINK;
	m.h.nlmsg_flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL | NLM_F_ACK;
	len = NLMSG_LENGTH(sizeof(m.i));
	nla(&m, &len, IFLA_IFNAME, "v0", 3);
	li = nla(&m, &len, IFLA_LINKINFO, NULL, 0);
	nla(&m, &len, IFLA_INFO_KIND, "veth", 4);
	da = nla(&m, &len, IFLA_INFO_DATA, NULL, 0);
	pe = nla(&m, &len, VETH_INFO_PEER, &pi, sizeof(pi));
	nla(&m, &len, IFLA_IFNAME, "v1", 3);
	nla(&m, &len, IFLA_NET_NS_PID, &pid, 4);
	pe->rta_len = (char *)&m + len - (char *)pe;
	da->rta_len = (char *)&m + len - (char *)da;
	li->rta_len = (char *)&m + len - (char *)li;
	m.h.nlmsg_len = len;
	if (sendto(s, &m, len, 0, (struct sockaddr *)&k, sizeof(k)) < 0)
		return -errno;
	n = recv(s, ack, sizeof(ack), 0);
	close(s);
	if (n < (int)NLMSG_LENGTH(sizeof(struct nlmsgerr)))
		return -EIO;
	return ((struct nlmsgerr *)NLMSG_DATA((struct nlmsghdr *)ack))->error;
}

static int ifup(const char *dev, const char *ip)	/* no /bin/sh in the test ramdisk: no system() */
{
	pid_t p = fork();
	int st = -1;

	if (p == 0) {
		setresuid(0, 0, 0);	/* busybox drops privileges when ruid != euid */
		execl("/bin/busybox", "ifconfig", dev, ip, "netmask", "255.255.255.0", "up", (char *)NULL);
		_exit(127);
	}
	waitpid(p, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int pkg_setup(void)
{
	char c = 0;
	int r;

	if (pipe(pkg_go) || pipe(pkg_done))
		return -1000;
	pkg_srv = fork();
	if (pkg_srv == 0) {
		struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(5555) };
		int one = 1, l = socket(AF_INET, SOCK_STREAM, 0), s;
		char b[8];

		if (setresgid(APP_UID, APP_UID, APP_UID) || setresuid(APP_UID, APP_UID, APP_UID))
			_exit(9);
		setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		if (bind(l, (struct sockaddr *)&a, sizeof(a)) || listen(l, 4))
			_exit(8);
		for (;;) {
			s = accept(l, NULL, NULL);
			if (s < 0)
				continue;
			if (read(s, b, 4) == 4)
				write(s, "pong", 4);
			close(s);
		}
	}
	pkg_peer = fork();
	if (pkg_peer == 0) {
		struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(5555) };
		int up = 0;

		inet_pton(AF_INET, "10.9.0.1", &a.sin_addr);
		c = unshare(CLONE_NEWNET) ? 'E' : 'R';
		write(pkg_done[1], &c, 1);
		while (read(pkg_go[0], &c, 1) == 1) {
			char b[8];
			int s, i, ok = 0;

			if (!up++)
				ifup("v1", "10.9.0.2");
			for (i = 0; i < 30 && !ok; i++) {
				s = socket(AF_INET, SOCK_STREAM, 0);
				if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0 &&
				    write(s, "ping", 4) == 4 && read(s, b, 4) == 4)
					ok = 1;
				else
					usleep(100000);
				close(s);
			}
			c = ok ? 'K' : 'F';
			write(pkg_done[1], &c, 1);
		}
		_exit(0);
	}
	if (read(pkg_done[0], &c, 1) != 1 || c != 'R')
		return -2000;
	r = veth_add(pkg_peer);
	if (r)
		return r;
	r = ifup("v0", "10.9.0.1");
	return r ? -3000 - r : 0;
}

static void tcp_burst(void)
{
	char c = 'g';

	write(pkg_go[1], &c, 1);
	if (read(pkg_done[0], &c, 1) != 1 || c != 'K')
		printf("KFT: note tcp burst failed (%c)\n", c);
}

static void pkg_test(void)
{
	struct kfreecess_msg_data d;
	int r = pkg_setup();

	res(r == 0, "pkg: veth pair + netns peer + server uid %d (r=%d)", APP_UID, r);
	if (r) {
		kill(pkg_srv, SIGKILL); kill(pkg_peer, SIGKILL);
		return;
	}
	tcp_burst();
	r = nl_recv(&d, 300);
	res(r == 0, "pkg: TCP for an unrecorded uid -> no report (r=%d)", r);
	r = nl_send(MSG_TO_KERN, MOD_PKG, 0, 0, 0 /* ADD_UID */, APP_UID);
	tcp_burst();
	r = r ? r : nl_recv(&d, 1000);
	res(r == 1 && d.type == MSG_TO_USER && d.mod == MOD_PKG && d.target_uid == APP_UID && d.pkg_info.uid == APP_UID,
	    "pkg: ADD_UID then TCP data -> MOD_PKG r=%d uid %d pkg uid %u", r, d.target_uid, d.pkg_info.uid);
	r = nl_recv(&d, 300);
	tcp_burst();
	r = r ? r : nl_recv(&d, 300);
	res(r == 0, "pkg: reported once, uid forgotten (r=%d)", r);
	nl_send(MSG_TO_KERN, MOD_PKG, 0, 0, 0, APP_UID);
	r = nl_send(MSG_TO_KERN, MOD_PKG, 0, 0, 1 /* DEL_UID */, APP_UID);
	tcp_burst();
	r = r ? r : nl_recv(&d, 300);
	res(r == 0, "pkg: ADD_UID + DEL_UID -> no report (r=%d)", r);
	kill(pkg_srv, SIGKILL); kill(pkg_peer, SIGKILL);
	waitpid(pkg_srv, NULL, 0); waitpid(pkg_peer, NULL, 0);
}

int main(int argc, char **argv)
{
	struct sockaddr_nl a = { .nl_family = AF_NETLINK };
	struct kfreecess_msg_data d;
	int r, v1_only = argc > 1 && !strcmp(argv[1], "v1");

	if (argc > 1 && !strcmp(argv[1], "absent")) {
		nl = socket(AF_NETLINK, SOCK_RAW, NETLINK_KFREECESS);
		res(nl < 0 && errno == EPROTONOSUPPORT, "no module: socket() = %d errno %d (EPROTONOSUPPORT %d)",
		    nl, errno, EPROTONOSUPPORT);
		return fails;
	}

	nl = socket(AF_NETLINK, SOCK_RAW, NETLINK_KFREECESS);
	res(nl >= 0, "socket(AF_NETLINK, SOCK_RAW, %d) = %d errno %d", NETLINK_KFREECESS, nl, nl < 0 ? errno : 0);
	if (nl < 0)
		return fails;
	a.nl_pid = port = getpid();
	res(bind(nl, (struct sockaddr *)&a, sizeof(a)) == 0, "bind portid %d", port);

	if (!v1_only) {
		/* uid 0 is not the framework */
		r = nl_send(LOOPBACK_MSG, MOD_SIG, 0x20000003, 0, 0, 0);
		r = r ? r : nl_recv(&d, 300);
		res(r == 0, "hello from uid 0 is ignored (r=%d)", r);
	}
	/* netlink credentials carry the real uid: be "system" there, keep euid 0 for cgroup files and kill */
	res(setresuid(1000, 0, 0) == 0, "real uid 1000 (system)");

	if (!v1_only) {
		/* the OneUI 9 framework's word: fw version 2 (16-byte token header), bit 0 cgroup2, bit 1 one freezer.
		 * Module loaded with max_version=6: the S26 answer */
		hello(0x20000003, 6);
		sig_test("v2", "/cg2/t/cgroup.procs", "/cg2/cgroup.procs", 0);
		binder_test("v2", "/cg2/t/cgroup.procs", "/cg2/cgroup.procs");
		pkg_test();
	}
	/* default module (max_version=1) with the real word, or a framework without bit 0:
	 * the kernel answers version 1 and looks at the v1 freezer */
	hello(v1_only ? 0x20000003 : 2u << 28, 1);
	sig_test("v1", "/dev/freezer/frozen/cgroup.procs", "/dev/freezer/cgroup.procs", 1);
	binder_test("v1", "/dev/freezer/frozen/cgroup.procs", "/dev/freezer/cgroup.procs");
	if (v1_only)
		pkg_test();

	printf("KFT: END fails=%d\n", fails);
	return fails;
}
