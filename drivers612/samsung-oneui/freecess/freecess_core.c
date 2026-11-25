// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) Samsung Technologies Co., Ltd. 2001-2017. All rights reserved.
 *
 * File name: freecess.c
 * Description: Use to thaw process from state 'D'
 * Author: chao.gu@samsung.com
 *
 * Module build for GKI android16-6.12 (a52sxq): the S26 6.12 freecess.c (version negotiation with
 * cgroup2/cgroup1 mode) with these differences:
 *  - loadable module (S26 and the 5.4 A52s kernel have it built in), init/exit of the pkg and hook parts
 *    from here, real errnos from init
 *  - a report for a mod whose framework port is not bound yet is dropped before it is built. The
 *    Samsung code unicasts it to portid 0 = the kernel socket itself, which lands in recv_handler and
 *    logs "freecess--uid: 0, permission denied" for every report until the framework says hello.
 *  - counters in /sys/module/freecess/parameters (read-only) for on-phone checks
 *  - param max_version (default 1): the highest kernel version to answer with. 1 = cgroup v1 freezer
 *    (/dev/freezer/frozen), what the 5.4 A52s kernel answers and what the OneUI 9 port has always run
 *    with; 2 = cgroup2 freezer (the framework then freezes through cgroup.freeze); 6 = cgroup2 + "one
 *    freezer" (the full S26 negotiation). The framework accepts exactly 1, 2 and 6.
 *  - the framework's port is taken from the netlink sender (NETLINK_CB(skb).portid), not from the
 *    payload's src_portid: the framework never binds, it writes Process.myPid() there and relies on
 *    autobind having picked the same number
 */
#define pr_fmt(fmt) "freecess: " fmt

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/netlink.h>
#include <linux/skbuff.h>
#include <linux/freezer.h>
#include <linux/sched/jobctl.h>
#include <linux/cred.h>
#include <net/sock.h>
#include <net/net_namespace.h>
#include "freecess.h"

#define RET_OK   0
#define RET_ERR  1
static struct sock *kfreecess_mod_sock;
static atomic_t bind_port[MOD_END];
static atomic_t kfreecess_init_suc;
static int last_kill_pid = -1;

int freecess_fw_version;	/* record freecess framework version */
module_param_named(fw_version, freecess_fw_version, int, 0444);

/* freecess uses cgroup2 or cgroup1 mode, default is cgroup2 (S26: static key freecess_use_cgroup2) */
static bool freecess_use_cgroup2 = true;
module_param_named(use_cgroup2, freecess_use_cgroup2, bool, 0444);
static int FREECESS_KERNEL_VERSION = 2;
module_param_named(kernel_version, FREECESS_KERNEL_VERSION, int, 0444);
static int max_version = 1;
module_param(max_version, int, 0444);
MODULE_PARM_DESC(max_version, "highest kernel version to answer: 1 cgroup v1 freezer as the 5.4 A52s kernel (default), 2 cgroup2, 6 cgroup2 + one freezer (S26)");
static bool debug;
module_param(debug, bool, 0644);

