#!/bin/sh
# /extra/m3gpu.sh in the mainline 7.3 bring-up ramdisk (M3 part 3, GPU). Boot with the GPU tree
# (sm7325-samsung-a52sxq-gpu.dtb = base + panel + gpu overlays). Usage: /extra/m3gpu.sh [submits]
# Firmware ONLY from this phone's own partitions, all mounted read-only, nothing in the ramdisk:
#   zap      a660_zap.mdt/.b0x from the own apnhlos (/fw/image = firmware_class.path, as m2up dsp)
#   SQE/GMU  a660_sqe.fw / a660_gmu.bin from the own vendor (an extent of super, mounted through a
#            read-only loop device at /vnd; /lib/firmware/<name> is a runtime symlink into it)
# Then loads the panel module (the msm DRM device binds with the GPU as a component; its fbdev
# client's open loads the firmware, boots the GMU, loads the zap shader), prints the GPU state and
# runs /extra/gputest (CP_MEM_WRITE submits). Every step logs to kmsg first (ramoops).
log() { echo "a52sxq-m3gpu: $*" > /dev/kmsg; echo "$*"; }
N=${1:-3}
B=/bin/busybox
part() { for u in /sys/class/block/sd*/uevent; do grep -q "^PARTNAME=$1$" $u && grep ^DEVNAME= $u | cut -d= -f2; done; }
# 1. own apnhlos (zap)
P=$(part apnhlos); [ -n "$P" ] || { log "no apnhlos partition"; exit 1; }
mkdir -p /fw; grep -q " /fw " /proc/mounts || mount -t vfat -o ro /dev/$P /fw || { log "mount apnhlos $P failed"; exit 1; }
echo -n /fw/image > /sys/module/firmware_class/parameters/path
log "apnhlos $P ro at /fw, firmware path /fw/image"
# 2. own vendor (SQE/GMU). Extent of vendor in super from the phone's own dm table (6.18 / LineageOS
#    `dmctl table vendor`: 0-2233600 linear super 9183232); checked by the ext4 magic before mounting.
S=$(part super); [ -n "$S" ] || { log "no super partition"; exit 1; }
VSEC=${VSEC:-9183232}; OFS=$((VSEC * 512))
MAG=$($B dd if=/dev/$S bs=1 skip=$((OFS + 1080)) count=2 2>/dev/null | $B od -An -tx1 | tr -d ' ')
[ "$MAG" = 53ef ] || { log "no ext4 magic at super sector $VSEC ($MAG): vendor not mounted"; exit 1; }
mkdir -p /vnd
if ! grep -q " /vnd " /proc/mounts; then
	L=$($B losetup -f); $B losetup -r -o $OFS $L /dev/$S || { log "losetup failed"; exit 1; }
	mount -t ext4 -o ro,noload $L /vnd || { log "mount vendor ($L) failed"; $B losetup -d $L; exit 1; }
fi
log "vendor (super $S + $VSEC sectors) ro at /vnd"
mkdir -p /lib/firmware
for f in a660_sqe.fw a660_gmu.bin; do
	[ -f /vnd/firmware/$f ] || { log "/vnd/firmware/$f missing: STOP"; exit 1; }
	ln -sf /vnd/firmware/$f /lib/firmware/$f
done
# hashes of the files as read from this phone's own Android (2026-11-16)
CHK="f911a4badf7b56719cb130492bc39f9edb85335f54e8b4983b5c67eb9e6204bb /vnd/firmware/a660_sqe.fw
6bb9360a1601253a86ee3ae1b9b916f5f1832a72d55e9b8573567f1740c94e2b /vnd/firmware/a660_gmu.bin
d6c551422a06904bd0cf7339c311606b517b4ce625874b5eef71962f4a39a6ec /fw/image/a660_zap.mdt
e18210e36c1d1f25becbec8f92ede88dbcc5ca3c952e39337bc1b0adf4a093d6 /fw/image/a660_zap.b00
c04ef7766153815e36d91a7656b66d55055d0ac15022e1b11b51be698cd796f4 /fw/image/a660_zap.b01
1a5fdbf458ea547c5459b301ab577a83461797b77bde9501fb48fc62d2d5f185 /fw/image/a660_zap.b02"
echo "$CHK" | while read h f; do
	[ "$($B sha256sum $f | cut -c1-64)" = "$h" ] && log "fw ok $f" || { log "fw HASH MISMATCH $f"; touch /tmp/fwbad; }
done
[ -e /tmp/fwbad ] && { log "firmware hash mismatch: STOP"; exit 1; }
# 3. speed bin: drm/msm reports it in MSM_PARAM_CHIP_ID bits 32..39 (gputest prints it); the
#    nvmem read of qfprom 0x1e9 is not used (the cell is not exported to sysfs here)
# 4. panel module -> msm DRM bind (GPU component)
grep -q "^panel_samsung_s6e3fc3 " /proc/modules || { log "insmod panel"; insmod /extra/panel-samsung-s6e3fc3.ko; }
sleep 4
dmesg | grep -iE "adreno|a6xx|gmu|zap|msm_gpu|gpu@3d00000|3d6a000|firmware|\[drm\]" | tail -n 40
ls -l /dev/dri/ 2>&1
grep -q " /sys/kernel/debug " /proc/mounts || mount -t debugfs none /sys/kernel/debug
for d in /sys/class/devfreq/*gpu*; do [ -d $d ] && log "devfreq $d: $(cat $d/governor) cur $(cat $d/cur_freq) avail $(cat $d/available_frequencies)"; done
# 5. submit test
log "gputest $N"
/extra/gputest /dev/dri/renderD128 $N; R=$?
log "gputest exit $R"
# 6. hang + recovery: one IB that never finishes, hangcheck must recover, then submits work again
if [ $R = 0 ] && [ -z "$NOHANG" ]; then
	log "gputest hang"; /extra/gputest /dev/dri/renderD128 0 hang > /tmp/gh.txt; H=$?; tail -n 3 /tmp/gh.txt
	/extra/gputest /dev/dri/renderD128 2 > /tmp/g2.txt; R2=$?; tail -n 2 /tmp/g2.txt
	log "hang test exit $H, submits after recovery exit $R2"; [ $R2 = 0 ] || R=7
fi
for d in /sys/class/devfreq/*gpu*; do [ -d $d ] && log "devfreq after: cur $(cat $d/cur_freq) trans $(cat $d/trans_stat 2>/dev/null | tail -n 1)"; done
G=$(ls -d /sys/kernel/debug/dri/*/gpu 2>/dev/null | head -1)
[ -n "$G" ] && { log "debugfs $G"; head -n 30 $G; }
dmesg | grep -iE "adreno|a6xx|gmu|zap|hang|fault|recover" | tail -n 20
log "done ($R)"
exit $R
