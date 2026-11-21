# USB gadget (PC side), charging, Wi-Fi, hotspot, Bluetooth, NFC, GNSS, modem
usb_sys() { local d; for d in /sys/bus/usb/devices/*; do [ "$(cat $d/serial 2>/dev/null)" = "$S" ] && { echo $d; return; }; done; }
# MTP: only the pinned phone is opened (mtppin.py: libmtp raw device matched by bus/devnum; mtp-detect
# opens every MTP device on the PC, incl. other sessions' phones). The phone is always put back to adb-only;
# when adb does not re-list it within 30 s the suite stops with "adb lost" (no adb kill-server here: other
# sessions share the adb server; no USB reset: no proven per-device method).
MTPPIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mtppin.py
usb_listed() { adb devices | grep -q "^$S[[:space:]]*device"; }
usb_adb_back() {
	local i
	for i in $(seq 30); do usb_listed && { sleep 1; return 0; }; sleep 1; done
	echo "adb lost: restart the adb server (adb kill-server; adb start-server) when no other session needs adb"
	fail "adb did not re-list $S within 30 s after leaving MTP mode: adb lost, suite stopped"; exit 3
}
reg usb - 1 "USB gadget from the PC side: speed, interfaces, MTP session + adb when switched to MTP"
t_usb() {
	local d; d=$(usb_sys); [ -n "$d" ] || { fail "PC sysfs has no USB device with serial $S"; return; }
	local sp; sp=$(cat $d/speed); metric usb_speed_mbit "$sp"; echo "  $d speed $sp bMaxPower $(cat $d/bMaxPower) config $(cat $d/bConfigurationValue)"; for i in $d/*:*; do echo "   if $(basename $i) class $(cat $i/bInterfaceClass)/$(cat $i/bInterfaceSubClass)/$(cat $i/bInterfaceProtocol) $(cat $i/interface 2>/dev/null)"; done
	chk "enumerated at $sp Mbit/s (>= high speed)" [ "$sp" -ge 480 ]
	chk "adb interface (ff/42/01) present on the PC" grep -qs 42 $d/*:*/bInterfaceSubClass
	if [ "${DAILY:-0}" = 1 ] || [ "$UNLOCKED" = 0 ]; then skip "MTP switch (needs an unlocked test phone)"; else
		wake; A 'svc usb setFunctions mtp' >/dev/null; sleep 6; timeout 30 adb -s "$S" wait-for-device 2>/dev/null; d=$(usb_sys); for i in $d/*:*; do echo "   mtp-mode if $(basename $i) class $(cat $i/bInterfaceClass)/$(cat $i/bInterfaceSubClass)/$(cat $i/bInterfaceProtocol) $(cat $i/interface 2>/dev/null)"; done
		if grep -qsi mtp $d/*:*/interface || grep -qs 06 $d/*:*/bInterfaceClass; then local o; o=$(timeout 40 python3 -I "$MTPPIN" info "$(cat $d/busnum)" "$(cat $d/devnum)" 2>&1); echo "$o" | grep -aE "Serial number|Model:|StorageDescription|MaxCapacity|FreeSpaceInBytes|Device version|error|Unable" | head -12
			if echo "$o" | grep -aq "Model: "; then if echo "$o" | grep -aq MaxCapacity; then ok "MTP: PC opened a session and read the storage list"; else ok "MTP: PC opened a session (device info read)"; skip "MTP storage list empty (phone locked?); file round trip (todo: mtp-sendfile/getfile with checksum)"; fi
			else fail "MTP interface enumerates but mtp-detect could not open the device: $(echo "$o" | grep -aiE 'error|unable|busy' | head -1 | cut -c1-140)"; fi
		else fail "svc usb setFunctions mtp is not applied: sys.usb.state stays '$(A getprop sys.usb.state)', the PC sees no MTP interface ($(A dumpsys usb | grep -m1 -oE 'current_functions_applied=[a-z]+'))"; A 'logcat -d -t 200 | grep -iE "usb" | tail -10' | cut -c1-200; fi
		A 'svc usb setFunctions' >/dev/null; usb_adb_back
		chk "adb back after leaving MTP mode" [ "$(A echo hi)" = hi ]
	fi
	hands "USB: unplug/replug the cable, OTG stick + mouse, USB-C headphones/DAC (USB audio), PD fast charger"
}

