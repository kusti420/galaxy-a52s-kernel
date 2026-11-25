// SPDX-License-Identifier: GPL-2.0-only
/*
 * Freecess MOD_PKG (thaw a frozen uid when TCP data arrives for one of its sockets) and the MOD_CFB
 * request handler. Samsung freecess_pkg.c (5.4 A52s == S26 6.12), as part of the freecess module:
 *  - netfilter hooks through pernet_operations (Samsung: for_each_net once at init, later namespaces
 *    get none)
 *  - the no-op LOCAL_OUT hooks are dropped
 *  - socket owner from sk->sk_uid (what SOCK_INODE(sk->sk_socket)->i_uid holds, without touching
 *    sk_socket of a socket that may be closing)
 */
#define pr_fmt(fmt) "freecess: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/skbuff.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv6.h>
#include <linux/types.h>
#include <linux/uidgid.h>
#include <net/sock.h>
#include <net/ip.h>
#include <net/ipv6.h>
#include <net/tcp.h>
#include <net/net_namespace.h>
#include "freecess.h"

#define MAX_REC_UID 64
static atomic_t uid_rec[MAX_REC_UID];
static atomic_t uid_rec_cnt;	/* fast path: no lookups while nothing is recorded */

static void freecess_add_uid(uid_t uid)
{
	int i, j;
	uid_t inner_uid;

	for (i = 0, j = MAX_REC_UID; i < MAX_REC_UID; i++) {
		inner_uid = atomic_read(&uid_rec[i]);
		if (inner_uid == 0 && j == MAX_REC_UID)
			j = i;
		else if (inner_uid == uid)
			return;
	}

	if (j < MAX_REC_UID) {
		atomic_set(&uid_rec[j], uid);
		atomic_inc(&uid_rec_cnt);
	} else {
		pr_err("%s : add uid:%d failed (full)!\n", __func__, uid);
	}
}

static void freecess_del_uid(uid_t uid)
{
	int i;

	for (i = 0; i < MAX_REC_UID; i++) {
		if (atomic_cmpxchg(&uid_rec[i], uid, 0) == uid) {
			atomic_dec(&uid_rec_cnt);
			break;
		}
	}
}

static void freecess_clear_all(void)
{
	int i;

	for (i = 0; i < MAX_REC_UID; i++)
		if (atomic_xchg(&uid_rec[i], 0))
			atomic_dec(&uid_rec_cnt);
}

static int find_and_clear_uid(uid_t uid)
{
	int i;

	if (atomic_read(&uid_rec_cnt) <= 0)
		return 0;
	for (i = 0; i < MAX_REC_UID; i++) {
		if (unlikely(atomic_read(&uid_rec[i]) == uid)) {
			if (atomic_cmpxchg(&uid_rec[i], uid, 0) == uid) {
				atomic_dec(&uid_rec_cnt);
				return 1;
			}
			break;
		}
	}
	return 0;
}

static void kfreecess_pkg_hook(void *data, unsigned int len)
{
	struct kfreecess_msg_data *payload = (struct kfreecess_msg_data *)data;

	if (payload->pkg_info.uid == 0 && payload->pkg_info.cmd != CLEAR_ALL_UID)
		return;		/* 0 is the empty-slot marker */

	switch (payload->pkg_info.cmd) {
	case ADD_UID:
		freecess_add_uid(payload->pkg_info.uid);
		break;
	case DEL_UID:
		freecess_del_uid(payload->pkg_info.uid);
		break;
	case CLEAR_ALL_UID:
		freecess_clear_all();
		break;
	default:
		break;
	}
}

static void kfreecess_cfb_hook(void *data, unsigned int len)
{
	struct kfreecess_msg_data *payload = (struct kfreecess_msg_data *)data;

	binders_in_transcation(payload->target_uid);
}

static void freecess_tcp_in(struct sk_buff *skb)
{
	struct sock *sk;
	uid_t uid;

	if (atomic_read(&uid_rec_cnt) <= 0)
		return;
	sk = skb_to_full_sk(skb);
	if (sk == NULL || !sk_fullsock(sk))
		return;

	uid = from_kuid(&init_user_ns, sk->sk_uid);
	if (uid < UID_MIN_VALUE)
		return;

	if (find_and_clear_uid(uid))
		pkg_report((int)uid);
}

static unsigned int freecess_ip4_in(void *priv, struct sk_buff *skb, const struct nf_hook_state *state)
{
	if (ip_hdr(skb)->protocol == IPPROTO_TCP)
		freecess_tcp_in(skb);
	return NF_ACCEPT;
}

static unsigned int freecess_ip6_in(void *priv, struct sk_buff *skb, const struct nf_hook_state *state)
{
	unsigned int thoff = 0;
	unsigned short frag_off = 0;

	if (atomic_read(&uid_rec_cnt) <= 0)
		return NF_ACCEPT;
	if (ipv6_find_hdr(skb, &thoff, -1, &frag_off, NULL) == IPPROTO_TCP)
		freecess_tcp_in(skb);
	return NF_ACCEPT;
}

static const struct nf_hook_ops freecess_nf_ops[] = {
	{
		.hook		= freecess_ip4_in,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_LOCAL_IN,
		.priority	= NF_IP_PRI_SELINUX_LAST + 1,
	},
	{
		.hook		= freecess_ip6_in,
		.pf		= NFPROTO_IPV6,
		.hooknum	= NF_INET_LOCAL_IN,
		.priority	= NF_IP6_PRI_SELINUX_LAST + 1,
	},
};

static int __net_init freecess_net_init(struct net *net)
{
	return nf_register_net_hooks(net, freecess_nf_ops, ARRAY_SIZE(freecess_nf_ops));
}

static void __net_exit freecess_net_exit(struct net *net)
{
	nf_unregister_net_hooks(net, freecess_nf_ops, ARRAY_SIZE(freecess_nf_ops));
}

static struct pernet_operations freecess_net_ops = {
	.init = freecess_net_init,
	.exit = freecess_net_exit,
};

int freecess_pkg_init(void)
{
	int ret = register_pernet_subsys(&freecess_net_ops);

	if (ret) {
		pr_err("netfilter hooks: %d\n", ret);
		return ret;
	}
	register_kfreecess_hook(MOD_PKG, kfreecess_pkg_hook);
	register_kfreecess_hook(MOD_CFB, kfreecess_cfb_hook);
	return 0;
}

void freecess_pkg_exit(void)
{
	unregister_kfreecess_hook(MOD_PKG);
	unregister_kfreecess_hook(MOD_CFB);
	unregister_pernet_subsys(&freecess_net_ops);
}
