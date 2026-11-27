#!/bin/bash
# The three 6.12 build lines in one place (they used to live in scratch wrappers that got lost).
#   build-lines.sh main  <name> [REF]   main line (LineageOS / any AOSP ROM; white cable proof phone), WALT=1 since rb112w;
#                                       rb111 = WALT=0 REF=s99oj, rb112 = WALT=0 (default REF s99ok)
#   build-lines.sh oneui <name> [REF]   One UI 9 port, KernelSU LKM entry ("6.12"). rbou9e = REF s99ou9e, rbou9f = s99ou9f
#   build-lines.sh susfs <name> [REF]   One UI 9 port, built-in ReSukiSU + SUSFS entry ("6.12 + SUSFS"). rbou9es = s99ou9e, rbou9fs = s99ou9f
# Extra environment is passed through and wins (e.g. DIAG_BOOTARGS="log_buf_len=1M", ONEUI_DUMP=<dir>).
# Proven 2026-11-27: `main rb111` / `oneui rbou9e` / `susfs rbou9es` with the old REFs rebuild the shipped images
# byte for byte. Only builds; flashes nothing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
LINE=${1:?main|oneui|susfs}; NAME=${2:?name}
COMMON=(STRIP_BTF=1 "ASYNC_LAST=stm_ts qti_devfreq_cdev sm5714_fuelgauge frpc-adsprpc qcom-spmi-temp-alarm s2mpb03 camera"
	UFS_QOS=0 UFS_WB=always ICE_RAW=1 HOLD_MS=1000 LPM=1 GPU_BUSY_UP=75 "THERMAL_X=qmi adctm bclmap secth" ADSPFAC=1
	ADSPFAC_KO=$TOP/drivers612/sensors-factory/out-p1/adsp_factory_dlkm.ko QRNG=1 HALL=1 USBAUDIO=1 DIAG=1
	MODEM=1 SDCARD=1 SHM_BRIDGE_OFF=1)
ONEUI=(VOLKEY=1 BWCOMPAT=1 ARGOS=1 SOCSTATS=1 NTFS3=1 USBACC=1 ZRAM_LZ4=1 USERSPACE=samsung
	"EXTRA_CMDLINE=stm_ts.lp_dump_inf=1" "DUMP=${ONEUI_DUMP:-$TOP/testdev-PHONE1/oneui9-9.3.177}")
case "$LINE" in
main)  SET=("${COMMON[@]}" WALT=1 "REF=${3:-s99ok}") ;;   # WALT=1 since rb112w (11-27); WALT=0 = rb111/rb112 style
oneui) SET=("${COMMON[@]}" "${ONEUI[@]}" KSU=1 "KSU_DIR=$HERE/modules/resukisu/out" "REF=${3:-s99ou9f}") ;;
susfs) SET=("${COMMON[@]}" "${ONEUI[@]/#EXTRA_CMDLINE=/EXTRA_CMDLINE=androidboot.a52sxq.susfs=1 }" SUSFS=1 "IMAGE=$TOP/bsp612/out/susfs/Image" "REF=${3:-s99ou9f}") ;;
*) echo "line: main|oneui|susfs" >&2; exit 2 ;;
esac
# caller's environment wins over the line's values (DIAG_BOOTARGS defaults to none: the shipped lines had no debug words)
ARGS=()
for kv in "${SET[@]}"; do k=${kv%%=*}; [ -n "${!k+x}" ] && ARGS+=("$k=${!k}") || ARGS+=("$kv"); done
[ -n "${DIAG_BOOTARGS+x}" ] || ARGS+=(DIAG_BOOTARGS=none)
echo "build-lines: $LINE $NAME: ${ARGS[*]}"
cd "$TOP" && exec env "${ARGS[@]}" "$HERE/build-realboot.sh" "$NAME"
