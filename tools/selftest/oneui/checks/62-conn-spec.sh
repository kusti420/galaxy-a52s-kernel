#!/system/bin/sh
# Wi-Fi / Bluetooth / NFC / GNSS rows of drivers612/SPEC/02-audio-connectivity-telephony.md (WIFI-*, BT-*, NFC-*, GNSS-*). Read-only, silent. PRIVACY: no MAC, SSID, BD address,
# coordinates or country value is printed: classes ("provisioned"), presence, counts and short hashes only.
# Never read here: /sys/class/nfc_test/test (power-cycles the NFC chip), /proc/tzdbg/*, anything under /sys/class/lcd.
. "${0%/*}/../dev-lib.sh"
# ---- Wi-Fi: Samsung sysfs set with modes (5.4: 8 names, mac_addr/ant/pm/memdump write-only)
m=; for n in ant mac_addr memdump pm qcwlanstate softap wificable wifiver; do m="$m $n=$(stat -c %a /sys/wifi/$n 2>/dev/null || echo absent)"; done
C wifi.sysfs_modes "$(printf '%s' "$m" | grep -q absent && echo FAIL || echo PASS)" kernel "set:$m" "mac_addr owner $(stat -c %U:%G /sys/wifi/mac_addr 2>/dev/null) label $(lz /sys/wifi/mac_addr)"
nodes wifi.boot_nodes kernel /dev/wlan /sys/kernel/icnss/wpss_boot /sys/module/wlan/parameters/con_mode
setl wifi.ifaces kernel 2 "$(ls /sys/class/net 2>/dev/null | grep -E '^(wlan0|p2p0|swlan0|wifi-aware0)$' | tr '\n' ' ')"
# factory MAC: p2p0 keeps the driver's own address (wlan0 shows Android's per-network random one). Class only.
pa=$(cat /sys/class/net/p2p0/address 2>/dev/null)
case "$pa" in "") C wifi.mac_class SKIP kernel "p2p0 absent" "Wi-Fi off or driver not started";;
00:03:7f:*|02:03:7f:*) C wifi.mac_class FAIL kernel "qualcomm default" "macloader did not provision the driver: efs file $([ -e /mnt/vendor/efs/wifi/.mac.info ] && echo present || echo absent), macloader=$(svc macloader)";;
*) C wifi.mac_class PASS kernel "provisioned" "local bit on p2p0: $(( (16#$(printf '%s' "$pa" | cut -c1-2) & 2) / 2 )); macloader=$(svc macloader)";; esac
if needroot wifi.fw_version kernel; then v=$(rd /sys/wifi/wifiver); fw=$(printf '%s' "$v" | grep -oE 'FW: *[^,]*, *HW: *[^,]*')
	C wifi.fw_version "$([ -n "$fw" ] && echo PASS || echo FAIL)" kernel "${fw:-unreadable}" "$(printf '%s' "$v" | grep -oE 'HostSW: *[^,]*|BoardVersion: *[0-9a-f]+|BoardDataRev: *[0-9a-f]+' | tr '\n' ' ')"; fi
if needroot wifi.softap_info kernel; then val wifi.softap_info kernel /sys/wifi/softap; fi
ini=/vendor/firmware/wlan/qca_cld/qca6750/WCNSS_qcom_cfg.ini
if [ -r $ini ]; then k=; for x in gEnableConcurrentSTA gRuntimePM gEnableModulatedDTIM gIPAConfig gEnableSelfRecovery rx_wakelock_timeout; do k="$k $x=$(grep -m1 -E "^$x *=" $ini | cut -d= -f2 | tr -d ' \r')"; done
	C wifi.ini PASS ROM "sha $(sha256sum < $ini | cut -c1-12)" "$k"; else C wifi.ini FAIL kernel+ROM "unreadable" "$ini (the driver refuses to start without it)"; fi
