#!/bin/busybox sh
# everything that works, in one go (needs hw-audio-full-r02.dtb): GPU, video (+venus boot), ADSP+CDSP, audio, secure
cd "${0%/*}"
for s in "s2.sh" "s5.sh NONE open" "s3.sh" "s4.sh" "s1.sh"; do echo "===== $s"; sh ./$s > /tmp/${s%% *}.out 2>&1; grep -v '^## insmod' /tmp/${s%% *}.out | grep -v '^\[' | head -${1:-70}; done
echo "===== summary"; cat /proc/asound/cards; cat /sys/class/kgsl/kgsl-3d0/gpu_model; ls /dev/video32 /dev/video33 /dev/ion /dev/qseecom /dev/smcinvoke /dev/qce /dev/kgsl-3d0 2>&1 | tr '\n' ' '
for r in /sys/class/remoteproc/remoteproc*; do echo "$(cat $r/name)=$(cat $r/state)"; done; cat /sys/kernel/debug/devices_deferred
