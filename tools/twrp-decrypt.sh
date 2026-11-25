#!/bin/bash
# Unattended TWRP /data decrypt for a test phone with a pattern lock, then optionally continue an install.
#   tools/twrp-decrypt.sh <serial> [zip-on-phone]
# Waits for recovery adb, then until TWRP has been up > 60 s and its GUI sits on the decrypt page with a stable
# recovery pid (a `twrp decrypt` sent while the GUI is still starting crashed TWRP: SIGSEGV in drmModePageFlip,
# the restarted TWRP dropped its openrecoveryscript). Sends `twrp decrypt` ONCE, verifies /data/media/0/Android (CE: /data/system is visible while still encrypted), then runs
# `twrp install <zip>` if given. Pattern: ~/.config/a52sxq/<serial>-pattern or p1/p2-pattern (local only); it is
# passed on the adb command line but never printed or logged here.
set -u
S=${1:?serial}; ZIP=${2:-}
case "$S" in PHONE1) F=p1;; PHONE2) F=p2;; *) F=$S;; esac
P=$(cat ~/.config/a52sxq/$S-pattern 2>/dev/null || cat ~/.config/a52sxq/$F-pattern 2>/dev/null) || { echo "no pattern file"; exit 2; }
a() { timeout 20 adb -s "$S" shell "$@" 2>/dev/null | tr -d '\r'; }
say() { echo "$(date +%T) twrp-decrypt: $*"; }
T0=$(date +%s)
until [ "$(timeout 5 adb -s "$S" get-state 2>/dev/null)" = recovery ]; do
	[ $(( $(date +%s) - T0 )) -gt 300 ] && { say "no recovery adb in 300 s"; exit 3; }; sleep 2; done
say "recovery adb up"
if a '[ -d /data/media/0/Android ] && echo y' | grep -q y; then say "/data already decrypted"; else
	last=""; stable=0
	while :; do
		up=$(a 'cut -d. -f1 /proc/uptime'); pid=$(a 'pidof recovery'); pg=$(a 'grep "Set page" /tmp/recovery.log | tail -1')
		[ -n "$pid" ] && [ "$pid" = "$last" ] && stable=$((stable+1)) || stable=0; last=$pid
		case "$pg" in *decrypt*) dp=1;; *) dp=0;; esac
		[ "${up:-0}" -gt 60 ] && [ "$stable" -ge 3 ] && [ "$dp" = 1 ] && break
		[ $(( $(date +%s) - T0 )) -gt 400 ] && { say "TWRP not idle on the decrypt page (up=$up pid=$pid page=$pg)"; exit 4; }
		sleep 3
	done
	say "TWRP idle on the decrypt page (uptime $up s, pid $pid): decrypting"
	timeout 60 adb -s "$S" shell "twrp decrypt $P" >/dev/null 2>&1
	# TWRP restarts its adbd/MTP after a successful decrypt: allow up to 90 s for the shell to come back
	# (the result of the loop decides: a second probe right after can hit TWRP's adbd restart and give a false FAIL)
	ok=0; for i in $(seq 1 45); do a '[ -d /data/media/0/Android ] && echo y' | grep -q y && { ok=1; break; }; sleep 2; done
	[ $ok = 1 ] || { say "decrypt FAILED (recovery pid now $(a 'pidof recovery'))"; exit 5; }
	say "/data decrypted"
fi
[ -z "$ZIP" ] && exit 0
a "ls '$ZIP' >/dev/null 2>&1 && echo y" | grep -q y || { say "no $ZIP on the phone"; exit 6; }
say "installing $ZIP"
timeout 300 adb -s "$S" shell "twrp install '$ZIP'" 2>&1 | tr -d '\r' | tail -8
