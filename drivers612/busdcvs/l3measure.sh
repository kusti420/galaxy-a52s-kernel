#!/bin/bash
# Measure the real L3 clock (debugcc ring oscillator) vs memlat's software vote on a phone running
# a 6.12 test Android (kexec) or real boot. Usage: PHONE=1|2 [AB=1] drivers612/busdcvs/l3measure.sh <tag>
# Loads bsp612 debugcc-sc7280.ko once (measure-only clocks), screen off, idles 60 s, then samples
# 10x 3 s apart. Output: logs/l3measure-<tag>.txt
# Values are read with the shell's builtin `read` right after each sleep (no fork before the
# hardware read: a forked cat is itself a CPU burst that memlat can sample = observer bias).
# The memlat module parameters of soc-repo patch 0010 (idle_decay_ms, idle_min_vote) are printed
# if present. AB=1: after the 10 samples set both to 0 (= Qualcomm behaviour), idle 30 s, take
# 10 more samples, then restore the previous values (same boot, A/B of patch 0010).
set -u
cd "$(dirname "$0")/../.."
case "${PHONE:-2}" in 1) S=PHONE1;; 2) S=PHONE2;; *) exit 1;; esac
O=logs/l3measure-$1.txt
KO=$(ls bsp612/out/dist/lib/modules/*/drivers/clk/qcom/debugcc-sc7280.ko)
adb -s $S root >/dev/null 2>&1; sleep 2
adb -s $S push "$KO" /data/local/tmp/debugcc-sc7280.ko >/dev/null
adb -s $S shell 'grep -q debugcc /proc/modules || insmod /data/local/tmp/debugcc-sc7280.ko; mount | grep -q " /sys/kernel/debug " || mount -t debugfs debugfs /sys/kernel/debug' 2>&1
adb -s $S shell 'input keyevent KEYCODE_SLEEP' >/dev/null 2>&1
sleep 60
adb -s $S shell "AB=${AB:-0}"'
M=/sys/kernel/debug/clk/measure_only_apcs_l3_post_acd_clk/clk_measure
[ -e $M ] || M=$(ls /sys/kernel/debug/clk/*l3*/clk_measure 2>/dev/null | head -1)
B=/sys/devices/system/cpu/bus_dcvs; P=/sys/module/memlat/parameters
params() { if [ -e $P/idle_decay_ms ]; then read d < $P/idle_decay_ms; read v < $P/idle_min_vote; echo "memlat idle_decay_ms=$d idle_min_vote=$v"; else echo "memlat: no idle parameters (pre-0010 module)"; fi; }
samples() {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    read hw < $M; read l3 < $B/L3/cur_freq; read ddr < $B/DDR/cur_freq; read llcc < $B/LLCC/cur_freq
    echo "hw_l3=$hw sw_l3=$l3 ddr=$ddr llcc=$llcc"
  done
}
echo "uname $(uname -r) meas=$M"; params
samples
if [ "$AB" = 1 ] && [ -e $P/idle_decay_ms ]; then
  read d0 < $P/idle_decay_ms; read v0 < $P/idle_min_vote
  echo 0 > $P/idle_decay_ms; echo 0 > $P/idle_min_vote; echo "--- B: patch 0010 off"; params
  sleep 30; samples
  echo $d0 > $P/idle_decay_ms; echo $v0 > $P/idle_min_vote; echo "--- restored"; params
fi' | tee "$O"
