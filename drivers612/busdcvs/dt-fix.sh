#!/bin/sh
# Bus-DCVS device-tree fix for the 6.12 trees (kexec/mkandroidtree.sh and
# drivers612/realboot/build-realboot.sh call it at the same point, so the tested and the real
# tree stay identical). Usage: dt-fix.sh <dtb>   (edited in place)
#
# Removes /soc/qcom,scmi/protocol@80 and protocol@81. Reason (README.md, run ab-s76): the
# phone's CPUCP (RIMPS) firmware is the 5.4-era one. Its BASE protocol list is rejected by the
# 6.12 SCMI core ("No. Returned protocols > Total protocols"), so 0x80/0x81 count as "not
# implemented" and no SCMI device is created for them; and 0x80 there is the 5.4 memlat-v1
# protocol (MEMLAT_SET_CPU_GROUP..., drivers/firmware/arm_scmi/memlat_vendor.c), not the 6.12
# qcom_scmi_vendor "set_param(algo string)" protocol, so it could not be used anyway.
# qcom_scmi_client.c's platform_get_qcom_scmi_device() returns -EPROBE_DEFER for as long as an
# "arm,scmi" node has a child with reg = 0x80 and no client probed: qcom-pmu-lib and memlat
# deferred forever. Without the child it returns -ENODEV and both run in AP-only mode, which is
# what the yupik memlat nodes ask for (no memlat-mon has qcom,cpucp-enabled; 5.4 ran
# DDR/LLCC memlat on the AP as well).
set -eu
D=${1:?dtb}
S=/soc/qcom,scmi
[ "$(fdtget "$D" $S compatible)" = arm,scmi ] || { echo "dt-fix: $S is not arm,scmi" >&2; exit 1; }
n=0
for p in protocol@80 protocol@81; do
	if fdtget -l "$D" $S | grep -qx "$p"; then fdtput -r "$D" $S/$p; n=$((n + 1)); fi
done
# their labels would dangle in /__symbols__ (nothing references them: checked on android-r02)
for l in scmi_memlat scmi_perf_lock; do
	if fdtget "$D" /__symbols__ $l >/dev/null 2>&1; then fdtput -d "$D" /__symbols__ $l; fi
done
fdtget -l "$D" $S | grep -q '^protocol@8[01]$' && { echo "dt-fix: protocol node still there" >&2; exit 1; }
# no other arm,scmi node may carry a reg = <0x80> child (the client's lookup walks all of them)
[ "$(fdtget -l "$D" /soc | grep -c '^qcom,scmi')" = 1 ] || { echo "dt-fix: more than one qcom,scmi node" >&2; exit 1; }
echo "dt-fix: removed $n SCMI vendor protocol node(s) from $S (memlat/pmu-lib AP mode)"

# --- L3 (L3-MEMLAT.md). Env: A52_L3_VOTE_OFFSET (default 0x90; "keep" = leave Qualcomm's value),
# A52_L3_FLOOR (default 1; 0 = leave the gold/prime tables alone).
# (1) Vote register. yupik.dtsi gives the L3 sampling path qcom,shared-offset = <0x0920>: that is
# the OSM (sm8150) PERF_STATE offset (5.4 qcom-cpufreq-hw.c std_offsets, osm-l3.c), not an EPSS
# one. yupik's L3 is EPSS: the phone's 5.4 kernel voted the AP's shared L3 vote at base + 0x90
# (5.4 interconnect/qcom/epss-l3.c REG_L3_VOTE, SLAVE_EPSS_L3_SHARED = domain 0 cpu 0), every
# other EPSS target in the 6.12 BSP uses <0x0090> (waipio, pineapple, ...), and dcvs_epss.c itself
# defines L3_VOTING_OFFSET 0x90. With 0x920 the AP's L3 DCVS votes most likely reach no voter.
L3P=/soc/qcom,dcvs/l3/sp
L3O=${A52_L3_VOTE_OFFSET:-0x90}
if [ "$L3O" != keep ]; then
	[ "$(fdtget "$D" $L3P compatible)" = qcom,dcvs-path ] || { echo "dt-fix: $L3P is not qcom,dcvs-path" >&2; exit 1; }
	[ "$(fdtget "$D" /soc/qcom,dcvs/l3 reg-names | cut -d' ' -f1)" = l3-base ] || { echo "dt-fix: l3 has no l3-base" >&2; exit 1; }
	old=$(fdtget -tx "$D" $L3P qcom,shared-offset)
	fdtput -tu "$D" $L3P qcom,shared-offset $((L3O))
	echo "dt-fix: L3 shared vote offset 0x$old -> $(printf 0x%x $((L3O)))"
