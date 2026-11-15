#!/bin/bash
# Offline check of the ABL's device-tree overlay step (phone 2, A528BXXS2DWB5 LinuxLoader) with a
# host build of the same libufdt (donors/abl-edk2/EmbeddedPkg/Library/LibUfdt, 5 MiB bump allocator).
# See drivers612/realboot/ABL-HANG.md.
#
#   check.sh MAIN.dtb DTBO_ENTRY.dtbo [MIN_SLACK]    exit 0 = fits with >= MIN_SLACK (default 16384)
#   check.sh --selftest                              reference cases (stock fits, rb5 crashes at 0x91ec8)
#
# The hypervisor RM's overlays are replaced by hyp-overlay-p2.dts padded to their measured total
# size (1272 bytes); that stand-in reproduces phone 2's crash registers exactly for rb4/rb5.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$H/../../../.." && pwd)"
L="$R/donors/abl-edk2/EmbeddedPkg/Library/LibUfdt"
B="${TMPDIR:-/tmp}/ufdt-host.$UID"; mkdir -p "$B"
if [ ! -x "$B/ufdt-host" ] || [ "$H/ufdt_host.c" -nt "$B/ufdt-host" ] || [ "$H/sysdeps_host.c" -nt "$B/ufdt-host" ]; then
	gcc -O0 -g -w -include "$H/fdt_entry_node.h" -DINCLUDE_PLATFORM_HDRS -I"$L/include" -I"$L/sysdeps/include" -I"$L" \
		-o "$B/ufdt-host" "$H/ufdt_host.c" "$H/sysdeps_host.c" "$L/ufdt_convert.c" "$L/ufdt_node.c" \
		"$L/ufdt_node_dict.c" "$L/ufdt_overlay.c" -lfdt
fi
dtc -q -@ -S 1272 -I dts -O dtb -o "$B/hyp.dtbo" "$H/hyp-overlay-p2.dts"
run() { "$B/ufdt-host" "$1" "$2" "$B/hyp.dtbo" 2>/dev/null || true; }
if [ "${1:-}" = --selftest ]; then
	O="$R/drivers612/realboot/out"; ok=1
	python3 -I - "$R/testdev-PHONE2/dtbo.img" "$B/stock-r02.dtbo" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read(); h=struct.unpack('>8I',d[:32]); e=struct.unpack('>8I',d[h[5]+2*h[3]:h[5]+2*h[3]+32])
open(sys.argv[2],'wb').write(d[e[1]:e[1]+e[0]])
PY
	out=$(run "$O/rb7/work/stock-base.dtb" "$B/stock-r02.dtbo")
	echo "stock base + dtbo r02: $(echo "$out" | grep -E 'SLACK|RESULT' | tr '\n' ' ')"; echo "$out" | grep -q 'RESULT fits' || ok=0
	out=$(run "$O/rb5/vendor_boot.dtb" "$O/rb5/realboot.dtbo")
	echo "rb5: $(echo "$out" | grep RESULT)"; echo "$out" | grep -q ABL-CRASH || ok=0
	[ $ok = 1 ] && echo "selftest OK" || { echo "selftest FAILED"; exit 1; }
	exit 0
fi
out=$(run "$1" "$2"); echo "$out"
slack=$(echo "$out" | sed -nE 's/.*SLACK ([-0-9]+) bytes.*/\1/p')
[ -n "$slack" ] && [ "$slack" -ge "${3:-16384}" ] || { echo "FAIL: ABL overlay step would crash or is too tight (need >= ${3:-16384} bytes slack)"; exit 1; }
echo "OK: slack $slack bytes"
