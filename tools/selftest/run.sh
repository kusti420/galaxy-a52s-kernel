#!/bin/bash
# Hands-free feature self-test of an A52s on the 6.12 (or 6.18) kernel.
#   tools/selftest/run.sh <serial> [--quick] [--daily] [--oneui] [--only id,id] [--skip id,id] [--list]
# --oneui = profile for the OneUI 9 port (K4_UN1CA) on either kernel: root through `su -c` (ReSukiSU, u:r:ksu:s0), Samsung
# refresh-rate setting, no audio test at all (AUDIBLE=1 brings the muted loopback back), no soak/framework-restart/DRM
# handover/bench, and the read-mostly OneUI parity sweep (tools/selftest/oneui/sweep.sh) appended as o.<id> rows.
# Combine with --daily for the non-destructive subset. 5.4 vs 6.12: tools/selftest/oneui/report.py <5.4 run> <6.12 run>.
# --daily = non-destructive subset for a phone in daily use (no toggles, no load, no volume/brightness changes;
# the user's phones are refused unless OWNER_OK=1 is set by the user).
# Works with root adb (LineageOS userdebug: adbd root or su) and without (IchthysOS user build: shell uid; the
# kernel log then comes from /sys/devices/system/cpu/a52kmsg, present on DEBUG=1 kernels).
# Prints a PASS/FAIL/SKIP table and writes logs/selftest/<serial>-<time>/ : one log per test (+ .kmsg/.logcat/
# .crash/.avc deltas), kernel log + logcat before and after, summary.txt, hands-on.txt.
# Every test checks real function and additionally FAILs on: new kernel WARN/BUG/oops lines, new kernel-side
# SELinux denial signatures, a daemon that died (init) or a fatal crash in logcat during the test.
# Rules built in: never vibrates, keeps all streams muted, installs nothing, never disables adb, restores every
# setting it changes, monkey only launches a fixed allow-list of stock apps.
# Tests: tools/selftest/tests/*.sh (reg <id> <needs: - root sim hands> <quick 1|0> <title>; function t_<id>).
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
S=${1:?usage: run.sh <serial> [--quick] [--only a,b] [--skip a,b] [--list]}; shift
QUICK=0; ONLY=; SKIPL=; LIST=0; DAILY=0; ONEUI=0
while [ $# -gt 0 ]; do case "$1" in --quick) QUICK=1;; --only) ONLY=",$2,"; shift;; --skip) SKIPL="${SKIPL:-,}$2,"; shift;; --list) LIST=1;; --daily) DAILY=1; SKIPL=",memory,hotspot,nfc,thermal,soak,fwrestart,drmhandover,display,audio,bench,";; --oneui) ONEUI=1; SKIPL="${SKIPL:-,}soak,fwrestart,drmhandover,bench,"; [ "${AUDIBLE:-0}" = 1 ] || SKIPL="${SKIPL}audio,";; *) echo "unknown option $1"; exit 2;; esac; shift; done
. "$HERE/lib.sh"
IDS=(); declare -A NEED QK TITLE
reg() { IDS+=("$1"); NEED[$1]=$2; QK[$1]=$3; TITLE[$1]=$4; }
for f in "$HERE"/tests/*.sh; do . "$f"; done
if [ $LIST = 1 ]; then for i in "${IDS[@]}"; do printf '%-14s needs=%-10s quick=%s  %s\n' "$i" "${NEED[$i]}" "${QK[$i]}" "${TITLE[$i]}"; done; exit 0; fi
case "$S" in DAILYPHONE|OTHERPHONE) [ "${OWNER_OK:-}" = 1 ] || { echo "refusing $S (protected phones) without OWNER_OK=1"; exit 3; };; esac
adb -s "$S" get-state 2>/dev/null | grep -q device || { adb kill-server >/dev/null 2>&1; sleep 2; adb -s "$S" get-state 2>/dev/null | grep -q device || { echo "$S not on adb"; exit 4; }; }
RUN=$REPO/logs/selftest/$S-$(date +%Y%m%d-%H%M%S); mkdir -p "$RUN"; : > "$RUN/avc-seen.txt"; : > "$RUN/hands-on.txt"
# privilege + kernel log source
ROOT=none; [ "$(A id -u)" = 0 ] && ROOT=adbd
SUSH=; SUTRY=('su 0 sh' 'su -c sh'); [ $ONEUI = 1 ] && SUTRY=('su -c sh' 'su 0 sh')   # OneUI 9 port: ReSukiSU, root only via su -c
[ $ROOT = none ] && for s in "${SUTRY[@]}"; do [ "$(printf 'id -u\n' | timeout 10 adb -s "$S" shell "$s" 2>/dev/null | tr -d '\r' | tail -1)" = 0 ] && { ROOT=su; SUSH=$s; break; }; done
KLOG=none; if have_root; then KLOG=dmesg; elif [ -n "$(A 'head -c 64 /sys/devices/system/cpu/a52kmsg 2>/dev/null')" ]; then KLOG=a52kmsg; fi
SIM=0; A getprop gsm.sim.state | grep -qE 'LOADED|READY' && SIM=1
SDK=$(A getprop ro.build.version.sdk); KREL=$(A uname -r)
{ echo "selftest $(date '+%F %T')  serial $S  quick=$QUICK"; echo "kernel $KREL  build $(A getprop ro.build.description)"; echo "root=$ROOT klog=$KLOG sim=$SIM bootloader=$(A getprop ro.bootloader) uptime=$(A 'cut -d" " -f1 /proc/uptime') s"; } | tee "$RUN/summary.txt"
[ $ONEUI = 1 ] && echo "profile=oneui su='$SUSH' context=$(R 'id -Z' 2>/dev/null | tail -1) setup_complete=$(A settings get secure user_setup_complete) (UI tests need a finished setup wizard)" | tee -a "$RUN/summary.txt"
[ $KLOG = none ] && echo "NOTE: no kernel log access (no root, no a52kmsg): kernel WARN/oops checks are blind on this phone" | tee -a "$RUN/summary.txt"
cleanup() { trap - EXIT INT TERM; restore_settings; A 'pkill -f "st-bur[n]"; rm -rf /data/local/tmp/st' >/dev/null 2>&1; [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null; [ $DAILY = 1 ] || mute; }
trap 'cleanup; exit 130' INT TERM; trap cleanup EXIT
# tools on the phone
A 'rm -rf /data/local/tmp/st; mkdir -p /data/local/tmp/st' >/dev/null
for d in "$HERE/java/st.dex" "$HERE/clk/clk.dex" "$REPO"/tools/{tone/tone,rec/rec,vdec/vdec,torch/torch,gnss/gnss}.dex; do [ -f "$d" ] && adb -s "$S" push "$d" /data/local/tmp/st/ >/dev/null 2>&1; done
# root adbd without a su binary (LineageOS): the shell-uid tools go through tools/selftest/asshell (asshell.c)
if [ $ROOT = adbd ] && [ "$(printf 'id -u\n' | timeout 10 adb -s "$S" shell 'su shell sh' 2>/dev/null | tr -d '\r')" != 2000 ]; then
	adb -s "$S" push "$HERE/asshell" /data/local/tmp/st/asshell >/dev/null 2>&1; A 'chmod 755 /data/local/tmp/st/asshell' >/dev/null
	USH=/data/local/tmp/st/asshell
	[ "$(U 'id -u')" = 2000 ] || echo "NOTE: no way to run as the shell uid (su missing, asshell failed: $(U 'id -u' | head -1)): app_process tools will fail" | tee -a "$RUN/summary.txt"
fi
A 'chmod -R a+rX /data/local/tmp/st' >/dev/null
# a phone without a working modem (white cable: baseband empty) restarts the radio daemons for ever, on 5.4 too:
# not a finding of whichever test happens to run
if [ -z "$(A getprop gsm.version.baseband | tr -d ', ')" ]; then
	SVC_IGNORE="${SVC_IGNORE%)\'}|ril-daemon[0-9]*|vendor.sehradiomanager)'"
	NOMODEM=1
	echo "NOTE: no baseband on this phone: ril-daemon / sehradiomanager restarts and rild crashes are ignored" | tee -a "$RUN/summary.txt"
fi
[ $DAILY = 1 ] || mute; mkdir -p /tmp/claude-1000; ps system sound_effects_enabled 0; ps system haptic_feedback_enabled 0; ps global stay_on_while_plugged_in 0
klog > "$RUN/kmsg-before.txt"; A 'logcat -d' > "$RUN/logcat-before.txt" 2>&1; avc_sigs "$RUN/logcat-before.txt" "$RUN/kmsg-before.txt" > "$RUN/avc-before.txt"
# denials that existed before the run are reported by the selinux test, not blamed on whichever test runs next
cp "$RUN/avc-before.txt" "$RUN/avc-seen.txt"
LOCKMSG=$(unlock); echo "keyguard: $LOCKMSG" | tee -a "$RUN/summary.txt"; UNLOCKED=1; locked && UNLOCKED=0
printf '\n%-14s %-5s %s\n' TEST RES DETAIL
NP=0; NF=0; NS=0
for id in "${IDS[@]}"; do
	[ -n "$ONLY" ] && [[ "$ONLY" != *",$id,"* ]] && continue
	[[ "$SKIPL" == *",$id,"* ]] && continue
	SVC_ALLOW=; CRASH_OK=; T_OK=0; T_FAIL=0; T_SKIP=0; T_MSG=; T_FMSG=; T_SMSG=; L="$RUN/$id"
	need=${NEED[$id]}
	if [[ "$need" == *root* ]] && ! have_root; then res=SKIP; det="needs root"
	elif [[ "$need" == *sim* ]] && [ $SIM = 0 ]; then res=SKIP; det="needs a SIM"
	elif [[ "$need" == *hands* ]]; then res=SKIP; det="hands-on (see checklist)"; t_$id >> "$L.log" 2>&1
	else
		adb -s "$S" get-state 2>/dev/null | grep -q device || { sleep 20; adb -s "$S" get-state 2>/dev/null | grep -q device || { adb kill-server >/dev/null 2>&1; sleep 5; adb -s "$S" wait-for-device; }; }
		[ "$S" = PHONE1 ] && { exec 9>/tmp/claude-1000/a52-bs.lock; flock -w ${LOCK_WAIT:-240} 9 || echo "NOTE: phone lock busy > ${LOCK_WAIT:-240} s before $id: ran anyway" | tee -a "$RUN/summary.txt"; }   # broken screen is shared between sessions
		t0=$(date +%s); guard_begin
		{ echo "== $id: ${TITLE[$id]} ($(date +%T))"; t_$id; guard_end "$L"; } >> "$L.log" 2>&1
		el=$(( $(date +%s) - t0 )); [ "$S" = PHONE1 ] && flock -u 9
		if [ $T_FAIL -gt 0 ]; then res=FAIL; det=$T_FMSG; elif [ $T_OK -eq 0 ] && [ $T_SKIP -gt 0 ]; then res=SKIP; det=$T_SMSG; elif [ $T_OK -eq 0 ]; then res=SKIP; det="no check ran"; else res=PASS; det="$T_MSG${T_SMSG:+ [skipped: $T_SMSG]}"; fi
		det="$det (${el}s)"
	fi
	case $res in PASS) NP=$((NP+1));; FAIL) NF=$((NF+1));; SKIP) NS=$((NS+1));; esac
	printf '%-14s %-5s %s\n' "$id" "$res" "$det" | tee -a "$RUN/table.txt" | cut -c1-400
done
if [ $ONEUI = 1 ] && [ -z "$ONLY" ]; then echo; echo "OneUI parity sweep:"; "$HERE/oneui/sweep.sh" "$S" --into "$RUN" $([ $DAILY = 1 ] && echo --readonly) | grep -E ' (FAIL|SKIP) |^ONEUI SWEEP' | cut -c1-300
	n=$(cut -f2 "$RUN/oneui.tsv" 2>/dev/null | grep -c PASS); NP=$((NP+n)); n=$(cut -f2 "$RUN/oneui.tsv" 2>/dev/null | grep -c FAIL); NF=$((NF+n)); n=$(cut -f2 "$RUN/oneui.tsv" 2>/dev/null | grep -c SKIP); NS=$((NS+n)); fi
klog > "$RUN/kmsg-after.txt"; A 'logcat -d' > "$RUN/logcat-after.txt" 2>&1; A 'logcat -b crash -d' > "$RUN/logcat-crash-after.txt" 2>&1
{ echo; echo "TOTAL: $NP PASS, $NF FAIL, $NS SKIP"; echo; echo "HANDS-ON CHECKLIST (cannot be tested without a person):"; sort -u "$RUN/hands-on.txt" | sed 's/^/  [ ] /'; echo; echo "logs: $RUN"; } | tee -a "$RUN/summary.txt"
cat "$RUN/table.txt" >> "$RUN/summary.txt" 2>/dev/null
python3 "$HERE/mkjson.py" "$RUN" 2>/dev/null && echo "results: $RUN/results.json  (compare: tools/selftest/compare.py <baseline run> $RUN)"
[ $NF = 0 ]
