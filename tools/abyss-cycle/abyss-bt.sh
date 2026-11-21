#!/system/bin/sh
# Abyss Bluetooth A2DP (abyss-btd + abyssd) hands-free, as root ON the phone:
#   sh abyss-bt.sh <addr> <name> <file-or-dir> [secs=60] [offload=1] [codec=ldac|aac|sbc]
# Writes abyssd's last-headphones file, sets persist.abyss.bt.offload and the root-only test hook
# sys.abyss.debug=bt-file:<path> (abyssd connects the last headphones and plays <path> once the
# Bluetooth output is up), enters Abyss, records abyssd's log + kernel lines for <secs>, leaves and
# restores the properties. Use a zero-amplitude file: abyssd asks the headset for full scale.
ADDR=$1; NAME=$2; FILE=$3; SECS=${4:-60}; OFF=${5:-1}; CODEC=${6:-}
O=/data/local/tmp/abyss-bt; rm -rf $O; mkdir -p $O
android_up() { [ -n "$(pidof system_server)" ] && [ "$(getprop init.svc.bootanim)" = stopped ] && dumpsys window 2>/dev/null | grep -q mCurrentFocus; }
OLD_OFF=$(getprop persist.abyss.bt.offload); OLD_CODEC=$(getprop persist.abyss.bt.codec); OLD_TO=$(getprop persist.abyss.screen_timeout_s)
[ -f /data/misc/abyss/out/bt_last.json ] && cp /data/misc/abyss/out/bt_last.json $O/bt_last.saved
echo "{\"addr\":\"$ADDR\",\"name\":\"$NAME\"}" > /data/misc/abyss/out/bt_last.json
chown root:system /data/misc/abyss/out/bt_last.json; chmod 0660 /data/misc/abyss/out/bt_last.json
setprop persist.abyss.bt.offload $OFF; [ -n "$CODEC" ] && setprop persist.abyss.bt.codec $CODEC; setprop sys.abyss.debug "bt-file:$FILE"
echo "abyss-bt $(date +%T) $(uname -r) addr $ADDR offload=$OFF codec=${CODEC:-default} file $FILE"
logcat -b all -c; dmesg -c > /dev/null
setprop sys.abyss.request enter
i=0; while [ "$(getprop sys.abyss.state)" != active ] && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
echo "state $(getprop sys.abyss.state) after $((i/2)) s, abyssd $(pidof abyssd)"
t=0; while [ $t -lt $SECS ]; do sleep 5; t=$((t+5)); echo "+${t}s abyss-btd=$(pidof abyss-btd) bt=$(getprop sys.abyss.bt) $(logcat -d -s abyssd 2>/dev/null | grep -cE 'bluetooth|offload|a2dp') abyssd bt lines"; done
logcat -d -b all > $O/logcat.txt; dmesg > $O/dmesg.txt
setprop sys.abyss.debug ""
setprop sys.abyss.request leave
i=0; while ! android_up && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
echo "leave: android up after ${i}s, state $(getprop sys.abyss.state)"
setprop persist.abyss.bt.offload "$OLD_OFF"; setprop persist.abyss.bt.codec "$OLD_CODEC"; setprop persist.abyss.screen_timeout_s "$OLD_TO"
if [ -f $O/bt_last.saved ]; then cp $O/bt_last.saved /data/misc/abyss/out/bt_last.json; fi
echo "restored persist.abyss.bt.offload='$(getprop persist.abyss.bt.offload)'"
echo "=== abyssd bluetooth / dsp lines"; grep -E " abyssd *:" $O/logcat.txt | grep -iE "bluetooth|bt:|offload|a2dp|dsp|debug|output|error|warn|fail" | cut -c1-220 | head -60
echo "=== abyss-btd lines"; grep -iE "abyss-btd|abyss_bt" $O/logcat.txt | grep -iE "a2dp|offload|codec|format|started|error|fail" | cut -c1-220 | head -30
echo "=== kernel"; grep -iE "btfm|slim|afe|enc_cfg|q6|adsp|error" $O/dmesg.txt | grep -v avc | cut -c1-180 | head -40