reg charging - 1 "charging: measured battery current/voltage/temperature on USB, Type-C role"
t_charging() {
	local st lvl cur v t i; st=$(A cmd battery get status); lvl=$(A cmd battery get level); v=$(A dumpsys battery | awk '/^ *voltage:/{print $2}'); t=$(A dumpsys battery | awk '/temperature:/{print $2}')
	local sum=0 n=0; for i in 1 2 3 4 5; do cur=$(num "$(A cmd battery get current_now)"); echo "  current_now $cur"; sum=$((sum+cur)); n=$((n+1)); sleep 1; done; cur=$((sum/n))
	[ "${cur#-}" -gt 20000 ] && cur=$((cur/1000))   # uA -> mA
	metric bat_current_ma "$cur"; metric bat_level "$lvl"; metric bat_mv "$v"; metric bat_temp_dc "$t"; A dumpsys battery | grep -E 'powered: true|status|health|level|voltage:|temperature|Charge counter'
	chk "battery sane: level $lvl %, $v mV, $((t/10)) C" between "$v" 3300 4500
	chk "battery temperature 5-50 C" between "$t" 50 500
	if [ "$st" = 5 ] && [ "$lvl" -ge 99 ]; then if [ "$cur" -ge -60 ]; then ok "Full on USB: battery current ${cur} mA (not draining)"; else fail "status Full on USB but battery drains ${cur} mA (charger off while VBUS present?)"; fi; skip "charge current magnitude (battery is full: needs a run below 90 %)"
	elif [ "$cur" -gt 50 ]; then ok "charging on USB: +${cur} mA at ${lvl} %"
	else fail "USB attached at ${lvl} % but battery current is ${cur} mA (status $st)"; fi
	local u; u=$(A dumpsys usb | grep -E 'current_mode|power_role|data_role|connected=' | tr -s ' ' | tr '\n' ' '); echo "  $u"
	if echo "$u" | grep -q 'power_role=sink' && echo "$u" | grep -q 'data_role=device'; then ok "Type-C port reports sink/device while on the PC"; else fail "Type-C port role wrong on a PC port: $u"; fi
	have_root && R 'for f in /sys/class/typec/port0/*role* /sys/class/power_supply/usb/{online,current_max,voltage_now} /sys/class/power_supply/battery/{current_now,charge_now,batt_temp}; do echo "$f $(cat $f 2>/dev/null)"; done'
}

