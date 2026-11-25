# tools/selftest/oneui/dev-lib.sh: phone-side helpers of the OneUI parity checks (sourced by checks/*.sh; mksh + toybox).
# Output contract (read by sweep.sh / report.py), one line each, TAB separated:
#   CHECK <id> <PASS|FAIL|SKIP> <owner> <stable> <detail>
#     stable = the value that must be equal on 5.4 and 6.12 (report.py compares it; "set: a b c" is diffed by name)
#     detail = evidence that may legitimately differ (labels, counts, temperatures)
#     owner  = who fixes a difference: kernel | ROM | kernel+ROM | info
#   METRIC <name> <number>
# Rules for every check: read-mostly, silent (no audio, no vibration), nothing under /sys/class/lcd/panel is written,
# no SIM/IMEI/serial value is ever printed (lengths and short hashes only). Runs of 14+ digits are masked anyway.
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1
_scr() { tr '\t\r\n' '   ' | sed -e 's/[0-9]\{14,\}/<digits>/g' -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-"$1"; }
# without root most nodes are unreadable: a FAIL would be a guess, so it is downgraded to SKIP
C() { local st=$2 d=${5:-}; if [ "$ROOT" = 0 ] && [ "$st" = FAIL ]; then st=SKIP; d="no root, unverified: $d"; fi
	printf 'CHECK\t%s\t%s\t%s\t%s\t%s\n' "$1" "$st" "$3" "$(printf '%s' "$4" | _scr 4000)" "$(printf '%s' "$d" | _scr 700)"; }
M() { printf 'METRIC\t%s\t%s\n' "$1" "$2"; }
rd() { head -c 400 "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
lz() { ls -dZ "$1" 2>/dev/null | cut -d' ' -f1 | sed -e 's/^u:object_r://' -e 's/:s0$//'; }
h12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
num() { printf '%s' "${1:-}" | grep -oE -- '-?[0-9]+' | head -1; }
# nodes <id> <owner> <path>...: PASS when every path exists
nodes() { local id=$1 own=$2 miss= n=0 p; shift 2; for p in "$@"; do n=$((n+1)); [ -e "$p" ] || miss="$miss $p"; done
	if [ -z "$miss" ]; then C "$id" PASS "$own" "$n/$n present" "label of the first: $(lz "$1")"; else C "$id" FAIL "$own" "missing:$miss" "$n expected"; fi; }
# setl <id> <owner> <min> <names>: a set of names (one string, space separated); FAIL below <min> entries
setl() { local id=$1 own=$2 min=$3 l n; l=$(printf '%s\n' $4 | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//'); n=$(printf '%s\n' $l | grep -c .)
	if [ "$n" -ge "$min" ]; then C "$id" PASS "$own" "set: $l" "$n entries"; else C "$id" FAIL "$own" "set: $l" "$n entries, expected >= $min"; fi; }
# val <id> <owner> <path>: PASS with the node's content as the stable value, FAIL when unreadable
val() { local v; if [ -r "$3" ] && v=$(rd "$3") && [ -n "$v" ]; then C "$1" PASS "$2" "$v" "$(lz "$3")"; elif [ -e "$3" ]; then C "$1" FAIL "$2" "unreadable" "$3 exists, read gave nothing ($(lz "$3"))"; else C "$1" FAIL "$2" "absent" "$3"; fi; }
needroot() { [ "$ROOT" = 1 ] && return 0; C "$1" SKIP "$2" "needs root"; return 1; }
svc() { getprop "init.svc.$1"; }
# D <service> [args]: dumpsys, always drained into a file first. NEVER pipe dumpsys itself into head / grep -m1: when the
# reader closes early dumpsys dies, the service's end of the dump pipe breaks and a native HAL that does not ignore SIGPIPE
# is killed (seen 2026-11-22: "init: Service 'sec-camera-provider-4-0' received SIGPIPE" from `dumpsys media.camera | head`).
_DTMP="${TMPDIR:-/data/local/tmp}/.st-dump.$$"
D() { timeout "${DT:-20}" dumpsys "$@" > "$_DTMP" 2>/dev/null; cat "$_DTMP" 2>/dev/null; rm -f "$_DTMP"; }
