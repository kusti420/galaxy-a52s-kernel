#!/system/bin/sh
# Touch IC state in AOD (root, screen must be Dozing): touch-aod.sh [getevent_secs=10]
# Read-only: wakefulness, the last stm_ts low-power-mode lines, sec tsp sysfs gesture/fod nodes,
# input device inhibit state, and a getevent capture (nobody touches: shows spontaneous events only).
G=${1:-10}
echo "kernel $(uname -r) $(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1)"
echo "== stm_ts lowpower lines (last 6)"; dmesg | grep -E "stm_ts_set_lowpowermode|lp changed|Normal changed|opmode|mode:0000" | tail -6 | cut -c1-200
D=/sys/class/sec/tsp; [ -d $D ] || D=$(ls -d /sys/class/sec/tsp* 2>/dev/null | head -1)
echo "== $D nodes"; for f in enabled fod_pos fod_info aod_active_area virtual_prox prox_power_off support_feature input/enabled; do [ -r $D/$f ] && echo "  $f: $(cat $D/$f 2>/dev/null | head -c 120 | tr '\n' ' ')"; done
for c in get_lp_dump; do :; done
echo "== cmd results"; for c in "aod_enable" "spay_enable" "singletap_enable" "fod_enable" "fod_lp_mode" "set_aod_rect"; do :; done
[ -r $D/cmd_list ] && echo "  cmd_list has: $(cat $D/cmd_list | grep -E 'aod|fod|singletap|spay|double|lp|press' | tr '\n' ' ')"
for e in /sys/class/input/input*; do n=$(cat $e/name); case "$n" in sec_touchscreen|sec_touchpad) echo "  $n: inhibited=$(cat $e/inhibited 2>/dev/null) $(ls -d $e/event* | xargs -n1 basename)";; esac; done
echo "== getevent $G s (sec_touchscreen)"; EV=$(getevent -pl 2>/dev/null | grep -B1 '"sec_touchscreen"' | head -1 | awk '{print $4}')
timeout $G getevent -lt $EV 2>/dev/null | head -40; echo "  (end)"