ifmac() { A "ip -o link" | grep -E "^[0-9]+: $1[:@]" | grep -oE "link/ether [0-9a-f:]+" | cut -d" " -f2; }
wifi_connected() { A cmd wifi status | grep -q 'Wifi is connected'; }
reg wifi - 1 "Wi-Fi: 5 off/on cycles with reconnect, scan, ping, measured throughput both directions vs the PC, MAC stable, P2P iface"
t_wifi() {
	local was; was=$(A cmd wifi status | head -1); wifi_connected || { A 'svc wifi enable' >/dev/null; sleep 12; }
	wifi_connected || { skip "Wi-Fi traffic (needs a saved network in range; status: $(A cmd wifi status | sed -n 2,4p | tr '\n' ' ' | cut -c1-100))"; return; }
	local mac0 p2p0 n=5 good=0 i k; mac0=$(ifmac wlan0); p2p0=$(ifmac p2p0)
	if [ "${DAILY:-0}" = 1 ]; then skip "Wi-Fi off/on cycles (daily phone)"; else [ "$QUICK" = 1 ] && n=2
		for i in $(seq 1 $n); do A 'svc wifi disable' >/dev/null; sleep 3; local off; off=$(A cmd wifi status | head -1); A 'svc wifi enable' >/dev/null; for k in $(seq 1 25); do sleep 1; wifi_connected && break; done
			echo "  cycle $i: '$off' -> reconnected after ${k}s: $(wifi_connected && echo yes || echo NO)"; [ "$off" = "Wifi is disabled" ] && wifi_connected && good=$((good+1)); metric wifi_reconnect_s "$k"; done
		if [ $good = $n ]; then ok "$n/$n off/on cycles reconnected"; else fail "only $good/$n Wi-Fi off/on cycles reconnected within 25 s"; fi
		chk "p2p0 MAC unchanged over the cycles ($p2p0)" [ "$(ifmac p2p0)" = "$p2p0" ]
	fi
	A cmd wifi status | grep -oE 'SSID: [^,]*|RSSI: [^,]*|Link speed: [^,]*|Frequency: [^,]*|Wi-Fi standard: [^,]*' | tr '\n' ' '; echo
	A 'cmd wifi start-scan' >/dev/null; sleep 6; local sc; sc=$(A 'cmd wifi list-scan-results' | grep -cE '^ *([0-9a-f]{2}:){5}'); metric wifi_scan_aps "$sc"
	if [ "$sc" -ge 1 ]; then ok "scan found $sc APs"; else fail "scan returned 0 APs"; fi
	local gw pl; gw=$(A 'ip route show dev wlan0' | awk '/default|via/{print $3; exit}'); [ -z "$gw" ] && gw=$(A 'ip route get 8.8.8.8' | grep -oE 'via [0-9.]+' | cut -d' ' -f2)
	pl=$(A "ping -c 10 -i 0.2 -W 2 ${gw:-8.8.8.8}" | tee /dev/stderr | grep -oE '[0-9]+% packet loss' | cut -d% -f1); metric wifi_ping_loss_pct "${pl:-100}"
	if [ "${pl:-100}" -le 10 ]; then ok "ping ${gw:-8.8.8.8}: ${pl}% loss"; else fail "ping ${gw:-8.8.8.8}: ${pl:-100}% loss"; fi
	# throughput against the PC (LAN, no internet involved)
	# throughput against the PC over the LAN, both directions (phone listens with toybox nc, the PC connects and times it)
	local ip sz=40 port=47231 r; [ "$QUICK" = 1 ] && sz=15; ip=$(A 'ip -4 -o addr show wlan0' | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
	( TMO=40 A "nc -l -p $port | wc -c" > "$L.dl.out" 2>&1 & ); sleep 1.5
	r=$(python3 - "$ip" $port $((sz*1000000)) <<'PY'
import socket, sys, time
try:
    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5); n = int(sys.argv[3]); b = b"\xa5" * 65536; t = time.time()
    while n > 0: s.sendall(b[:min(n, 65536)]); n -= 65536
    s.shutdown(socket.SHUT_WR)
    try: s.settimeout(10); s.recv(1)
    except Exception: pass
    print(round(time.time() - t, 3))
except Exception as e: print("ERR", e)
PY
); sleep 1.5; local got; got=$(num "$(cat "$L.dl.out")"); echo "  PC->phone: sent $((sz)) MB in $r s, phone counted ${got:-0} bytes"
	if [ "${got:-0}" -ge $((sz*1000000)) ]; then local mbd; mbd=$(python3 -c "print(int($sz*8/$r))"); metric wifi_down_mbit "$mbd"; if [ "$mbd" -ge 20 ]; then ok "receive ${mbd} Mbit/s (${sz} MB from the PC, byte count verified)"; else fail "receive only ${mbd} Mbit/s"; fi
	else skip "LAN throughput PC->phone (got ${got:-0} of $((sz*1000000)) bytes, $r: needs the PC to reach $ip:$port on the LAN)"; fi
	( TMO=40 A "head -c $((sz*1000000)) /dev/zero | nc -l -p $((port+1))" > /dev/null 2>&1 & ); sleep 1.5
	r=$(python3 - "$ip" $((port+1)) <<'PY'
import socket, sys, time
try:
    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5); s.settimeout(10); n = 0; t = time.time()
    while True:
        b = s.recv(65536)
        if not b: break
        n += len(b)
    print(n, round(time.time() - t, 3))
except Exception as e: print("ERR", e)
PY
); echo "  phone->PC: $r"; set -- $r
	if [ "${1:-0}" -ge $((sz*1000000)) ] 2>/dev/null; then local mbu; mbu=$(python3 -c "print(int($1*8/1e6/$2))"); metric wifi_up_mbit "$mbu"; if [ "$mbu" -ge 20 ]; then ok "send ${mbu} Mbit/s (byte count verified)"; else fail "send only ${mbu} Mbit/s"; fi
	else skip "LAN throughput phone->PC ($r)"; fi
	chk "wlan0 MAC unchanged ($mac0)" [ -n "$mac0" -a "$(ifmac wlan0)" = "$mac0" ]
	chk "P2P (Wi-Fi Direct) interface p2p0 exists with its own MAC" [ -n "$p2p0" ]
	skip "Wi-Fi Direct group formation (needs a peer: hands-on)"; hands "Wi-Fi Direct / Quick Share to another device"
}

