#!/bin/bash
# OneUI 9 parity sweep: Samsung/OneUI-specific kernel consumers, comparable between the 5.4 and the 6.12 kernel on
# the same phone. READ-MOSTLY and SILENT: no audio, no vibration, no reboot, no setting changed, adb never touched,
# nothing written under /sys/class/lcd/panel, no SIM/IMEI/serial value printed or stored.
#   tools/selftest/oneui/sweep.sh <serial> [--readonly] [--only 10,70] [--no-app] [--into <selftest run dir>]
# The only writes: the project's own files in /data/local/tmp/st-oneui (removed at the end); read-only sec touch
# commands (get_fw_ver_ic ...) through the tsp cmd node; /sys/power/cpufreq_max_limit set for ~0.5 s and put back
# (proves the SSRM limit reaches cpufreq; --readonly leaves it out); test keys in the shell user's keystore
# (generated and deleted; --no-app leaves the keystore/Widevine app_process probes out).
# Root: `su -c` (ReSukiSU / KernelSU, context u:r:ksu:s0), else root adbd, else shell (most rows SKIP then).
# Output: logs/selftest/<serial>-<time>/ with oneui.tsv (id, status, owner, stable, detail), oneui-*.log (raw),
# collectors.json + collect-*.txt (avc groups, dying services, tombstones, ENOENT sysfs, Freecess/MARs), kmsg.txt,
# logcat.txt (main,system,crash,events: never the radio buffer), table.txt/metrics.tsv/summary.txt/results.json in
# the selftest format. Compare two runs: tools/selftest/oneui/report.py <5.4 run> <6.12 run>.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
S=${1:?usage: sweep.sh <serial> [--readonly] [--only 10,70] [--no-app] [--into <run dir>]}; shift
WRITE=1; ONLY=; APP=1; INTO=
while [ $# -gt 0 ]; do case "$1" in --readonly) WRITE=0;; --only) ONLY=",$2,"; shift;; --no-app) APP=0;; --into) INTO=$2; shift;; *) echo "unknown option $1"; exit 2;; esac; shift; done
case "$S" in DAILYPHONE|OTHERPHONE) [ "${OWNER_OK:-}" = 1 ] || { echo "refusing $S (protected phones) without OWNER_OK=1"; exit 3; };; esac
adb -s "$S" get-state 2>/dev/null | grep -q device || { echo "$S not on adb"; exit 4; }
a() { timeout "${TMO:-90}" adb -s "$S" shell "$@" 2>&1 | tr -d '\r'; }
D=/data/local/tmp/st-oneui
if [ "$(a "su -c 'id -u'" | tail -1)" = 0 ]; then ROOT=su-c; r() { a "su -c '$1'"; }
elif [ "$(a id -u)" = 0 ]; then ROOT=adbd; r() { a "$1"; }
else ROOT=none; r() { a "$1"; }; fi
if [ -n "$INTO" ]; then RUN=$INTO; else RUN=$REPO/logs/selftest/$S-$(date +%Y%m%d-%H%M%S); fi; mkdir -p "$RUN"
if [ "$S" = PHONE1 ] && [ -z "$INTO" ]; then mkdir -p /tmp/claude-1000; exec 9>/tmp/claude-1000/a52-bs.lock; flock -w "${LOCK_WAIT:-600}" 9 || { echo "phone lock busy"; exit 5; }; fi   # broken screen is shared between sessions
KREL=$(a uname -r)
[ -z "$INTO" ] && { echo "selftest $(date '+%F %T')  serial $S  quick=0"; echo "kernel $KREL  build $(a getprop ro.build.description)"; echo "root=$ROOT klog=$([ $ROOT = none ] && echo none || echo dmesg) sim=$(a getprop gsm.sim.state | grep -qE 'LOADED|READY' && echo 1 || echo 0) bootloader=$(a getprop ro.boot.bootloader) uptime=$(a 'cut -d" " -f1 /proc/uptime') s"; echo "profile=oneui-sweep write=$WRITE app=$APP setup_complete=$(a settings get secure user_setup_complete) context=$(r 'id -Z' | tail -1)"; } | tee "$RUN/summary.txt"
[ $ROOT = none ] && echo "NOTE: no root (su -c refused: grant Shell in the ReSukiSU manager): unreadable nodes are SKIP, not FAIL" | tee -a "$RUN/summary.txt"
: > "$RUN/oneui.tsv"
a "rm -rf $D; mkdir -p $D/checks" >/dev/null
adb -s "$S" push "$HERE/dev-lib.sh" $D/ >/dev/null 2>&1; adb -s "$S" push "$HERE"/checks/*.sh $D/checks/ >/dev/null 2>&1
[ -f "$HERE/kq/kq-arm64" ] && adb -s "$S" push "$HERE/kq/kq-arm64" $D/kq >/dev/null 2>&1
[ -f "$HERE/actl/actl-arm64" ] && adb -s "$S" push "$HERE/actl/actl-arm64" $D/actl >/dev/null 2>&1   # ALSA control probe (checks/65-bt-audio.sh)
[ $APP = 1 ] && [ -f "$HERE/../java/st.dex" ] && adb -s "$S" push "$HERE/../java/st.dex" $D/ >/dev/null 2>&1
a "chmod -R a+rX $D; chmod 755 $D/kq $D/actl" >/dev/null
trap 'a "rm -rf $D" >/dev/null 2>&1' EXIT
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$RUN/oneui.tsv"; }
for f in "$HERE"/checks/*.sh; do b=$(basename "$f" .sh); n=${b%%-*}
	[ -n "$ONLY" ] && [[ "$ONLY" != *",$n,"* ]] && continue
	TMO=240 r "ONEUI_WRITE=$WRITE sh $D/checks/$b.sh" > "$RUN/oneui-$b.log" 2>&1
	grep -a $'^CHECK\t' "$RUN/oneui-$b.log" | cut -f2- >> "$RUN/oneui.tsv"
	grep -a $'^METRIC\t' "$RUN/oneui-$b.log" | cut -f2- >> "$RUN/metrics.tsv"
	grep -aq $'^CHECK\t' "$RUN/oneui-$b.log" || row "script.$b" FAIL info "no CHECK line" "$(tail -2 "$RUN/oneui-$b.log" | tr '\n\t' '  ' | cut -c1-200)"
done
# app_process probes as the shell user (TEE keystore incl. attestation, Widevine level): silent, no UI
if [ $APP = 1 ] && [ -f "$HERE/../java/st.dex" ] && { [ -z "$ONLY" ] || [[ "$ONLY" == *",app,"* ]]; }; then
	for t in keystore drm; do o=$(TMO=120 a "app_process -cp $D/st.dex / St $t"); echo "$o" > "$RUN/oneui-app-$t.log"
		l=$(echo "$o" | grep -m1 "^RESULT $t "); st=$(echo "$l" | cut -d' ' -f3); det=$(echo "$l" | cut -d' ' -f4- | sed -E 's/[0-9]{14,}/<digits>/g')
		case "$t" in keystore) id=sec.keystore; stable=$(echo "$det" | grep -oE 'attestation [A-Za-z0-9 ]+' | head -1);; drm) id=sec.widevine; stable=$(echo "$det" | grep -oE 'securityLevel=[A-Z0-9]+' | head -1);; esac
		case "$st" in PASS|FAIL|SKIP) row $id "$st" kernel+ROM "${stable:-$st}" "$det";; *) row $id FAIL kernel+ROM "no RESULT line" "$(echo "$o" | tail -1 | cut -c1-200)";; esac
	done
	# spec rows (drivers612/SPEC/04): camera2 static characteristics per camera id and the codec list with the limits the
	# HAL reports. Nothing is opened, captured, encoded or played: CameraManager.getCameraCharacteristics / MediaCodecList.
	for t in caminfo codecs; do o=$(TMO=120 a "app_process -cp $D/st.dex / St $t"); echo "$o" > "$RUN/oneui-app-$t.log"
		echo "$o" | grep -a $'^CHECK\t' | cut -f2- | sed -E 's/[0-9]{14,}/<digits>/g' >> "$RUN/oneui.tsv"
		echo "$o" | grep -a '^METRIC ' | sed -e 's/^METRIC //' -e 's/ /\t/' >> "$RUN/metrics.tsv"
		echo "$o" | grep -aq $'^CHECK\t' || row "script.app-$t" FAIL info "no CHECK line" "$(echo "$o" | tail -1 | tr '\t' ' ' | cut -c1-200)"
	done
fi
# an early capture of this boot (tools/selftest/oneui/boot-capture.sh: kernel log + logcat taken right after boot, while the
# TA load lines are still in the ring buffers) is copied in when its boot id is this boot's
BID=$(a 'cat /proc/sys/kernel/random/boot_id' | tr -dc 'a-f0-9-'); EC=$REPO/logs/selftest/early/$S-$BID
if [ -n "$BID" ] && [ -d "$EC" ]; then cp "$EC/kmsg.txt" "$RUN/kmsg-early.txt" 2>/dev/null; cp "$EC/logcat.txt" "$RUN/logcat-early.txt" 2>/dev/null; echo "early capture of this boot: $EC ($(cat "$EC/uptime.txt" 2>/dev/null) s after kernel start)" | tee -a "$RUN/summary.txt"; fi
# collectors: raw material (no radio buffer, no full getprop) + host-side grouping
if [ -z "$ONLY" ] || [[ "$ONLY" == *",collect,"* ]]; then
	[ $ROOT != none ] && TMO=60 r dmesg > "$RUN/kmsg.txt" 2>/dev/null
	TMO=120 r 'logcat -d -b main,system,crash,events' > "$RUN/logcat.txt" 2>/dev/null
	grep -aiE 'vaultkeeper|VK |CASS' "$RUN/logcat.txt" | sed -E 's/[0-9]{14,}/<digits>/g' > "$RUN/logcat-vaultkeeper.txt"   # 5.4 vs 6.12: "no VK ID" loop = ROM or kernel?
	a 'getprop' | grep -E '^\[(init\.svc\.|sys\.boot\.reason|ro\.boot\.bootreason|sys\.kernel_check\.|bpf\.|apexd\.status|sys\.boot_completed|ro\.build\.display\.id|persist\.sys\.boot\.reason)' > "$RUN/props.txt"
	r 'ls -l /data/tombstones 2>/dev/null; for t in /data/tombstones/tombstone_[0-9][0-9]; do [ -f "$t" ] || continue; echo "== $t"; grep -m8 -E "^(Timestamp|Cmdline|pid:|signal |Abort message|Cause:)|^ +#0[0-3] " "$t"; done' > "$RUN/tombstones.txt" 2>&1
	a 'dumpsys dropbox 2>/dev/null' | grep -oE '^[0-9-]+ [0-9:]+ [A-Za-z_@.0-9]+' | cut -d' ' -f3 | sort | uniq -c | sort -rn > "$RUN/dropbox-tags.txt"
	# full dump, cut on the PC: `dumpsys media.camera | head` on the phone kills the camera provider with SIGPIPE (see dev-lib.sh D)
	TMO=60 a 'dumpsys media.camera 2>&1' > "$RUN/dumpsys-camera.txt"; head -80 "$RUN/dumpsys-camera.txt" > "$RUN/dumpsys-camera-head.txt"   # raw material for camera.provider_devices + the per-id digest
	python3 -I "$HERE/collect.py" "$RUN" >> "$RUN/oneui.tsv"
fi
# table in the selftest format (ids prefixed o.) + counts
awk -F'\t' '{ printf "o.%-34s %-5s %s%s\n", $1, $2, $4, ($5 != "" ? " | " $5 : "") }' "$RUN/oneui.tsv" >> "$RUN/table.txt"
NP=$(cut -f2 "$RUN/oneui.tsv" | grep -c PASS); NF=$(cut -f2 "$RUN/oneui.tsv" | grep -c FAIL); NS=$(cut -f2 "$RUN/oneui.tsv" | grep -c SKIP)
printf '\n%-38s %-5s %s\n' "ONEUI CHECK" RES "EVIDENCE"; awk -F'\t' '{ printf "%-38s %-5s %s%s\n", $1, $2, $4, ($5 != "" ? " | " $5 : "") }' "$RUN/oneui.tsv" | cut -c1-230
{ echo; echo "ONEUI SWEEP on $KREL: $NP PASS, $NF FAIL, $NS SKIP (FAIL = absent/broken on THIS kernel; the verdict is the 5.4-vs-6.12 comparison)"; echo "logs: $RUN"; } | tee -a "$RUN/summary.txt"
if [ -z "$INTO" ]; then python3 "$HERE/../mkjson.py" "$RUN" >/dev/null 2>&1; echo "compare: tools/selftest/oneui/report.py <5.4 run> <6.12 run>"; fi
exit 0
