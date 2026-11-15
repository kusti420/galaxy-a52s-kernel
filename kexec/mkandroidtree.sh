#!/bin/sh
# The full device tree for Android-on-6.12 test runs: boarddt's merged tree (all agent fragments
# that integrate) + the GPU, video and audio fragments built by drivers612/hwbringup/mkdtb.sh
# + the bring-up edits that are not right for a finished ROM (see kexec/mkfulltree.sh) + two
# dma-heap children off (secure_cdsp, display: without that no CMA heap probes) + SoundWire
# master version 1.6 as on 5.4. Usage: kexec/mkandroidtree.sh [out.dtb]
set -e
cd "$(dirname "$0")/.."
OUT=${1:-out-ack/kx/android-r02.dtb}; H=drivers612/hwbringup/dt
(cd drivers612/boarddt && ./check-dt.sh > out/check-run.log 2>&1; tail -1 out/check-run.log)
kexec/mkfulltree.sh r02 "$OUT.base" >/dev/null
fdtoverlay -i "$OUT.base" -o "$OUT.gv" $H/gpu.dtbo $H/video.dtbo
for n in qcom,secure_cdsp qcom,display; do fdtput -t s "$OUT.gv" /soc/qcom,dma-heaps/$n status disabled; done
# FastRPC (legacy adsprpc nodes from the phone's 5.4 tree, drivers612/secure/adsprpc): without
# them frpc-adsprpc.ko has no device and cdsprpcd/adsprpcd fail with ENOENT.
printf '/dts-v1/; /plugin/;\n#include "%s"\n' "$PWD/drivers612/secure/adsprpc/a52sxq-fastrpc.dtsi" > $H/fastrpc.wrap.dts
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -Ibsp612/kernel/include \
  -Ibsp612/kernel/scripts/dtc/include-prefixes $H/fastrpc.wrap.dts > $H/fastrpc.pp.dtso
dtc -@ -q -I dts -O dtb -o $H/fastrpc.dtbo $H/fastrpc.pp.dtso
# Camera (drivers612/camera/a52sxq-camera.dtsi via its dt-work/check.sh -> check-overlay.dtbo).
# Its sm5714-fled node must stay disabled (see the dtsi); the Qualcomm pmic-glink battery
# charger is turned off below because leds-qti-flash pulls qti_battery_charger in and its
# "battery" power supply would clash with Samsung's sec-battery.
(cd drivers612/camera && bash dt-work/check.sh >/dev/null 2>&1) || { echo "camera overlay build failed"; exit 1; }
# NFC (Samsung S3NRN4V sec-nfc, drivers612/nfc): dt-check.sh builds dt-work/a52sxq-nfc.dtbo
(cd drivers612/nfc && ./dt-check.sh >/dev/null 2>&1) || { echo "nfc overlay build failed"; exit 1; }
# Vibrator (samsung,dc_vibrator, drivers612/vibrator)
(cd drivers612/vibrator && dtc -@ -q -I dts -O dtb -o a52sxq-vibrator.dtbo vib-overlay.dts) || { echo "vibrator overlay build failed"; exit 1; }
# Fingerprint (Egis ET713, drivers612/fingerprint): dt-check.sh builds dt-work/a52sxq-fingerprint.dtbo
(cd drivers612/fingerprint && ./dt-check.sh >/dev/null 2>&1) || { echo "fingerprint overlay build failed"; exit 1; }
fdtoverlay -i "$OUT.gv" -o "$OUT" $H/audio.dtbo $H/fastrpc.dtbo drivers612/camera/dt-work/check-overlay.dtbo \
  drivers612/fingerprint/dt-work/a52sxq-fingerprint.dtbo drivers612/vibrator/a52sxq-vibrator.dtbo \
  drivers612/nfc/dt-work/a52sxq-nfc.dtbo
fdtput -t s "$OUT" /soc/qcom,pmic_glink/qcom,battery_charger status disabled
B=/soc/qcom,msm-audio-apr/qcom,q6core-audio/bolero-cdc
for n in rx-macro@3200000/rx_swr_master tx-macro@3220000/tx_swr_master wsa-macro@3240000/wsa_swr_master; do
  fdtput -t x "$OUT" $B/$n qcom,swr-master-version 0x01060000; done
# Bus DCVS: drop the SCMI vendor-protocol nodes the phone's CPUCP firmware does not implement,
# else qcom-pmu-lib + memlat defer forever (drivers612/busdcvs/README.md). Same step in
# drivers612/realboot/build-realboot.sh.
drivers612/busdcvs/dt-fix.sh "$OUT" >/dev/null
# The modem stays off in test runs: without the IPA data path it crashes, and remoteproc
# then panics the kernel (seen 2026-11-13). MODEM=1 keeps it on.
[ "${MODEM:-0}" = 1 ] || fdtput -t s "$OUT" "$(fdtget "$OUT" /__symbols__ modem_pas)" status disabled
# 5.4 sysfs paths (research/sepolicy/PATHS.md): the enabled QUP I2C/SPI/UART nodes become /soc
# children with qcom,wrapper-core (as on 5.4), /aliases i2cN get the 5.4 bus numbers. The same
# step runs in drivers612/realboot/build-realboot.sh and bsp618/android/mkdtb-618.sh. Needs
# i2c-msm-geni / msm_geni_serial / spi-msm-geni with bsp612/patches/soc-repo/0009 (test ramdisks
# s75 / a9 and later; with older ones the geni buses never probe on this tree).
python3 -I drivers612/boarddt/tools/sysfscompat.py apply -q "$OUT" "$OUT"
rm -f "$OUT.base" "$OUT.gv"
echo "$OUT: $(stat -c %s "$OUT") bytes"
