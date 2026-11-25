#!/system/bin/sh
# On the phone, as root: cgroup-v1 freezer vs pm_test=freezer cycle (no real suspend). Usage: run-on-phone.sh [cycles]
T=/data/local/tmp; G=/dev/freezer/a52frz; N=${1:-1}
mkdir -p $G; echo THAWED > $G/freezer.state
$T/frztest $T/frz.cnt > $T/frz.out & sleep 1; P=$(sed -n 's/^pid \([0-9]*\).*/\1/p' $T/frz.out); cat $T/frz.out
snap() { echo "--- $1: freezer.state=$(cat $G/freezer.state) self_freezing=$(cat $G/freezer.self_freezing) counters(futex epoll busy)=$(od -A n -t u8 -N 24 $T/frz.cnt | tr -s ' ')"
	for t in /proc/$P/task/*; do echo "    tid ${t##*/} $(awk '{print $2, "state", $3}' $t/stat) $(grep -E '^State' $t/status | tr -s '\t ' ' ')"; done; }
snap running; sleep 3; snap running+3s
for t in /proc/$P/task/*; do echo ${t##*/} > $G/tasks; done
echo FROZEN > $G/freezer.state; sleep 1; snap frozen; sleep 4; snap frozen+4s
i=0; while [ $i -lt $N ]; do i=$((i+1))
	echo freezer > /sys/power/pm_test; echo mem > /sys/power/state; echo "pm_test cycle $i: rc=$?"; echo none > /sys/power/pm_test
	snap after-cycle-$i; sleep 4; snap after-cycle-$i+4s
done
dmesg | grep -E "PM: suspend|Freezing|Restarting tasks|freecess|a52frz|WARNING|__thaw_task" | tail -12
echo THAWED > $G/freezer.state; sleep 2; snap thawed+2s
kill -9 $P; sleep 1; rmdir $G; echo "END pm_test=$(cat /sys/power/pm_test)"
