#!/bin/bash
# Feature check of a REAL (flashed, enforcing) 6.12 boot on a test phone, over root adb. Read-mostly:
# it plays a muted tone, records 2 s, toggles the screen, changes the brightness and the GPU max_freq
# and puts both back. It flashes nothing, never touches adb/USB settings, never vibrates.
#
#   drivers612/realboot/verify-realboot.sh <label> [expected realboot name]
#     -> logs/verify-<label>-<HHMMSS>/{dmesg.txt,logcat.txt,RESULT.txt,...}; exit 0 when no check FAILs
# Env: SERIAL (default PHONE2 = white cable; the only other allowed one is PHONE1),
#      BASE_DMESG (default logs/rb31-realboot-dmesg.txt: the WARN list to compare with),
#      BASE_MEMTOTAL_KB (default 5334696 = rb31..rb33 on white cable), MEM_GAIN_MIB (default 46: the audit's
#      dump_mem 44 MiB + ramoops-region 2 MiB carve-outs; the 100 MiB non_secure_display CMA pool was already
#      inside MemTotal, it shows as CmaTotal 417792 -> 315392 kB), BASE_CMATOTAL_KB,
#      SKIP="camera stopstart ..." (check names to skip), STOPSTART=1 (also run `stop`/`start`: the
#      framework restart that reset the SoC on rb31-33; default 0, run it last),
#      MODEM_OK=0 (default: the phone has no working modem; only "no crash, phone process calm")
set -u
cd "$(dirname "$0")/../.."
LABEL=${1:?label}; WANT=${2:-}
S=${SERIAL:-PHONE2}
case "$S" in PHONE2|PHONE1) ;; *) echo "refusing serial $S (test phones only)" >&2; exit 2;; esac
BASE_DMESG=${BASE_DMESG:-logs/rb31-realboot-dmesg.txt}
BASE_MEM=${BASE_MEMTOTAL_KB:-5334696}; GAIN=${MEM_GAIN_MIB:-46}; BASE_CMA=${BASE_CMATOTAL_KB:-417792}
L=logs/verify-$LABEL-$(date +%H%M%S); mkdir -p "$L"
R=$L/RESULT.txt; : > "$R"
A() { adb -s "$S" "$@"; }
sh() { A shell "$@" 2>&1 | tr -d '\r'; }
NP=0; NF=0; NI=0
res() { # PASS|FAIL|INFO name detail
	case "$1" in PASS) NP=$((NP+1));; FAIL) NF=$((NF+1));; *) NI=$((NI+1));; esac
	printf '%-4s %-16s %s\n' "$1" "$2" "$3" | tee -a "$R"
}
ok() { [ "$1" = 1 ] && res PASS "$2" "$3" || res FAIL "$2" "$3"; }
skip() { case " ${SKIP:-} " in *" $1 "*) res INFO "$1" "skipped (SKIP)"; return 0;; esac; return 1; }
dm() { sh dmesg > "$L/$1"; }

[ "$(A get-state 2>/dev/null)" = device ] || { echo "$S not in Android"; exit 1; }
A root >/dev/null 2>&1; timeout 30 adb -s "$S" wait-for-device
for i in $(seq 60); do [ "$(sh getprop sys.boot_completed)" = 1 ] && break; sleep 2; done
# mute first (after every boot)
sh 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done'
for t in tone rec vdec photo; do A push tools/$t/$t.dex /data/local/tmp/$t.dex >/dev/null 2>&1; done