fi
# (2) Idle floor. memlat.c cpufreq_to_memfreq() returns the FIRST table row when no CPU of the
# monitor qualifies (max_cpufreq 0), so the gold/prime L3 monitors never vote below 556800 kHz;
# 5.4's governor_memlat voted 0 there (-> min_freq 300 MHz). Prepend <300000 300000> (the row
# lahaina.dtsi's 6.12 gold/prime L3 tables start with): effective core freq <= 300 MHz -> 300 MHz.
if [ "${A52_L3_FLOOR:-0}" = 1 ]; then
	for m in gold prime; do
		p=/soc/qcom,memlat/l3/$m
		t=$(fdtget -tu "$D" $p qcom,cpufreq-memfreq-tbl)
		[ -n "$t" ] || { echo "dt-fix: no table in $p" >&2; exit 1; }
		case "$t" in 300000\ 300000\ *) echo "dt-fix: $p already has the 300 MHz floor row"; continue ;; esac
		# shellcheck disable=SC2086
		fdtput -tu "$D" $p qcom,cpufreq-memfreq-tbl 300000 300000 $t
		echo "dt-fix: $p floor row 300000 -> 300000 added"
	done
fi
# --- SE8 / SM5714 USB-PD (2026-11-15). The 6.12 boarddt copied Qualcomm's qcom,gpios-reserved list
# (32 33 48 49 50 51 56 57 58 59); 5.4 reserved only 56..59 and runs the SM5714 USB-PD chip
# (usbpd-sm5714@33) on SE8 = i2c@a80000, pins 32/33. With them reserved, a80000.i2c never probes
# ("could not request pin 32"), the PD chip stays unbound -> no Type-C attach events -> after a
# cable re-plug nothing sends NOTIFY_EVENT_VBUS and USB stays dead (phone 1, 2026-11-15); it also
# kept the interconnect's sync_state pending. Drop 32/33 only (48..51 stay: TZ-owned SPI likely).
# Env A52_SE8_UNRESERVE=0 keeps Qualcomm's list.
TP=/soc/pinctrl@f000000
if [ "${A52_SE8_UNRESERVE:-1}" = 1 ] && fdtget "$D" $TP qcom,gpios-reserved >/dev/null 2>&1; then
	old=$(fdtget -tu "$D" $TP qcom,gpios-reserved)
	new=$(for g in $old; do case $g in 32|33) ;; *) printf '%s ' $g;; esac; done)
	if [ "$old " != "$new" ]; then
		# shellcheck disable=SC2086
		fdtput -tu "$D" $TP qcom,gpios-reserved $new
		echo "dt-fix: TLMM gpios-reserved '$old' -> '${new% }' (SE8 USB-PD pins freed)"
	fi
fi

