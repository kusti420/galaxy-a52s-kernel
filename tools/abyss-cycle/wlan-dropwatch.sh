#!/system/bin/sh
# Catch the kernel log around a Wi-Fi drop that follows a WLAN suspend timeout (daily phone 11-21:
# 12 of 13 drops came 1.2 s after "wcn6750 failed to suspend: error -110" / "phy0 ... -62", none on 5.4).
# Root, detached:  setsid nohup sh wlan-dropwatch.sh >/dev/null 2>&1 &
# Follows the kernel log, keeps the last 300 lines in memory and, at every line matching the
# trigger, writes those 300 lines + the next 200 to /data/local/tmp/wlan-drops/<time>.txt. Read-only
# otherwise; stop it with: pkill -f wlan-dropwatch
O=/data/local/tmp/wlan-drops; mkdir -p $O
dmesg -w 2>/dev/null | awk -v dir=$O '
  { buf[NR % 300] = $0 }
  /Failed to receive WoW Enable Ack|failed to suspend: error -110|failed to suspend: error -62|qdf_trigger_self_recovery|QDF_SUSPEND_TIMEOUT|Credits:.*Pending_Cmds/ {
    if (after <= 0) {
      cmd = "date +%Y%m%d-%H%M%S"; cmd | getline t; close(cmd); f = dir "/" t ".txt"
      for (i = NR - 299; i <= NR; i++) if (i > 0) print buf[i % 300] > f
      after = 200; fflush(f); next
    }
  }
  after > 0 { print > f; after--; if (after == 0) close(f) }'