# ---- 1. identity
UN=$(sh uname -r); BC=$(sh getprop sys.boot_completed); ENF=$(sh getenforce)
MARK=$(sh 'cat /proc/device-tree/soc/a52sxq,realboot' | tr -d '\0')
ok $([ "$BC" = 1 ] && echo 1 || echo 0) boot_completed "sys.boot_completed=$BC, $UN, realboot=$MARK, up $(sh 'cut -d. -f1 /proc/uptime') s"
ok $([ "$ENF" = Enforcing ] && echo 1 || echo 0) enforcing "$ENF"
[ -z "$WANT" ] || ok $([ "$MARK" = "$WANT" ] && echo 1 || echo 0) build "dtbo marker '$MARK' (want $WANT), base $(sh 'cat /proc/device-tree/soc/a52sxq,realboot-base' | tr -d '\0')"
case "$UN" in 6.12.*) ;; *) res FAIL kernel "$UN is not 6.12"; echo "summary: pass=$NP fail=$NF"; exit 1;; esac
sh 'cat /proc/cmdline' > "$L/cmdline.txt"

# ---- 2. things that need settling: wait until 75 s of uptime (touch fw recheck at ~60 s, tunables at ~50 s)
UP=$(sh 'cut -d. -f1 /proc/uptime'); [ "$UP" -lt 75 ] && sleep $((75 - UP))

# ---- 3. audio
CARD=$(sh 'cat /proc/asound/cards' | head -1)
ok $(echo "$CARD" | grep -q 'lahaina-yupikidp' && echo 1 || echo 0) soundcard "${CARD:-none}; /dev/snd nodes $(sh 'ls /dev/snd | wc -l'); card0/state=$(sh 'cat /proc/asound/card0/state')"
T=$(sh 'app_process -cp /data/local/tmp/tone.dex / Tone 2>/dev/null' | grep '^tone: state')
ok $(echo "$T" | grep -q 'head 48000/48000 underruns 0' && echo 1 || echo 0) tone "${T:-no output}"
T=$(sh 'app_process -cp /data/local/tmp/tone.dex / Tone ll 2>/dev/null' | grep '^tone: state')
ok $(echo "$T" | grep -q 'head 48000/48000' && echo 1 || echo 0) tone-lowlat "${T:-no output}"
M=$(sh 'app_process -cp /data/local/tmp/rec.dex / Rec 2>/dev/null' | grep '^rec: frames')
ok $(echo "$M" | grep -q 'frames 96000/96000' && ! echo "$M" | grep -q 'nonzero 0 ' && echo 1 || echo 0) mic "${M:-no output}"

# ---- 4. Wi-Fi, Bluetooth, NFC
W=$(sh 'cmd wifi status' | grep -m1 'Wifi is connected to')
for i in 1 2 3 4 5 6; do [ -n "$W" ] && break; sleep 5; W=$(sh 'cmd wifi status' | grep -m1 'Wifi is connected to'); done
P=$(sh 'ping -c 3 -W 3 8.8.8.8' | grep -E 'packets transmitted')
ok $([ -n "$W" ] && echo "$P" | grep -q ' 0% packet loss' && echo 1 || echo 0) wifi "${W:-not connected}; ping: ${P:-none}; wlan0 $(sh 'cat /sys/class/net/wlan0/operstate')"
BT=$(sh 'dumpsys bluetooth_manager' | grep -m1 -iE '^ *state: ')
ok $(echo "$BT" | grep -qE 'ON$' && echo 1 || echo 0) bluetooth "$(echo $BT), bluetooth_on=$(sh 'settings get global bluetooth_on')"
NFC=$(sh 'dumpsys nfc' | grep -m1 'mState=')
ok $(echo "$NFC" | grep -q 'mState=on' && echo 1 || echo 0) nfc "${NFC:-no mState}; hal $(sh 'getprop init.svc.vendor.sec_nfc_hal_service')"

