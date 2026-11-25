// SPDX-License-Identifier: GPL-2.0-only
/*
 * SPEC/07 test process: the shape of an ART app for the freezer. Thread "sleeper" (like HeapTaskDaemon)
 * sleeps 100 ms in the kernel in a loop and writes "<its loops> <spinner loops>" to the file argv[1].
 * Thread "spinner" (like a thread in Java code) runs in user space and counts. In a v1 FROZEN cgroup
 * the sleeper is frozen in place and the spinner in the refrigerator.
 */
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile unsigned long spins;

static void *spinner(void *arg)
{
	for (;;)
		spins++;
	return NULL;
}

int main(int argc, char **argv)
{
	pthread_t t;
	unsigned long loops = 0;
	char buf[64];
	int fd = open(argc > 1 ? argv[1] : "/halfthaw.out", O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0 || pthread_create(&t, NULL, spinner, NULL))
		return 1;
	for (;;) {
		struct timespec ts = { 0, 100 * 1000 * 1000 };

		nanosleep(&ts, NULL);
		snprintf(buf, sizeof(buf), "%lu %lu\n", ++loops, spins);
		pwrite(fd, buf, strlen(buf) + 1, 0);
	}
}
