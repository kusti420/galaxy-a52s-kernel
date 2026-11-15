# sourced by the stage scripts; run from the pack directory
k() { echo "a52sxq-init: hw: $*" > /dev/kmsg; echo "## $*"; }
ld() { # ld <stage> [skip-regex]: insmod every module of <stage>.list
  for m in $(cat $1.list); do
    n=${m%.ko}; [ -n "$2" ] && echo "$n" | grep -qE "$2" && { k "SKIP $m"; continue; }
    [ -d /sys/module/$(echo $n | tr - _) ] && continue
    k "insmod $m"; insmod m/$m 2>&1 || k "FAIL $m"
  done; sh /p/mkdevs; }
# the 6.12 GKI has no devtmpfs: the ramdisk makes nodes from sysfs (mkdevs); call it after insmod
