#!/usr/bin/env python3
# Generator used once to write patch 0002 (kept for reference): edits src/smcinvoke/compat/smcinvoke.c
import sys,re
p=sys.argv[1]; s=open(p).read(); o=s
def rep(a,b,cnt=1):
    global s
    assert s.count(a)==cnt, (a, s.count(a))
    s=s.replace(a,b)
rep('''static long smcinvoke_ioctl(struct file *, unsigned int, unsigned long);
''','''static long smcinvoke_ioctl(struct file *, unsigned int, unsigned long);

/*
 * a52sxq: the 5.4 (SM7325 vendor) UAPI layout. The closed 5.4-era userspace (libminkdescriptor
 * and its users) was built against these structures; the ioctl numbers differ from the 6.12 ones
 * because the sizes differ, so both generations are accepted side by side.
 */
struct smcinvoke_obj_legacy {
	__s64 fd;
	__s32 cb_server_fd;
	__s32 reserved;
};

union smcinvoke_arg_legacy {
	struct smcinvoke_buf b;
	struct smcinvoke_obj_legacy o;
};

struct smcinvoke_cmd_req_legacy {
	__u32 op;
	__u32 counts;
	__s32 result;
	__u32 argsize;
	__u64 args;
};

struct smcinvoke_accept_legacy {
	__u32 has_resp;
	__u32 txn_id;
	__s32 result;
	__s32 cbobj_id;
	__u32 op;
	__u32 counts;
	__s32 reserved;
	__u32 argsize;
	__u64 buf_len;
	__u64 buf_addr;
};

struct smcinvoke_server_legacy {
	__u32 cb_buf_size;
};

#define SMCINVOKE_IOCTL_INVOKE_REQ_LEGACY \\
	_IOWR(SMCINVOKE_IOC_MAGIC, 1, struct smcinvoke_cmd_req_legacy)
#define SMCINVOKE_IOCTL_ACCEPT_REQ_LEGACY \\
	_IOWR(SMCINVOKE_IOC_MAGIC, 2, struct smcinvoke_accept_legacy)
#define SMCINVOKE_IOCTL_SERVER_REQ_LEGACY \\
	_IOWR(SMCINVOKE_IOC_MAGIC, 3, struct smcinvoke_server_legacy)
#define SMCINVOKE_IOCTL_ACK_LOCAL_OBJ_LEGACY \\
	_IOWR(SMCINVOKE_IOC_MAGIC, 4, __s32)

static_assert(sizeof(union smcinvoke_arg_legacy) == 16);
static_assert(sizeof(struct smcinvoke_cmd_req_legacy) == 0x18);
static_assert(sizeof(struct smcinvoke_accept_legacy) == 0x30);
static_assert(SMCINVOKE_IOCTL_INVOKE_REQ_LEGACY == 0xc0189801);
static_assert(SMCINVOKE_IOCTL_ACCEPT_REQ_LEGACY == 0xc0309802);
static_assert(SMCINVOKE_IOCTL_SERVER_REQ_LEGACY == 0xc0049803);
static_assert(SMCINVOKE_IOCTL_ACK_LOCAL_OBJ_LEGACY == 0xc0049804);

/*
 * Marks the kernel copy of a struct smcinvoke_accept that came in through the legacy ioctl, so
 * the marshalling helpers use the 16 byte argument slots. Never copied to or accepted from
 * userspace.
 */
#define SMCI_LEGACY_MARK	0x4c474359

static inline bool smci_accept_legacy(const struct smcinvoke_accept *r)
{
	return r->reserved == SMCI_LEGACY_MARK;
}

static inline size_t smci_accept_argsz(const struct smcinvoke_accept *r)
{
	return smci_accept_legacy(r) ? sizeof(union smcinvoke_arg_legacy) :
			sizeof(union smcinvoke_arg);
}

static void smci_arg_to_legacy(union smcinvoke_arg_legacy *l,
		const union smcinvoke_arg *a, bool is_obj)
{
	memset(l, 0, sizeof(*l));
	if (is_obj) {
		l->o.fd = a->o.fd;
		l->o.cb_server_fd = (__s32)a->o.cb_server_fd;
	} else {
		l->b = a->b;
	}
}

static void smci_arg_from_legacy(union smcinvoke_arg *a,
		const union smcinvoke_arg_legacy *l, bool is_obj)
{
	memset(a, 0, sizeof(*a));
	if (is_obj) {
		a->o.fd = l->o.fd;
		a->o.cb_server_fd = l->o.cb_server_fd;
	} else {
		a->b = l->b;
	}
}

/* Argument slot i of a callback request/response buffer, in the caller's layout. */
static int smci_put_cb_arg(const struct smcinvoke_accept *r, int i,
		const union smcinvoke_arg *a, bool is_obj)
{
	union smcinvoke_arg_legacy l;

	if (!smci_accept_legacy(r))
		return copy_to_user(u64_to_user_ptr(r->buf_addr + i * sizeof(*a)),
				a, sizeof(*a)) ? -EFAULT : 0;
	smci_arg_to_legacy(&l, a, is_obj);
	return copy_to_user(u64_to_user_ptr(r->buf_addr + i * sizeof(l)),
			&l, sizeof(l)) ? -EFAULT : 0;
}

static int smci_get_cb_arg(const struct smcinvoke_accept *r, int i,
		union smcinvoke_arg *a, bool is_obj)
{
	union smcinvoke_arg_legacy l;

	if (!smci_accept_legacy(r))
		return copy_from_user(a, u64_to_user_ptr(r->buf_addr + i * sizeof(*a)),
				sizeof(*a)) ? -EFAULT : 0;
	if (copy_from_user(&l, u64_to_user_ptr(r->buf_addr + i * sizeof(l)), sizeof(l)))
		return -EFAULT;
	smci_arg_from_legacy(a, &l, is_obj);
	return 0;
}
''')
# marshal_in_tzcb_req
rep('''	size_t user_req_buf_offset = sizeof(union smcinvoke_arg) *
			OBJECT_COUNTS_TOTAL(tzcb_req->hdr.counts);''','''	size_t user_req_buf_offset = smci_accept_argsz(user_req) *
			OBJECT_COUNTS_TOTAL(tzcb_req->hdr.counts);''')
