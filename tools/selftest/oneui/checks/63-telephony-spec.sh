#!/system/bin/sh
# Modem / telephony / cellular data rows of drivers612/SPEC/02-audio-connectivity-telephony.md (TEL-*) beyond 60-radio.sh.
# Read-only and silent. PRIVACY: no IMEI, IMSI, ICCID, number, operator name, cell id or IP address is printed: counts,
# lengths and enum words only; EFS partitions are sized, never read. Nothing is dialled or sent.
. "${0%/*}/../dev-lib.sh"
# ---- QRTR: protocol registered + open sockets (rild alone holds ~120 on 5.4, MR:79)
q=$(grep -m1 '^QIPCRTR ' /proc/net/protocols 2>/dev/null | tr -s ' ' | cut -d' ' -f3)
if [ -n "$q" ]; then C modem.qrtr_sockets "$([ "$q" -ge 20 ] && echo PASS || echo FAIL)" kernel "QIPCRTR registered" "$q sockets; qrtr-ns=$(svc vendor.qrtr-ns)"; else C modem.qrtr_sockets FAIL kernel "no QIPCRTR row" "/proc/net/protocols"; fi
# ---- slot count: config vs what the framework reports (no /proc/simslot_count on this phone, OUI:291)
mc=$(getprop persist.radio.multisim.config); case "$mc" in dsds|dsda) want=2;; tsts) want=3;; *) want=1;; esac
sf=$(getprop gsm.sim.state | tr ',' '\n' | grep -c .)
C modem.slot_count "$([ "$sf" = "$want" ] && echo PASS || echo FAIL)" kernel+ROM "config=${mc:-unset} slots=$want sim_state_fields=$sf" "rild pids $(pidof rild | wc -w); simslot_count node $([ -e /proc/simslot_count ] && echo present || echo absent)"
# ---- IMEI of slot 2: digit count only (verify: "cmd phone get-imei -s 1" syntax on One UI)
n2=$(cmd phone get-imei -s 1 2>/dev/null | tr -dc '0-9' | wc -c)
case "$n2" in 14|15|16) C modem.imei2_length PASS kernel "$n2 digits" "slot 2, value not read into the log";; *) C modem.imei2_length SKIP kernel+ROM "not readable from the shell" "digit count $n2";; esac
# ---- registration detail: enum words only, cut out of the ServiceState line inside the pipe (verify field names)
ssl=$(DT=25 D telephony.registry | grep -m1 'mServiceState='); f() { printf '%s' "$ssl" | grep -oE "$1" | head -1; }
C modem.reg_detail PASS info "$(f 'getRilDataRadioTechnology=[0-9]+\([A-Za-z_0-9]+\)') $(f 'getRilVoiceRadioTechnology=[0-9]+\([A-Za-z_0-9]+\)')" "$(f 'isUsingCarrierAggregation=(true|false)') $(f 'nrState=[A-Z_]+') $(f 'isEnDcAvailable ?= ?(true|false)') $(f 'mNrFrequencyRange=[0-9-]+') $(f 'mIsDataRoaming=(true|false)') bandwidths=$(f 'mCellBandwidths=\[[0-9, ]*\]' | tr -cd ',' | wc -c)"
# ---- emergency state without a SIM: must be equal on 5.4 and 6.12 (never dials anything)
if ! getprop gsm.sim.state | grep -qE 'LOADED|READY'; then C modem.emergency_state PASS info "$(f 'mVoiceRegState=[0-9]+\([A-Z_]+\)') $(f 'mIsEmergencyOnly=(true|false)')" "no SIM; emergency numbers known: $(DT=25 D telephony.registry | grep -c -i 'EmergencyNumber')"; fi
# ---- signal level 0..4 of the serving technology (no cell identity; verify)
lv=$(DT=25 D telephony.registry | grep -m1 'mSignalStrength=' | grep -oE 'level=[0-4]' | sort -u | tr '\n' ' ')
C modem.signal_level "$([ -n "$lv" ] && echo PASS || echo SKIP)" info "level field present" "${lv:-no mSignalStrength line}"
# ---- IMS registration bit (ImsStack on IchthysOS, Samsung IMS on One UI; verify the field name per ROM)
ims=$(DT=25 D phone | grep -oE '(isImsRegistered\(\)|mImsRegistered)=(true|false)' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
if [ -n "$ims" ]; then C modem.ims_registered PASS info "$ims" "imsd=$(svc imsd) volte_avail_ovr=$(getprop persist.dbg.volte_avail_ovr)"; else C modem.ims_registered SKIP ROM "no IMS field in dumpsys phone" "imsd=$(svc imsd)"; fi
# ---- rmnet links: count, UP links, MTUs, mux/flags of the first link (no addresses)
up=; for i in /sys/class/net/rmnet_data*; do [ -d "$i" ] || continue; [ $(( $(rd $i/flags) & 1 )) = 1 ] && up="$up ${i##*/}:mtu$(rd $i/mtu)"; done
C modem.rmnet_links "$([ -d /sys/class/net/rmnet_ipa0 ] && echo PASS || echo FAIL)" kernel "rmnet_ipa0 mtu=$(rd /sys/class/net/rmnet_ipa0/mtu) links=$(ls -d /sys/class/net/rmnet_data* 2>/dev/null | wc -l)" "up:${up:- none}; $(ip -d link show rmnet_data0 2>/dev/null | grep -oE 'rmnet mux_id [0-9]+( [a-z-]+ [a-z0-9]+)*' | head -1); qdisc $(tc qdisc show dev rmnet_data0 2>/dev/null | grep -c .)"
# ---- address families on the cellular links: counts only
C modem.data_families PASS info "v4=$(ip -4 -o addr show 2>/dev/null | grep -c ' rmnet_data') v6_global=$(ip -6 -o addr show scope global 2>/dev/null | grep -c ' rmnet_data')" "clat=$(ls /sys/class/net 2>/dev/null | grep -c '^v4-rmnet')"
# ---- uplink completion (the 2026-11-15 bug: hw_tx ran away from tx_compl, LDR E1); debugfs = root + 6.12 only
if needroot modem.ipa_tx_outstanding kernel; then s=/sys/kernel/debug/ipa/stats
	if [ -r $s ]; then ht=$(num "$(grep -m1 -oE 'hw_tx=[0-9]+' $s)"); tc=$(num "$(grep -m1 -oE 'tx_compl=[0-9]+' $s)"); o=$(( ${ht:-0} - ${tc:-0} ))
		C modem.ipa_tx_outstanding "$([ "$o" -lt 64 ] && echo PASS || echo FAIL)" kernel "outstanding < 64" "hw_tx=$ht tx_compl=$tc outstanding=$o rmnet_ipa0 tx=$(rd /sys/class/net/rmnet_ipa0/statistics/tx_packets) watchdog=$(dmesg 2>/dev/null | grep -c 'NETDEV WATCHDOG: rmnet_ipa0') active_clients_lines=$(grep -c . /sys/kernel/debug/ipa/active_clients 2>/dev/null)"
	else C modem.ipa_tx_outstanding SKIP kernel "ipa debugfs not readable" "no debugfs on the 5.4 user build"; fi; fi
# ---- the rest of the IPA / tethering node set (60-radio.sh checks only /dev/ipa and /dev/wwan_ioctl)
nodes modem.ipa_nodes_full kernel /dev/ipaNatTable /dev/ipa_odl_ctl /dev/ipa_adpl /dev/rmnet_ctrl /dev/dpl_ctrl
setl tether.usb_functions kernel 1 "$(ls /config/usb_gadget/g1/functions 2>/dev/null | grep -E '^(gsi|ncm|rndis)' | tr '\n' ' ')"
C tether.offload PASS info "ipacm=$(svc vendor.ipacm) offload_state_file=$([ -e /data/vendor/ipa/offload_state ] && echo y || echo n)" "$(DT=20 D tethering | grep -m3 -i 'offload' | tr '\n' ' ')"
# ---- RIL character devices (glink_pkt + drb + subsys + rmtfs uio): existence and the label of the first
nodes modem.glink_nodes kernel /dev/drb /dev/smd4 /dev/smd7 /dev/smd8 /dev/smd11 /dev/smdcntl8 /dev/at_mdm0 /dev/subsys_modem /dev/uio0
nodes modem.ril_sysfs kernel /sys/class/power_supply/battery/voltage_now /sys/class/lcd/panel/mipi_switch /sys/class/nfc_sec/nfc_support /dev/block/by-name/param /dev/rtc0
# ---- EFS transport: uio name/size and the four partitions (size + ro flag only; contents are never read)
un=; for u in /sys/class/uio/uio*; do [ -d "$u" ] && un="$un $(rd $u/name):$(rd $u/maps/map0/size)"; done
C modem.rmtfs_uio "$(printf '%s' "$un" | grep -q 'rmtfs:0x' && echo PASS || echo FAIL)" kernel "${un:- none}" "rmt_storage=$(svc vendor.rmt_storage) tftp_server=$(svc vendor.tftp_server)"
ep=; for p in modemst1 modemst2 fsg fsc; do b=$(readlink /dev/block/by-name/$p 2>/dev/null); b=${b##*/}; ep="$ep $p=$(rd /sys/class/block/$b/size)s,ro$(rd /sys/class/block/$b/ro)"; done
C modem.efs_parts "$(printf '%s' "$ep" | grep -q '=s,' && echo FAIL || echo PASS)" kernel "$ep" "sizes in 512-byte sectors; no content read"
# ---- SSR configuration and crash count since boot; the sysfs attribute libsec-ril names
C modem.ssr_config PASS info "restart_level: $(cat /sys/bus/msm_subsys/devices/*/restart_level 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ' ')" "recovery=$(cat /sys/class/remoteproc/*/recovery 2>/dev/null | tr '\n' ' ') coredump=$(cat /sys/class/remoteproc/*/coredump 2>/dev/null | tr '\n' ' ') crashes=$(dmesg 2>/dev/null | grep -c -E 'handling crash|fatal error received') ril_ssr_attr=$(ls -d /sys/devices/platform/soc/*mss*/ssr 2>/dev/null | wc -l)"
# ---- modem thermal: TMD cooling devices and QMI zones as name sets (DT:7565-7715 has 26 modem TMD names)
setl thermal.modem_tmd kernel 10 "$(cat /sys/class/thermal/cooling_device*/type 2>/dev/null | grep -E '^(modem_|cdsp_)' | tr '\n' ' ')"
setl thermal.modem_zones kernel 8 "$(cat /sys/class/thermal/thermal_zone*/type 2>/dev/null | grep -E '^(modem-|msm-skin)' | tr '\n' ' ')"
# ---- wakeup sources of the modem path + the label system_suspend needs (CL:2988-2992)
if needroot power.wakeup_modem kernel; then
	setl power.wakeup_modem kernel 1 "$(cat /sys/class/wakeup/*/name 2>/dev/null | grep -iE 'remoteproc|mss|ipa|glink|qrtr|smp2p|rmnet' | sort -u | tr '\n' ' ')"
	for d in /sys/class/wakeup/wakeup*; do case "$(rd $d/name)" in *remoteproc-mss*|*4080000*) C power.wakeup_mss_label "$([ "$(lz $d)" = sysfs ] && echo FAIL || echo PASS)" ROM "$(lz $d)" "$(rd $d/name) event_count=$(rd $d/event_count) wakeup_count=$(rd $d/wakeup_count)"; break;; esac; done; fi
# ---- SoC sleep counters with the modem up (6.12: qcom_stats is built but not loaded, P18:145)
sl=; for p in /sys/kernel/debug/qcom_stats/cxsd /sys/kernel/debug/qcom_stats/aosd /sys/power/soc_sleep/stats /sys/power/system_sleep/stats; do [ -r $p ] && sl="$sl ${p##*/qcom_stats/}:$(grep -m1 -iE '^count' $p | tr -dc '0-9')"; done
C power.soc_sleep_stats "$([ -n "$sl" ] && echo PASS || echo FAIL)" kernel "$([ -n "$sl" ] && echo readable || echo absent)" "${sl:- no sleep-stats node (load qcom_stats.ko)}"
# ---- SAR input: grip sensor attrs and input devices
setl sar.grip_attrs kernel 3 "$(ls /sys/class/sensors/grip_sensor 2>/dev/null | tr '\n' ' ')"
C sar.grip_inputs "$([ "$(grep -c -E 'Name="grip_(sensor|notifier)"' /proc/bus/input/devices)" = 2 ] && echo PASS || echo FAIL)" kernel "$(grep -oE 'Name="grip_[a-z]+"' /proc/bus/input/devices | tr '\n' ' ')" "country_code=$([ -e /sys/class/sensors/grip_sensor/country_code ] && echo y || echo n)"
# ---- Samsung RIL optional knobs + diag nodes + time daemon + TCP default: sets/values to compare across kernels
k=; for p in /proc/sys/net/ipv4/tcp_netpm /proc/sys/net/core/support_dropdump /proc/sys/net/optr /proc/net/xt_qtaguid/iface_stat_fmt /sys/class/xt_hardidletimer/timers /dev/network_throughput /dev/ramdump_memshare /dev/tun; do [ -e $p ] && k="$k ${p##*/}"; done
setl net.sec_ril_knobs info 0 "$k"
C modem.diag_nodes PASS info "diag=$([ -e /dev/diag ] && echo y || echo n) ffs_diag=$([ -d /dev/ffs-diag ] && echo y || echo n)" "diag-router=$(svc vendor.diag-router) ramdump nodes $(ls /dev 2>/dev/null | grep -c '^ramdump_')"
C modem.time_daemon "$(pidof time_daemon >/dev/null 2>&1 && echo PASS || echo FAIL)" kernel+ROM "time_daemon $(pidof time_daemon >/dev/null 2>&1 && echo running || echo not running)" "rtc0=$([ -e /dev/rtc0 ] && echo y || echo n) auto_time=$(settings get global auto_time 2>/dev/null)"
val net.tcp_cong info /proc/sys/net/ipv4/tcp_congestion_control
if needroot net.xfrm kernel; then C net.xfrm PASS info "xfrm_stat=$([ -r /proc/net/xfrm_stat ] && echo y || echo n)" "SAs=$(ip xfrm state 2>/dev/null | grep -c '^src') policies=$(ip xfrm policy 2>/dev/null | grep -c '^src') nonzero_errors=$(grep -c -vE ' 0$' /proc/net/xfrm_stat 2>/dev/null)"; fi
