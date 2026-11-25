#!/system/bin/sh
# Modem / RIL, Wi-Fi, Bluetooth. Read-only. PRIVACY: no IMEI, IMSI, ICCID, phone number, MAC address or SSID is
# ever printed: the IMEI is checked by its digit count inside a pipe, MACs by "present".
. "${0%/*}/../dev-lib.sh"
bb=$(getprop gsm.version.baseband); b1=${bb%%,*}
if [ -n "$b1" ]; then C modem.baseband PASS kernel "$b1" "ril-impl $(getprop gsm.version.ril-impl)"; else C modem.baseband FAIL kernel "empty" "RIL has no modem link"; fi
C modem.sim_state PASS info "$(getprop gsm.sim.state)" "slot count $(getprop persist.radio.multisim.config); network type $(getprop gsm.network.type)"
# IMEI: digit count only (the value never leaves the pipe)
n=$(cmd phone get-imei 2>/dev/null | tr -dc '0-9' | wc -c)
case "$n" in 14|15|16) :;; *) n=$(service call iphonesubinfo 1 s16 com.android.shell 2>/dev/null | grep -oE "'[^']*'" | tr -dc '0-9' | wc -c);; esac
case "$n" in 14|15|16) C modem.imei_length PASS kernel "$n digits" "value not read into the log";; *) C modem.imei_length SKIP kernel+ROM "not readable from the shell" "digit count $n (needs a privileged caller on this build)";; esac
rl=; for s in ril-daemon ril-daemon1 vendor.ril-daemon vendor.ril-daemon1 imsd vendor.qrtr-ns vendor.rmt_storage vendor.pd_mapper vendor.per_mgr vendor.tftp_server; do st=$(svc $s); [ -n "$st" ] && rl="$rl $s=$st"; done
C modem.ril_daemons "$(printf '%s' "$rl" | grep -q 'restarting' && echo FAIL || { pidof rild >/dev/null 2>&1 && echo PASS || echo FAIL; })" kernel+ROM "$rl" "rild pids $(pidof rild | wc -w); RildInit=$(getprop ril.RildInit)"
ss=$(cat /sys/class/remoteproc/*/state 2>/dev/null | tr '\n' ' '); sn=$(cat /sys/class/remoteproc/*/name 2>/dev/null | tr '\n' ' ')
[ -z "$ss" ] && { sn=$(cat /sys/bus/msm_subsys/devices/*/name 2>/dev/null | tr '\n' ' '); ss=$(cat /sys/bus/msm_subsys/devices/*/state 2>/dev/null | tr '\n' ' '); }
C modem.subsystems "$(printf '%s' "$ss" | grep -qiE 'crash|offlin' && echo FAIL || echo PASS)" kernel "states: $(printf '%s\n' $ss | sort | uniq -c | tr -s ' ' | tr '\n' ' ')" "$sn: $ss"
tr_=$(DT=25 D telephony.registry | grep -m1 -oE 'mVoiceRegState=[0-9]+\([A-Z_]+\)')
C modem.registration PASS info "${tr_:-unknown}" "data: $(D telephony.registry | grep -m1 -oE 'mDataRegState=[0-9]+\([A-Z_]+\)'); needs a SIM to mean anything"
C modem.net_ifaces PASS kernel "rmnet_ipa0=$([ -d /sys/class/net/rmnet_ipa0 ] && echo y || echo n) rmnet_data=$(ls /sys/class/net 2>/dev/null | grep -c '^rmnet_data')" "$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
nodes modem.ipa_nodes kernel /dev/ipa /dev/wwan_ioctl
C modem.ipacm PASS kernel+ROM "ipacm=$(svc vendor.ipacm)" "ipaNatTable=$([ -e /dev/ipaNatTable ] && echo y || echo n) odu_ipa_bridge=$([ -e /dev/odu_ipa_bridge ] && echo y || echo n)"
# ---- Wi-Fi
ws=$(cmd wifi status 2>/dev/null); en=$(printf '%s\n' "$ws" | grep -m1 -oE 'Wifi is (enabled|disabled)'); con=$(printf '%s\n' "$ws" | grep -m1 -oE 'Wifi is (connected|not connected)')
up=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
if [ -d /sys/class/net/wlan0 ]; then C wifi.iface PASS kernel "wlan0 present" "operstate=$up; $en; $con; MAC $([ -n "$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':0\n')" ] && echo set || echo zero); p2p0=$([ -d /sys/class/net/p2p0 ] && echo y || echo n) swlan0=$([ -d /sys/class/net/swlan0 ] && echo y || echo n)"
else C wifi.iface FAIL kernel "wlan0 absent" "$en; hal $(svc vendor.wifi_hal_legacy)"; fi
C wifi.up "$([ "$en" = "Wifi is enabled" ] && echo PASS || echo SKIP)" kernel+ROM "${en:-no answer from cmd wifi}" "$con (a saved network is the user's)"
setl wifi.sysfs kernel 0 "$(ls /sys/wifi 2>/dev/null | tr '\n' ' ')"
C wifi.driver PASS kernel "con_mode=$(rd /sys/module/wlan/parameters/con_mode)" "fwpath=$(rd /sys/module/wlan/parameters/fwpath) cnss-daemon=$(svc cnss-daemon) wpa_supplicant=$(svc wpa_supplicant)"
# ---- Bluetooth
bs=$(D bluetooth_manager | grep -m1 -E '^ *(State|state):' | tr -d ' ')
C bt.state "$([ -n "$bs" ] && echo PASS || echo FAIL)" kernel+ROM "service answers" "$bs hal=$(svc vendor.bluetooth-1-0-qti) (on/off is the user's setting)"
C bt.nodes PASS kernel "btpower=$([ -e /dev/btpower ] && echo y || echo n) rfkill=$(cat /sys/class/rfkill/*/type 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ' ')" "$(lz /dev/btpower)"
