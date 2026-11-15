#!/bin/busybox sh
# Test T1 (drivers612/power/THERMISTOR-ADC.md): pa/wf board thermistors with the modem off / on /
# off. Sourced by m1.sh when the argument "therm" is given (after common.sh).
# READ ONLY on the PMIC: nothing here writes a PMIC register. The only SPMI writes are the ones the
# VADC driver makes on its own peripheral (PMK8350 0x3100: channel select + conversion request) for
# every read, exactly as sec_thermistor's reads do. The GPIO registers are read through the
# qti-regmap-debugfs "address"/"count"/"data" files (address/count are kernel variables, data is a
# read) and the pinctrl debugfs (pinconf-groups reads EN_CTL/RT_STS live). No sec_thermistor and no
# sec-battery are loaded, so nobody on the apps side tries to configure gpio1..4.
#
# Output lines (all start with "T1 ", collected by all.sh):
#   T1 ADC  <phase>#<n> t=<uptime> ap=<uV>/<R_ntc>k/<C> pa=... wf=... chg=<uV>/<R>k bat=... quiet=<mC> xo=<mC> die=<mC>
#   T1 GPIO <phase>#<n> gN rt=<0x10> m40..4a=<11 bytes: MODE VIN PULL DIG_IN SRC OUT EN 47 48 49 ANA> en=<0x46>
#   T1 PIN  <phase>#<n> <pinconf-groups line of gpio1..4>
T1_IIO=; T1_REG=; T1_PIN=; T1_TB=/tmp/t1; T1_FIRST=1
# The bsp612 ramdisk links only a subset of busybox applets into /bin (bsp612/ramdisk/init):
# awk, od and paste are NOT among them (run kx-m1t-p1-182150: "awk: not found" -> every value
# that went through awk came out empty). Call them through busybox.
awk() { /bin/busybox awk "$@"; }
od() { /bin/busybox od "$@"; }
paste() { /bin/busybox paste "$@"; }

