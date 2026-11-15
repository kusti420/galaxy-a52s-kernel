#!/bin/bash
# dt/ipa-iova-fix.sh <dtb>: fixes the IPA SMMU IOVA windows of drivers612/conn/data/a52sxq-ipa.dtsi
# in place (idempotent). Used by dt/mkmodemtree.sh and drivers612/realboot/build-realboot.sh
# (MODEM=1).
#
# The bug (POLISH.md "IPA DT: 2+2 cells"): ipa_{ap,uc}_iommu_region_partition hold
#   iommu-addresses = <&ipa_smmu_X 0x0 0x0 0x0 0x20000000>, <&ipa_smmu_X 0x0 0x40000000 0x0 0xc0000000>,
#                     <&ipa_smmu_X 0x1 0x0 0xf 0x0>
# (2+2 cells: reserve everything except the 5.4 pool 0x20000000 + 512 MiB). of_iommu_get_resv_regions()
# -> of_translate_dma_region() takes the cell counts from the parent of the cb node = the IPA node,
# which has no #address-cells/#size-cells, so /soc's 1+1 apply: the property is read as
# (ph 0 0) (ph 0 0x40000000) (ph 1 0) with the other words skipped as unknown phandles. Result on
# 6.12 (every modem run, e.g. logs/kx-m1c-p1-p1-162401): "ipa_smmu_ap: Cannot reserve IOVA region
# of 0 size" (x6, uc x4) and ONE reservation [0, 0x40000000): the fastmap AP domain then allocates
# from [0x40000000, 4 GiB) (qcom_iommu_get_fast_iova_range), the range where the IPA driver
# identity-maps SMEM (0x80900000, filter tables) and maps its own buffers from va_end = 0x40000000
# upwards (ipa_uc_wdi.c next_addr): DMA API IOVAs and the driver's fixed maps can collide. 5.4 kept
# the DMA API inside the pool.
# Fix: #address-cells = <2>, #size-cells = <2> on the IPA node (the cells the property was written
# for) and only the two entries below 4 GiB. The third one cannot be kept: translating
# 0x1_0000_0000 up through /soc (#address-cells 1) truncates it to 0 (of_bus_default_translate), and
# [0, 0xf_0000_0000) would then reserve the window too. Fastmap ignores IOVAs above 4 GiB anyway
# (fastmap_max_iova = SZ_4G - 1), so the AP range becomes exactly [0x20000000, 0x3fffffff] as on 5.4.
# The IPA node's children have no reg/ranges, so the new cell counts change nothing else.
set -euo pipefail
D=${1:?dtb}
fail() { echo "ipa-iova-fix: CHECK FAILED: $*" >&2; exit 1; }
I=/soc/qcom,ipa@1e00000
fdtget "$D" $I compatible | grep -qx qcom,ipa || fail "no $I"
for c in $(fdtget -l "$D" $I); do
	fdtget "$D" "$I/$c" reg >/dev/null 2>&1 && fail "$I/$c has a reg: new cell counts would change it"
	fdtget "$D" "$I/$c" ranges >/dev/null 2>&1 && fail "$I/$c has ranges"
done
fdtget "$D" $I dma-ranges >/dev/null 2>&1 && fail "$I has dma-ranges (translation assumptions)"
fdtget "$D" /soc dma-ranges >/dev/null 2>&1 && fail "/soc has dma-ranges (translation assumptions)"
[ "$(fdtget "$D" /soc '#address-cells') $(fdtget "$D" /soc '#size-cells')" = "1 1" ] || fail "/soc cells are not 1 1"
fdtput -t u "$D" $I '#address-cells' 2
fdtput -t u "$D" $I '#size-cells' 2
for cb in ap uc; do
	P=/soc/ipa_${cb}_iommu_region_partition
	PH=$(printf '%x' "$(fdtget "$D" $I/ipa_smmu_$cb phandle)")
	[ "$(fdtget "$D" $I/ipa_smmu_$cb memory-region)" = "$(fdtget "$D" $P phandle)" ] || fail "ipa_smmu_$cb memory-region is not $P"
	CUR=$(fdtget -t x "$D" $P iommu-addresses)
	OLD="$PH 0 0 0 20000000 $PH 0 40000000 0 c0000000 $PH 1 0 f 0"
	NEW="$PH 0 0 0 20000000 $PH 0 40000000 0 c0000000"
	case "$CUR" in "$OLD") fdtput -t x "$D" $P iommu-addresses $NEW;; "$NEW") ;; *) fail "$P iommu-addresses unexpected: $CUR";; esac
	[ "$(fdtget -t x "$D" $P iommu-addresses)" = "$NEW" ] || fail "$P not rewritten"
	[ "$(fdtget -t x "$D" $I/ipa_smmu_$cb qcom,ipa-dma-addr-pool)" = "20000000 20000000" ] || fail "ipa_smmu_$cb pool is not 0x20000000+0x20000000"
done
echo "ipa-iova-fix: $I #address-cells/#size-cells 2/2; ipa_ap/uc iova reservations [0,0x20000000) + [0x40000000,4G) (window 0x20000000+512M, as 5.4)"
