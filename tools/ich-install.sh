#!/bin/bash
# Package an IchthysOS real-boot build (rbichN) as a TWRP zip and install it on the IchthysOS daily phone through
# TWRP (on its recovery), leaving TWRP via Download mode on the hub port. Owner-approved debugging (2026-11-18).
# Usage: OWNER_OK=1 tools/ich-install.sh <N>     (builds out/ichthysN from out/rbichN)
set -u; N=$1; cd "$(dirname "$0")/.." || exit 1
R=drivers612/realboot; D=testdev-ichthys-202611112021; P=$R/out/ichthys$N/pkg; S=DAILYPHONE; PORT=${PORT:-6-5.3}
rm -rf $R/out/ichthys$N; mkdir -p $P; cp -a $R/out/rbich$N/vendor-addon $P/; cp $R/out/alpha5/pkg/install-addon.sh $P/
echo "IchthysOS debug build rbich$N." > $P/README.txt
T=$(mktemp -d); cp $R/out/rbich$N/{boot,vendor_boot,dtbo}.img $T/; tar --owner=0 --group=0 --numeric-owner -C $T -cf $P/a52s-k612-ichthys$N-AP.tar boot.img vendor_boot.img dtbo.img
cp $D/{boot,vendor_boot,dtbo}.img $T/; tar --owner=0 --group=0 --numeric-owner -C $T -cf $P/a52s-lineage-20261111-stock-AP.tar boot.img vendor_boot.img dtbo.img; rm -rf $T
(cd $P && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
ALLOW_ICHTHYS=1 $R/twrp/mk-twrp-zips.sh $P > logs/ichthys$N-zips.log 2>&1 || { echo "zip build failed"; exit 1; }
Z=$R/out/ichthys$N/twrp/a52s-k612-ichthys$N-twrp.zip
adb -s $S reboot recovery; for i in $(seq 1 50); do [ "$(adb -s $S get-state 2>/dev/null)" = recovery ] && break; sleep 3; done; sleep 3
adb -s $S push $Z /tmp/k.zip >/dev/null 2>&1
adb -s $S shell 'rm -f /tmp/a52s-k612.log; twrp install /tmp/k.zip' >/dev/null 2>&1
for i in $(seq 1 50); do adb -s $S shell 'grep -qE "^Done\.|Aborted" /tmp/a52s-k612.log' 2>/dev/null && break; sleep 4; done
adb -s $S shell 'grep -E "^Done|Aborted|ERROR" /tmp/a52s-k612.log' | cut -c1-120
adb -s $S reboot download; for i in $(seq 1 30); do [ "$(cat /sys/bus/usb/devices/$PORT/idProduct 2>/dev/null)" = 685d ] && break; sleep 2; done
tools/dlexit.sh $PORT >/dev/null 2>&1; sleep 25
for i in $(seq 1 60); do [ "$(adb -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 3; done
adb -s $S shell 'echo "kernel $(uname -r) boot_completed=$(getprop sys.boot_completed)"'
