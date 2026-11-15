/* Host harness: runs the Qualcomm ABL's own libufdt (donors/abl-edk2, EmbeddedPkg/Library/LibUfdt)
 * on a base dtb and overlays, with its error messages visible, to reproduce what the phone's
 * bootloader does in ApplyOverlay. Usage: ufdt-host base.dtb overlay1.dtbo [overlay2.dtbo ...] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libfdt.h"
#include "ufdt_overlay.h"
static void *slurp(const char *p, size_t *n) {
	FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
	fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f);
	void *b = malloc(*n + 0x100000); if (fread(b, 1, *n, f) != *n) exit(2); fclose(f); return b;
}
int main(int argc, char **argv) {
	size_t n; void *base = slurp(argv[1], &n);
	struct fdt_header *m = ufdt_install_blob(base, n);
	if (!m) { fprintf(stderr, "install blob failed\n"); return 1; }
	HARNESS_LIST
	struct fdt_header *out = ufdt_apply_multi_overlay(m, fdt_totalsize(m), HARNESS_HEAD);
	if (!out) { fprintf(stderr, "RESULT: ufdt apply overlay FAILED\n"); return 1; }
	fprintf(stderr, "RESULT: ok, merged size %u\n", fdt_totalsize(out));
	if (getenv("OUT")) { FILE *f = fopen(getenv("OUT"), "wb"); fwrite(out, 1, fdt_totalsize(out), f); fclose(f); }
	return 0;
}
