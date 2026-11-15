#!/bin/busybox sh
# whole kernel-only modem test: sh /p/all.sh  (output also in /tmp/m1.out)
cd "${0%/*}"
sh ./m1.sh "$@" > /tmp/m1.out 2>&1; rc=$?
echo "===== m1 rc=$rc"; grep -E "^## |rollback=|state=|uio|SKIP|FAIL|guard|rproc crash|recover|panic|IPA FW loaded|initialization was successful|^rmnet_|^ipam|^msm_mem|client not found|memshare_alloc|WARNING: CPU" /tmp/m1.out | head -120
echo "===== qrtr"; sed -n '/QRTR servers/,/observe/p' /tmp/m1.out | head -80
echo "===== M2 (only with the argument m2)"; grep -E "^M2 |^efsdump|^## m2|RMTFS\] shared memory|^\[storage\]|FAIL m2" /tmp/m1.out | head -120
echo "===== M2 qrtr-lookup + rmtfs/tftp logs after the observe window"; sed -n '/^## m2: after/,/^## m1: deliberate/p' /tmp/m1.out | head -260
echo "===== M2 end (verify)"; sed -n '/^## m2: efsdump verify/,$p' /tmp/m1.out | head -20
echo "===== NAS / DATA (qmi-nas, only with the arguments nas / data)"; [ -f /tmp/nas.out ] && head -3000 /tmp/nas.out
echo "===== DATA summary"; [ -f /tmp/nas.out ] && grep -E "^== data-probe|^(DPM|WDA|WDS) summary|^qmi-nas data:|^ipa-setup:|^rmnet: |^dataup: |^## qmi-nas (data|ipa)" /tmp/nas.out | head -200
echo "===== T1 (only with the argument therm)"; grep -E "^T1 |T1 sample|T1 FAIL|^## T1" /tmp/m1.out | head -160
