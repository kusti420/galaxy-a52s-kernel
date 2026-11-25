// secheap: list /dev/dma_heap and allocate/free one buffer from a named heap (static arm64).
// For the secure heaps (qcom,secure-pixel / -non-pixel / -bitstream) an allocation = hyp_assign of
// system pages to the CP VMID; a bad one can reset the SoC, so run it in a kexec rehearsal first.
//   secheap list
//   secheap alloc <heap> <bytes[k|m]> [--hold <s>]
//   secheap loop <heap> <bytes> <n> [--hold <s>]   n allocations in a row (stress)
//   secheap seq [--hold <s>]     qcom,system, secure-pixel, secure-non-pixel, secure-bitstream, 1 MiB each
// Every step is printed and fsync'ed to stdout BEFORE the ioctl so the last line survives a reset.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct dma_heap_allocation_data { uint64_t len; uint32_t fd; uint32_t fd_flags; uint64_t heap_flags; };
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void say(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
	fflush(stdout); fsync(1);
}

static int list(void)
{
	DIR *d = opendir("/dev/dma_heap"); struct dirent *e; int n = 0;
	if (!d) { say("list: /dev/dma_heap: %s\n", strerror(errno)); return 1; }
	while ((e = readdir(d))) if (e->d_name[0] != '.') { say("heap %s\n", e->d_name); n++; }
	closedir(d); say("heaps: %d\n", n); return 0;
}

static int alloc(const char *heap, uint64_t len, int hold)
{
	char p[256]; struct dma_heap_allocation_data a = { .len = len, .fd_flags = O_RDWR | O_CLOEXEC };
	snprintf(p, sizeof p, "/dev/dma_heap/%s", heap);
	int h = open(p, O_RDONLY | O_CLOEXEC);
	if (h < 0) { say("alloc %s: open: %s\n", heap, strerror(errno)); return 1; }
	say("alloc %s %llu bytes: calling DMA_HEAP_IOCTL_ALLOC\n", heap, (unsigned long long)len);
	if (ioctl(h, DMA_HEAP_IOCTL_ALLOC, &a) < 0) { say("alloc %s: FAILED: %s (errno %d)\n", heap, strerror(errno), errno); close(h); return 1; }
	say("alloc %s: fd %u\n", heap, a.fd);
	if (hold > 0) { say("holding %d s\n", hold); sleep(hold); }
	say("free %s: closing fd (hyp unassign or return to the secure pool)\n", heap);
	close(a.fd); close(h);
	say("ok %s\n", heap);
	return 0;
}

static uint64_t size(const char *s)
{
	char *e; uint64_t v = strtoull(s, &e, 0);
	if (*e == 'k' || *e == 'K') v <<= 10; else if (*e == 'm' || *e == 'M') v <<= 20;
	return v;
}

int main(int argc, char **argv)
{
	int hold = 0;
	for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "--hold")) hold = atoi(argv[i + 1]);
	if (argc >= 2 && !strcmp(argv[1], "list")) return list();
	if (argc >= 4 && !strcmp(argv[1], "alloc")) return alloc(argv[2], size(argv[3]), hold);
	if (argc >= 2 && !strcmp(argv[1], "seq")) {
		static const char *const h[] = { "qcom,system", "qcom,secure-pixel", "qcom,secure-non-pixel", "qcom,secure-bitstream" };
		int bad = 0; list();
		for (unsigned i = 0; i < 4; i++) { if (alloc(h[i], 1 << 20, hold)) { bad++; break; } }
		say(bad ? "seq: FAILED\n" : "seq: all ok\n"); return bad;
	}
	if (argc >= 5 && !strcmp(argv[1], "loop")) {	/* the 11-12 resets came after ~8 secure allocations */
		int n = atoi(argv[4]);
		for (int i = 1; i <= n; i++) { say("loop %d/%d\n", i, n); if (alloc(argv[2], size(argv[3]), hold)) return 1; }
		say("loop: all ok\n"); return 0;
	}
	fprintf(stderr, "usage: secheap list | alloc <heap> <bytes[k|m]> [--hold s] | seq [--hold s] | loop <heap> <bytes> <n> [--hold s]\n");
	return 2;
}
