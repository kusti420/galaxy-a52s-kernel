/* asshell: from root adbd (LineageOS userdebug, no su binary) run /system/bin/sh as the shell user:
 * groups of adbd's shell, gid/uid 2000, SELinux context u:r:shell:s0 (dyntransition from u:r:su:s0),
 * then exec sh with the given arguments (stdin = the script when none). The suite's app_process tools
 * need the shell package identity (uid 2000). Static, no libc.
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -o asshell asshell.c */
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define NR_openat 56
#define NR_close 57
#define NR_write 64
#define NR_exit 93
#define NR_setresuid 147
#define NR_setresgid 149
#define NR_setgroups 159
#define NR_execve 221
static void die(const char *m, long n) { sc(NR_write, 2, (long)m, n, 0); sc(NR_exit, 1, 0, 0, 0); }
void start_c(long *sp) {
	long argc = sp[0]; char **argv = (char **)(sp + 1); char **envp = argv + argc + 1;
	/* adbd's supplementary groups for the shell user (system/core adb daemon) */
	static const unsigned int groups[] = { 1004, 1007, 1011, 1015, 1028, 1078, 1079, 3001, 3002, 3003, 3006, 3009, 3011, 3012 };
	static const char con[] = "u:r:shell:s0";
	char *sh = "/system/bin/sh";
	long fd;
	/* the attr file must be opened while still root (after setuid /proc/self is root-owned: not dumpable);
	 * the uid must change before the context does (the shell domain has no setuid capability) */
	fd = sc(NR_openat, -100, (long)"/proc/self/attr/current", 1 /* O_WRONLY */, 0);
	if (fd < 0) die("asshell: open attr\n", 19);
	if (sc(NR_setgroups, sizeof(groups) / sizeof(groups[0]), (long)groups, 0, 0)) die("asshell: setgroups\n", 19);
	if (sc(NR_setresgid, 2000, 2000, 2000, 0)) die("asshell: setresgid\n", 19);
	if (sc(NR_setresuid, 2000, 2000, 2000, 0)) die("asshell: setresuid\n", 19);
	if (sc(NR_write, fd, (long)con, sizeof(con) - 1, 0) != sizeof(con) - 1) die("asshell: setcon\n", 16);
	sc(NR_close, fd, 0, 0, 0);
	argv[0] = sh;
	sc(NR_execve, (long)sh, (long)argv, (long)envp, 0);
	die("asshell: exec\n", 14);
}
__asm__(".global _start\n_start:\n mov x0, sp\n bl start_c\n");
