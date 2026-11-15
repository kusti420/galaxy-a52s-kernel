#!/bin/bash
# tools/mkpatch.sh <repo: soc-repo|devicetree> <patch-name> <file>...   (description on stdin)
# Writes patches/<repo>/<patch-name>.patch = donor vs our edited copy, for the given files.
set -e
BSP=$(cd "$(dirname "$0")/.." && pwd)
case "$1" in soc-repo) D=$BSP/../donors/clo-kernel-6.12 ;; devicetree) D=$BSP/../donors/clo-devicetree-6.12 ;; *) exit 2 ;; esac
repo=$1; name=$2; shift 2
out=$BSP/patches/$repo/$name.patch; : > "$out.tmp"
for f in "$@"; do
  ( cd "$BSP" && diff -u --label "a/$f" --label "b/$f" "$D/$f" "$repo/$f" >> "$out.tmp" ) || true
done
{ cat; cat "$out.tmp"; } > "$out"; rm -f "$out.tmp"
echo "$out: $(grep -c '^@@' "$out") hunks"