# WPSS (Wi-Fi firmware processor): up, recovery armed, crash count
w=; for s in /sys/bus/msm_subsys/devices/subsys*; do [ "$(cat $s/name 2>/dev/null)" = wpss ] && { w="state=$(rd $s/state) restart_level=$(rd $s/restart_level) crash_count=$(rd $s/crash_count)"; M wifi_wpss_crash_count "$(num "$(rd $s/crash_count)")"; }; done
for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name 2>/dev/null)" in *wpss*) w="$w rproc=$(rd $r/state) recovery=$(rd $r/recovery)";; esac; done
case "$w" in *ONLINE*|*rproc=running*) C wifi.wpss PASS kernel "wpss up" "$w";; "") C wifi.wpss FAIL kernel "no wpss node" "neither msm_subsys nor remoteproc lists it";; *) C wifi.wpss FAIL kernel "wpss not up" "$w";; esac
# suspend with Wi-Fi: -11 = firmware WoW NACK (retried, also on 5.4); -110 = ack timeout -> self recovery = Wi-Fi drop
ss=/sys/power/suspend_stats; lf="$(rd $ss/last_failed_dev) / $(rd $ss/last_failed_errno)"
case "$lf" in *wcn6750*-110*|*icnss*-110*) C wifi.suspend_fail FAIL kernel "last failed suspend: wlan -110" "$lf";; *) C wifi.suspend_fail PASS kernel "no wlan -110 as last failure" "last_failed dev/errno: $lf";; esac
if needroot wifi.wow_dmesg kernel; then dm=$(dmesg 2>/dev/null); na=$(printf '%s\n' "$dm" | grep -c 'FW not ready to WOW'); to=$(printf '%s\n' "$dm" | grep -cE 'Failed to receive WoW Enable Ack|failed to suspend: error -110'); sr=$(printf '%s\n' "$dm" | grep -ciE 'self.?recovery')
	M wifi_wow_nack "$na"; M wifi_wow_ack_timeout "$to"; M wifi_self_recovery "$sr"
	C wifi.wow_dmesg "$([ "$to" = 0 ] && [ "$sr" = 0 ] && echo PASS || echo FAIL)" kernel "ack timeouts $to, recoveries $sr" "WoW NACKs $na (retried; same path on 5.4). The ring covers only the last minutes"; fi
setl wifi.wakeup_sources kernel 1 "$(for x in /sys/class/wakeup/wakeup*; do n=$(cat $x/name 2>/dev/null); case "$n" in *wlan*|*wow*|*icnss*|*cnss*|*wpss*|qcom_rx_wakelock) echo "$n";; esac; done | sort -u | tr '\n' ' ')"
setl wifi.thermal kernel 0 "$(cat /sys/class/thermal/cooling_device*/type /sys/class/thermal/thermal_zone*/type 2>/dev/null | grep -iE 'icnss|wlan|wpss|wifi|sec-wf' | sort -u | tr '\n' ' ')"
# framework view (answers come from the HAL + driver)
cc=$(cmd wifi get-country-code 2>/dev/null | grep -oE '[A-Z][A-Z0-9]$')
C wifi.country "$([ -n "$cc" ] && echo PASS || echo SKIP)" kernel+ROM "$([ -n "$cc" ] && echo set || echo empty)" "empty = the hotspot refuses to start (no SIM / no modem: same on 5.4); value not printed"
sf=$(cmd wifi get-softap-supported-features 2>/dev/null | grep -E '^wifi_softap' | tr '\n' ' ')
if [ -n "$sf" ]; then setl wifi.softap_caps kernel+ROM 1 "$sf"; else C wifi.softap_caps SKIP kernel+ROM "no answer" "cmd wifi get-softap-supported-features gave nothing for this uid"; fi
apf=$(DT=30 D network_stack | grep -m1 -oE 'ApfCapabilities\{[^}]*\}')
C wifi.apf "$([ -n "$apf" ] && echo PASS || echo SKIP)" kernel+ROM "${apf:-no ApfCapabilities line}" "packet filter the firmware runs while the phone sleeps; SKIP when Wi-Fi is not connected"
ll=$(DT=30 D wifi | grep -m1 -oE 'on_time *[:=] *[0-9]+' | grep -oE '[0-9]+$')
C wifi.ll_stats "$([ "${ll:-0}" -gt 0 ] && echo PASS || echo SKIP)" kernel "radio on_time $([ "${ll:-0}" -gt 0 ] && echo counted || echo 'not reported')" "on_time=${ll:-none} ms (link-layer stats from the driver)"
setl radio.features kernel+ROM 4 "$(pm list features 2>/dev/null | sed 's/^feature://' | cut -d= -f1 | grep -E 'hardware\.(wifi|bluetooth|nfc|location\.gps|uwb)' | tr '\n' ' ')"
# ---- Bluetooth
nodes bt.fw_files ROM /vendor/firmware/msbtfw11.tlv /vendor/firmware/msnv11.bin
nodes bt.transport kernel /dev/btpower /dev/ttyHS0 /dev/btfmslim
fv=$(getprop vendor.bluetooth_fw_ver)
C bt.fw_version "$([ -n "$fv" ] && echo PASS || echo SKIP)" kernel+ROM "soc=$(getprop vendor.qcom.bluetooth.soc) fw=${fv:-unset}" "nv=$(getprop vendor.bluetooth_nv_ver) init_fail=$(getprop vendor.bluetooth_init_fail) (set by the HAL after the patch download; unset when Bluetooth was never on this boot)"
bp=; for r in /sys/class/rfkill/rfkill*; do [ "$(cat $r/name 2>/dev/null)" = bt_power ] && bp="state=$(rd $r/state) extldo=$(rd $r/device/extldo)"; done
C bt.power_node "$([ -n "$bp" ] && echo PASS || echo FAIL)" kernel "rfkill bt_power $([ -n "$bp" ] && echo present || echo absent)" "$bp (state follows the user's Bluetooth switch)"
if needroot bt.addr_source kernel+ROM; then f=/mnt/vendor/efs/bluetooth/bt_addr; C bt.addr_source "$([ -s $f ] && echo PASS || echo FAIL)" kernel+ROM "efs bt_addr $([ -s $f ] && echo present || echo absent)" "$(cat $f 2>/dev/null | wc -c) bytes, label $(lz $f); content not read into the log"; fi
setl bt.le_audio_props ROM 0 "$(getprop 2>/dev/null | grep -E '^\[bluetooth\.profile\.(bap|csip|mcp|ccp|vcp|hap)[^]]*\]: \[true\]' | cut -d'[' -f2 | cut -d']' -f1 | tr '\n' ' ')"
C bt.a2dp_offload_cap PASS ROM "$(getprop persist.bluetooth.a2dp_offload.cap)" "supported=$(getprop ro.bluetooth.a2dp_offload.supported) disabled=$(getprop persist.bluetooth.a2dp_offload.disabled) samsung=$(getprop persist.bluetooth.samsung.a2dp_offload.cap)"
setl bt.wakeup_sources kernel 0 "$(for x in /sys/class/wakeup/wakeup*; do n=$(cat $x/name 2>/dev/null); case "$n" in *bluetooth*|*bt_*|*99c000*|*hs_uart*) echo "$n";; esac; done | sort -u | tr '\n' ' ')"
# ---- NFC (kernel side beyond nfc.dev / nfc.service)
nodes nfc.sysfs kernel /sys/class/nfc_sec/nfc_support /proc/nfclog
C nfc.pvdd_node "$([ -e /sys/class/nfc_sec/pvdd ] && echo PASS || echo SKIP)" kernel "pvdd $([ -e /sys/class/nfc_sec/pvdd ] && echo present || echo absent)" "absent on the 5.4 kernel by design (the init write fails there); mode $(stat -c %a /sys/class/nfc_sec/pvdd 2>/dev/null)"
nodes nfc.fw_files ROM /vendor/firmware/nfc/sec_s3nrn4v_firmware.bin /vendor/etc/nfc/sec_s3nrn4v_hwreg.bin /vendor/etc/nfc/sec_s3nrn4v_swreg.bin
ni=$(grep -c 'sec-nfc' /proc/interrupts 2>/dev/null)
C nfc.irq "$([ "${ni:-0}" -ge 1 ] && echo PASS || echo FAIL)" kernel "${ni:-0} irq lines" "expected 2 (data + clk_req): $(grep 'sec-nfc' /proc/interrupts 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')"
setl nfc.wakeup_sources kernel 1 "$(for x in /sys/class/wakeup/wakeup*; do n=$(cat $x/name 2>/dev/null); case "$n" in nfc_*) echo "$n";; esac; done | sort -u | tr '\n' ' ')"
if needroot nfc.log kernel; then ne=$(grep -ciE 'i2c (write|read) error|NOK|probe.*fail' /proc/nfclog 2>/dev/null); np=$(grep -c 'pvdd val' /proc/nfclog 2>/dev/null)
	C nfc.log "$([ "${ne:-1}" = 0 ] && echo PASS || echo FAIL)" kernel "error lines ${ne:-unreadable}" "pvdd writes logged: ${np:-0} (OneUI init writes 3); $(cat /proc/nfclog 2>/dev/null | wc -l) lines"; fi
