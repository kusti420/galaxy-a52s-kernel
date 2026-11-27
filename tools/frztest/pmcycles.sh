#!/system/bin/sh
# On the phone, as root: N frztest processes frozen in a v1 freezer cgroup, then back-to-back pm_test=freezer cycles
# with PM debug messages; counts freeze failures. Usage: pmcycles.sh <refreeze 0|1> [procs=30] [mem_cycles=30] [s2idle_cycles=10]
RF=$1; NP=${2:-30}; NM=${3:-30}; NS=${4:-10}; T=/data/local/tmp; G=/dev/freezer/a52frz; M=/sys/module/freecess/parameters
[ -d $M ] || insmod $T/freecess.ko || { echo "no freecess"; exit 1; }
echo $RF > $M/refreeze; echo 1 > /sys/power/pm_debug_messages; OLDLL=$(cut -f1 /proc/sys/kernel/printk); dmesg -n 8
st() { echo "$1: success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail) failed_freeze=$(cat /sys/power/suspend_stats/failed_freeze) last_step=$(cat /sys/power/suspend_stats/last_failed_step) errno=$(cat /sys/power/suspend_stats/last_failed_errno) | refreeze=$(cat $M/refreeze) runs=$(cat $M/stat_refreeze_runs) escaped=$(cat $M/stat_refreeze_escaped) queued=$(cat $M/stat_refreeze_queued)"; }
mkdir -p $G; echo THAWED > $G/freezer.state; PIDS=""
i=0; while [ $i -lt $NP ]; do $T/frztest $T/frz.cnt.$i > /dev/null & PIDS="$PIDS $!"; i=$((i+1)); done; sleep 2
for p in $PIDS; do for t in /proc/$p/task/*; do echo ${t##*/} > $G/tasks 2>/dev/null; done; done
echo FROZEN > $G/freezer.state; sleep 2
cnt() { n=0; d=0; for p in $PIDS; do for t in /proc/$p/task/*; do n=$((n+1)); case "$(awk '{print $3}' $t/stat 2>/dev/null)" in D) d=$((d+1));; esac; done; done; echo "threads $n, state D $d, freezer.state $(cat $G/freezer.state)"; }
echo "== refreeze=$RF procs=$NP: $(cnt)"; st before; MARK="a52pm-mark-$$-$RF"; echo "$MARK start" > /dev/kmsg
run() { mode=$1; n=$2; ok=0; bad=0; slow=0; i=0; echo freezer > /sys/power/pm_test
	while [ $i -lt $n ]; do i=$((i+1)); t0=$(date +%s%N); echo $mode > /sys/power/state 2>/dev/null; rc=$?; t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
		[ $rc = 0 ] && ok=$((ok+1)) || bad=$((bad+1)); [ $ms -gt 8000 ] && slow=$((slow+1)); [ $rc = 0 ] && [ $ms -le 8000 ] || echo "  $mode cycle $i: rc=$rc ${ms} ms"; done
	echo none > /sys/power/pm_test; echo "$mode x$n: ok=$ok failed=$bad slower-than-8s=$slow (each cycle = freeze + 5 s pm_test wait + thaw)"; }
run mem $NM; echo "after mem cycles: $(cnt)"; run freeze $NS; echo "after s2idle cycles: $(cnt)"; sleep 3; echo "3 s later: $(cnt)"; st after
echo "$MARK end" > /dev/kmsg
dmesg | sed -n "/$MARK start/,/$MARK end/p" > $T/pmcycles-dmesg-$RF.txt
echo "dmesg in window: $(wc -l < $T/pmcycles-dmesg-$RF.txt) lines; 'refusing to freeze' $(grep -c 'refusing to freeze' $T/pmcycles-dmesg-$RF.txt); 'Freezing .* failed' $(grep -cE 'Freezing .*(failed|aborted)' $T/pmcycles-dmesg-$RF.txt); 'Freezing user space processes completed' $(grep -c 'Freezing user space processes completed' $T/pmcycles-dmesg-$RF.txt); wakeup lines $(grep -ciE 'wakeup pending|Wakeup pending|active wakeup' $T/pmcycles-dmesg-$RF.txt)"
grep -E 'refusing to freeze|Freezing .*(failed|aborted)|tasks refusing|wakeup' $T/pmcycles-dmesg-$RF.txt | head -12
grep -oE 'Freezing user space processes completed \(elapsed [0-9.]+ seconds\)' $T/pmcycles-dmesg-$RF.txt | awk '{gsub(/[()]/,""); t=$7; if(t>m)m=t; s+=t; n++} END{if(n)printf "freeze time user space: avg %.3f s max %.3f s over %d\n", s/n, m, n}'
echo THAWED > $G/freezer.state; sleep 1; for p in $PIDS; do kill -9 $p; done; sleep 1; rmdir $G; rm -f $T/frz.cnt.*; echo 0 > /sys/power/pm_debug_messages; dmesg -n $OLDLL; echo "END pm_test=$(cat /sys/power/pm_test)"