reg hotspot - 1 "Wi-Fi hotspot: start, AP interface up and beaconing state, stop (a client join needs a second device)"
t_hotspot() {
	[ "${DAILY:-0}" = 1 ] && { skip "hotspot (daily phone)"; return; }
	local before; before=$(A 'cmd wifi start-softap a52selftest wpa2 selftest1234 -b 5'); echo "$before" | head -3; local k up=
	echo "$before" | grep -q 'does not have access' && { skip "hotspot start (needs root: cmd wifi start-softap is refused for the shell uid on user builds)"; hands "Hotspot: turn it on in Settings, join from another phone, load a page"; return; }
	for k in $(seq 1 15); do sleep 1; up=$(A 'ip -o link' | grep -E '(swlan|wlan[1-9])[0-9]*:' | grep -E 'LOWER_UP' | awk -F': ' '{print $2}' | head -1); [ -n "$up" ] && break; done
	A 'dumpsys wifi | grep -iE "softap.*(state|enabled|started)|mApInterfaceName|SoftApManager.*(freq|channel)"' | tail -6 | cut -c1-200
	if [ -n "$up" ]; then ok "soft AP interface $up came up (carrier) ${k}s after start-softap"; metric hotspot_start_s "$k"; else fail "start-softap: no AP interface with carrier within 15 s"; fi
	A 'cmd wifi stop-softap' >/dev/null; sleep 4; up=$(A 'ip -o link' | grep -E '(swlan|wlan[1-9])[0-9]*:' | grep -c LOWER_UP)
	chk "AP interface down after stop-softap" [ "$up" = 0 ]
	sleep 3; if wifi_connected; then ok "station still connected after the hotspot"; else sleep 10; chk "station reconnected after the hotspot" wifi_connected; fi
	skip "client joining the hotspot + traffic (needs a second device: hands-on)"; hands "Hotspot: join it from another phone and load a page"
}

bt_state() { A dumpsys bluetooth_manager | grep -m1 -E '^ *State:' | awk '{print $2}'; }
reg bluetooth - 1 "Bluetooth: 5 off/on cycles (measured adapter state), LE scan finds real advertisers; A2DP/SCO need a headset"
t_bluetooth() {
	[ "${DAILY:-0}" = 1 ] && { skip "Bluetooth toggles (daily phone)"; return; }
	local was n=5 good=0 i k; was=$(bt_state); [ "$QUICK" = 1 ] && n=2
	for i in $(seq 1 $n); do A 'svc bluetooth disable' >/dev/null; for k in $(seq 1 10); do sleep 1; [ "$(bt_state)" = OFF ] && break; done; local off; off=$(bt_state)
		A 'svc bluetooth enable' >/dev/null; for k in $(seq 1 15); do sleep 1; [ "$(bt_state)" = ON ] && break; done; echo "  cycle $i: $off -> $(bt_state) after ${k}s"; [ "$off" = OFF ] && [ "$(bt_state)" = ON ] && good=$((good+1)); done
	metric bt_cycles_ok "$good"; if [ $good = $n ]; then ok "$n/$n off/on cycles (HCI up each time)"; else fail "only $good/$n Bluetooth off/on cycles reached ON"; fi
	sleep 2; wake; strun ble 6
	if have_root; then local c; c=$(R 'PATH=$PATH:/data/local/tmp; tinymix 2>/dev/null | grep -cE "SLIM[_ ]7"'); R 'PATH=$PATH:/data/local/tmp; tinymix 2>/dev/null | grep -E "SLIM[_ ]7" | head -8'; metric slim7_controls "$(num "$c")"; note "SLIM_7 mixer controls: $c (presence only, not a pass)"; fi
	skip "A2DP / SCO audio over SLIMbus (needs a paired headset: hands-on)"; hands "Bluetooth earbuds: music (A2DP) and a call (SCO), check sound both ways"
	[ "$was" = OFF ] && A 'svc bluetooth disable' >/dev/null
}

reg nfc - 1 "NFC: off/on cycle with measured controller state (tag read needs a tag)"
t_nfc() {
	[ "${DAILY:-0}" = 1 ] && { skip "NFC toggle (daily phone)"; return; }
	local was a b c; nst() { A dumpsys nfc | grep -m1 -E '^ *mState=' | cut -d= -f2; }; was=$(nst)
	A 'cmd nfc disable-nfc' >/dev/null; sleep 4; a=$(nst); A 'cmd nfc enable-nfc' >/dev/null; sleep 6; b=$(nst); echo "  was $was -> $a -> $b"
	A 'logcat -d -t 300 | grep -iE "nfc.*(firmware|fw version|NCI_VERSION|chip)" | tail -3' | cut -c1-160
	if [ "$a" = off ] && [ "$b" = on ]; then ok "controller went off and back on (NCI init ok)"; else fail "NFC toggle: off->'$a', on->'$b'"; fi
	[ "$was" = off ] && A 'cmd nfc disable-nfc' >/dev/null
	skip "tag read / card emulation (needs a tag: hands-on)"; hands "NFC: tap a card/tag"
}