# ---- 5. camera
NC=$(sh 'dumpsys media.camera' | sed -n 's/.*Number of camera devices: //p' | head -1)
ok $([ "$NC" = 5 ] && echo 1 || echo 0) cameras "$NC camera devices"
if ! skip camera; then
	# camera2 still through the camera service (tools/photo): works while the user is still locked after boot
	C0=$(sh 'app_process -cp /data/local/tmp/photo.dex / Photo 0 /data/local/tmp/photo0.jpg 2>/dev/null' | grep -E '^photo: (cam|no|open|configure|device)' | tail -1)
	C1=$(sh 'app_process -cp /data/local/tmp/photo.dex / Photo 1 /data/local/tmp/photo1.jpg 2>/dev/null' | grep -E '^photo: (cam|no|open|configure|device)' | tail -1)
	A pull /data/local/tmp/photo0.jpg "$L/photo-rear.jpg" >/dev/null 2>&1; A pull /data/local/tmp/photo1.jpg "$L/photo-front.jpg" >/dev/null 2>&1
	ok $(echo "$C0" | grep -q 'bytes [0-9]\{6,\}' && echo "$C1" | grep -q 'bytes [0-9]\{6,\}' && echo 1 || echo 0) photo "rear: ${C0:-none}; front: ${C1:-none}; CAM_ERR lines $(sh dmesg | grep -c CAM_ERR)"
fi

