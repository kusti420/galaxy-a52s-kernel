#!/bin/bash
# Build the 6.18 port tree bsp618/src (made by port618.py) against the survey's ACK 6.18.33
# kernel (bsp618/out-survey/gki + lahaina module config, reused unchanged; out-ack/ and the
# bsp612 outputs are not touched). Same make invocations as the survey (build-survey.sh soc /
# drivers, with -i -k so modpost runs over whatever compiled), only the source mirror differs.
# Offline only: flashes nothing.
#
# Usage: bsp618/port/build618.sh [port] [soc] [drivers] [report]   (default: all four)
#   port     python3 port618.py (regenerate bsp618/src, incremental; PORT_ARGS=--fresh to wipe)
#   soc      soc-repo-staging, -j$(nproc) then a -j1 pass over what failed (clean diagnostics;
#            logs/soc-j24.log, logs/soc.log)
#   drivers  every drivers612/ + samsung612/modules set (logs/drivers/), plus build-survey.sh
#            "extra": fingerprint, nfc, vibrator, suspend/a52susp, realboot dspboot, modules/hhwdt
#   report   survey-report.py + survey-symbols.py on the port tree -> out-port/{report,clusters,
#            symbols}.json, modules.md, report.txt
set -uo pipefail
P=$(cd "$(dirname "$0")" && pwd); B=$(dirname "$P")
export SURVEY_SRC=$B/src SURVEY_LOGS=$B/out-port/logs SURVEY_RESULTS=$B/out-port
mkdir -p "$SURVEY_LOGS"
for step in ${@:-port soc drivers report}; do
  case "$step" in
    port)    python3 "$P/port618.py" ${PORT_ARGS:-} || exit 1 ;;
    soc)     "$B/build-survey.sh" soc && mv "$SURVEY_LOGS/soc.log" "$SURVEY_LOGS/soc-j24.log" \
               && J=1 "$B/build-survey.sh" soc ;;
    drivers) "$B/build-survey.sh" drivers extra 2>&1 | tee "$SURVEY_RESULTS/drivers.run" ;;
    report)  { python3 "$B/survey-report.py"; python3 "$B/survey-symbols.py"; } | tee "$SURVEY_RESULTS/report.txt" ;;
    *) echo "unknown step $step"; exit 2 ;;
  esac
done
