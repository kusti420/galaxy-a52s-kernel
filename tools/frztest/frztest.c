// frztest: 3 threads for the cgroup-v1 freezer vs system-resume test (SPEC/07, ART SuspendAll timeouts).
//   frztest <counter file>   -> prints "pid P tids futex=T0 epoll=T1 busy=T2", runs until killed.
// counters (3 x u64, mmap'd shared file): [0] futex sleeper (pthread_cond_timedwait, 1 s), [1] epoll_wait on a
// 1 s timerfd, [2] userspace busy loop (counts ~every 100 ms of spinning). Read with: od -A n -t u8 <file>
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/syscall.h>
static volatile uint64_t *c; static volatile int tid[3];
static void *t_futex(void *a) {
	pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER; pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
	tid[0] = syscall(SYS_gettid); pthread_mutex_lock(&m);
	for (;;) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1;
		pthread_cond_timedwait(&cv, &m, &ts); c[0]++; }
}
static void *t_epoll(void *a) {
	int ep = epoll_create1(0), tf = timerfd_create(CLOCK_MONOTONIC, 0);
	struct itimerspec it = { {1, 0}, {1, 0} }; struct epoll_event ev = { .events = EPOLLIN };
	tid[1] = syscall(SYS_gettid); timerfd_settime(tf, 0, &it, 0); epoll_ctl(ep, EPOLL_CTL_ADD, tf, &ev);
	for (;;) { uint64_t n; if (epoll_wait(ep, &ev, 1, -1) > 0) { if (read(tf, &n, 8) == 8) c[1]++; } }
}
static void *t_busy(void *a) {
	tid[2] = syscall(SYS_gettid);
	for (;;) { volatile uint64_t i; for (i = 0; i < 60000000ull; i++) ; c[2]++; }
}
int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: frztest <counter file>\n"); return 2; }
	int fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644); if (fd < 0 || ftruncate(fd, 4096)) { perror("file"); return 2; }
	c = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (c == MAP_FAILED) { perror("mmap"); return 2; }
	pthread_t t; pthread_create(&t, 0, t_futex, 0); pthread_create(&t, 0, t_epoll, 0); pthread_create(&t, 0, t_busy, 0);
	while (!tid[0] || !tid[1] || !tid[2]) usleep(1000);
	printf("pid %d tids futex=%d epoll=%d busy=%d\n", getpid(), tid[0], tid[1], tid[2]); fflush(stdout);
	for (;;) pause();
}
