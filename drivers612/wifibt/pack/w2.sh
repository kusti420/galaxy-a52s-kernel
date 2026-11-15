#!/bin/busybox sh
# W2: wlan.ko (qcacld-3.0) after W1 reported FW ready. Passive: no ifconfig up, no scan.
cd "${0%/*}"; . ./lib.sh
ld w2 "$1"
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 3; [ -e /sys/class/net/wlan0 ] && break; done
sleep 3
k "w2 net"; ls /sys/class/net | tr '\n' ' '; echo; ifconfig -a 2>&1 | grep -E 'Link|HWaddr' ; ls /sys/class/ieee80211 2>&1
cat /proc/net/wireless 2>&1
for f in /sys/wifi/*; do [ -r $f ] && echo "$f: $(cat $f 2>&1 | head -2 | tr '\n' ' ')"; done
for p in /sys/class/ieee80211/*; do echo "$p: $(cat $p/macaddress 2>/dev/null) $(ls $p | tr '\n' ' ')"; done
k "w2 dmesg"; dmesg | grep -iE 'wlan|hdd|cfg80211|wma|cds|qdf|hif|htc|wmi|icnss|regdb|bdf|ini' | grep -v 'hw: insmod' | tail -90
k "w2 done"
