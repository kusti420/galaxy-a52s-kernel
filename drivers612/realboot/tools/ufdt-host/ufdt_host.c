/* ufdt-host MAIN.dtb OVL1.dtbo [OVL2.dtbo ...]
 * Runs the ABL's ufdt_install_blob + ufdt_apply_multi_overlay (exactly what ApplyOverlay in
 * the Samsung LinuxLoader does: out buffer = main + sum(overlays)) and reports the slack left
 * in the out buffer. The ABL bug: when the re-serialised tree does not fit, _fdt_grab_space()
 * returns NULL, prop->fdt_tag_ptr = NULL, and ufdt_node_dict_add() dereferences it. Here that
 * is a SIGSEGV (same NULL deref), caught and reported as ABL-CRASH. Exit 0 = fits, 2 = crash. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libfdt.h>
#include "libufdt.h"
#include "ufdt_overlay.h"
extern size_t ufdt_host_peak;
static void segv(int s) { (void)s; static const char m[] = "RESULT ABL-CRASH: NULL deref while re-serialising (out buffer too small) = data abort in the ABL, no kernel\n"; write(1, m, sizeof m - 1); _exit(2); }
static void *rd(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(1); } fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f); void *b = malloc(*n); if (fread(b, 1, *n, f) != *n) exit(1); fclose(f); return b; }
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s main.dtb overlay.dtbo...\n", argv[0]); return 1; }
  signal(SIGSEGV, segv);
  size_t mn; void *m = rd(argv[1], &mn);
  struct fdt_entry_node *head = NULL, **tail = &head; size_t ovl = 0;
  for (int i = 2; i < argc; i++) {
    size_t n; void *o = rd(argv[i], &n);
    struct fdt_entry_node *e = calloc(1, sizeof *e); e->address = (uint64_t)(uintptr_t)o; e->size = fdt_totalsize(o);
    ovl += e->size; *tail = e; tail = &e->next;
  }
  pre_overlay_malloc();
  struct fdt_header *t = ufdt_install_blob(m, fdt_totalsize(m));
  if (!t) { printf("RESULT install-blob failed\n"); return 1; }
  printf("main totalsize %#x, overlays %#zx, out buffer %#zx\n", fdt_totalsize(m), ovl, fdt_totalsize(m) + ovl);
  struct fdt_header *r = ufdt_apply_multi_overlay(t, fdt_totalsize(t), head);
  if (!r) { printf("RESULT apply failed (ABL: \"ApplyOverlay: ufdt apply overlay failed\" -> Download mode)\n"); return 3; }
  unsigned used = fdt_off_dt_struct(r) + fdt_size_dt_struct(r) + fdt_size_dt_strings(r);
  printf("merged: totalsize %#x struct %#x strings %#x used %#x -> SLACK %d bytes; pre-buffer used %zu KiB of 5120\n",
         fdt_totalsize(r), fdt_size_dt_struct(r), fdt_size_dt_strings(r), used, (int)(fdt_totalsize(r) - used), ufdt_host_peak >> 10);
  if (argc > 0 && getenv("UFDT_OUT")) { FILE *f = fopen(getenv("UFDT_OUT"), "wb"); fwrite(r, 1, fdt_totalsize(r), f); fclose(f); }
  printf("RESULT fits\n");
  return 0;
}
