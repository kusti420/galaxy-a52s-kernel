#!/bin/bash
# zram.ko from the unmodified bsp612/kernel/drivers/block/zram sources with ONE change: the default compressor is
# lz4 instead of CONFIG_ZRAM_DEF_COMP ("lzo-rle"), as CONFIG_ZRAM_DEF_COMP_LZ4=y would set it (SPEC/03 G13: One UI
# wants lz4 and 6.12 falls back to the default on every zram reset). Same backends as the GKI config (lzo/lzo-rle,
# lz4, zstd) + the Android ioctl. External module, no GKI rebuild.
#   drivers612/samsung-oneui/zram-lz4/mk.sh   -> out/zram.ko (stripped)
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$D/../../.." && pwd); K=$TOP/bsp612/kernel/drivers/block/zram
rm -rf "$D/src"; mkdir -p "$D/src"
cp "$K"/*.c "$K"/*.h "$D/src/"
( cd "$K" && sha256sum *.c *.h | sha256sum | cut -c1-16 ) > "$D/src.sha"
grep -q '^static const char \*default_compressor = CONFIG_ZRAM_DEF_COMP;$' "$D/src/zram_drv.c"
sed -i 's/^static const char \*default_compressor = CONFIG_ZRAM_DEF_COMP;$/static const char *default_compressor = "lz4"; \/* a52sxq: CONFIG_ZRAM_DEF_COMP_LZ4 *\//' "$D/src/zram_drv.c"
grep -q 'default_compressor = "lz4"' "$D/src/zram_drv.c"
cat > "$D/src/Kbuild" <<'KB'
obj-m := zram.o
zram-y := zcomp.o zram_drv.o backend_lzorle.o backend_lzo.o backend_lz4.o backend_zstd.o zram_ioctl.o
KB
# the shipped zram.ko is the GKI build (out/gki: WRITEBACK, MULTI_COMP, ZSTD, ANDROID_IOCTL); out/lahaina has none of them
BUILD_O=$TOP/bsp612/out/gki "$D/../build.sh" "$D/src"
mkdir -p "$D/out"; cp "$D/src/out/zram.ko" "$D/out/zram.ko"
( cd "$D/out" && sha256sum zram.ko > SHA256SUMS ); cat "$D/out/SHA256SUMS"