rep('''	user_req->argsize = sizeof(union smcinvoke_arg);

	trace_marshal_in_tzcb_req_handle''','''	user_req->argsize = smci_accept_argsz(user_req);

	trace_marshal_in_tzcb_req_handle''')
rep('''		if (copy_to_user(u64_to_user_ptr
				(user_req->buf_addr + i * sizeof(tmp_arg)),
				&tmp_arg, sizeof(tmp_arg)) ||
				copy_to_user(''','''		if (smci_put_cb_arg(user_req, i, &tmp_arg, false) ||
				copy_to_user(''')
rep('''		tmp_arg.b.addr = user_req->buf_addr + user_req_buf_offset;

		if (copy_to_user(u64_to_user_ptr
				(user_req->buf_addr + i * sizeof(tmp_arg)),
				&tmp_arg, sizeof(tmp_arg))) {''','''		tmp_arg.b.addr = user_req->buf_addr + user_req_buf_offset;

		if (smci_put_cb_arg(user_req, i, &tmp_arg, false)) {''')
rep('''		tmp_arg.o.fd = temp_fd;

		if (ret) {
			ret = -EINVAL;
			goto out;
		}
		if (copy_to_user(u64_to_user_ptr
				(user_req->buf_addr + i * sizeof(tmp_arg)),
				&tmp_arg, sizeof(tmp_arg))) {''','''		tmp_arg.o.fd = temp_fd;

		if (ret) {
			ret = -EINVAL;
			goto out;
		}
		if (smci_put_cb_arg(user_req, i, &tmp_arg, true)) {''')
# marshal_out_tzcb_req
rep('''		if (copy_from_user((uint8_t *)&tmp_arg, u64_to_user_ptr(
				user_req->buf_addr + i * sizeof(union smcinvoke_arg)),
				sizeof(union smcinvoke_arg))) {
			ret = -EFAULT;
			goto out;
		}
		if (tmp_arg.b.size > tz_args[i].b.size)''','''		if (smci_get_cb_arg(user_req, i, &tmp_arg, false)) {
			ret = -EFAULT;
			goto out;
		}
		if (tmp_arg.b.size > tz_args[i].b.size)''')
rep('''		if (copy_from_user((uint8_t *)&tmp_arg, u64_to_user_ptr(
				user_req->buf_addr + i * sizeof(union smcinvoke_arg)),
				sizeof(union smcinvoke_arg))) {
			ret = -EFAULT;
			goto out;
		}
		ret = get_tzhandle_from_uhandle(tmp_arg.o.fd,''','''		if (smci_get_cb_arg(user_req, i, &tmp_arg, true)) {
			ret = -EFAULT;
			goto out;
		}
		ret = get_tzhandle_from_uhandle(tmp_arg.o.fd,''')