reg gnss - 1 "GNSS: engine start and satellites tracked (C/N0), fix needs sky view"
t_gnss() {
	local s=45; [ "$QUICK" = 1 ] && s=25; ps global location_background_throttle_package_whitelist com.android.shell
	local o; o=$(TMO=$((s+30)) dex gnss Gnss $s status 2>&1); echo "$o" | grep -v 'step' | tail -15; restore_one global location_background_throttle_package_whitelist
	local seen best; seen=$(echo "$o" | grep -oE 'seen [0-9]+' | awk '{print $2}' | sort -n | tail -1); best=$(echo "$o" | grep -oE 'bestCN0 [0-9.]+' | awk '{print $2}' | sort -n | tail -1)
	metric gnss_sats_seen "${seen:-0}"; metric gnss_best_cn0 "${best:-0}"
	if [ "${seen:-0}" -ge 1 ] && python3 -c "import sys; sys.exit(0 if float('${best:-0}')>=15 else 1)"; then ok "engine started, ${seen} satellites tracked, best C/N0 ${best} dB-Hz"
	elif echo "$o" | grep -q 'engine started'; then skip "engine started but 0 satellites above 15 dB-Hz in ${s}s (needs sky view: hands-on)"
	elif [ -n "${NOMODEM:-}" ]; then skip "GNSS engine did not start; this phone has no modem (the GNSS engine lives in the modem subsystem; same on its 5.4 kernel)"
	else fail "GNSS engine did not start in ${s}s: $(echo "$o" | tail -1 | cut -c1-120)"; fi
	echo "$o" | grep -q 'FIRST FIX' && ok "position fix obtained" || hands "GPS: put the phone at a window, check a fix in a maps app"
}

reg modem - 1 "modem: RIL answers (baseband version read), SIM/service state, phone process not spinning"
t_modem() {
	local bb sim reg cpu; bb=$(A getprop gsm.version.baseband); sim=$(A getprop gsm.sim.state); echo "  baseband '$bb' sim '$sim' operator '$(A getprop gsm.operator.alpha)' type '$(A getprop gsm.network.type)'"
	if [ -n "${bb%%,*}" ]; then ok "RIL read the baseband version from the modem: ${bb%%,*}"; elif [ -n "${NOMODEM:-}" ]; then skip "no baseband: this phone has no working modem (not a kernel verdict)"; else fail "no baseband version (RIL has no modem link)"; fi
	reg=$(A dumpsys telephony.registry | grep -m1 -oE 'mVoiceRegState=[0-9]+\([A-Z_]+\)|mDataRegState=[0-9]+\([A-Z_]+\)|mIsEmergencyOnly=[a-z]+' | tr '\n' ' '); A dumpsys telephony.registry | grep -m2 -E 'mServiceState=' | cut -c1-300
	cpu=$(A 'top -b -n 2 -d 2 2>/dev/null | grep -E "com.android.phone|rild|qcrild" | tail -3' | awk '{c=$9+0; if (c>m) m=c} END{print int(m)}'); metric phone_cpu_pct "${cpu:-0}"
	if [ "${cpu:-0}" -lt 40 ]; then ok "com.android.phone/rild CPU ${cpu:-0} % (no spin)"; else fail "com.android.phone/rild spinning at ${cpu} % CPU"; fi
	if [ "$SIM" = 1 ]; then local ss; ss=$(A dumpsys telephony.registry | grep -m1 -oE 'mVoiceRegState=0\(IN_SERVICE\)'); if [ -n "$ss" ]; then ok "registered: $(A getprop gsm.operator.alpha) $(A getprop gsm.network.type)"; else fail "SIM present but not in service: $reg"; fi
		local dp; dp=$(A 'ping -c 5 -W 3 -I rmnet_data0 8.8.8.8 2>&1' | grep -oE '[0-9]+% packet loss'); note "mobile data ping: ${dp:-n/a}"
		hands "Call: make and receive a call (audio both ways, proximity screen-off), send + receive an SMS"
	else skip "registration, mobile data, calls, SMS (needs a SIM); state without SIM: $reg"; hands "Insert a SIM: call both ways, SMS, mobile data, in-call proximity"; fi
}
