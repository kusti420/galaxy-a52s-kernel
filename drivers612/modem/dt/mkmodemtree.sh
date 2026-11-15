#!/bin/bash
# dt/mkmodemtree.sh <in.dtb> <out.dtb>: the Android-on-6.12 test tree with the modem ON.
# Input: the tree kexec/mkandroidtree.sh makes (default out-ack/kx/android-r02.dtb; read only).
# Equivalent to "MODEM=1 kexec/mkandroidtree.sh" plus the modem fix-ups below, so that script
# (which also regenerates other agents' overlays) need not be run from here.
#
# Changes, each against the phone's 5.4 tree (downstream-dt/a52sxq-r02.dts) and its 5.4 kernel:
#  1. &modem_pas: status okay (mkandroidtree.sh disables it unless MODEM=1).
#  2. memshare client_4 (Samsung, client-id 3 = DHMS_MEM_CLIENT_MODEM, the modem's CP RAM-log
#     buffer): status disabled, so client id 3 is not registered at all. That is what 5.4 ends
#     up with on both test phones: their bootloaders pass androidboot.reserve_mem_region=0x0
#     (testdev-*/last_kmsg-*), the client's memory-region modem_shared_mem@d0000000 has
#     reg size 0 ("failed to reserve memory ... size 0 MiB" in phone 1's 5.4 kmsg), so
#     __reserved_mem_alloc_size() fails (no "size" property), the region gets no ops, and 5.4's
#     memshare_child_probe() returns -EINVAL from of_reserved_mem_device_init(): no client 3.
#     The modem's requests for 96 MiB (0x6000000 = peripheral 32 MiB + reserved 64 MiB, the
#     "LEVEL1" size) and 32 MiB ("LEVEL2") then find no client: 5.4 logs "client not found"
#     and sends no reply, 6.12 logs the same and replies QMI failure; nothing is allocated
#     either way, and the modem runs without the RAM-log buffer. The earlier fix (peripheral-size 0, run kx-m1b) kept the client with init_size
#     0: the 6.12 driver then called dma_alloc_attrs(size 0) -> get_order(0) = 52 -> the
#     mm/page_alloc.c order WARN on every request.
#  3. IPA SMMU IOVA windows: dt/ipa-iova-fix.sh (2026-11-15; IPA_IOVA_FIX=0 leaves them as the
#     M1/M2 runs had them: the 2+2-cell iommu-addresses were read with /soc's 1+1 cells ->
#     "Cannot reserve IOVA region of 0 size" and a [0,1G) reservation instead of the 5.4 pool).
#  4. checks only (fail if different): mpss region 0x8b800000+0xf600000, IPA GSI fw region
#     0x8b710000+0xa000, modem firmware-name modem.mdt, IPA/rmnet/rmtfs/glinkpkt nodes enabled,
#     IPA smp2p entries present, no qcom,rmtfs-mem node (upstream rmtfs must not grab it), root
#     compatible without qcom,sc7280 (else the in-kernel pd-mapper collides with the vendor one).
# The live rmtfs@9c900000 region of the 6.18 harness (assigned to the modem by the harness's
# qcom_rmtfs_mem) is carried into the kexec tree as no-map by kexec/mkkexecdtb.py at run time.
set -euo pipefail
IN=${1:?in.dtb}; OUT=${2:?out.dtb}
fail() { echo "mkmodemtree: CHECK FAILED: $*" >&2; exit 1; }
sym() { fdtget "$OUT" /__symbols__ "$1"; }
cp "$IN" "$OUT"
MSS=$(sym modem_pas)
fdtput -t s "$OUT" "$MSS" status okay
C=/soc/qcom,memshare/qcom,client_4
[ "$(fdtget "$OUT" $C qcom,client-id 2>/dev/null)" = 3 ] || fail "$C missing or not client-id 3"
fdtput -t s "$OUT" $C status disabled
[ "${IPA_IOVA_FIX:-1}" = 1 ] && "$(dirname "$0")/ipa-iova-fix.sh" "$OUT"
# ---- checks
reg() { fdtget -t x "$OUT" "$(sym "$1")" reg | tr ' ' ,; }
[ "$(reg pil_mpss_mem)" = "0,8b800000,0,f600000" ] || fail "mpss region $(reg pil_mpss_mem)"
[ "$(reg pil_ipa_gsi_mem)" = "0,8b710000,0,a000" ] || fail "ipa gsi region $(reg pil_ipa_gsi_mem)"
[ "$(fdtget "$OUT" "$MSS" firmware-name)" = modem.mdt ] || fail "modem firmware-name"
ok() { s=$(fdtget "$OUT" "$1" status 2>/dev/null || echo okay); case "$s" in ok|okay) ;; *) fail "$1 status=$s";; esac; }
for n in "$MSS" /soc/qcom,ipa@1e00000 /soc/qcom,rmnet-ipa /soc/qcom,msm_gsi /soc/qcom,rmtfs_sharedmem@0 \
	 /soc/qcom,glinkpkt /soc/qcom,memshare /soc/qcom,ipa@1e00000/ipa_smmu_ap /soc/qcom,ipa@1e00000/ipa_smmu_uc \
	 /soc/qcom,ipa@1e00000/ipa_smmu_wlan /soc/qcom,ipa@1e00000/ipa_smmu_11ad; do
	fdtget "$OUT" "$n" compatible >/dev/null 2>&1 || fdtget -l "$OUT" "$n" >/dev/null 2>&1 || fail "missing $n"
	ok "$n"
done
[ "$(fdtget "$OUT" /soc/qcom,ipa@1e00000 qcom,max_num_smmu_cb)" = 4 ] || fail "IPA qcom,max_num_smmu_cb != 4"
fdtget "$OUT" /soc/qcom,ipa@1e00000 firmware-names | grep -x yupik_ipa_fws >/dev/null || fail "IPA firmware-names"
fdtget -l "$OUT" /soc/qcom,ipa@1e00000 | grep smp2p_map_ipa_1_in >/dev/null || fail "IPA smp2p in"
dtc -I dtb -O dts "$OUT" 2>/dev/null | grep '"qcom,rmtfs-mem"' >/dev/null && fail "upstream qcom,rmtfs-mem node present"
fdtget "$OUT" / compatible | grep "qcom,sc7280" >/dev/null && fail "root compatible has qcom,sc7280"
for c in client_1:0 client_2:2 client_3:1; do
	[ "$(fdtget "$OUT" /soc/qcom,memshare/qcom,${c%%:*} qcom,client-id)" = "${c#*:}" ] || fail "memshare ${c%%:*} client-id"
	ok /soc/qcom,memshare/qcom,${c%%:*}
done
echo "$OUT: modem_pas okay, memshare client_4 (id 3) disabled, $(stat -c %s "$OUT") bytes"
