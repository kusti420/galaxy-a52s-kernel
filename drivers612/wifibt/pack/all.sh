#!/bin/busybox sh
# everything that works: WPSS + FW ready (w1), wlan.ko -> wlan0 (w2), btpower probe + rfkill on/off (b1)
cd "${0%/*}"
sh ./w1.sh > /tmp/w1.out 2>&1; echo "===== w1"; grep -E "now up|FW is ready|FAIL|WLFW" /tmp/w1.out
sh ./w2.sh > /tmp/w2.out 2>&1; echo "===== w2"; grep -E "wlan0|swlan0|p2p0|qcwlanstate|wifiver|FAIL" /tmp/w2.out
sh ./b1.sh on > /tmp/b1.out 2>&1; echo "===== b1"; grep -E "/dev/|rfkill|state=|gpio8[4-6]|FAIL" /tmp/b1.out
echo "===== summary"; for r in /sys/class/remoteproc/remoteproc*; do echo "$(cat $r/name)=$(cat $r/state)"; done
dmesg | grep -c 'Unable to wakeup pci ep'
