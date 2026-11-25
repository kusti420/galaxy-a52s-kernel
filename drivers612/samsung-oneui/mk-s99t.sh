#!/bin/bash
# s99t = s99r (s99q + freecess + nfc_sec pvdd) + sdp_dek + the s99s four + batch 3 (sec-battery swap, sec_class, grip).
# Usage: drivers612/samsung-oneui/mk-s99t.sh [GRIP_KO...]   -> drivers612/androidboot/out/s99t-rd.cpio.gz
set -euo pipefail
TOP=$(cd "$(dirname "$0")/../.." && pwd); O=$TOP/drivers612/samsung-oneui; R=$TOP/drivers612/androidboot/out
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I "$TOP/drivers612/realboot/tools/rd-swap-ko.py" "$R/s99r-rd.cpio.gz" "$T/a.cpio.gz" "$O/battery_attrs/out/sec-battery.ko"
python3 -I "$O/rd-add-ko.py" "$T/a.cpio.gz" "${OUT:-$R/s99t-rd.cpio.gz}" vibrator \
	"$O/sdp/out/sdp_dek.ko" \
	"$O/vrr_state/out/a52sxq_vrr_state.ko" "$O/mm_boost/out/a52sxq_mm_boost.ko" "$O/blk_sec_stats/out/blk_sec_stats.ko" "$O/argos/out/sec_argos.ko" \
	"$O/sec_class/out/a52sxq_sec_class.ko" "$@"
sha256sum "${OUT:-$R/s99t-rd.cpio.gz}"
