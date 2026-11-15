#!/bin/sh
# First on-device test of the A52s touchscreen on the 6.12 BSP, for the busybox test ramdisk.
# Put this file and the 9 modules (sec_core.ko + the 8 from drivers612/touch/src) in one
# directory of the ramdisk (bsp612/ramdisk/extra -> /extra) and run:  sh /extra/touch-test.sh
#
# Preconditions: the board dtb contains a52sxq-touch.dtsi, and the ramdisk has already loaded
# pinctrl-yupik, gcc-sc7280, rpmh-regulator (first-stage list) and i2c-msm-geni with its
# dependencies (see README.md). NO firmware file is needed or wanted for the first test.
D=${1:-/extra}
LCD=$(sed -n 's/.*sec_common_fn\.lcd_id=\([0-9A-Fa-f]*\).*/\1/p' /proc/cmdline)

say() { echo "touch-test: $*"; }

# 1. bus
if ! ls /sys/bus/i2c/devices/ 2>/dev/null | grep -q -- '-0049$'; then
	say "FAIL no i2c client at 0x49: SE13 bus not up (i2c-msm-geni loaded? dtsi applied?)"
	ls /sys/bus/i2c/devices/ 2>/dev/null
	dmesg | grep -i -e geni -e a94000 | tail -20
	exit 1
fi

# 2. modules, in dependency order. busybox insmod does not read module parameters from the
#    kernel command line, so the bootloader's sec_common_fn.lcd_id= is passed by hand.
for m in sec_core sec_tsp_log sec_input_notifier sec_cmd sec_secure_touch sec_common_fn \
	 sec_tclm_v2 sec_tsp_dumpkey stm_ts; do
	[ -d /sys/module/$m ] && continue
	if [ $m = sec_common_fn ] && [ -n "$LCD" ]; then
		insmod $D/$m.ko lcd_id=$LCD || { say "FAIL insmod $m"; exit 1; }
	else
		insmod $D/$m.ko || { say "FAIL insmod $m"; exit 1; }
	fi
done
sleep 3		# probe + the 50 ms read_info work

# 3. probe result
dmesg | grep -e sec_input -e stm_ts | tail -60
if [ ! -e /sys/class/sec/tsp/cmd ]; then
	say "FAIL /sys/class/sec/tsp/cmd missing: probe did not finish (see log above)"
	exit 1
fi
say "sysfs: $(ls /sys/class/sec/tsp/ | tr '\n' ' ')"
say "input: $(cat /sys/class/sec/tsp/input/name) enabled=$(cat /sys/class/sec/tsp/input/enabled)"

# 4. talk to the IC through the factory command interface (pure I2C reads, nothing is written
#    to the IC's flash)
for c in get_chip_vendor get_chip_name get_fw_ver_ic get_fw_ver_bin get_x_num get_y_num; do
	echo $c > /sys/class/sec/tsp/cmd
	say "$c -> $(cat /sys/class/sec/tsp/cmd_result)"
done

# 5. raw touches: 10 s of events. Opening the event node calls the driver (input open ->
#    stm_ts_input_open), the same path Android takes when it opens the device.
EV=
for e in /sys/class/input/event*; do
	[ "$(cat $e/device/name)" = sec_touchscreen ] && EV=/dev/input/${e##*/}
done
[ -n "$EV" ] || { say "FAIL no event node for sec_touchscreen"; exit 1; }
[ -e $EV ] || mknod $EV c 13 $((64 + ${EV##*event}))
say "touch the screen now (10 s), reading $EV"
say "one line per event, 32-bit words: sec sec usec usec CCCCTTTT VALUE (TTTT 0003 = ABS, CCCC 0035/0036 = X/Y, 0039 = tracking id)"
timeout 10 hexdump -v -e '6/4 "%08x " "\n"' $EV 2>/dev/null | sed 's/^/  /' | head -80
say "irq count: $(grep stm_ts /proc/interrupts)"
say "done"
