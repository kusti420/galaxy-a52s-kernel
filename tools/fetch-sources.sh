#!/bin/sh
# Fetch the upstream trees listed in SOURCES.lock at their pinned commits.
#   tools/fetch-sources.sh                  the trees needed to build (note "build: ...")
#   tools/fetch-sources.sh --all            also the read-only reference donors
#   tools/fetch-sources.sh <path-prefix>... only these
# Shallow fetch of the exact commit; falls back to a full fetch if the server refuses
# fetching by SHA. Existing clones are left alone. Then run tools/prepare-vendored.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALL=0; [ "${1:-}" = --all ] && { ALL=1; shift; }
grep -v '^#' "$ROOT/SOURCES.lock" | while IFS="$(printf '\t')" read -r path url commit note; do
  [ -n "$path" ] || continue
  if [ $# -gt 0 ]; then
    m=0; for pre in "$@"; do case "$path" in "$pre"*) m=1;; esac; done; [ $m = 1 ] || continue
  elif [ $ALL = 0 ]; then
    case "$note" in build*) ;; *) continue;; esac
  fi
  d=$ROOT/$path
  if [ -d "$d/.git" ]; then echo "have  $path ($(git -C "$d" rev-parse --short HEAD))"; continue; fi
  echo "fetch $path <- $url @ $commit"
  mkdir -p "$d"; git -C "$d" init -q; git -C "$d" remote add origin "$url"
  if ! git -C "$d" fetch -q --depth 1 origin "$commit"; then
    git -C "$d" fetch -q origin
  fi
  git -C "$d" -c advice.detachedHead=false checkout -q "$commit"
done
