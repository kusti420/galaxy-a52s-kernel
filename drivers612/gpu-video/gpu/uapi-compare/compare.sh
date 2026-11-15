#!/bin/bash
# Compare msm_kgsl.h of the phone's 5.4 kernel with the 6.12 donor: every IOCTL_KGSL_* number and
# every struct size, for aarch64 and for 32-bit arm (compat callers). Output: report.txt
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
OLD=${OLD:-$HOME/git/android/kernel/samsung/sm7325/include/uapi/linux/msm_kgsl.h}
NEW=${NEW:-$D/../src/include/uapi/linux/msm_kgsl.h}
UAPI=${UAPI:-$D/../../../../bsp612/out/lahaina/usr/include}
CLANG=${CLANG:-$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin/clang}
gen() { # header target tag
  local h=$1 t=$2 tag=$3 c=$D/.gen.$3.c
  { echo '#include <stddef.h>'; echo "#include \"$h\""
    grep -oE '^#define[ \t]+IOCTL_KGSL_[A-Z0-9_]+' "$h" | awk '{print $2}' | sort -u | while read -r n; do
      echo "unsigned long long v_$n = $n;"; done
    grep -oE '^struct[ \t]+[a-z0-9_]+[ \t]*\{' "$h" | awk '{print $2}' | sort -u | while read -r n; do
      echo "unsigned long long s_$n = sizeof(struct $n);"; done
  } > "$c"
  "$CLANG" -target "$t" -ffreestanding -D__user= -I"$UAPI" -S -emit-llvm -o - "$c" 2>"$D/.gen.$tag.err" |
    sed -nE 's/^@([vs]_[A-Za-z0-9_]+) = .*global i64 (-?[0-9]+).*/\1 \2/p' | sort > "$D/.gen.$tag.txt"
  rm -f "$c"
}
gen "$OLD" aarch64-linux-gnu old64; gen "$NEW" aarch64-linux-gnu new64
gen "$OLD" armv7a-linux-gnueabi old32; gen "$NEW" armv7a-linux-gnueabi new32
{
for b in 64 32; do
  echo "== ${b}-bit: only in 5.4 (REMOVED in donor)";  join -v1 "$D/.gen.old$b.txt" "$D/.gen.new$b.txt"
  echo "== ${b}-bit: only in donor (added)";           join -v2 "$D/.gen.old$b.txt" "$D/.gen.new$b.txt"
  echo "== ${b}-bit: in both, value DIFFERS (name 5.4 donor)"; join "$D/.gen.old$b.txt" "$D/.gen.new$b.txt" | awk '$2!=$3'
  echo "== ${b}-bit: identical: $(join "$D/.gen.old$b.txt" "$D/.gen.new$b.txt" | awk '$2==$3' | wc -l) symbols (ioctls: $(join "$D/.gen.old$b.txt" "$D/.gen.new$b.txt" | awk '$2==$3 && /^v_/' | wc -l), structs: $(join "$D/.gen.old$b.txt" "$D/.gen.new$b.txt" | awk '$2==$3 && /^s_/' | wc -l))"
done
} > "$D/report.txt"
cat "$D/.gen."*.err | sort -u | head -20
cat "$D/report.txt"
