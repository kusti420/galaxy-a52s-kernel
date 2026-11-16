#!/bin/bash
# Get the user's attention for a physical step (touch a phone, keys, unplug).
# Plays a mechanical air-raid siren on the PC and shows a critical desktop notification that names
# this session (terminal window title) and the task; its "Show" button focuses the exact terminal
# window in niri (found by walking this process's ancestry to a niri window's pid).
# Usage: tools/attention.sh "what to do"
M=${1:-"your hands are needed at the phone"}
S=$HOME/.local/share/a52s/siren.wav   # generated 11 s two-tone mechanical siren; fallback: freedesktop bell
[ -f "$S" ] || S=/usr/share/sounds/freedesktop/stereo/bell.oga
( paplay "$S" 2>/dev/null || pw-play "$S" 2>/dev/null ) &
read -r WID WTITLE < <(niri msg --json windows 2>/dev/null | python3 -c '
import json, sys, os
ws = json.load(sys.stdin); anc = set(); p = os.getppid()
while p > 1:
    anc.add(p)
    try: p = int(open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1])
    except Exception: break
for w in ws:
    if w.get("pid") in anc:
        print(w["id"], (w.get("title") or "terminal").strip()); break
')
TITLE="A52s kernel: action needed"
BODY="$M"$'\n'"Window: ${WTITLE:-this Claude session} (repo a52sxq-mainline)"
if [ -n "$WID" ]; then
	( a=$(notify-send -u critical -a "A52s kernel" -A show=Show --wait "$TITLE" "$BODY" 2>/dev/null)
	  [ "$a" = show ] && niri msg action focus-window --id "$WID" >/dev/null 2>&1 ) &
else
	notify-send -u critical -a "A52s kernel" "$TITLE" "$BODY" 2>/dev/null || true
fi
