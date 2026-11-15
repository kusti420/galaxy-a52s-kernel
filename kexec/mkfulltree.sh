#!/bin/sh
# Builds the dtb used as KEXEC_BASE for 6.12 runs with the full Samsung board tree:
# drivers612/boarddt's merged tree for one hardware-revision entry (default r02 = revisions 3
# and 4), with the bring-up-only edits that are not right for a finished ROM:
#  - /soc/ssusb@a600000 extcon: only the EUD (first phandle). The second one is Samsung's
#    extcon, provided by the charging stack; without that driver the USB controller never
#    probes and the test kernel has no shell.
# Usage: kexec/mkfulltree.sh [r02] [out.dtb]   (default out: out-ack/kx/full-<rev>-usb.dtb)
set -e
cd "$(dirname "$0")/.."
REV=${1:-r02}; OUT=${2:-out-ack/kx/full-$REV-usb.dtb}
SRC=drivers612/boarddt/out/build/merged-$REV.dtb
mkdir -p "$(dirname "$OUT")"; cp "$SRC" "$OUT.tmp"
EUD=$(fdtget -t u "$OUT.tmp" /soc/ssusb@a600000 extcon | cut -d' ' -f1)
fdtput -t u "$OUT.tmp" /soc/ssusb@a600000 extcon "$EUD"
fdtget "$OUT.tmp" /soc/rsc@af20000/drv@0/sde_rsc_rpmh compatible >/dev/null
mv "$OUT.tmp" "$OUT"; echo "$OUT: extcon=<$EUD>, $(stat -c %s "$OUT") bytes"