# ---- 6. video decode
if ! skip vdec; then
	CLIP=$(ls logs/ab-s73-video.mp4 logs/*.mp4 2>/dev/null | head -1)
	if [ -n "$CLIP" ]; then
		A push "$CLIP" /data/local/tmp/vdec-clip.mp4 >/dev/null 2>&1
		V=$(sh 'app_process -cp /data/local/tmp/vdec.dex / Vdec /data/local/tmp/vdec-clip.mp4 2>/dev/null' | tr '\n' ' ')
		ok $(echo "$V" | grep -q 'hw true' && echo "$V" | grep -qE 'frames [1-9]' && ! echo "$V" | grep -q timeout && echo 1 || echo 0) vdec "$V"
	else res INFO vdec "no clip in logs/"; fi
fi

# ---- 7. display: off/on 5x, brightness, screencap
if ! skip display; then
	E0=$(sh 'dmesg' | grep -cE 'underrun|sde_encoder.*(timeout|error)|dsi.*(error|failed)|\[drm:.*ERROR')
	OKC=0
	for i in 1 2 3 4 5; do
		sh 'input keyevent KEYCODE_SLEEP'; sleep 2; a=$(sh 'dumpsys power' | sed -n 's/.*mWakefulness=//p' | head -1)
		sh 'input keyevent KEYCODE_WAKEUP'; sleep 2; b=$(sh 'dumpsys power' | sed -n 's/.*mWakefulness=//p' | head -1)
		[ "$a" != Awake ] && [ "$b" = Awake ] && OKC=$((OKC+1))
	done
	sh 'wm dismiss-keyguard; input keyevent KEYCODE_HOME' >/dev/null; sleep 2
	E1=$(sh 'dmesg' | grep -cE 'underrun|sde_encoder.*(timeout|error)|dsi.*(error|failed)|\[drm:.*ERROR')
	ok $([ "$OKC" = 5 ] && [ "$E1" = "$E0" ] && echo 1 || echo 0) display-offon "$OKC/5 sleep/wake cycles, display error lines $E0 -> $E1"
	BR0=$(sh 'settings get system screen_brightness'); BM0=$(sh 'settings get system screen_brightness_mode')
	sh 'settings put system screen_brightness_mode 0; settings put system screen_brightness 30'; sleep 2; K1=$(sh 'dmesg' | grep -E 'ss_brightness_dcs|bl_level|backlight' | tail -1)
	sh 'settings put system screen_brightness 200'; sleep 2; K2=$(sh 'dmesg' | grep -E 'ss_brightness_dcs|bl_level|backlight' | tail -1)
	sh "settings put system screen_brightness $BR0; settings put system screen_brightness_mode $BM0"
	ok $([ -n "$K2" ] && [ "$K1" != "$K2" ] && echo 1 || echo 0) brightness "30: $(echo "$K1" | cut -c1-110) | 200: $(echo "$K2" | cut -c1-110)"
	sh 'input keyevent KEYCODE_WAKEUP' >/dev/null; sleep 1.5
	A exec-out screencap -p > "$L/screen.png" 2>/dev/null
	SC=$(python3 -I - "$L/screen.png" <<'EOF'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
if d[:8] != b'\x89PNG\r\n\x1a\n': print("0 not-a-png"); sys.exit()
i = 8; idat = b''; w = h = 0
while i < len(d):
    n, t = struct.unpack('>I4s', d[i:i+8])
    if t == b'IHDR': w, h = struct.unpack('>II', d[i+8:i+16])
    if t == b'IDAT': idat += d[i+8:i+8+n]
    i += 12 + n
raw = zlib.decompress(idat)
nz = sum(1 for b in raw[::997] if b > 16); tot = len(raw[::997])
# a dark lock screen (clock on black) is a rendered UI too: a few bright samples + several distinct values
print("%d %dx%d bright-samples %d/%d distinct %d" % (1 if nz >= 20 and len(set(raw[::997])) >= 8 else 0, w, h, nz, tot, len(set(raw[::997]))))
EOF
)
	ok "${SC%% *}" screencap "${SC#* } ($(stat -c %s "$L/screen.png") bytes)"
fi

# ---- 8. GPU
K=/sys/class/kgsl/kgsl-3d0
G="model $(sh "cat $K/gpu_model") gov $(sh "cat $K/devfreq/governor") freqs $(sh "cat $K/devfreq/available_frequencies")"
ok $(echo "$G" | grep -q 'msm-adreno-tz' && echo 1 || echo 0) gpu "$G; kgsl oom lines $(sh dmesg | grep -c 'kgsl: out of memory')"
if ! skip gpu-pmqos; then
	rd() { echo "max_freq=$(sh "cat $K/devfreq/max_freq") max_gpuclk=$(sh "cat $K/max_gpuclk") thermal_pwrlevel=$(sh "cat $K/thermal_pwrlevel") max_pwrlevel=$(sh "cat $K/max_pwrlevel")"; }
	Q0=$(rd)
	sh "echo 450000000 > $K/devfreq/max_freq"; sleep 1; Q1=$(rd)
	sh "echo 560000000 > $K/devfreq/max_freq"; sleep 1; Q2=$(rd)
	sh "echo 320000000 > $K/devfreq/max_freq"; sleep 1; Q3=$(rd)
	sh "echo 560000000 > $K/devfreq/max_freq"; sleep 1; Q4=$(rd)
	printf 'start: %s\n450M:  %s\n560M:  %s\n320M:  %s\n560M:  %s\n' "$Q0" "$Q1" "$Q2" "$Q3" "$Q4" > "$L/gpu-pmqos.txt"
	lv() { echo "$1" | sed -n 's/.*thermal_pwrlevel=\([0-9]*\).*/\1/p'; }
	ok $([ "$(lv "$Q1")" = 1 ] && [ "$(lv "$Q2")" = 0 ] && [ "$(lv "$Q3")" = 2 ] && [ "$(lv "$Q4")" = 0 ] && echo 1 || echo 0) gpu-pmqos "thermal_pwrlevel 450M/560M/320M/560M = $(lv "$Q1")/$(lv "$Q2")/$(lv "$Q3")/$(lv "$Q4") (want 1/0/2/0); $L/gpu-pmqos.txt"
fi

# ---- 9. thermal
TZ=$(sh 'ls /sys/class/thermal | grep -c thermal_zone'); CD=$(sh 'ls /sys/class/thermal | grep -c cooling_device')
sh 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) temp=$(cat $z/temp 2>/dev/null) trips=$(cat $z/trip_point_0_temp 2>/dev/null),$(cat $z/trip_point_1_temp 2>/dev/null),$(cat $z/trip_point_2_temp 2>/dev/null) cdevs=$(ls $z | grep -c "^cdev[0-9]*$")"; done' > "$L/thermal.txt"
NOCD=$(grep -E '^(cpu-|pm|gpu)' "$L/thermal.txt" | grep -c 'cdevs=0$')
ok $([ "$TZ" -ge 32 ] && [ "$CD" -ge 36 ] && echo 1 || echo 0) thermal "$TZ zones, $CD cooling devices; cpu/gpu/pm zones without a cdev: $NOCD; binding failures in dmesg: $(sh dmesg | grep -c 'binding.*failed')"
PM=$(grep -E '^(pm7325_tz|pm8350c_tz|pmr735a_tz) ' "$L/thermal.txt" | tr '\n' ';')
ok $([ "$(grep -cE '^(pm7325_tz|pm8350c_tz) .*trips=95000,115000,145000 cdevs=[1-9]' "$L/thermal.txt")" = 2 ] && echo 1 || echo 0) thermal-pmic "$PM above-max-stage2 lines: $(sh dmesg | grep -c 'is above the maximum stage 2')"
res INFO thermal-bcl "$(grep bcl "$L/thermal.txt" | tr '\n' ';')"

