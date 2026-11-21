/*
 * wakeloop: a periodic timerfd watched by an EPOLLWAKEUP epoll set, as an app holding a "[timerfd]"
 * wakeup source would have it. Test for the daily phone's AOD loop (11-21: every ~0.1 s s2idle sleep
 * ended with "Pending Wakeup Sources: [timerfd]"): with a CLOCK_MONOTONIC (or CLOCK_BOOTTIME)
 * timerfd the kernel's s2idle must freeze the timer, so off the cable the phone should still sleep
 * long; if suspends end every <period> with [timerfd], the 6.12 s2idle path lets non-wake timers
 * fire during suspend.
 *   wakeloop <period_ms> <seconds> [clock: 1 MONOTONIC (default) | 7 BOOTTIME | 9 BOOTTIME_ALARM]
 * Prints one line per expiry: CLOCK_MONOTONIC and CLOCK_BOOTTIME time and the expiry count.
 * Needs CAP_BLOCK_SUSPEND for EPOLLWAKEUP (run as root); without it the flag is dropped silently.
 * Build: clang --target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -o wakeloop wakeloop.c
 */
typedef unsigned long u64;
typedef long s64;
struct timespec { s64 tv_sec; s64 tv_nsec; };
struct itimerspec { struct timespec it_interval; struct timespec it_value; };
struct epoll_event { unsigned int events; u64 data; } __attribute__((packed));

static long sys(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
#define SYS_write 64
#define SYS_read 63
#define SYS_exit 93
#define SYS_clock_gettime 113
#define SYS_epoll_create1 20
#define SYS_epoll_ctl 21
#define SYS_epoll_pwait 22
#define SYS_timerfd_create 85
#define SYS_timerfd_settime 86
#define EPOLLIN 1u
#define EPOLLWAKEUP (1u << 29)

static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void out(const char *s) { sys(SYS_write, 1, (long)s, slen(s), 0, 0); }
static void num(long v)
{
	char b[24]; int i = 23; int neg = v < 0; b[i] = 0;
	if (neg) v = -v;
	do { b[--i] = '0' + v % 10; v /= 10; } while (v);
	if (neg) b[--i] = '-';
	out(b + i);
}
static long atol_(const char *s) { long v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }
static long now_ms(int clk) { struct timespec t; sys(SYS_clock_gettime, clk, (long)&t, 0, 0, 0); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }

void __attribute__((noreturn)) main_(long argc, char **argv)
{
	long period = argc > 1 ? atol_(argv[1]) : 600, secs = argc > 2 ? atol_(argv[2]) : 60;
	int clk = argc > 3 ? (int)atol_(argv[3]) : 1;
	int tfd = sys(SYS_timerfd_create, clk, 0, 0, 0, 0);
	int ep = sys(SYS_epoll_create1, 0, 0, 0, 0, 0);
	struct itimerspec its = { { period / 1000, (period % 1000) * 1000000 }, { period / 1000, (period % 1000) * 1000000 } };
	struct epoll_event ev = { EPOLLIN | EPOLLWAKEUP, 0 };
	long t_end = now_ms(1) + secs * 1000, n = 0;
	if (tfd < 0 || ep < 0) { out("wakeloop: create failed\n"); sys(SYS_exit, 1, 0, 0, 0, 0); }
	if (sys(SYS_timerfd_settime, tfd, 0, (long)&its, 0, 0) < 0) { out("wakeloop: settime failed\n"); sys(SYS_exit, 1, 0, 0, 0, 0); }
	if (sys(SYS_epoll_ctl, ep, 1 /* ADD */, tfd, (long)&ev, 0) < 0) { out("wakeloop: epoll_ctl failed\n"); sys(SYS_exit, 1, 0, 0, 0, 0); }
	out("wakeloop: period "); num(period); out(" ms clock "); num(clk); out(" EPOLLWAKEUP\n");
	while (now_ms(1) < t_end) {
		struct epoll_event got; u64 cnt = 0;
		long r = sys(SYS_epoll_pwait, ep, (long)&got, 1, 5000, 0);
		if (r <= 0) continue;
		sys(SYS_read, tfd, (long)&cnt, 8, 0, 0);
		n++;
		out("tick "); num(n); out(" mono_ms "); num(now_ms(1)); out(" boot_ms "); num(now_ms(7));
		out(" expirations "); num((long)cnt); out("\n");
	}
	out("wakeloop: done, "); num(n); out(" ticks\n");
	sys(SYS_exit, 0, 0, 0, 0, 0);
	for (;;) ;
}

__asm__(".global _start\n_start:\n ldr x0, [sp]\n add x1, sp, #8\n bl main_\n");