# --- PMIC temp-alarm trips (audit 2026-11-18): fdtoverlay reverses children an overlay adds
# (trip2,trip1,trip0). qcom-spmi-temp-alarm takes the FIRST critical trip as its stage-2 threshold
# (5.4: 115 C; reversed: 145 C -> thresh 3, every stage +10 C, pm8350c S2 not overridden). Restore
# ascending order in the *_tz zones only (the only ones whose driver depends on trip order).
# Env A52_TRIP_ORDER_FIX=0 keeps the tree as is.
if [ "${A52_TRIP_ORDER_FIX:-1}" = 1 ]; then
	for z in $(fdtget -l "$D" /soc/thermal-zones | grep '_tz$'); do
		T=/soc/thermal-zones/$z/trips
		kids=$(fdtget -l "$D" $T 2>/dev/null) || continue
		sorted=$(for k in $kids; do echo "$(fdtget -ti "$D" $T/$k temperature) $k"; done | sort -k1,1n -k2,2 | cut -d' ' -f2)
		if [ "$(echo $kids)" = "$(echo $sorted)" ]; then continue; fi
		# check every trip before the first one is touched
		for k in $kids; do
			for p in $(fdtget -p "$D" $T/$k); do
				case $p in type|temperature|hysteresis|phandle) ;; *) echo "dt-fix: $T/$k has $p" >&2; exit 1;; esac
			done
		done
		for k in $(printf '%s\n' $sorted | tac); do	# fdtput -c inserts in front
			ty=$(fdtget -ts "$D" $T/$k type); te=$(fdtget -ti "$D" $T/$k temperature); hy=$(fdtget -ti "$D" $T/$k hysteresis)
			ph=$(fdtget -tu "$D" $T/$k phandle 2>/dev/null || true)
			fdtput -r "$D" $T/$k; fdtput -c "$D" $T/$k
			fdtput -ts "$D" $T/$k type "$ty"; fdtput -ti "$D" $T/$k temperature $te; fdtput -ti "$D" $T/$k hysteresis $hy
			if [ -n "$ph" ]; then fdtput -tu "$D" $T/$k phandle $ph; fi
		done
		[ "$(echo $(fdtget -l "$D" $T))" = "$(echo $sorted)" ] || { echo "dt-fix: $T reorder failed" >&2; exit 1; }
		echo "dt-fix: $T trips reordered ascending"
	done
fi

# --- SD card detect (audit 2026-11-18): the phone's 5.4 base has bias-disable on gpio91 in sdc2_on
# (external pull-up, active-low CD); Qualcomm's 6.12 base has bias-pull-up, which draws current for
# as long as a card sits in the tray. An overlay cannot delete a base property, hence here.
SDCD=/soc/pinctrl@f000000/sdc2_on/sd-cd
if [ "${A52_SDCD_BIAS_FIX:-1}" = 1 ] && fdtget "$D" $SDCD bias-pull-up >/dev/null 2>&1; then
	[ "$(fdtget "$D" $SDCD pins)" = gpio91 ] || { echo "dt-fix: $SDCD is not gpio91" >&2; exit 1; }
	fdtput -d "$D" $SDCD bias-pull-up
	fdtput -ts "$D" $SDCD bias-disable
	echo "dt-fix: $SDCD bias-pull-up -> bias-disable (as the phone's 5.4 base)"
fi

# Thermal cooling-maps: Qualcomm 5.4 trees use THERMAL_MAX_LIMIT (0xfffffffe = "straight to max state") in the
# PMIC-temp and BCL zones (pm7325_tz, pm8350c_tz, pm8350c-bcl-lvl1/2, pmr735a_tz); 6.12 rejects it ("binding cdev
# kgsl/cdsp to trip N failed: -22") so those zones never throttled anything. Replace with THERMAL_NO_LIMIT
# (lower 0, upper max_state). Env A52_COOL_MAX_FIX=0 keeps the tree as is.
if [ "${A52_COOL_MAX_FIX:-1}" = 1 ]; then
	T=$(mktemp); dtc -q -I dtb -O dts -o "$T" "$D" 2>/dev/null
	python3 -I "$(dirname "$0")/cool-max-fix.py" "$T" > "$T.fix" || { rm -f "$T" "$T.fix"; echo "dt-fix: cool-max-fix failed" >&2; exit 1; }
	n=0
	while read -r p cells; do
		# shellcheck disable=SC2086
		fdtput -tx "$D" "$p" cooling-device $cells || { rm -f "$T" "$T.fix"; echo "dt-fix: fdtput $p failed" >&2; exit 1; }
		n=$((n + 1))
	done < "$T.fix"
	rm -f "$T" "$T.fix"
	if [ "$n" -gt 0 ]; then echo "dt-fix: $n cooling-maps 0xfffffffe (5.4 THERMAL_MAX_LIMIT) -> THERMAL_NO_LIMIT"; fi
fi
