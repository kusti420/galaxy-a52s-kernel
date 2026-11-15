#!/bin/bash
# Reboots ONE phone out of Download mode, addressed by its USB port, with odin4 --reboot.
# Unlike `heimdall print-pit` this works with several phones in Download mode at once.
# Like it, the round trip clears the bootloader's sticky PARAM_BOOT_RECOVERY_ENTER flag.
# Usage: tools/dlexit.sh <usb port, e.g. 1-5.3 or /sys/bus/usb/devices/1-5.3>
P=/sys/bus/usb/devices/$(basename "$1")
[ "$(cat $P/idVendor 2>/dev/null):$(cat $P/idProduct 2>/dev/null)" = 04e8:685d ] || { echo "$P is not in Download mode"; exit 5; }
DEV=$(printf '/dev/bus/usb/%03d/%03d' "$(cat $P/busnum)" "$(cat $P/devnum)")
odin4 -l 2>/dev/null | grep -qx "$DEV" || { echo "odin4 does not list $DEV"; exit 6; }
odin4 --reboot -d "$DEV" >/dev/null 2>&1