struct freecess_stats freecess_stats;
#define STAT_PARAM(name, field) \
	static int stat_get_##name(char *buf, const struct kernel_param *kp) \
	{ return sysfs_emit(buf, "%ld\n", atomic_long_read(&freecess_stats.field)); } \
	static const struct kernel_param_ops stat_ops_##name = { .get = stat_get_##name }; \
	module_param_cb(stat_##name, &stat_ops_##name, NULL, 0444)
STAT_PARAM(loopback, loopback);
STAT_PARAM(to_kern, to_kern);
STAT_PARAM(sent_binder, sent[MOD_BINDER]);
STAT_PARAM(sent_sig, sent[MOD_SIG]);
STAT_PARAM(sent_pkg, sent[MOD_PKG]);
STAT_PARAM(sent_cfb, sent[MOD_CFB]);
STAT_PARAM(send_fail, send_fail);
STAT_PARAM(binder_sync, binder_sync);
STAT_PARAM(binder_async, binder_async);
STAT_PARAM(binder_full, binder_full);
STAT_PARAM(cfb_req, cfb_req);
STAT_PARAM(cfb_hit, cfb_hit);
STAT_PARAM(denied, denied);

struct priv_data {
	int target_uid;
	int flag;		/* MOD_SIG, MOD_BINDER */
	int code;		/* RPC code */
	char rpcname[INTERFACETOKEN_BUFF_SIZE];	/* interface token */
	pkg_info_t pkg_info;	/* MOD_PKG */
};

static freecess_hook mod_recv_handler[MOD_END];

static int check_msg_type(int type)
{
	return (type < MSG_TYPE_END) && (type > 0);
}

static int check_mod_type(int mod)
{
	return (mod < MOD_END) && (mod > 0);
}

bool freecess_mod_bound(int mod)
{
	return atomic_read(&bind_port[mod]) != 0;
}

int thread_group_is_frozen(struct task_struct *task)
{
	struct task_struct *leader = task->group_leader;

	if (freecess_use_cgroup2)
		return !!(leader->jobctl & JOBCTL_TRAP_FREEZE);
	else
		/* frozen() is not exported on GKI: it is this one read (kernel/freezer.c) */
		return freezing(leader) || (READ_ONCE(leader->__state) & TASK_FROZEN);
}

/*
 * This is used to identify threads frozen by cgroup2
 * in freecess cgroup1 mode. In cgroup2 mode, it always
 * returns false.
 */
bool cgroup2_frozen(struct task_struct *task)
{
	if (freecess_use_cgroup2)
		return false;
	return !!(task->jobctl & JOBCTL_TRAP_FREEZE);
}

static void dump_kfreecess_msg(struct kfreecess_msg_data *msg)
{
	pr_info("hello: mod %d src_portid %d dst_portid %d kernel version %d fw version %d (word %#x) target_uid %d\n",
		msg->mod, msg->src_portid, msg->dst_portid, FREECESS_KERNEL_VERSION,
		FREECESS_PEER_VERSION(msg->version), msg->version, msg->target_uid);
}

static int mod_sendmsg(int type, int mod, struct priv_data *data)
{
	int ret, msg_len = 0;
	struct sk_buff *skb = NULL;
	struct nlmsghdr *nlh = NULL;
	struct kfreecess_msg_data *payload = NULL;
	int port;

	if (!atomic_read(&kfreecess_init_suc))
		return RET_ERR;

	if (!check_msg_type(type)) {
		pr_err("%s: msg type is invalid! %d\n", __func__, type);
		return RET_ERR;
	}

	if (!check_mod_type(mod)) {
		pr_err("%s: mod type is invalid! %d\n", __func__, mod);
		return RET_ERR;
	}

	port = atomic_read(&bind_port[mod]);
	if (!port)	/* framework not registered for this mod: nobody to tell (see header comment) */
		return RET_ERR;

	msg_len = sizeof(struct kfreecess_msg_data);
	skb = nlmsg_new(msg_len, GFP_ATOMIC);
	if (!skb) {
		atomic_long_inc(&freecess_stats.send_fail);
		return RET_ERR;
	}

	nlh = nlmsg_put(skb, 0, 0, 0, msg_len, 0);
	if (!nlh) {
		kfree_skb(skb);
		return RET_ERR;
	}

	payload = nlmsg_data(nlh);
	memset(payload, 0, msg_len);
	payload->type = type;
	payload->mod = mod;
	payload->src_portid = KERNEL_ID_NETLINK;
	payload->dst_portid = port;

	if (data) {
		payload->caller_pid = task_uid(current).val;
		payload->target_uid = data->target_uid;
		if (payload->mod == MOD_BINDER) {
			payload->code = data->code;
			memcpy(payload->rpcname, data->rpcname, sizeof(data->rpcname));
			payload->pkg_info.cmd = data->pkg_info.cmd;
			payload->pkg_info.uid = task_uid(current).val;
			payload->caller_pid = task_tgid_nr(current);
		}
		if (payload->mod == MOD_PKG)
			memcpy(&payload->pkg_info, &data->pkg_info, sizeof(pkg_info_t));
		else
			payload->flag = data->flag;
	} else {
		payload->version = FREECESS_PACK_VERSION(FREECESS_KERNEL_VERSION);
	}

	ret = nlmsg_unicast(kfreecess_mod_sock, skb, port);
	if (ret < 0) {
		/* -ECONNREFUSED: the framework socket is gone (system_server restart): forget the port */
		if (ret == -ECONNREFUSED)
			atomic_cmpxchg(&bind_port[mod], port, 0);
		atomic_long_inc(&freecess_stats.send_fail);
		if (debug)
			pr_err("nlmsg_unicast failed! mod %d errno %d\n", mod, ret);
		return RET_ERR;
	}
	if (type == MSG_TO_USER)
		atomic_long_inc(&freecess_stats.sent[mod]);

	return RET_OK;
}

int sig_report(struct task_struct *p, bool report_pid)
{
	int ret = RET_OK;
	struct priv_data data;
	int target_pid = task_tgid_nr(p);

	memset(&data, 0, sizeof(struct priv_data));
	data.target_uid = task_uid(p).val;
	if (report_pid && !p->group_leader->ptrace)
		data.flag = target_pid;

	if (thread_group_is_frozen(p) && (target_pid != last_kill_pid)) {
		last_kill_pid = target_pid;
		ret = mod_sendmsg(MSG_TO_USER, MOD_SIG, &data);
	}

	return ret;
}

int binder_report(struct task_struct *p, int code, const char *str, int flag)
{
	int ret = RET_OK;
	struct priv_data data;

	memset(&data, 0, sizeof(struct priv_data));
	data.target_uid = -1;
	data.flag = flag;
	data.code = code;
	strscpy(data.rpcname, str, INTERFACETOKEN_BUFF_SIZE);
	if (p) {
		data.target_uid = task_uid(p).val;
		data.pkg_info.cmd = p->pid;
	}
	ret = mod_sendmsg(MSG_TO_USER, MOD_BINDER, &data);
	return ret;
}

int pkg_report(int target_uid)
{
	int ret = RET_OK;
	struct priv_data data;

	memset(&data, 0, sizeof(struct priv_data));
	data.target_uid = target_uid;
	data.pkg_info.uid = (uid_t)target_uid;
	ret = mod_sendmsg(MSG_TO_USER, MOD_PKG, &data);
	return ret;
}

int cfb_report(int target_uid, const char *reason)
{
	int ret = RET_OK;
	struct priv_data data;

	if (debug)
		pr_info("cfb_report: uid %d frozen, reason: %s\n", target_uid, reason);
	memset(&data, 0, sizeof(struct priv_data));
	data.target_uid = target_uid;
	ret = mod_sendmsg(MSG_TO_USER, MOD_CFB, &data);

	return ret;
}

static void recv_handler(struct sk_buff *skb)
{
	struct kfreecess_msg_data *payload = NULL;
	struct nlmsghdr *nlh = NULL;
	unsigned int msglen  = 0;
	uid_t uid = 0;
	int sender;

	if (unlikely(!skb))
		return;

	uid = (*NETLINK_CREDS(skb)).uid.val;
	/* only allow system user to communicate with Freecess kernel part. */
	if (uid != 1000) {
		atomic_long_inc(&freecess_stats.denied);
		pr_err_ratelimited("freecess--uid: %d, permission denied\n", uid);
		return;
	}

	if (skb->len < NLMSG_SPACE(0) + sizeof(struct kfreecess_msg_data)) {
		pr_err("freecess recv_handler msglen invalid %u %lu\n", skb->len,
					(unsigned long)(NLMSG_SPACE(0) + sizeof(struct kfreecess_msg_data)));
		return;
	}

	nlh = nlmsg_hdr(skb);
	msglen = NLMSG_PAYLOAD(nlh, 0);
	if (msglen < sizeof(struct kfreecess_msg_data)) {
		pr_err("USER_HOOK_CALLBACK: payload msglen invalid %u %lu\n",
					msglen, (unsigned long)sizeof(struct kfreecess_msg_data));
		return;
	}

	payload = (struct kfreecess_msg_data *)NLMSG_DATA(nlh);

	sender = NETLINK_CB(skb).portid;
	if (sender != payload->src_portid)
		pr_info_ratelimited("sender portid %d != payload src_portid %d: using the sender\n",
				    sender, payload->src_portid);

	if (payload->src_portid < 0 && !sender) {
		pr_err("USER_HOOK_CALLBACK %s: src_portid %d is not valid!\n", __func__, payload->src_portid);
		return;
	}

	if (payload->dst_portid != KERNEL_ID_NETLINK) {
		pr_err("USER_HOOK_CALLBACK %s: dst_portid is %d not kernel!\n", __func__, payload->dst_portid);
		return;
	}

	if (!check_mod_type(payload->mod)) {
		pr_err("USER_HOOK_CALLBACK %s: mod %d is not valid!\n", __func__, payload->mod);
		return;
	}

	switch (payload->type) {
	case LOOPBACK_MSG:
		atomic_long_inc(&freecess_stats.loopback);
		atomic_set(&bind_port[payload->mod], sender);
		freecess_fw_version = FREECESS_PEER_VERSION(payload->version);
		if (max_version <= 1 || !(payload->version & 1)) {
			if (FREECESS_KERNEL_VERSION != 1) {
				freecess_use_cgroup2 = false;
				FREECESS_KERNEL_VERSION = 1;
				pr_warn("freecess fw is old, switch to version 1 (cgroup v1 freezer)\n");
			}
		} else if ((payload->version & (1<<1)) && max_version >= 6) {
			if (FREECESS_KERNEL_VERSION != 6)
				pr_warn("freecess enables one freezer feature\n");
			FREECESS_KERNEL_VERSION = 6;
		}
		dump_kfreecess_msg(payload);
		mod_sendmsg(LOOPBACK_MSG, payload->mod, NULL);
		break;
	case MSG_TO_KERN:
		atomic_long_inc(&freecess_stats.to_kern);
		if (mod_recv_handler[payload->mod])
			mod_recv_handler[payload->mod](payload, sizeof(struct kfreecess_msg_data));
		break;
	default:
		pr_err("msg type is valid %d\n", payload->type);
	}
}

int register_kfreecess_hook(int mod, freecess_hook hook)
{
	if (!check_mod_type(mod)) {
		pr_err("%s: mod type is invalid! %d\n", __func__, mod);
		return RET_ERR;
	}

	if (hook)
		mod_recv_handler[mod] = hook;
	return RET_OK;
}

int unregister_kfreecess_hook(int mod)
{
	if (!check_mod_type(mod)) {
		pr_err("%s: mod type is invalid! %d\n", __func__, mod);
		return RET_ERR;
	}
	mod_recv_handler[mod] = NULL;
	return RET_OK;
}

static int __init kfreecess_init(void)
{
	int ret, i;
	struct netlink_kernel_cfg cfg = {
		.input = recv_handler,
	};

	for (i = 1; i < MOD_END; i++)
		atomic_set(&bind_port[i], 0);
	if (max_version <= 1) {
		freecess_use_cgroup2 = false;
		FREECESS_KERNEL_VERSION = 1;
	}

	kfreecess_mod_sock = netlink_kernel_create(&init_net, NETLINK_KFREECESS, &cfg);
	if (!kfreecess_mod_sock) {
		pr_err("%s: create kfreecess_mod_sock socket error!\n", __func__);
		return -EBUSY;
	}

	ret = freecess_pkg_init();
	if (ret)
		goto err_sock;
	ret = freecess_hooks_init();
	if (ret)
		goto err_pkg;
	ret = freecess_refreeze_init();
	if (ret)
		goto err_hooks;
	atomic_set(&kfreecess_init_suc, 1);
	pr_info("NETLINK_KFREECESS %d registered (module, GKI vendor hooks, max_version %d)\n",
		NETLINK_KFREECESS, max_version);
	return 0;

err_hooks:
	freecess_hooks_exit();
err_pkg:
	freecess_pkg_exit();
err_sock:
	netlink_kernel_release(kfreecess_mod_sock);
	return ret;
}

static void __exit kfreecess_exit(void)
{
	atomic_set(&kfreecess_init_suc, 0);
	freecess_refreeze_exit();
	freecess_hooks_exit();
	freecess_pkg_exit();
	netlink_kernel_release(kfreecess_mod_sock);
}

module_init(kfreecess_init);
module_exit(kfreecess_exit);

MODULE_DESCRIPTION("Samsung Freecess (NETLINK_KFREECESS) for GKI 6.12 via Android vendor hooks");
MODULE_LICENSE("GPL");
