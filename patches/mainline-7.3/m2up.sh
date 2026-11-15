#!/bin/sh
# /extra/m2up.sh in the mainline 7.3 bring-up ramdisk: brings up the M2 board drivers that are
# modules on purpose (a crash in them lands in the harness). Every step logs to kmsg first, so
# ramoops shows how far it got. Usage: /extra/m2up.sh [wdt] [sd] [vib] [dsp]   (default: all)
#   wdt  gunyah_wdt + busybox feeder on it (30 s, petted every 5 s; stop: killall watchdog)
#   sd   sdhci-msm (microSD host; nothing is mounted)
#   vib  gpio-vibra (FF device; /extra/ffbuzz /dev/input/eventN <ms> plays one effect)
#   dsp  mounts the phone's OWN apnhlos read-only at /fw, points firmware_class at /fw/image,
#        loads the PAS driver (ADSP + CDSP boot) and fastrpc. Never another phone's firmware.
log() { echo "a52sxq-m2up: $*" > /dev/kmsg; echo "$*"; }
X=/extra
want() { [ $# = 0 ] || case " $ARGS " in *" $1 "*) return 0;; esac; [ -z "$ARGS" ]; }
ARGS="$*"
if want wdt; then
	log "gunyah_wdt"; insmod $X/gunyah_wdt.ko 2>/dev/null
	W=; for w in /sys/class/watchdog/watchdog*; do [ -e $w/device ] && W=/dev/${w##*/}; done
	[ -n "$W" ] && watchdog -T 30 -t 5 $W && log "watchdog $W armed 30 s, feeder every 5 s"
fi
want sd && { log "sdhci-msm"; insmod $X/sdhci-msm.ko; }
want vib && { log "gpio-vibra"; insmod $X/gpio-vibra.ko; }
if want dsp; then
	P=; for u in /sys/class/block/sd*/uevent; do grep -q "^PARTNAME=apnhlos$" $u && P=$(grep ^DEVNAME= $u | cut -d= -f2); done
	[ -n "$P" ] || { log "no apnhlos partition: dsp skipped"; exit 1; }
	mkdir -p /fw; grep -q " /fw " /proc/mounts || mount -t vfat -o ro /dev/$P /fw || { log "mount $P failed"; exit 1; }
	echo -n /fw/image > /sys/module/firmware_class/parameters/path
	log "firmware path /fw/image (own apnhlos $P, ro); loading PAS: ADSP + CDSP boot"
	for m in qcom_pil_info qcom_common qcom_q6v5 qcom_q6v5_pas; do insmod $X/$m.ko || log "insmod $m failed"; done
	i=0; while [ $i -lt 30 ]; do
		n=0; for r in /sys/class/remoteproc/*/state; do [ "$(cat $r)" = running ] && n=$((n + 1)); done
		[ $n -ge 2 ] && break; sleep 1; i=$((i + 1))
	done
	for r in /sys/class/remoteproc/*; do log "$(cat $r/name) $(cat $r/state)"; done
	log "fastrpc"; insmod $X/fastrpc.ko; sleep 1; log "$(ls /dev/fastrpc* | tr '\n' ' ')"
fi
log "done"
