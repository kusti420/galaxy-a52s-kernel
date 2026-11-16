#!/bin/sh
# /extra/m3touch.sh [seconds] in the mainline 7.3 bring-up ramdisk: loads the FTS5CU56A touch
# driver (stmfts5.ko; I2C13 + GPI DMA are built in), reports the chip identity read at probe and
# captures the input events for <seconds> (default 20). Touches need a person on the screen.
# Module options for the insmod: STMFTS5_ARGS (e.g. "debug=1": IC status registers in dmesg).
# Every step logs to kmsg first (ramoops shows how far it got). The IC's own firmware is used:
# the driver has no firmware update path.
log() { echo "a52sxq-m3touch: $*" > /dev/kmsg; echo "$*"; }
S=${1:-20}
X=/extra
log "i2c13: $(ls /sys/bus/i2c/devices/ | tr '\n' ' ')"
grep -q '^stmfts5 ' /proc/modules || { log "insmod stmfts5"; insmod $X/stmfts5.ko $STMFTS5_ARGS || log "insmod stmfts5 failed"; }
sleep 2
C=; for d in /sys/bus/i2c/drivers/stmfts5/*-0049; do [ -e "$d" ] && C=$d; done
[ -n "$C" ] || { log "stmfts5 not bound: $(dmesg | grep -i -E 'stmfts5|0049|geni_i2c|gpi' | tail -n 8)"; exit 1; }
log "bound ${C##*/}: chip_id $(cat $C/chip_id) fw $(cat $C/fw_version) config $(cat $C/config_version) main $(cat $C/main_version)"
E=; for e in /sys/class/input/event*; do grep -q 'STM FTS5' $e/device/name 2>/dev/null && E=/dev/input/${e##*/}; done
[ -n "$E" ] || { log "no input device"; exit 1; }
log "input $E ($(cat /sys/class/input/${E##*/}/device/name)); irq: $(grep stmfts5 /proc/interrupts | tr -s ' ')"
# interrupt path without a finger: make the IC post the echo of a harmless command (0x62 =
# clear event FIFO, which the driver also sends at every power on); the driver reads it from
# its interrupt thread, so the TLMM 81 count must rise
I0=$(grep stmfts5 /proc/interrupts | tr -s ' ' | cut -d' ' -f3-10 | tr ' ' '+' | sed 's/+$//')
P=$X/i2cpoke; [ -x /tmp/i2cpoke ] && P=/tmp/i2cpoke
B=${C##*/}; B=/dev/i2c-${B%-0049}
$P $B 49 62 && sleep 1
I1=$(grep stmfts5 /proc/interrupts | tr -s ' ' | cut -d' ' -f3-10 | tr ' ' '+' | sed 's/+$//')
log "irq test (0x62 echo via $B): count $((I0)) -> $((I1))"
log "capturing $S s from $E: touch the screen now (orientation check: first tap the top-left corner, then the bottom-right corner, then swipe)"
cat $E > /tmp/touch-ev.bin & P=$!
sleep $S; kill $P 2>/dev/null; wait $P 2>/dev/null
# decode with the static tools/evcount (busybox hexdump/awk mis-parsed the 24-byte records)
log "$($X/evcount /tmp/touch-ev.bin 0 | tail -n 1); irq: $(grep stmfts5 /proc/interrupts | tr -s ' ')"
$X/evcount /tmp/touch-ev.bin 20 | head -n 20
[ -r $C/ic_status ] && while read -r l; do log "ic_status: $l"; done < $C/ic_status
log "done"
