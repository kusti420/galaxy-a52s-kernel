#!/bin/bash
# Hands-free unlock for the self-test: wakes the phone, opens the bouncer (MENU key: works on the
# Compose scene-container keyguard where a swipe does not), and draws the pattern from
# ~/.config/a52sxq/<serial>-pattern or p1/p2-pattern (dots 1-9, keypad order; never stored in the repo).
# Handles both the classic lockPatternView and the Compose bouncer_pattern_root.
# Usage: tools/selftest/unlock.sh <serial>     exit 0 = unlocked / not locked, 1 = could not unlock
S=${1:?serial}
a() { adb -s "$S" shell "$@" 2>/dev/null; }
showing() { a dumpsys window policy | grep -m1 -o 'showing=[a-z]*' | grep -q true; }
a input keyevent KEYCODE_WAKEUP; sleep 0.7
showing || { echo "not locked"; exit 0; }
a input keyevent 82; sleep 1.2
showing || { echo "unlocked (no credential)"; exit 0; }
case "$S" in PHONE1) F=p1;; PHONE2) F=p2;; *) F=$S;; esac
P=$(cat ~/.config/a52sxq/$S-pattern 2>/dev/null || cat ~/.config/a52sxq/$F-pattern 2>/dev/null) || { echo "locked, no pattern file"; exit 1; }
for try in 1 2 3; do
  B=$(a 'uiautomator dump /data/local/tmp/st-ui.xml >/dev/null 2>&1; cat /data/local/tmp/st-ui.xml; rm -f /data/local/tmp/st-ui.xml' | tr '>' '\n' | grep -E 'id/(lockPatternView|bouncer_pattern_root)"' | head -1 | grep -o 'bounds="[^"]*"' | grep -o '[0-9]*' | tr '\n' ' ')
  read -r x0 y0 x1 y1 <<< "$B"
  [ -n "${y1:-}" ] && break
  a input keyevent KEYCODE_WAKEUP; a input keyevent 82; sleep 1.5
done
[ -n "${y1:-}" ] || { echo "pattern view not found"; exit 1; }
s=""
for ((i=0;i<${#P};i++)); do d=$(( ${P:$i:1} - 1 )); cx=$(( x0 + (x1-x0)*(2*(d%3)+1)/6 )); cy=$(( y0 + (y1-y0)*(2*(d/3)+1)/6 ))
  if [ -z "$s" ]; then s="input motionevent DOWN $cx $cy"; else for k in 1 2 3 4; do s="$s; input motionevent MOVE $(( lx+(cx-lx)*k/4 )) $(( ly+(cy-ly)*k/4 ))"; done; fi; lx=$cx; ly=$cy; done
a "$s; input motionevent MOVE $lx $ly; input motionevent UP $lx $ly"
for i in 1 2 3 4 5 6; do sleep 1; showing || { echo "unlocked"; exit 0; }; done
showing && { echo "still locked"; exit 1; }
echo "unlocked"
