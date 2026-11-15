/* layout from the Samsung LinuxLoader (ufdt_apply_multi_overlay: ldp address,size; next at +0x10) */
#include <stdint.h>
struct fdt_entry_node { uint64_t address; uint64_t size; struct fdt_entry_node *next; };
