#!/bin/busybox sh
# Run by "qmi-nas data --run" (m1.sh step "data") while the WDS call is up: puts the address the
# network assigned on rmnet_data0 (rmnet_core mux 1 over rmnet_ipa0), pings, removes it again.
# Env from qmi-nas: QMI_IP QMI_GW QMI_PREFIX QMI_DNS1 QMI_DNS2 QMI_MTU QMI_MUX QMI_HANDLE QMI_QMAP
# QMI_RMNET_FLAGS (rmnet_data0 and the IPA pipes are set up by qmi-nas before this runs).
D=rmnet_data0
# every step also to /dev/kmsg (ramoops survives; the PC-side output collection has been lossy)
K() { echo "a52sxq-init: dataup: $*" > /dev/kmsg; }
R() { o=$("$@" 2>&1); r=$?; echo "$o"; K "$* -> rc=$r $(echo "$o" | tr "\n" "|" | cut -c1-600)"; return $r; }
st() { for n in rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do printf "%s=%s " $n "$(cat /sys/class/net/$1/statistics/$n 2>/dev/null)"; done; echo; }
echo "dataup: ip=$QMI_IP gw=$QMI_GW prefix=$QMI_PREFIX dns=$QMI_DNS1 $QMI_DNS2 mtu=$QMI_MTU mux=$QMI_MUX handle=$QMI_HANDLE qmap=$QMI_QMAP rmnet-flags=$QMI_RMNET_FLAGS"
[ -n "$QMI_IP" ] || { K "no IPv4"; echo "dataup: no IPv4 address from the network: nothing to configure"; exit 2; }
[ -e /sys/class/net/$D ] || { K "no $D"; echo "dataup: no $D (rmnet-add failed?)"; exit 3; }
R ip link set $D up
[ -n "$QMI_MTU" ] && [ "$QMI_MTU" != 0 ] && ip link set $D mtu "$QMI_MTU"
R ip addr add "$QMI_IP/32" dev $D
R ip route add default dev $D metric 50
R ip addr show $D; R ip route
echo "dataup: before: $D $(st $D)"; echo "dataup: before: rmnet_ipa0 $(st rmnet_ipa0)"
R /bin/busybox ping -c 5 -W 5 -I $D 1.1.1.1; RC=$?
if [ -n "$QMI_DNS1" ]; then R /bin/busybox ping -c 3 -W 5 -I $D "$QMI_DNS1"; R2=$?; else R2=-; fi
echo "dataup: after: $D $(st $D)"; echo "dataup: after: rmnet_ipa0 $(st rmnet_ipa0)"
dmesg | grep -iE "rmnet|ipa_wan|wwan|ipa3_wwan|qmap" | tail -15
ip route del default dev $D metric 50 2>/dev/null
ip addr flush dev $D; ip link set $D down
echo "dataup: ping 1.1.1.1 rc=$RC, ping dns rc=$R2"; K "RESULT ping 1.1.1.1 rc=$RC, ping dns rc=$R2"
exit $RC
