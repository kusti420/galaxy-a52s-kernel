/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Samsung Freecess kernel<->framework protocol. UAPI part (numbers, struct kfreecess_msg_data) is
 * byte-identical to the 5.4 A52s kernel (include/linux/freecess.h) and the S26 6.12 kernel.
 */
#ifndef KFRECESS_H
#define KFRECESS_H

#include <linux/sched.h>

#ifndef NETLINK_KFREECESS
#define NETLINK_KFREECESS      27	/* Samsung: include/uapi/linux/netlink.h */
#endif

#define KERNEL_ID_NETLINK      0x12341234
#define UID_MIN_VALUE          10000
#define MSG_NOOP               0
#define LOOPBACK_MSG           1
#define MSG_TO_KERN            2
#define MSG_TO_USER            3
#define MSG_TYPE_END           4

#define MOD_NOOP               0
#define MOD_BINDER             1
#define MOD_SIG                2
#define MOD_PKG                3
#define MOD_CFB                4
#define MOD_END                5
#define INTERFACETOKEN_BUFF_SIZE 100

typedef enum {
	ADD_UID,
	DEL_UID,
	CLEAR_ALL_UID,
} pkg_cmd_t;

typedef struct {
	pkg_cmd_t cmd;
	uid_t uid;
} pkg_info_t;

/* |-- 4 bits version --|---------- 28 bits caller_pid ----------| */
#define FREECESS_PEER_VERSION(version)   (((version) & 0xF0000000) >> 28)
#define FREECESS_PACK_VERSION(version)    ((version) << 28)

struct kfreecess_msg_data {
	int type;
	int mod;
	int src_portid;
	int dst_portid;
	union {
		unsigned int caller_pid;
		unsigned int version;
	};
	int target_uid;
	int flag;		/* MOD_SIG, MOD_BINDER */
	int code;
	char rpcname[INTERFACETOKEN_BUFF_SIZE];
	pkg_info_t pkg_info;	/* MOD_PKG */
};

extern int freecess_fw_version;	/* top 4 bits of the framework's LOOPBACK version word */

typedef void (*freecess_hook)(void *data, unsigned int len);

int sig_report(struct task_struct *p, bool report_pid);
int binder_report(struct task_struct *p, int code, const char *str, int flag);
int pkg_report(int target_uid);
int cfb_report(int target_uid, const char *reason);
int register_kfreecess_hook(int mod, freecess_hook hook);
int unregister_kfreecess_hook(int mod);
int thread_group_is_frozen(struct task_struct *task);
bool cgroup2_frozen(struct task_struct *task);
bool freecess_mod_bound(int mod);

/* module-internal */
void binders_in_transcation(int uid);
int freecess_pkg_init(void);
void freecess_pkg_exit(void);
int freecess_hooks_init(void);
void freecess_hooks_exit(void);
int freecess_refreeze_init(void);
void freecess_refreeze_exit(void);

struct freecess_stats {
	atomic_long_t loopback, to_kern, sent[MOD_END], send_fail, binder_sync, binder_async,
		      binder_full, sig, pkg, cfb_req, cfb_hit, denied;
};
extern struct freecess_stats freecess_stats;
#endif
