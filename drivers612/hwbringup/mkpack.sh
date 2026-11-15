#!/bin/bash
# mkpack.sh <packdir> <stage> <module name | path.ko> ...
# Resolves soc-repo deps (tools/modorder.py) and the modinfo "depends" of external .ko files,
# copies stripped modules to <packdir>/m/ and writes <packdir>/<stage>.list (load order).
set -e
TOP=$(cd "$(dirname "$0")/../.." && pwd)
STRIP=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-strip
P=$1; ST=$2; shift 2; mkdir -p $P/m; : > $P/$ST.list
declare -A EXT   # name -> path of external modules given on the command line
for a in "$@"; do [ -f "$a" ] && EXT[$(basename $a .ko | tr - _)]=$a; done
emit() { local f=$1 b; b=$(basename $f); grep -qx "$b" $P/$ST.list && return 0
  [ -f $P/m/$b ] || $STRIP --strip-debug -o $P/m/$b $f; echo $b >> $P/$ST.list; }
addext() { local f=$1 d
  for d in $(modinfo -F depends $f | tr , ' '); do
    k=$(echo $d | tr - _)
    if [ -n "${EXT[$k]:-}" ]; then addext ${EXT[$k]}; else for m in $(python3 $TOP/tools/modorder.py $d 2>/dev/null); do emit $m; done; fi
  done; emit $f; }
for a in "$@"; do
  if [ -f "$a" ]; then addext $a; else for m in $(python3 $TOP/tools/modorder.py $a); do emit $m; done; fi
done
echo "$ST: $(wc -l < $P/$ST.list) modules"
