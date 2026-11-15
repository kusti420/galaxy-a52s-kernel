#!/bin/sh
# KEXEC_BASE for the 6.18 Android test: the 6.12 Android tree (out-ack/kx/android-r02.dtb, made by
# kexec/mkandroidtree.sh; the vendor DT does not depend on the kernel version) + one node:
#   /reserved-memory/a52ram@f0be0000   no-map, 128 KiB, compatible "a52,ramcon"
# so that the 6.18 kernel can be started with earlycon=a52ram,0xf0be0000 (ack/arch/arm64/kernel/
# a52ram.c, built into the survey GKI Image): its earliest log lands there and the harness shows
# it as /proc/a52ram (kx-cycle prints it after a failed jump). The 6.12 tree shortens ramoops to
# 0xf0b00000+0xe0000 for exactly this area but never reserved it (6.12 has no a52ram), so without
# this node the early console would write into memory the kernel may hand out.
# Test safety (2026-11-14): the USB controller node (/soc/ssusb@a600000/dwc3@a600000) also gets
#   qcom,iommu-faults = "non-fatal"
# The forked arm_smmu (soc-repo arm-smmu.c arm_smmu_context_fault) BUG()s on any unhandled
# context fault unless the client's DT node says "non-fatal" (parsed in
# arm_smmu_setup_default_domain). With it the fault is still printed in full (FAR/FSR/FSYNR/SID,
# soft + ATOS translation; ratelimited) and the stalled transaction is terminated, so a dwc3
# fault no longer takes the telnet/adb session down with it. A52_SMMU_FATAL=1 leaves it out.
# Usage: bsp618/android/mkdtb-618.sh [in.dtb [out.dtb]]   Offline only.
set -e
cd "$(dirname "$0")/../.."
IN=${1:-out-ack/kx/android-r02.dtb}; OUT=${2:-bsp618/android/out/android-r02-618.dtb}
mkdir -p "$(dirname "$OUT")"
# 5.4 sysfs paths (research/sepolicy/PATHS.md): kexec/mkandroidtree.sh already did this to its
# output; applied again (idempotent) so an older input cannot give a 6.18 tree in the other
# layout. Needs the 0009 geni modules (bsp612/patches/soc-repo/0009; 6.18 ramdisk a9 and later).
python3 -I drivers612/boarddt/tools/sysfscompat.py apply -q "$IN" "$OUT"
N=/reserved-memory/a52ram@f0be0000
fdtget -l "$OUT" /reserved-memory | grep -qi '^a52ram' && { echo "$IN already has an a52ram node" >&2; exit 1; }
[ "$(fdtget "$OUT" /reserved-memory '#address-cells') $(fdtget "$OUT" /reserved-memory '#size-cells')" = "2 2" ] || { echo "unexpected cells" >&2; exit 1; }
# nothing else may claim 0xf0be0000..0xf0c00000
fdtget -t x "$OUT" /reserved-memory/ramoops@F0B00000 reg | grep -qx "0 f0b00000 0 e0000" || { echo "ramoops is not 0xf0b00000+0xe0000" >&2; exit 1; }
fdtput -c "$OUT" $N
fdtput -t s "$OUT" $N compatible "a52,ramcon"
fdtput -t x "$OUT" $N reg 0 0xf0be0000 0 0x20000
fdtput -t s "$OUT" $N no-map ""
U=/soc/ssusb@a600000/dwc3@a600000
if [ "${A52_SMMU_FATAL:-0}" != 1 ]; then
	fdtget "$OUT" $U iommus >/dev/null || { echo "$U has no iommus" >&2; exit 1; }
	fdtput -t s "$OUT" $U qcom,iommu-faults non-fatal
	echo "$U: qcom,iommu-faults = $(fdtget "$OUT" $U qcom,iommu-faults) (SMMU faults logged, not fatal)"
fi
echo "$OUT: $(stat -c %s "$OUT") bytes ($(fdtget -t x "$OUT" $N reg))"