# ---- 10. power: charging, type-C, suspend stats
sh 'for f in status capacity current_now voltage_now; do echo "battery/$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"; done; for p in usb ac; do echo "$p/online=$(cat /sys/class/power_supply/$p/online 2>/dev/null)"; done; echo "icl=$(cat /sys/class/power_supply/sm5714-charger/input_current_limit 2>/dev/null) cc=$(cat /sys/class/power_supply/sm5714-charger/constant_charge_current 2>/dev/null)"; dumpsys battery | grep -E "USB powered|level|status|Max charging current"' > "$L/power.txt"
UO=$(sed -n 's/^usb\/online=//p' "$L/power.txt"); ST=$(sed -n 's/^battery\/status=//p' "$L/power.txt"); CN=$(sed -n 's/^battery\/current_now=//p' "$L/power.txt")
UC=$(sh dmesg | grep -E 'usb configure|sec_usb_set_property|set_input_current' | tail -1 | cut -c1-120)
ok $([ "$UO" = 1 ] && { [ "$ST" = Charging ] || [ "$ST" = Full ]; } && echo 1 || echo 0) charging "usb online=$UO, battery $ST $(sed -n 's/^battery\/capacity=//p' "$L/power.txt")% current_now=$CN mA, $(grep '^icl' "$L/power.txt"); last: $UC"
TC=$(sh 'ls /sys/class/typec' | tr '\n' ' ')
ok $(echo "$TC" | grep -q port0 && echo 1 || echo 0) typec "$TC; data_role=$(sh 'cat /sys/class/typec/port0/data_role') power_role=$(sh 'cat /sys/class/typec/port0/power_role')"
SS=$(sh 'cat /sys/kernel/debug/suspend_stats 2>/dev/null || for f in success fail failed_freeze failed_prepare failed_suspend failed_resume; do echo "$f: $(cat /sys/power/suspend_stats/$f)"; done' | head -12 | tr '\n' ' ')
ok $(echo "$SS" | grep -qE 'fail: 0 ' && echo 1 || echo 0) suspend-stats "$(echo $SS | cut -c1-200)"

# ---- 11. fingerprint, sensors
FP=$(sh 'getprop init.svc.vendor.fingerprint-default')
ok $([ "$FP" = running ] && echo 1 || echo 0) fingerprint "HAL $FP; $(sh 'dumpsys fingerprint' | grep -m1 -iE 'sensorId|"count"|prints' | cut -c1-100)"
SN=$(sh 'dumpsys sensorservice' | sed -n 's/^Total \([0-9]*\) h\/w sensors.*/\1/p' | head -1)
ok $([ "$SN" = 32 ] && echo 1 || echo 0) sensors "$SN h/w sensors"

