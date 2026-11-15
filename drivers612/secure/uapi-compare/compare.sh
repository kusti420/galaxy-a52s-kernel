#!/bin/bash
# Compare ioctl numbers (they encode direction, type, nr and sizeof(arg)) of the phone's 5.4 UAPI
# headers against the 6.12 securemsm-kernel ones, for 64-bit (aarch64) and 32-bit (armv7) callers.
# Nothing is executed: each macro is compiled to a constant and read back from the assembly.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PRJ=$(cd "$HERE/../../.." && pwd)
OLD=${ANDROID_TREE:-$HOME/android}/kernel/samsung/sm7325/include/uapi/linux
NEW=${NEW:-$PRJ/drivers612/secure/securemsm/src/include/uapi/linux}
CC=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/clang
UH=$PRJ/bsp612/out/lahaina/usr/include; [ -d "$UH/linux" ] || UH=/usr/include
dump() { # dir header target -> "NAME value"
  local dir=$1 h=$2 tgt=$3 names
  names=$(cat "$dir"/$h $( [ $h = qseecom.h ] && ls "$dir"/qseecom_api.h 2>/dev/null) | grep -oE '^#define[[:space:]]+[A-Z0-9_]+(_IOCTL_|_IOC_|IOCTL)[A-Z0-9_]*[[:space:]]' | awk '{print $2}' | sort -u)
  { echo "#include <linux/types.h>"; echo "#include <linux/ioctl.h>"; echo "#include \"$h\""; [ $h = qseecom.h ] && [ -e "$dir/qseecom_api.h" ] && echo "#include \"qseecom_api.h\"";
    for n in $names; do echo "#ifdef $n"; echo "unsigned long long v_$n = (unsigned int)($n);"; echo "#endif"; done; } > "$HERE/.t.c"
  "$CC" --target=$tgt -ffreestanding -Wno-everything -I"$dir" -isystem "$UH" -S -o - "$HERE/.t.c" 2>"$HERE/.err" |
    awk '/^v_[A-Za-z0-9_]+:/{n=substr($1,3); sub(":","",n)} /\.(quad|xword|long)/{ if(n!=""){ if(!(n in s)){s[n]=1; printf "%s 0x%08x\n", n, $2} ; if ($1==".quad"||$1==".xword") n=""; else if(++c[n]==2) n="" } }' | sort
  [ -s "$HERE/.err" ] && { echo "COMPILE PROBLEM $dir/$h $tgt:" >&2; head -5 "$HERE/.err" >&2; }
  return 0
}
for h in qseecom.h smcinvoke.h qcedev.h; do
  for tgt in aarch64-linux-gnu armv7a-linux-gnueabi; do
    dump "$OLD" $h $tgt > "$HERE/$h.$tgt.54.txt"; dump "$NEW" $h $tgt > "$HERE/$h.$tgt.612.txt"
    echo "=== $h $tgt: $(wc -l < "$HERE/$h.$tgt.54.txt") ioctls on 5.4, $(wc -l < "$HERE/$h.$tgt.612.txt") on 6.12"
    join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$HERE/$h.$tgt.54.txt" "$HERE/$h.$tgt.612.txt" | awk '$2!=$3{print "  DIFF " $0}'
  done
done
rm -f "$HERE/.t.c" "$HERE/.err"
