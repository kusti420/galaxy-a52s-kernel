#!/system/bin/sh
# WLAN RX hard-wake check (root): rxwake.sh [secs=20] [target=default gateway]
# Pings <target> over wlan0 (unicast replies = RX packets) while hardwake.sh counts the hard wakeup
# events by chain; also prints the qcacld rx wakelock setting in effect (qcom_rx_wakelock activity).
SECS=${1:-20}; GW=${2:-$(ip route show table all 2>/dev/null | awk '/default/ && /wlan0/ {print $3; exit}')}
[ -n "$GW" ] || GW=$(ip route | awk '/wlan0/ {split($1,a,"/"); split(a[1],b,"."); print b[1]"."b[2]"."b[3]".1"; exit}')
ws() { awk '$1=="qcom_rx_wakelock"{print $2, $4}' /sys/kernel/debug/wakeup_sources; }
echo "rxwake: ping $GW for $SECS s over wlan0; qcom_rx_wakelock (active_count wakeup_count) before: $(ws)"
(ping -I wlan0 -i 0.2 -c $((SECS*5)) $GW > /data/local/tmp/rxwake-ping.txt 2>&1 &)
sh /data/local/tmp/hardwake.sh $SECS | grep -v "node:svc" | sed -n 1,8p
echo "qcom_rx_wakelock after: $(ws); ping: $(tail -2 /data/local/tmp/rxwake-ping.txt | head -1)"