# ---- 12. memory
MT=$(sh 'cat /proc/meminfo' | awk '/^MemTotal/{print $2}'); CT=$(sh 'cat /proc/meminfo' | awk '/^CmaTotal/{print $2}')
DG=$(( (MT - BASE_MEM) / 1024 ))
# a build without log_buf_len=8M / the DIAG debug words (release style) has ~36 MiB more: upper bound +48 there
GHI=$((GAIN + 8)); grep -q 'log_buf_len=' "$L/cmdline.txt" || GHI=$((GAIN + 48))
ok $([ "$DG" -ge $((GAIN - 4)) ] && [ "$DG" -le $GHI ] && [ "$CT" -le $((BASE_CMA - 100000)) ] && echo 1 || echo 0) memory "MemTotal $MT kB = baseline $BASE_MEM + $DG MiB (want ~$GAIN); CmaTotal $CT kB (baseline $BASE_CMA, want -102400); dma heaps: $(sh 'ls /dev/dma_heap' | tr '\n' ' ')"

# ---- 13. modem side (no working modem on white cable): modules, no crash, phone process calm
LM=$(sh lsmod | awk '{print $1}')
MISS=""; for m in ipam ipanetm rmnet_core rmnet_ctl rmnet_offload rmnet_shs rmnet_mem gsim; do echo "$LM" | grep -qx "$m" || MISS="$MISS $m"; done
PH=$(sh 'top -b -n 1 -d 3 -o %CPU,ARGS 2>/dev/null' | grep -m1 'com.android.phone' | awk '{print $1}')
PHP=$(sh 'pidof com.android.phone'); sleep 20; PHP2=$(sh 'pidof com.android.phone')
ok $([ -z "$MISS" ] && [ -n "$PHP" ] && [ "$PHP" = "$PHP2" ] && [ "${PH%.*}" -lt 30 ] 2>/dev/null && echo 1 || echo 0) ipa-rmnet "missing modules:${MISS:- none}; rmnet_ipa0 $(sh 'ls /sys/class/net | grep -c rmnet_ipa0'); com.android.phone pid $PHP -> $PHP2 (20 s), ${PH:-?}% CPU; multisim=$(sh 'getprop persist.radio.multisim.config'); keep-rmnet lines $(sh dmesg | grep -c 'keep rmnet_ipa0')"

# ---- 14. secure world: qseecom, keystore, lock settings
QS=$(sh dmesg | grep -cE 'failed to provide qseecom ops|qseecom.*failed with =-95')
LS=$(sh 'cmd lock_settings verify' | tail -1)
KS=$(sh 'echo k | keystore_cli_v2 list 2>&1 | head -2; keystore_cli_v2 delete --name=a52verify >/dev/null 2>&1; keystore_cli_v2 generate --name=a52verify 2>&1 | tail -1; keystore_cli_v2 sign-verify --name=a52verify 2>&1 | tail -1; keystore_cli_v2 delete --name=a52verify >/dev/null 2>&1' | tr '\n' ' ')
ok $(echo "$LM" | grep -qx qseecom_dlkm && echo "$LM" | grep -qx smcinvoke_dlkm && [ "$QS" = 0 ] && echo 1 || echo 0) qseecom "qseecom_dlkm + smcinvoke_dlkm loaded, proxy/listener error lines $QS, qseecomd $(sh 'getprop init.svc.vendor.qseecomd')"
# a phone with a lock credential (white cable: a pattern) answers "old credential was not provided": the
# gatekeeper round trip then needs the pattern, which this script does not know -> INFO, keystore is the TEE proof
res $(echo "$LS" | grep -qi 'verified successfully' && echo PASS || echo INFO) lock-settings "$LS; user state $(sh 'dumpsys user' | sed -n 's/^ *State: //p' | head -1)"
ok $(echo "$KS" | grep -q 'Verify: OK' && ! echo "$KS" | grep -qi 'fail' && echo 1 || echo 0) keystore "$(echo "$KS" | cut -c1-200)"
res INFO keymint "$(sh 'getprop | grep -E "init.svc.(vendor.)?(keymint|keymaster|gatekeeper|qseecomd)[^ ]*\]"' | tr -d '[]' | tr '\n' ' ')"

