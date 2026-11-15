/* SPDX-License-Identifier: GPL-2.0-only */
/* host test only: -include this to run qmi-nas.c against test/fake-modem.c (see there) */
#include <net/if.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
int fake_socket(int, int, int);
int fake_close(int);
int fake_getsockname(int, struct sockaddr *, socklen_t *);
ssize_t fake_sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
ssize_t fake_recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
ssize_t fake_recv(int, void *, size_t, int);
int fake_poll(struct pollfd *, nfds_t, int);
int fake_ioctl(int, unsigned long, ...);
unsigned fake_if_nametoindex(const char *);
int fake_usleep(unsigned);
#define socket fake_socket
#define close fake_close
#define getsockname fake_getsockname
#define sendto fake_sendto
#define recvfrom fake_recvfrom
#define recv fake_recv
#define poll fake_poll
#define ioctl fake_ioctl
#define if_nametoindex fake_if_nametoindex
#define usleep fake_usleep
