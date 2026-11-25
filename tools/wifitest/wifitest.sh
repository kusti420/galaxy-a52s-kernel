#!/bin/bash
# Wi-Fi check of a real 6.12 boot on a test phone (root adb; silent; flashes nothing):
# link state, scan, pings, a download rate, 5 pm_test=devices suspend cycles each followed by pings
# (SPEC/06: Wi-Fi drops after suspend), wlan error counts in dmesg.
#   tools/wifitest/wifitest.sh <label>      -> logs/wifi/<label>.txt
# Env: SERIAL (PHONE2 default | PHONE1), URL (download test file; default a public speed-test
#      file, plain GET, no extra headers), DL_SECS (10), CYCLES (5), PM_TEST (devices)
set -u
S=${SERIAL:-PHONE2}
case "$S" in PHONE2|PHONE1) ;; *) echo "refusing serial $S (test phones only)" >&2; exit 2;; esac
LABEL=${1:?label}
URL=${URL:-http://speedtest.tele2.net/100MB.zip}; DL=${DL_SECS:-10}; CYC=${CYCLES:-5}; PMT=${PM_TEST:-devices}
cd "$(dirname "$0")/../.."; mkdir -p logs/wifi; O=logs/wifi/$LABEL.txt
A() { adb -s "$S" "$@"; }
P() { A shell "$@" 2>&1 | tr -d '\r'; }
exec > >(tee "$O") 2>&1
[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 1; }
[ "$(P id -u)" = 0 ] || { echo "needs root adb (adb -s $S root)"; exit 1; }
P 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done' >/dev/null
echo "== wifitest $LABEL $(date +%F_%T) serial $S kernel $(P uname -r) build $(P 'cat /proc/device-tree/soc/a52sxq,realboot' | tr -d '\0')"
echo "wlan module: srcversion $(P cat /sys/module/wlan/srcversion) refcnt $(P cat /sys/module/wlan/refcnt); driver: $(P 'cat /sys/kernel/wifi/wlan/driver_version 2>/dev/null || cat /sys/wifi/wifiver 2>/dev/null | head -3' | tr '\n' ' ')"
BAD0=$(P 'dmesg | grep -cE "firmware crashed|wlan.*recovery|fw_crash|WLAN suspend timeout|Suspend timeout|wow.*nack|PD_DOWN|qcom_q6v5.*fatal"')
link() { P 'cmd wifi status' | grep -E "Wifi is|WifiInfo|successfulTx|RSSI|Link speed|Frequency" | sed 's/, BSSID: [^,]*//; s/, MAC: [^,]*//' | cut -c1-330; }
echo "-- link"; link
GW=$(P 'ip route show dev wlan0' | awk '/default/{print $3; exit}'); [ -n "$GW" ] || GW=$(P 'ip route get 1.1.1.1' | awk '{for(i=1;i<NF;i++) if($i=="via") print $(i+1)}' | head -1)
echo "gateway: ${GW:-none}; wlan0: $(P 'ip -4 -o addr show wlan0' | awk '{print $4}')"
echo "-- scan"
P 'cmd wifi start-scan' | head -1; sleep 6
echo "scan results: $(P 'cmd wifi list-scan-results' | tail -n +2 | grep -c .) networks (5 GHz+: $(P 'cmd wifi list-scan-results' | awk 'NR>1 && $2>3000' | grep -c .))"
png() { # target count -> "tx/rx loss% avg ms"
	P "ping -c $2 -i 0.2 -W 2 $1" | awk -F'[ /]' '/packets transmitted/{tx=$1; rx=$4} /^rtt|^round-trip/{avg=$8} END{printf "%s/%s lost %d%% avg %s ms", tx, rx, (tx>0)?100*(tx-rx)/tx:100, (avg==""?"-":avg)}'
}
echo "-- ping x20"
[ -n "$GW" ] && echo "gateway $GW: $(png "$GW" 20)"
echo "1.1.1.1: $(png 1.1.1.1 20)"
echo "-- download ${DL} s from $URL"
P "T=/data/local/tmp/wifitest.bin; rm -f \$T; if command -v curl >/dev/null 2>&1; then timeout $DL curl -s -o \$T '$URL'; else timeout $DL toybox wget -q -O \$T '$URL' 2>/dev/null || timeout $DL wget -q -O \$T '$URL'; fi; B=\$(stat -c %s \$T 2>/dev/null || echo 0); rm -f \$T; echo \"bytes \$B in <= $DL s = \$((B / $DL / 1024)) KiB/s = \$((B * 8 / $DL / 1000000)) Mbit/s (tool: \$(command -v curl || echo wget))\""
RXB0=$(P 'cat /sys/class/net/wlan0/statistics/rx_bytes')
echo "-- $CYC x pm_test=$PMT suspend cycle, ping x5 after each"
FAILC=0
for i in $(seq "$CYC"); do
	rc=$(P "echo $PMT > /sys/power/pm_test; echo mem > /sys/power/state; echo rc=\$?; echo none > /sys/power/pm_test" | tail -1)
	sleep 1
	[ "$(A get-state 2>/dev/null)" = device ] || { echo "cycle $i: PHONE GONE"; exit 9; }
	r=$(png "${GW:-1.1.1.1}" 5); st=$(P 'cmd wifi status' | grep -m1 -oE "Wifi is [a-z ]+(connected to \"[^\"]*\")?")
	echo "cycle $i: state $rc; ping ${GW:-1.1.1.1}: $r; $st"
	case "$r" in *"lost 0%"*) ;; *) FAILC=$((FAILC + 1));; esac
done
P 'echo none > /sys/power/pm_test' >/dev/null
echo "-- after"; link
BAD1=$(P 'dmesg | grep -cE "firmware crashed|wlan.*recovery|fw_crash|WLAN suspend timeout|Suspend timeout|wow.*nack|PD_DOWN|qcom_q6v5.*fatal"')
WERR=$(P 'dmesg | grep -cE "wlan: \[[^]]*:(E|F):"'); WARNS=$(P 'dmesg | grep -cE "WARNING|BUG:|Oops"')
P 'dmesg | grep -E "firmware crashed|wlan.*recovery|fw_crash|WLAN suspend timeout|Suspend timeout|wow.*nack|PD_DOWN" | tail -5' | cut -c1-200
P 'dmesg | grep -E "PM: suspend (entry|exit)|PM: Some devices failed|failed to suspend" | tail -4' | cut -c1-160
echo "SUMMARY $LABEL: cycles with ping loss $FAILC/$CYC; wlan crash/recovery/suspend-timeout lines $BAD0 -> $BAD1; wlan E/F log lines $WERR; kernel WARN/BUG $WARNS; pm_test now $(P cat /sys/power/pm_test | grep -o '\[[a-z]*\]')"
echo "log: $O"