# ---- 15. debug file, misc
if grep -q 'androidboot.a52sxq.debug=1' "$L/cmdline.txt"; then
	# as the shell uid: the ROM has no su binary, so adbd is dropped to shell for this one read and put back
	A unroot >/dev/null 2>&1; sleep 3; timeout 30 adb -s "$S" wait-for-device
	KB=$(A shell 'id -u; cat /sys/devices/system/cpu/a52kmsg 2>&1 | wc -c' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
	A root >/dev/null 2>&1; sleep 3; timeout 30 adb -s "$S" wait-for-device
	ok $([ "${KB%% *}" = 2000 ] && [ "$(echo $KB | cut -d' ' -f2)" -gt 100000 ] 2>/dev/null && echo 1 || echo 0) a52kmsg "DEBUG build: uid/bytes read = $KB"
else
	ok $([ "$(sh 'ls /sys/devices/system/cpu/a52kmsg 2>/dev/null | wc -l')" = 0 ] && echo 1 || echo 0) a52kmsg "non-DEBUG build: file absent"
fi
if sh dmesg | grep -q 'bus DCVS tunables'; then
ok $(sh dmesg | grep -q 'bus DCVS tunables 56/56 applied' && echo 1 || echo 0) tunables "$(sh dmesg | grep -m1 'bus DCVS tunables' | sed 's/^\[[^]]*\]\[[^]]*\] *//' | cut -c1-120)"
else
	# the log ring wrapped (release-style builds: default log_buf_len): compare the nodes with busdcvs.conf instead
	TB=0; TN=0; while read -r pth val; do case "$pth" in ''|\#*) continue;; esac; case "$pth" in */boost_freq) continue;; esac
		TN=$((TN+1)); have=$(sh "cat /sys/$pth" < /dev/null | sed "s/ *$//"); [ "$have" = "$val" ] || { TB=$((TB+1)); echo "$pth: want $val have $have" >> "$L/tunables-diff.txt"; }; done < drivers612/busdcvs/busdcvs.conf
	ok $([ "$TN" -gt 40 ] && [ "$TB" = 0 ] && echo 1 || echo 0) tunables "log wrapped (first line $(sh dmesg | head -1 | cut -c1-14)): $((TN-TB))/$TN nodes of busdcvs.conf read back equal (boost_freq not compared)"
fi
res INFO touch-fw "$(sh dmesg | grep -E 'stm_ts_fw_recheck_work|skip fw update' | tail -2 | sed 's/^\[[^]]*\]\[[^]]*\] *//' | tr '\n' ';' | cut -c1-200)"
res INFO deferred "devices_deferred: $(sh 'cat /sys/kernel/debug/devices_deferred' | wc -l) ($(sh 'cat /sys/kernel/debug/devices_deferred' | awk '{print $1}' | tr '\n' ' ' | cut -c1-150))"

# ---- 16. kernel log: oops, WARN list vs baseline, known messages gone
dm dmesg.txt; A logcat -d > "$L/logcat.txt" 2>/dev/null
OOPS=$(grep -cE 'Unable to handle kernel|Internal error: Oops|Kernel panic|(^|[^A-Z])BUG: |kernel BUG at' "$L/dmesg.txt")
ok $([ "$OOPS" = 0 ] && echo 1 || echo 0) oops "$OOPS oops/BUG/panic lines"
wl() { grep -E 'WARNING: CPU' "$1" | sed -E 's/^\[[^]]*\](\[[^]]*\])? *//; s/CPU: [0-9]+ PID: [0-9]+ //; s/\+0x[0-9a-f]+\/0x[0-9a-f]+//' | sed 's|/home/[^ ]*/\.\./||' | sort | uniq -c; }
wl "$L/dmesg.txt" > "$L/warn-list.txt"; wl "$BASE_DMESG" > "$L/warn-list-base.txt"
NEWW=$(awk 'NR==FNR{$1="";b[$0]=1;next}{$1="";if(!($0 in b))print}' "$L/warn-list-base.txt" "$L/warn-list.txt")
ok $([ -z "$NEWW" ] && echo 1 || echo 0) warn-list "$(wc -l < "$L/warn-list.txt") distinct WARN sites ($(grep -c 'WARNING: CPU' "$L/dmesg.txt") hits; baseline $(wc -l < "$L/warn-list-base.txt") sites, $(grep -c 'WARNING: CPU' "$BASE_DMESG") hits); new:${NEWW:- none}"
QOS=$(grep -cE 'invalid qos table|qos table for client|vbif.*(invalid|remap.*fail)' "$L/dmesg.txt"); QOSB=$(grep -cE 'invalid qos table|qos table for client|vbif.*(invalid|remap.*fail)' "$BASE_DMESG")
ok $([ "$QOS" = 0 ] && echo 1 || echo 0) display-qos "QoS/VBIF complaint lines: $QOS (baseline $QOSB)"
for pat in 'regulator_bulk_free' '__flush_work' 'Invalid rsc clk device' 'SWR bus clsh' 'unresolved parent-node' 'SRAM partition too small' 'cnss_prealloc: not available' 'avc:  denied .* scontext=u:r:kernel'; do
	n=$(grep -c "$pat" "$L/dmesg.txt"); b=$(grep -c "$pat" "$BASE_DMESG"); [ "$n" = 0 ] && [ "$b" = 0 ] || res $([ "$n" -le "$b" ] && echo INFO || echo FAIL) "msg" "'$pat': $n (baseline $b)"
done
grep -E ' (E|F) .*(FATAL EXCEPTION|Fatal signal)' "$L/logcat.txt" | cut -c1-200 > "$L/fatal.txt"
res $([ -s "$L/fatal.txt" ] && echo INFO || echo PASS) userspace-crash "$(wc -l < "$L/fatal.txt") FATAL EXCEPTION / Fatal signal lines in logcat ($(cut -c32-110 "$L/fatal.txt" | sort | uniq -c | sort -rn | head -3 | tr '\n' ';'))"

# ---- 17. optional: framework stop/start (reset the SoC on rb31-33)
if [ "${STOPSTART:-0}" = 1 ]; then
	B0=$(sh 'cat /proc/sys/kernel/random/boot_id')
	( timeout 60 adb -s "$S" shell 'dmesg -w' > "$L/stopstart-dmesg-stream.txt" 2>&1 & )
	sh 'echo "a52verify: stop" > /dev/kmsg; stop'; sleep 12
	ALIVE=$(sh 'cat /proc/sys/kernel/random/boot_id')
	if [ "$ALIVE" = "$B0" ]; then
		sh 'echo "a52verify: start" > /dev/kmsg; start'
		for i in $(seq 45); do sleep 2; [ "$(sh 'cat /proc/sys/kernel/random/boot_id')" = "$B0" ] || break; [ "$(sh 'dumpsys window 2>/dev/null | grep -c mCurrentFocus')" -ge 1 ] && sh 'pidof com.android.systemui' | grep -q . && break; done
		sleep 8
	fi
	B1=$(sh 'cat /proc/sys/kernel/random/boot_id')
	ok $([ "$B1" = "$B0" ] && sh 'pidof system_server' | grep -q . && echo 1 || echo 0) stop-start "boot_id ${B0%%-*} -> ${B1%%-*} (same = no reset), system_server pid $(sh 'pidof system_server'), card: $(sh 'cat /proc/asound/cards' | head -1 | cut -c1-40)"
	sh 'for n in 0 1 2 3 4 5 6 7 8 9 10 11; do cmd media_session volume --stream $n --set 0 >/dev/null 2>&1; done'
	dm dmesg-after-stopstart.txt
fi
echo "summary $LABEL ($MARK): pass=$NP fail=$NF info=$NI  -> $L" | tee -a "$R"
[ "$NF" = 0 ]
