// SPDX-License-Identifier: GPL-2.0-only
/*
 * sdfat: file system type "sdfat" for the Galaxy A52s 6.12 kernel, as an alias.
 *
 * The 5.4 Samsung kernel mounts FAT12/16/32 and exFAT cards through its own "sdfat"
 * driver (fs/sdfat). One UI's vold looks for "sdfat" in /proc/filesystems and then mounts
 *   exFAT: -t sdfat -o fs=exfat,adj_req,iocharset=iso8859-1,utf8,uid=,gid=,fmask=,dmask=
 *   FAT:   -t sdfat -o fs=vfat,smart,delay,adj_req,adj_hid,iocharset=iso8859-1,utf8,uid=,...
 * (strings of /system/bin/vold, K4_UN1CA 9.3.173; optional ",time_offset=%d").
 * 6.12 has the upstream "exfat" and "vfat" drivers built in. This module registers the
 * NAME only: a mount of type sdfat is handed to exfat or vfat (fs= option; without it
 * exfat is tried first, then vfat), sdfat-only options are dropped, the rest is translated.
 * The resulting superblock belongs to exfat / vfat (/proc/mounts shows that type, SELinux
 * labels it by that type, remount goes straight to that driver); no file data passes
 * through this module.
 *
 * How: ->get_tree() builds a second fs_context for the target type, feeds it the source
 * and the translated options, calls the target's ->get_tree() and moves the root dentry
 * into the caller's context. vfs_get_tree() of the caller then does the SB_BORN /
 * security_sb_set_mnt_opts() step exactly once, with the caller's security options.
 */
#define pr_fmt(fmt) "sdfat-alias: " fmt

#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/fs_parser.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/string.h>

enum { SDFAT_AUTO, SDFAT_EXFAT, SDFAT_VFAT };

struct sdfat_opt {
	struct sdfat_opt *next;
	char *key;
	char *val;		/* NULL: flag */
};

struct sdfat_ctx {
	int type;
	bool utf8;
	bool shortname;
	struct sdfat_opt *head, **tail;
};

/* options the upstream drivers take with the same meaning as sdfat (fs/sdfat/sdfat.c) */
static const char *const exfat_keys[] = {
	"uid", "gid", "umask", "dmask", "fmask", "allow_utime", "iocharset", "errors",
	"discard", "time_offset", NULL
};
static const char *const vfat_keys[] = {
	"uid", "gid", "umask", "dmask", "fmask", "allow_utime", "codepage", "iocharset",
	"shortname", "utf8", "errors", "discard", "time_offset", "tz", "quiet", "showexec",
	"check", "flush", "usefree", "nonumtail", "rodir", "uni_xlate", NULL
};

static bool sdfat_key_in(const char *const *tab, const char *key)
{
	for (; *tab; tab++)
		if (!strcmp(*tab, key))
			return true;
	return false;
}

static void sdfat_free(struct fs_context *fc)
{
	struct sdfat_ctx *ctx = fc->fs_private;
	struct sdfat_opt *o, *n;

	if (!ctx)
		return;
	for (o = ctx->head; o; o = n) {
		n = o->next;
		kfree(o->key);
		kfree(o->val);
		kfree(o);
	}
	kfree(ctx);
	fc->fs_private = NULL;
}

static int sdfat_parse_param(struct fs_context *fc, struct fs_parameter *param)
{
	struct sdfat_ctx *ctx = fc->fs_private;
	struct sdfat_opt *o;
	int ret;

	ret = vfs_parse_fs_param_source(fc, param);
	if (ret != -ENOPARAM)
		return ret;

	if (param->type != fs_value_is_string && param->type != fs_value_is_flag)
		return invalf(fc, "sdfat: unsupported parameter type for '%s'", param->key);

	if (!strcmp(param->key, "fs")) {
		const char *v = param->type == fs_value_is_string ? param->string : "";

		if (!strcmp(v, "exfat"))
			ctx->type = SDFAT_EXFAT;
		else if (!strcmp(v, "vfat") || !strcmp(v, "fat") || !strcmp(v, "msdos"))
			ctx->type = SDFAT_VFAT;
		else if (!strcmp(v, "auto"))
			ctx->type = SDFAT_AUTO;
		else
			return invalf(fc, "sdfat: unknown fs=%s", v);
		return 0;
	}
	if (!strcmp(param->key, "utf8")) {
		ctx->utf8 = true;
		return 0;
	}
	if (!strcmp(param->key, "shortname"))
		ctx->shortname = true;

	o = kzalloc(sizeof(*o), GFP_KERNEL);
	if (!o)
		return -ENOMEM;
	o->key = kstrdup(param->key, GFP_KERNEL);
	if (param->type == fs_value_is_string)
		o->val = kstrdup(param->string, GFP_KERNEL);
	if (!o->key || (param->type == fs_value_is_string && !o->val)) {
		kfree(o->key);
		kfree(o->val);
		kfree(o);
		return -ENOMEM;
	}
	*ctx->tail = o;
	ctx->tail = &o->next;
	return 0;
}