# server req
rep('''	if (_IOC_SIZE(cmd) != sizeof(server_req)) {
		pr_err("invalid command size received for server request\\n");
		return -EINVAL;
	}
	ret = copy_from_user(&server_req, (void __user *)(uintptr_t)arg,
					sizeof(server_req));
	if (ret) {''','''	if (cmd == SMCINVOKE_IOCTL_SERVER_REQ_LEGACY) {
		struct smcinvoke_server_legacy l = {0};

		ret = copy_from_user(&l, (void __user *)(uintptr_t)arg, sizeof(l));
		server_req.cb_buf_size = l.cb_buf_size;
	} else if (_IOC_SIZE(cmd) != sizeof(server_req)) {
		pr_err("invalid command size received for server request\\n");
		return -EINVAL;
	} else {
		ret = copy_from_user(&server_req, (void __user *)(uintptr_t)arg,
					sizeof(server_req));
	}
	if (ret) {''')
# accept
rep('''	if (_IOC_SIZE(cmd) != sizeof(struct smcinvoke_accept)) {
		pr_err("command size invalid for accept request\\n");
		return -EINVAL;
	}

	if (copy_from_user(&user_args, (void __user *)arg,
			sizeof(struct smcinvoke_accept))) {
		pr_err("copying accept request from user failed\\n");
		return -EFAULT;
	}

	if (user_args.argsize != sizeof(union smcinvoke_arg)) {''','''	if (legacy) {
		struct smcinvoke_accept_legacy l;

		if (copy_from_user(&l, (void __user *)arg, sizeof(l))) {
			pr_err("copying accept request from user failed\\n");
			return -EFAULT;
		}
		user_args.has_resp = l.has_resp;
		user_args.txn_id = l.txn_id;
		user_args.result = l.result;
		user_args.cbobj_id = l.cbobj_id;
		user_args.op = l.op;
		user_args.counts = l.counts;
		user_args.reserved = SMCI_LEGACY_MARK;
		user_args.argsize = l.argsize;
		user_args.buf_len = l.buf_len;
		user_args.buf_addr = l.buf_addr;
	} else {
		if (_IOC_SIZE(cmd) != sizeof(struct smcinvoke_accept)) {
			pr_err("command size invalid for accept request\\n");
			return -EINVAL;
		}

		if (copy_from_user(&user_args, (void __user *)arg,
				sizeof(struct smcinvoke_accept))) {
			pr_err("copying accept request from user failed\\n");
			return -EFAULT;
		}
		/* the mark is kernel-internal: never taken from a 6.12-layout caller */
		if (user_args.reserved == SMCI_LEGACY_MARK)
			return -EINVAL;
	}

	if (user_args.argsize != smci_accept_argsz(&user_args)) {''')
rep('''	struct smcinvoke_accept user_args = {0};
	struct smcinvoke_cb_txn *cb_txn = NULL;''','''	struct smcinvoke_accept user_args = {0};
	const bool legacy = cmd == SMCINVOKE_IOCTL_ACCEPT_REQ_LEGACY;
	struct smcinvoke_cb_txn *cb_txn = NULL;''')
rep('''			ret = copy_to_user((void __user *)arg, &user_args,
					sizeof(struct smcinvoke_accept));''','''			if (legacy) {
				struct smcinvoke_accept_legacy l = {
					.has_resp = user_args.has_resp,
					.txn_id = (__u32)user_args.txn_id,
					.result = user_args.result,
					.cbobj_id = (__s32)user_args.cbobj_id,
					.op = user_args.op,
					.counts = user_args.counts,
					.reserved = 0,
					.argsize = user_args.argsize,
					.buf_len = user_args.buf_len,
					.buf_addr = user_args.buf_addr,
				};

				ret = copy_to_user((void __user *)arg, &l, sizeof(l));
			} else {
				ret = copy_to_user((void __user *)arg, &user_args,
						sizeof(struct smcinvoke_accept));
			}''')
# invoke
rep('''	bool tz_acked = false;
	uint32_t context_type = tzobj->context_type;

	if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ &&
			_IOC_SIZE(cmd) != sizeof(req)) {''','''	bool tz_acked = false;
	uint32_t context_type = tzobj->context_type;
	/* 5.4 layout: only ever from userspace */
	const bool legacy = cmd == SMCINVOKE_IOCTL_INVOKE_REQ_LEGACY &&
			context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ;
	int nr_bufs = 0, i;

	if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ && !legacy &&
			_IOC_SIZE(cmd) != sizeof(req)) {''')
