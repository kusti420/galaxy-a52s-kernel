#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Read-only check of ReSukiSU LKM root on a OneUI 9 (K4_UN1CA) phone booted with a KSU=1 KSU_DIR=modules/resukisu/out
# build:  drivers612/realboot/modules/resukisu/verify-oneui9.sh <serial> [logdir]
# Checks: module loaded by ksuinit (35203, LKM), no WARN/BUG/Oops, manager package + version, ksud present,
# su from adb shell (needs Superuser for Shell in the manager), the ROM's u:r:ksu:s0 boot jobs (init.rc exec
# 'gpudrv guard', metamod_apply, pif_cleanup, susfs_defaults) ran in that domain and exited 0, no transition denials.
# Nothing is written to the phone except a mute (media volume 0).
set -u
S=${1:?serial}; L=${2:-logs/resukisu-$(date +%m%d-%H%M)}; mkdir -p "$L"
A() { adb -s "$S" shell "$@"; }
R() { adb -s "$S" shell /system/bin/su -c "$*"; }
ok=0; bad=0; p() { echo "PASS $*"; ok=$((ok+1)); }; f() { echo "FAIL $*"; bad=$((bad+1)); }
A cmd media_session volume --set 0 --stream 3 > /dev/null 2>&1
echo "kernel $(A uname -r)  build $(A getprop ro.build.display.id)  uptime $(A cut -d' ' -f1 /proc/uptime)"
ID=$(R id 2>&1); echo "su -c id: $ID"
case "$ID" in *"uid=0(root)"*"context=u:r:ksu:s0"*) p "su from adb shell = uid 0 in u:r:ksu:s0";; *) f "su from adb shell (grant Shell in the manager?)";; esac
R dmesg > "$L/dmesg.txt" 2> /dev/null || A dmesg > "$L/dmesg.txt" 2> /dev/null
R logcat -b all -d > "$L/logcat.txt" 2> /dev/null
grep -q 'KernelSU: Initialized with driver version: 35203.*Work mode: LKM' "$L/dmesg.txt" && p "kernelsu.ko 35203 LKM loaded by ksuinit" || f "no 'Initialized with driver version: 35203 ... LKM' in dmesg"
grep -q 'a52: previous boot left a panic record' "$L/dmesg.txt" && echo "NOTE crash guard skipped KSU this boot (panic record of the previous boot)"
n=$(grep -c -E 'WARNING:|BUG:|Oops|Call trace' "$L/dmesg.txt"); [ "$n" = 0 ] && p "0 WARN/BUG/Oops lines" || { f "$n WARN/BUG/Oops lines"; grep -E 'WARNING:|BUG:|Oops' -A4 "$L/dmesg.txt" | head -30; }
grep -E 'KernelSU|ksuinit' "$L/dmesg.txt" | grep -v -E 'pgd of|p4d of|pud of|pmd of|phy addr|fixmap addr|patch dst|patch result' > "$L/ksu-dmesg.txt"
V=$(A dumpsys package com.resukisu.resukisu | grep -m1 versionCode | tr -s ' '); echo "manager:$V"
[ -n "$V" ] && p "manager com.resukisu.resukisu installed" || f "manager not installed"
R "ls -la /data/adb/ksud /data/adb/ksu/bin 2>&1" | tee "$L/ksud.txt"
R "test -x /data/adb/ksud" && p "/data/adb/ksud present" || f "/data/adb/ksud missing (open the manager once)"
R "/data/adb/ksud -V; /data/adb/ksud debug version 2>&1; /data/adb/ksud module list 2>&1 | head -c 600" > "$L/ksud-info.txt" 2>&1; cat "$L/ksud-info.txt"
for k in sys.metamod_gate sys.metamod sys.metamod_import sys.pif_cleanup init.svc.metamod_apply init.svc.pif_cleanup init.svc.susfs_defaults; do echo "$k=$(A getprop $k)"; done | tee "$L/props.txt"
grep -q '^sys.metamod_gate=ksu$' "$L/props.txt" && p "metamod gate saw KernelSU (stat of /data/adb/ksud in the ksu policy)" || f "sys.metamod_gate is not ksu"
for s in metamod_apply pif_cleanup susfs_defaults; do
	l=$(grep -E "Service '$s' \(pid [0-9]+\) exited with status" "$L/dmesg.txt" "$L/logcat.txt" | tail -n 1)
	case "$l" in *"status 0"*) p "$s (seclabel u:r:ksu:s0) ran and exited 0";; "") f "$s: no exit line";; *) f "$s: $l";; esac
done
grep -E "exec u:r:ksu:s0|gpudrv: guard|Command 'exec" "$L/dmesg.txt" "$L/logcat.txt" | grep -i gpudrv | tail -n 3
grep -q -E "gpudrv guard.*(succeeded|returned 0)|exited with status 0.*gpudrv" "$L/dmesg.txt" "$L/logcat.txt" && p "init.rc exec u:r:ksu:s0 gpudrv guard succeeded" || echo "INFO gpudrv guard: no success line (it logs only when /data/adb/modules has entries): see $L"
d=$(grep -c -E 'avc:  denied .*(transition|dyntransition).*tcontext=u:r:ksu:s0' "$L/dmesg.txt" "$L/logcat.txt" | awk -F: '{s+=$NF} END{print s+0}')
[ "$d" = 0 ] && p "0 denied transitions into u:r:ksu:s0" || f "$d denied transitions into u:r:ksu:s0"
R "cat /proc/self/attr/current; echo; getenforce"
echo "== $ok PASS / $bad FAIL  (logs $L)"