static int sdfat_set(struct fs_context *n, const char *key, const char *val)
{
	return vfs_parse_fs_string(n, key, val, val ? strlen(val) : 0);
}

static int sdfat_forward(struct fs_context *fc, bool exfat, bool silent)
{
	const char *name = exfat ? "exfat" : "vfat";
	const char *const *keys = exfat ? exfat_keys : vfat_keys;
	struct sdfat_ctx *ctx = fc->fs_private;
	struct file_system_type *type;
	struct fs_context *n;
	struct sdfat_opt *o;
	int err;

	if (!fc->source)
		return invalf(fc, "sdfat: no source");

	type = get_fs_type(name);
	if (!type)
		return -ENODEV;
	n = fs_context_for_mount(type, fc->sb_flags | (silent ? SB_SILENT : 0));
	module_put(type->owner);	/* fs_context_for_mount() holds its own reference */
	if (IS_ERR(n))
		return PTR_ERR(n);

	err = sdfat_set(n, "source", fc->source);
	for (o = ctx->head; o && !err; o = o->next) {
		if (!sdfat_key_in(keys, o->key)) {
			/* sdfat-only: smart delay adj_req adj_hid defrag symlink= namecase= ... */
			pr_debug("%s: option '%s' dropped\n", name, o->key);
			continue;
		}
		/* sdfat "utf8" = UTF-8 names whatever iocharset says; exfat spells that iocharset=utf8 */
		if (exfat && ctx->utf8 && !strcmp(o->key, "iocharset"))
			continue;
		err = sdfat_set(n, o->key, o->val);
	}
	if (!err && ctx->utf8)
		err = exfat ? sdfat_set(n, "iocharset", "utf8") : sdfat_set(n, "utf8", NULL);
	/* sdfat keeps the case of 8.3 names (as AOSP vold's vfat "shortname=mixed") */
	if (!err && !exfat && !ctx->shortname)
		err = sdfat_set(n, "shortname", "mixed");
	if (!err)
		err = n->ops->get_tree(n);
	if (!err) {
		if (WARN_ON(!n->root)) {
			err = -EINVAL;
		} else {
			fc->root = n->root;	/* locked superblock + root reference move over */
			n->root = NULL;
		}
	}
	put_fs_context(n);
	return err;
}

static int sdfat_get_tree(struct fs_context *fc)
{
	struct sdfat_ctx *ctx = fc->fs_private;
	int err;

	switch (ctx->type) {
	case SDFAT_EXFAT:
		return sdfat_forward(fc, true, false);
	case SDFAT_VFAT:
		return sdfat_forward(fc, false, false);
	}
	err = sdfat_forward(fc, true, true);
	if (err)
		err = sdfat_forward(fc, false, fc->sb_flags & SB_SILENT);
	return err;
}

static const struct fs_context_operations sdfat_context_ops = {
	.free		= sdfat_free,
	.parse_param	= sdfat_parse_param,
	.get_tree	= sdfat_get_tree,
};

static int sdfat_init_fs_context(struct fs_context *fc)
{
	struct sdfat_ctx *ctx;

	/* remount never comes here: the superblock's type is exfat / vfat */
	if (fc->purpose != FS_CONTEXT_FOR_MOUNT)
		return -EOPNOTSUPP;
	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	ctx->tail = &ctx->head;
	fc->fs_private = ctx;
	fc->ops = &sdfat_context_ops;
	return 0;
}

static struct file_system_type sdfat_fs_type = {
	.owner			= THIS_MODULE,
	.name			= "sdfat",
	.init_fs_context	= sdfat_init_fs_context,
	.kill_sb		= kill_block_super,	/* never used: no superblock has this type */
	.fs_flags		= FS_REQUIRES_DEV,
};

static int __init sdfat_alias_init(void)
{
	return register_filesystem(&sdfat_fs_type);
}

static void __exit sdfat_alias_exit(void)
{
	unregister_filesystem(&sdfat_fs_type);
}

module_init(sdfat_alias_init);
module_exit(sdfat_alias_exit);

MODULE_ALIAS_FS("sdfat");
MODULE_DESCRIPTION("Galaxy A52s: file system type \"sdfat\" forwarded to upstream exfat / vfat");
MODULE_AUTHOR("a52sxq-mainline");
MODULE_LICENSE("GPL");