rep('''		ret = copy_from_user(&req, (void __user *)arg, sizeof(req));
		if (ret) {
			pr_err("copying invoke req failed\\n");
			return -EFAULT;
		}
	} else {
		req = *(struct smcinvoke_cmd_req *)arg;
	}
	if (req.argsize != sizeof(union smcinvoke_arg)) {
		pr_err("arguments size for invoke req is invalid\\n");
		return -EINVAL;
	}
''','''		/* the legacy request is a prefix of the current one (no .reserved) */
		ret = copy_from_user(&req, (void __user *)arg, legacy ?
				sizeof(struct smcinvoke_cmd_req_legacy) : sizeof(req));
		if (ret) {
			pr_err("copying invoke req failed\\n");
			return -EFAULT;
		}
	} else {
		req = *(struct smcinvoke_cmd_req *)arg;
	}
	if (legacy) {
		if (req.argsize != sizeof(union smcinvoke_arg_legacy)) {
			pr_err("arguments size for legacy invoke req is invalid\\n");
			return -EINVAL;
		}
		/* from here on the kernel copy is in the current layout */
		req.argsize = sizeof(union smcinvoke_arg);
	}
	if (req.argsize != sizeof(union smcinvoke_arg)) {
		pr_err("arguments size for invoke req is invalid\\n");
		return -EINVAL;
	}
	nr_bufs = OBJECT_COUNTS_NUM_buffers(req.counts);
''')
rep('''		if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ) {
			ret = copy_from_user(args_buf,
					u64_to_user_ptr(req.args),
					nr_args * req.argsize);
			if (ret) {
				ret = -EFAULT;
				goto out;
			}
		} else {''','''		if (legacy) {
			union smcinvoke_arg_legacy l;

			for (i = 0; i < nr_args; i++) {
				if (copy_from_user(&l, u64_to_user_ptr(req.args +
						i * sizeof(l)), sizeof(l))) {
					ret = -EFAULT;
					goto out;
				}
				smci_arg_from_legacy(&args_buf[i], &l, i >= nr_bufs);
			}
		} else if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ) {
			ret = copy_from_user(args_buf,
					u64_to_user_ptr(req.args),
					nr_args * req.argsize);
			if (ret) {
				ret = -EFAULT;
				goto out;
			}
		} else {''')
rep('''		if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ)
			ret |= copy_to_user(u64_to_user_ptr(req.args),
					args_buf, nr_args * req.argsize);
		else''','''		if (legacy) {
			union smcinvoke_arg_legacy l;

			for (i = 0; i < nr_args; i++) {
				smci_arg_to_legacy(&l, &args_buf[i], i >= nr_bufs);
				ret |= copy_to_user(u64_to_user_ptr(req.args +
						i * sizeof(l)), &l, sizeof(l));
			}
		} else if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ)
			ret |= copy_to_user(u64_to_user_ptr(req.args),
					args_buf, nr_args * req.argsize);
		else''')
rep('''	if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ) {
		ret |= copy_to_user((void __user *)arg, &req, sizeof(req));
		if (ret)
			goto out;''','''	if (legacy) {
		req.argsize = sizeof(union smcinvoke_arg_legacy);
		ret |= copy_to_user((void __user *)arg, &req,
				sizeof(struct smcinvoke_cmd_req_legacy));
		if (ret)
			goto out;
	} else if (context_type == SMCINVOKE_OBJ_TYPE_TZ_OBJ) {
		ret |= copy_to_user((void __user *)arg, &req, sizeof(req));
		if (ret)
			goto out;''')
rep('''	case SMCINVOKE_IOCTL_INVOKE_REQ:
		ret = process_invoke_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_ACCEPT_REQ:
		ret = process_accept_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_SERVER_REQ:
		ret = process_server_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_ACK_LOCAL_OBJ:''','''	case SMCINVOKE_IOCTL_INVOKE_REQ:
	case SMCINVOKE_IOCTL_INVOKE_REQ_LEGACY:
		ret = process_invoke_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_ACCEPT_REQ:
	case SMCINVOKE_IOCTL_ACCEPT_REQ_LEGACY:
		ret = process_accept_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_SERVER_REQ:
	case SMCINVOKE_IOCTL_SERVER_REQ_LEGACY:
		ret = process_server_req(filp, cmd, arg);
		break;
	case SMCINVOKE_IOCTL_ACK_LOCAL_OBJ:
	case SMCINVOKE_IOCTL_ACK_LOCAL_OBJ_LEGACY:''')
open(p,'w').write(s)
