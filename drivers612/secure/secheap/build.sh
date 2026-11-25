#!/bin/bash
# Builds ONLY qcom_dma_heaps.ko (with soc-repo patch 0025: heap qcom,secure-bitstream, VMID_CP_BITSTREAM)
# out of tree from a copy of bsp612/soc-repo-staging/drivers/dma-buf/heaps, so the staging tree's own
# objects / .ko and bsp612/out/dist stay untouched. Output: drivers612/secure/out-secheap/qcom_dma_heaps.ko
# (unstripped) + qcom_dma_heaps.stripped.ko (llvm-strip --strip-debug, as the ramdisk stages).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); BSP=$(cd "$HERE/../../../bsp612" && pwd)
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
SOC=$BSP/soc-repo-staging; OUT=$HERE/../out-secheap; B=$OUT/build
export KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
grep -q 'qcom,secure-bitstream' "$SOC/drivers/dma-buf/heaps/qcom_dma_heap.c" || { echo "patch 0025 not applied in $SOC" >&2; exit 1; }
rm -rf "$B"; mkdir -p "$B"
cp "$SOC"/drivers/dma-buf/heaps/*.[ch] "$SOC/drivers/dma-buf/heaps/Makefile" "$B/"
# Kbuild wins over Makefile: the soc-repo headers ahead of ACK's, as soc-repo-staging/build/Makefile does
cat > "$B/Kbuild" <<K
LINUXINCLUDE := -I$SOC/. -I$SOC/arch/arm64/include -I$SOC/include -I$SOC/include/uapi -I$SOC/include/linux \$(LINUXINCLUDE) -I$BSP/kernel/
include \$(src)/Makefile
obj-m := qcom_dma_heaps.o
K
make -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" KCONFIG_EXT_PREFIX="$BSP/soc-repo/" \
  KERNEL_SRC="$BSP/kernel" M="$B" KBUILD_EXTRA_SYMBOLS="$SOC/build/Module.symvers" -j20 modules > "$OUT/build.log" 2>&1 || { grep -B2 -A6 "error" "$OUT/build.log" | head -40; exit 1; }
cp "$B/qcom_dma_heaps.ko" "$OUT/qcom_dma_heaps.ko"
"$CLANG/llvm-strip" --strip-debug -o "$OUT/qcom_dma_heaps.stripped.ko" "$B/qcom_dma_heaps.ko"
"$CLANG/llvm-readelf" -p .modinfo "$OUT/qcom_dma_heaps.ko" | grep -E "depends|vermagic|name" || true
strings "$OUT/qcom_dma_heaps.ko" | grep -c 'qcom,secure-bitstream'
( cd "$OUT" && sha256sum qcom_dma_heaps.ko qcom_dma_heaps.stripped.ko | tee SHA256SUMS )