C nfc.config PASS ROM "chip=$(getprop ro.vendor.nfc.feature.chipname) ese=$(getprop ro.vendor.nfc.support.ese) uicc=$(getprop ro.vendor.nfc.support.uicc)" "no eSE on this phone: ese=false expected"
# ---- GNSS (engine lives in the modem; no kernel driver)
gd=; for p in lowi-server xtra-daemon loc_launcher; do gd="$gd $p=$(pidof $p >/dev/null 2>&1 && echo up || echo down)"; done
C gnss.daemons "$([ "$(svc gnss_service)" = running ] && echo PASS || echo FAIL)" kernel+ROM "gnss_service=$(svc gnss_service)$gd" "loc_launcher svc=$(svc loc_launcher)"
C gnss.nodes PASS info "socket_hal=$([ -e /dev/socket/location/socket_hal ] && echo y || echo n) pps0=$([ -e /dev/pps0 ] && echo y || echo n)" "gps.conf sha $([ -r /vendor/etc/gps.conf ] && sha256sum < /vendor/etc/gps.conf | cut -c1-12)"
# capability list only: lines with coordinates ("Location[", "last location") are never selected
gl=$(DT=30 D location | grep -viE 'Location\[|last location|latitude|longitude' | grep -m1 -iE '^ *capabilities' | tr -s ' ')
C gnss.caps "$([ -n "$gl" ] && echo PASS || echo FAIL)" kernel+ROM "${gl:-no capabilities line}" "$(DT=30 D location | grep -m1 -iE 'hardware model name|gnss hardware model' | tr -s ' ')"
