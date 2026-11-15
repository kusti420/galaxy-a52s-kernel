#!/bin/busybox sh
# stage 2: GPU (gpucc + kgsl). Needs the dtb with the gpu fragment (hw-full-r02.dtb)
cd "${0%/*}"; . ./common.sh; . ./fw.sh; chmod 755 kgsltest*
mount -t debugfs none /sys/kernel/debug 2>/dev/null
fwmount; fwlink 'a660_zap.*'; ls -la /lib/firmware/ | grep a660; ls /fw/apnhlos/image | wc -l
k "deferred before"; cat /sys/kernel/debug/devices_deferred
ld s2a "$1"; sleep 2; k "deferred after gpucc"; cat /sys/kernel/debug/devices_deferred
ld s2g "$1"; ld s2b "$1"; sleep 3; sh /p/mkdevs; k "deferred after kgsl"; cat /sys/kernel/debug/devices_deferred
ls -l /dev/kgsl-3d0 2>&1; cat /sys/class/kgsl/kgsl-3d0/gpu_model /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies 2>&1; ls /sys/kernel/gpu 2>&1 | tr '\n' ' '; echo
k "kgsltest64"; ./kgsltest64 2>&1 | tail -40
k "kgsltest32"; ./kgsltest32 2>&1 | tail -25
k "governor: $(cat /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>&1) $(cat /sys/kernel/gpu/gpu_governor 2>&1)"
k "s2 done"; dmesg | grep -iE "kgsl|adreno|gmu|zap|a6xx|gpucc|gpu_cc|devfreq" | grep -v "hw: insmod" | tail -40
