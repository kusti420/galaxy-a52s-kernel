#!/bin/bash
# Unlock a test phone's pattern keyguard over adb (owner-approved for phone 1, 2026-11-15).
# The pattern is NOT in this repo: it is read from ~/.config/a52sxq/p<N>-pattern (dots 1-9, keypad order).
# Usage: PHONE=1 tools/unlock.sh
set -u
case "${PHONE:-1}" in 1) S=PHONE1;; 2) S=PHONE2;; *) exit 1;; esac
P=$(cat ~/.config/a52sxq/p${PHONE:-1}-pattern 2>/dev/null) || { echo "no pattern file"; exit 1; }
a() { adb -s $S shell "$@"; }
showing() { a dumpsys window policy 2>/dev/null | grep -m1 -o 'showing=[a-z]*' | grep -q true; }
a input keyevent KEYCODE_WAKEUP; sleep 0.5
showing || { echo "not locked"; exit 0; }
a input swipe 540 1900 540 600 250; sleep 1
# pattern view bounds from the UI dump
B=$(a 'uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; cat /data/local/tmp/ui.xml; rm -f /data/local/tmp/ui.xml' | tr '>' '\n' | grep 'id/lockPatternView"' | grep -o 'bounds="[^"]*"' | grep -o '[0-9]*' | tr '\n' ' ')
read -r x0 y0 x1 y1 <<< "$B"
[ -n "${y1:-}" ] || { echo "pattern view not found"; exit 1; }
cmd="input motionevent DOWN"; first=1
for ((i=0;i<${#P};i++)); do d=$(( ${P:$i:1} - 1 )); cx=$(( x0 + (x1-x0)*(2*(d%3)+1)/6 )); cy=$(( y0 + (y1-y0)*(2*(d/3)+1)/6 ))
  if [ $first = 1 ]; then s="input motionevent DOWN $cx $cy"; first=0; else s="$s; input motionevent MOVE $cx $cy"; fi; lx=$cx; ly=$cy; done
a "$s; input motionevent UP $lx $ly"; sleep 1.5
showing && { echo "still locked"; exit 1; } || echo "unlocked"