t1_setup() {
	k "T1: load the PMIC VADC (qcom-vadc-common + qcom-spmi-adc5; IIO core is built in)"
	ld therm.list
	for i in 1 2 3 4 5 6 7 8 9 10; do
		for d in /sys/bus/iio/devices/iio:device*; do
			[ -e "$d/in_temp_pa_therm_input" ] && { T1_IIO=$d; break; }
		done
		[ -n "$T1_IIO" ] && break; sleep 1
	done
	[ -n "$T1_IIO" ] || { k "T1 FAIL: no IIO device with in_temp_pa_therm_input"; dmesg | grep -iE "adc5|vadc|adc7|iio" | tail -10; ls /sys/bus/iio/devices/; }
	echo "T1 iio $T1_IIO name=$(cat $T1_IIO/name 2>/dev/null)"
	ls $T1_IIO 2>/dev/null | grep -E "_input$" | tr '\n' ' '; echo
	# qti-regmap-debugfs of PM7325 (SPMI SID 1, device 0-01)
	for d in /sys/kernel/debug/regmap/0-01 /sys/kernel/debug/regmap/0-01-*; do
		[ -e "$d/address" ] && [ -e "$d/data" ] && { T1_REG=$d; break; }
	done
	[ -n "$T1_REG" ] || echo "T1 FAIL: no qti regmap debugfs for 0-01 ($(ls /sys/kernel/debug/regmap 2>&1 | tr '\n' ' '))"
	# pinconf-GROUPS: pinctrl-spmi-gpio implements only pin_config_group_dbg_show, so pinconf-pins
	# prints nothing after "pin 0 (gpio1): " (seen in kx-m1t-p1-182150)
	for d in /sys/kernel/debug/pinctrl/*pm7325@1:pinctrl@8800*; do [ -e "$d/pinconf-groups" ] && T1_PIN=$d/pinconf-groups; done
	echo "T1 regmap=$T1_REG pinconf=$T1_PIN"
	# sec_thermistor's own tables, from the running DT (big-endian u32: uV ascending, 0.1 C)
	mkdir -p $T1_TB
	for p in 0:ap 2:pa 1:wf; do
		n=${p%%:*}; c=${p##*:}; D=
		for b in /sys/firmware/devicetree/base /proc/device-tree; do
			[ -e $b/samsung_mobile_device/sec_thermistor@$n/adc_array ] && { D=$b/samsung_mobile_device/sec_thermistor@$n; break; }
		done
		[ -n "$D" ] || D=$(find /sys/firmware/devicetree/base -type d -name "sec_thermistor@$n" 2>/dev/null | head -1)
		echo "T1 table $c from $D"
		t1_be32 $D/adc_array > $T1_TB/a; t1_be32 $D/temp_array > $T1_TB/t
		paste -d' ' $T1_TB/a $T1_TB/t > $T1_TB/$c.tbl
		echo "T1 table $c: $(wc -l < $T1_TB/$c.tbl) points, $(head -1 $T1_TB/$c.tbl) .. $(tail -1 $T1_TB/$c.tbl)"
	done
	for g in 1 2 3 4; do echo "T1 GPIO id g$g type/subtype=$(t1_rd $(t1_gbase $g 0x04) 2)"; done
}

t1_be32() { # big-endian u32 array file -> one signed integer per line
	od -An -v -tu1 "$1" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) b[n++] = $i }
		END { for (j = 0; j + 3 < n; j += 4) { v = ((b[j] * 256 + b[j+1]) * 256 + b[j+2]) * 256 + b[j+3]
			if (v >= 2147483648) v -= 4294967296; printf "%d\n", v } }'
}

t1_gbase() { printf "0x%x" $((0x8800 + ($1 - 1) * 0x100 + $2)); } # PM7325 gpio N register

t1_rd() { # t1_rd <addr> <count>: read-only regmap dump of PM7325 registers -> "aa bb cc"
	[ -n "$T1_REG" ] || { echo "-"; return; }
	echo "$1" > $T1_REG/address && echo "$2" > $T1_REG/count && cat $T1_REG/data | awk '{ printf "%s%s", s, $2; s = " " }'
}

t1_conv() { # t1_conv <channel> <uV>: "<uV>/<R_ntc>k[/<C>]" (sec_thermistor's binary search + interpolation)
	awk -v a="$2" -v f="$T1_TB/$1.tbl" 'BEGIN {
		if (a !~ /^-?[0-9]+$/) { printf "%s", a; exit }
		code = a * 28900 / 1875000; r = (code < 16384) ? 100 * code / (16384 - code) : -1
		printf "%d/%.1fk", a, r
		n = 0; while ((getline l < f) > 0) { split(l, x, " "); A[n] = x[1] + 0; T[n] = x[2] + 0; n++ }
		if (!n) exit
		lo = 0; hi = n - 1; got = 0
		if (A[lo] >= a) { t = T[lo]; got = 1 } else if (A[hi] <= a) { t = T[hi]; got = 1 }
		while (!got && lo <= hi) { m = int((lo + hi) / 2)
			if (A[m] > a) hi = m - 1; else if (A[m] < a) lo = m + 1; else { t = T[m]; got = 1 } }
		if (!got) t = T[hi] + int((T[lo] - T[hi]) * (a - A[hi]) / (A[lo] - A[hi]))
		printf "/%.1fC", t / 10 }'
}

t1_adc() { # t1_adc <label>: processed value; falls back to any *_input / *_raw attribute with the label in its name
	local f=$T1_IIO/in_temp_$1_input
	[ -e "$f" ] || f=$(ls $T1_IIO/*$1*_input $T1_IIO/*$1*_raw 2>/dev/null | head -1)
	[ -n "$f" ] && [ -e "$f" ] || { echo NOATTR; return; }
	cat "$f" 2>/dev/null || echo ERR
}

t1_inventory() { # once, with the first sample: what the paths really look like on the phone
	echo "T1 ls iio $T1_IIO: $(ls $T1_IIO 2>&1 | tr '\n' ' ')"
	echo "T1 ls regmap: $(ls /sys/kernel/debug/regmap 2>&1 | tr '\n' ' ')"
	echo "T1 ls regmap/0-01: $(ls /sys/kernel/debug/regmap/0-01 2>&1 | tr '\n' ' ')"
	echo "T1 ls pinctrl: $(ls /sys/kernel/debug/pinctrl 2>&1 | tr '\n' ' ')"
	echo "T1 ls pm7325 pinctrl: $(ls -d /sys/kernel/debug/pinctrl/*pm7325* 2>&1 | tr '\n' ' ')"
	echo "T1 ls sec_thermistor@2: $(ls /sys/firmware/devicetree/base/samsung_mobile_device/sec_thermistor@2 2>&1 | tr '\n' ' ')"
	[ -n "$T1_PIN" ] && sed -n '1,3p' $T1_PIN | sed 's/^/T1 pinconf-groups head: /'
	[ -e /sys/kernel/debug/gpio ] && grep -E "pm7325|gpio[1-4] *:" /sys/kernel/debug/gpio | head -8 | sed 's/^/T1 debug-gpio: /'
}

t1_sample() { # t1_sample <phase> <n>
	local tag="$1#$2" g line
	[ -n "$T1_FIRST" ] && { T1_FIRST=; t1_inventory; }
	line="T1 ADC  $tag t=$(cut -d' ' -f1 /proc/uptime)"
	for c in ap pa wf; do line="$line $c=$(t1_conv $c $(t1_adc ${c}_therm))"; done
	line="$line chg=$(t1_conv none $(t1_adc chg_thm)) bat=$(t1_conv none $(t1_adc bat_thm))"
	line="$line quiet=$(t1_adc pm7325_quiet_therm) xo=$(t1_adc pmk8350_xo_therm) die=$(t1_adc pm7325_die_temp)"
	echo "$line"
	for g in 1 2 3 4; do
		rt=$(t1_rd $(t1_gbase $g 0x10) 1); m=$(t1_rd $(t1_gbase $g 0x40) 11)
		echo "T1 GPIO $tag g$g rt=$rt m40..4a=[$m] en=$(echo "$m" | cut -d' ' -f7)"
	done
	[ -n "$T1_PIN" ] && grep -E "\((gpio[1-4])\):" $T1_PIN | sed "s/^/T1 PIN  $tag /"
}

t1_phase() { # t1_phase <phase> <count> [gap-seconds]
	local i=1
	k "T1 sample $1 x$2"
	while [ $i -le $2 ]; do t1_sample $1 $i; [ $i -lt $2 ] && sleep ${3:-2}; i=$((i + 1)); done
}
