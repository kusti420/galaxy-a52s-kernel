#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# WIFI-09 (Wi-Fi drops after a WLAN suspend timeout): READ-ONLY capture from a phone in daily use.
#   drivers612/wifibt/wifi09/wifi09-capture.sh <serial> [outdir]
# Run by hand only (it uses adb). Nothing is written on the phone, no setting is changed, nothing is
# pushed, no reboot, no radio or screen state is touched. Root (su) is used for three reads when it is available;
# without root those files are skipped and the rest is still enough for the counts.
# Then on the PC:  drivers612/wifibt/wifi09/wifi09-stats.py <outdir>/batterystats-history.txt
set -u
S=${1:?serial}; cd "$(dirname "$0")/../../.." || exit 1
D=${2:-logs/wifi09-$(date +%Y%m%d-%H%M)-$S}; mkdir -p "$D"
A="adb -s $S"
sh_() { $A shell "$1" 2>/dev/null; }
su_() { $A shell "su -c '$1'" 2>/dev/null; }
{ echo "kernel: $(sh_ 'uname -r')"; echo "uptime: $(sh_ 'cat /proc/uptime')"; echo "date: $(sh_ date)"
  echo "build: $(sh_ 'getprop ro.build.display.id') rp=$(sh_ 'getprop ro.boot.rp')"
  echo "wlan build-id: $(sh_ 'od -An -tx1 -j16 /sys/module/wlan/notes/.note.gnu.build-id' | tr -d ' \n')"
  echo "wlan taint/refcnt: $(sh_ 'cat /sys/module/wlan/taint /sys/module/wlan/refcnt' | tr '\n' ' ')"
  echo "wifiver: $(sh_ 'cat /sys/wifi/wifiver' | tr '\n' ' ')"; } > "$D/info.txt"
# 1. the history that carries every abort reason and every supplicant state change (no root needed)
sh_ 'dumpsys batterystats --history' > "$D/batterystats-history.txt"
# 2. kernel suspend counters
sh_ 'for f in /sys/power/suspend_stats/*; do [ -f $f ] && echo "$(basename $f): $(cat $f)"; done' > "$D/suspend_stats.txt"
sh_ 'dumpsys suspend_control_internal' > "$D/suspend_control_internal.txt"
# 3. the WLAN wakeup sources (pmo_wow_wl = 1 s per NACK, qcom_rx_wakelock must stay 0) and the kernel log (root)
su_ 'cat /sys/kernel/debug/wakeup_sources' > "$D/wakeup_sources.txt"
su_ 'dmesg' > "$D/dmesg.txt"
su_ 'ls -la /data/local/tmp/wlan-drops 2>/dev/null; for f in /data/local/tmp/wlan-drops/*.txt; do [ -f $f ] && { echo "=== $f"; cat $f; }; done' > "$D/wlan-drops.txt"
# 4. link state and the framework's own disconnect bookkeeping
sh_ 'dumpsys wifi' | grep -aE 'mWifiInfo|Supplicant state|DISCONNECT|disconnect|reason=|WifiLastResort|selfRecovery|SelfRecovery|restart' | tail -300 > "$D/dumpsys-wifi-grep.txt"
# summary
{ echo "== $D"; cat "$D/info.txt"
  echo "timeouts (-110/-62): $(grep -acE '(wcn6750|phy0).*(error|returned) -(110|62)' "$D/batterystats-history.txt")"
  echo "WoW NACK (-11):      $(grep -acE '(wcn6750|phy0).*(error|returned) -11[^0-9]' "$D/batterystats-history.txt")"
  echo "wake/abort records:  $(grep -ac 'wake_reason=' "$D/batterystats-history.txt")"
  echo "history starts:      $(grep -am1 'RESET:TIME' "$D/batterystats-history.txt")"
  for k in 'Unable to wakeup pci ep' 'EP state reset is not done' 'Failed to receive WoW Enable Ack' 'Timeout waiting for resume event' \
           'FW not ready to WOW' 'qdf_trigger_self_recovery\|Triggering SSR\|trigger_recovery' 'early crash indication' 'failed to suspend' ; do
    echo "dmesg '$k': $(grep -ac "$k" "$D/dmesg.txt")"; done
  grep -aE 'pmo_wow_wl|qcom_rx_wakelock|wlan_pno_wl|^name' "$D/wakeup_sources.txt" | cut -c1-150
  grep -aE '^(success|fail|failed_suspend|last_failed_dev|last_failed_errno)' "$D/suspend_stats.txt"; } | tee "$D/summary.txt"
