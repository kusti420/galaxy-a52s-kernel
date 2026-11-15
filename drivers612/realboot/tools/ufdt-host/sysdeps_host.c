/* Host sysdeps for the ABL's old libufdt (donors/abl-edk2/EmbeddedPkg/Library/LibUfdt):
 * same 5 MiB bump allocator as libufdt_sysdeps_vendor.c (no alignment, no free, NULL when
 * exhausted), printing to stderr instead of the ABL's silent dto_print(). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "libufdt_sysdeps.h"
#define PRE_ALLOC_BUFFER_SZ (5 * 1024 * 1024)
static char *buffer; static size_t ssize; size_t ufdt_host_peak;
int dto_print(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vfprintf(stderr, fmt, ap); va_end(ap); return r; }
void dto_qsort(void *b, size_t n, size_t s, int (*c)(const void *, const void *)) { qsort(b, n, s, c); }
void *pre_overlay_malloc() { buffer = malloc(PRE_ALLOC_BUFFER_SZ); memset(buffer, 0xa5, PRE_ALLOC_BUFFER_SZ); return buffer; }
void post_overlay_free() { }
void *dto_malloc(size_t size) {
  if ((SIZE_MAX - ssize) < size || ssize + size > PRE_ALLOC_BUFFER_SZ) { fprintf(stderr, "dto_malloc: 5 MiB pre-buffer EXHAUSTED (%zu + %zu)\n", ssize, size); return NULL; }
  void *r = buffer + ssize; ssize += size; ufdt_host_peak = ssize; return r;
}
void dto_free(void *p) { (void)p; }
char *dto_strdup(const char *s) { size_t l = strlen(s) + 1; char *r = dto_malloc(l); if (!r) return NULL; memcpy(r, s, l); return r; }
char *dto_strchr(const char *s, int c) { return strchr(s, c); }
unsigned long int dto_strtoul(const char *n, char **e, int b) { return strtoul(n, e, b); }
size_t dto_strlen(const char *s) { return strlen(s); }
void *dto_memcpy(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
int dto_strcmp(const char *a, const char *b) { return strcmp(a, b); }
int dto_strncmp(const char *a, const char *b, size_t n) { return strncmp(a, b, n); }
void *dto_memchr(const void *s, int c, size_t n) { return memchr(s, c, n); }
void *dto_memset(void *s, int c, size_t n) { return memset(s, c, n); }
