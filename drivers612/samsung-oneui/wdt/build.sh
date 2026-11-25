#!/bin/bash
# Build the a52 OneUI watchdog variant (qcom_wdt_core.ko + gh_virt_wdt.ko -> out/) and the QEMU-only sim backend
# (sim/out/a52_wdt_sim.ko) against bsp612. Offline, flashes nothing. Then: qemu-test/run.sh (and CORE=dist for the
# negative control). See ../WDT-ONEUI.md.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); S=$(cd "$H/.." && pwd); TOP=$(cd "$S/../.." && pwd)
M=$TOP/bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734
# the variant must still be the soc-repo source + the two recorded diffs
for f in qcom_wdt_core.c:drivers/soc/qcom gh_virt_wdt.c:drivers/virt/gunyah; do
	cmp -s "$H/orig/${f%%:*}" "$TOP/bsp612/soc-repo/${f##*:}/${f%%:*}" || { echo "orig/${f%%:*} differs from bsp612/soc-repo: re-base the variant" >&2; exit 1; }
done
{ diff -u "$H/orig/qcom_wdt_core.c" "$H/qcom_wdt_core.c" || true; } | tail -n +3 | cmp -s - <(tail -n +3 "$H/a52-wdt-core.diff") || { echo "a52-wdt-core.diff is stale" >&2; exit 1; }
{ diff -u "$H/orig/gh_virt_wdt.c" "$H/gh_virt_wdt.c" || true; } | tail -n +3 | cmp -s - <(tail -n +3 "$H/a52-wdt-gh.diff") || { echo "a52-wdt-gh.diff is stale" >&2; exit 1; }
python3 "$S/ko2symvers.py" "$H/dist-deps.symvers" "$M/drivers/soc/qcom/minidump.ko" "$M/drivers/firmware/qcom/qcom-scm.ko"
EXTRA_SYMVERS="$H/dist-deps.symvers" "$S/build.sh" "$H"
EXTRA_SYMVERS="$H/dist-deps.symvers $H/Module.symvers" "$S/build.sh" "$H/sim"
# drop-in check: same exports with the same CRCs as the dist qcom_wdt_core.ko
T=$(mktemp -d)
python3 "$S/ko2symvers.py" "$T/d" "$M/drivers/soc/qcom/qcom_wdt_core.ko" > /dev/null; python3 "$S/ko2symvers.py" "$T/v" "$H/out/qcom_wdt_core.ko" > /dev/null
diff <(cut -f1,2,4 "$T/d" | sort) <(cut -f1,2,4 "$T/v" | sort) > /dev/null && echo "exports + CRCs = dist qcom_wdt_core.ko ($(wc -l < "$T/v"))" || { echo "exports differ from the dist module" >&2; exit 1; }
rm -r "$T"; sha256sum "$H"/out/*.ko "$H"/sim/out/*.ko
