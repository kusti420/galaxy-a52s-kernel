/* a52sxq 6.12 port shims for Samsung's 5.4 adsp_factory sources (force-included by Kbuild). */
#ifndef A52_ADSP_FACTORY_COMPAT612_H
#define A52_ADSP_FACTORY_COMPAT612_H
#include <linux/fs.h>
#include <linux/rtc.h>
#include <linux/timekeeping.h>
#include <linux/string.h>
/* set_fs() is gone (5.10+): kernel buffers go through kernel_read()/kernel_write() */
typedef int mm_segment_t;
#define KERNEL_DS 0
#define get_fs() (0)
#define set_fs(x) ((void)(x))
#define vfs_read(f, buf, n, pos) kernel_read(f, (void *)(buf), n, pos)
#define vfs_write(f, buf, n, pos) kernel_write(f, (const void *)(buf), n, pos)
/* y2038 time API */
#define timespec timespec64
#define getnstimeofday(ts) ktime_get_real_ts64(ts)
#define rtc_time_to_tm(t, tm) rtc_time64_to_tm(t, tm)
#ifndef strlcpy
#define strlcpy(d, s, n) strscpy(d, s, n)
#endif
/*
 * One module instead of built-in objects: every file's initcall becomes a52_init_<file>() /
 * a52_exit_<file>(), called by main.c in the 5.4 link order (Kbuild passes -DA52_OBJ=<file>).
 */
#include <linux/module.h>
#include <linux/init.h>
#ifdef A52_OBJ
#define A52_CAT_(a, b) a##b
#define A52_CAT(a, b) A52_CAT_(a, b)
#undef module_init
#undef module_exit
#undef subsys_initcall
#define module_init(fn) int __init A52_CAT(a52_init_, A52_OBJ)(void) { return fn(); }
#define module_exit(fn) void __exit A52_CAT(a52_exit_, A52_OBJ)(void) { fn(); }
#define subsys_initcall(fn) module_init(fn)
#endif
#endif
