#!/bin/sh
# Put the vendored upstream driver trees back together. Each <tree>.upstream/ directory says
# which pinned upstream clone the tree comes from (source), which of its files the tree uses
# (files.list), our changes to them (changes.patch) and the symlinks (symlinks.list). Files we
# added are already in <tree>/. Run tools/fetch-sources.sh first.
#   tools/prepare-vendored.sh [tree ...]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
find . -path ./.git -prune -o -type d -name '*.upstream' -print | sed 's|^\./||' | sort |
while read -r meta; do
  tree=${meta%.upstream}
  if [ $# -gt 0 ]; then
    m=0; for t in "$@"; do [ "${t%/}" = "$tree" ] && m=1; done; [ $m = 1 ] || continue
  fi
  donor=$(sed -n 's/^path=//p' "$meta/source"); commit=$(sed -n 's/^commit=//p' "$meta/source")
  if [ -f "$tree/.prepared" ]; then echo "have     $tree"; continue; fi
  [ -d "$donor/.git" ] || { echo "missing  $donor (tools/fetch-sources.sh $donor)" >&2; exit 1; }
  [ "$(git -C "$donor" rev-parse HEAD)" = "$commit" ] || { echo "$donor is not at $commit" >&2; exit 1; }
  mkdir -p "$tree"
  (cd "$donor" && tar -cf - --no-recursion -T "$ROOT/$meta/files.list") | tar -xf - -C "$tree"
  while read -r l t; do [ -n "$l" ] && mkdir -p "$(dirname "$tree/$l")" && ln -sfn "$t" "$tree/$l"; done < "$meta/symlinks.list"
  [ -s "$meta/changes.patch" ] && patch -s -p1 -d "$tree" < "$meta/changes.patch"
  : > "$tree/.prepared"
  echo "prepared $tree ($(wc -l < "$meta/files.list") files from $donor)"
done
