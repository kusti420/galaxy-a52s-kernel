#!/system/bin/sh
# Kernel suspend test on a USB-connected test phone (6.12 test Android, run as root).
# The PC's USB link keeps dwc3 busy (device_prepare -> -EBUSY), so the controller is detached
# for the test and re-attached afterwards INCLUDING Android's configfs gadget (UDC), which a
# plain driver re-bind does not restore (lost phone 2 on 2026-11-14 that way).
# Safety: a deadman reboots the phone after DEADMAN seconds unless the script finishes, so a
# hang in suspend/resume never needs anyone at the phone. Results: /data/local/tmp/susp.log
#   usage: susptest.sh [pm_test level ... | s2idle | skip]   (skip = only detach/re-attach USB)   e.g. susptest.sh devices   or   susptest.sh s2idle
L=/data/local/tmp/susp.log; : > $L; DEADMAN=${DEADMAN:-240}
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $L; }
( sleep $DEADMAN; log "DEADMAN: rebooting"; sync; echo b > /proc/sysrq-trigger ) & DM=$!
G=/config/usb_gadget/g1; UDC=$(cat $G/UDC 2>/dev/null)
log "levels=$* udc=$UDC deadman=${DEADMAN}s pid $DM"
sleep 3
echo a600000.ssusb > /sys/bus/platform/drivers/msm-dwc3/unbind; log "usb unbound rc=$?"
for lvl in "${@:-devices}"; do
	[ "$lvl" = skip ] && { log "level=skip (usb detach/attach only)"; continue; }
	dmesg -c > /dev/null
	if [ "$lvl" = s2idle ]; then
		echo none > /sys/power/pm_test; echo s2idle > /sys/power/mem_sleep
		echo 0 > /sys/class/rtc/rtc0/wakealarm; echo +15 > /sys/class/rtc/rtc0/wakealarm
	else
		echo "$lvl" > /sys/power/pm_test
	fi
	echo mem > /sys/power/state; rc=$?
	log "level=$lvl rc=$rc"
	dmesg | grep -E "PM: |failed|not prepared|Abort|returns -" | grep -v avc >> $L
	sleep 2
done
echo none > /sys/power/pm_test
log "done: success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"
echo a600000.ssusb > /sys/bus/platform/drivers/msm-dwc3/bind; log "usb bound rc=$?"
sleep 2
# re-attach the gadget: clear and re-write the UDC (name from before, else the first UDC present)
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc | head -1)
echo "" > $G/UDC 2>/dev/null; echo "$UDC" > $G/UDC; log "gadget UDC=$UDC rc=$?"
kill $DM 2>/dev/null; log "deadman cancelled"
