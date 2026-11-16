#!/bin/sh
# /extra/m4wifi.sh in the mainline 7.3 bring-up ramdisk (M4 part 1, Wi-Fi). Boot with the Wi-Fi tree
# (sm7325-samsung-a52sxq-wifi.dtb = base + wifi overlay). Usage: /extra/m4wifi.sh [noscan]
# Firmware ONLY from this phone's own partitions, all mounted read-only, nothing in the ramdisk:
#   WPSS      wpss.mdt + .b00..b07 from the own apnhlos (/fw/image = firmware_class.path): the
#             rollback-5 set phone 2's TZ accepts (the image its 6.12/6.18 boots load daily)
#   board     ath11k/WCN6750/hw1.0/board.bin -> own vendor firmware/qca6750/bdwlan.elf
#             (= .elf1 = .elf2 on this phone; qcacld picks bdwlan.elf without macloader's
#             antenna file, and phone 2 has no efs wifi/.ant.info), regdb.bin -> own vendor
#             firmware/qca6750/regdb.bin. ath11k's api-1 fallback names: no board-2.bin needed,
#             the files are used byte for byte (an ELF BDF: ath11k sends it as BDF type ELF and
#             skips caldata). /lib/firmware/ath11k/... are runtime symlinks into the ro vendor mount.
# Then: remoteproc PAS modules, ath11k_ahb (its probe boots WPSS), wait for the firmware, list the
# interfaces (/extra/nlscan dev = iw dev), bring the station interface up and scan (nlscan scan).
# Nothing is joined (no credentials exist here). Every step logs to kmsg first (ramoops).
log() { echo "a52sxq-m4wifi: $*" > /dev/kmsg; echo "$*"; }
B=/bin/busybox
part() { for u in /sys/class/block/sd*/uevent; do grep -q "^PARTNAME=$1$" $u && grep ^DEVNAME= $u | cut -d= -f2; done; }
# 1. own apnhlos (WPSS)
P=$(part apnhlos); [ -n "$P" ] || { log "no apnhlos partition"; exit 1; }
mkdir -p /fw; grep -q " /fw " /proc/mounts || mount -t vfat -o ro /dev/$P /fw || { log "mount apnhlos $P failed"; exit 1; }
echo -n /fw/image > /sys/module/firmware_class/parameters/path
log "apnhlos $P ro at /fw, firmware path /fw/image"
# 2. own vendor (board data). Extent of vendor in super from the phone's own dm table (as m3gpu.sh)
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
# hashes of the files as read from this phone's own Android (6.18 rb618-12, 2026-11-16)
CHK="c4af1d6f82c10718536bd8fcaeffa4f04575092de9ba5eb076121d85b63983de /fw/image/wpss.mdt
968fdd2ea8471c3ecc9aab51c20d5582f568de9d87bfcd201afd2438e154fbf6 /fw/image/wpss.b00
32e3aaa5abfaa398c8ee697ffbb8dd344c4aa429b4ac2c6b80e2a04fc5a64c1e /fw/image/wpss.b01
4ca7fcb1236ac37bfd04f19872eece90e6446bb902098f13180108d42e0615a5 /fw/image/wpss.b02
d6879a251bd4bdc9796d35659983bef725d4a79554aaadb83504733205e7aac3 /fw/image/wpss.b03
68a538ad8e34a7b810c20dbe003917d273f2a8ef6b51006ec748de41296127e7 /fw/image/wpss.b04
0932b27890dd64846404d6dd188172b7b3badc4ecd904c60c5e07fd8ee49e0ff /fw/image/wpss.b05
0be89709f21ba5fee76fc74b436c43c093a0ca65d1e6edc001fc7baeb283753d /fw/image/wpss.b06
830b03dcbba158205b2e9463b35effc3833466e8902a8a3b4694415bb3fb6aa2 /fw/image/wpss.b07
c9e1a10a5b74c211bc56bebc1ad8e59774ee4a5b5c2916f63e3b697b5ec25460 /vnd/firmware/qca6750/bdwlan.elf
f1c1a016cbf2ce663fc08ea74295182494cd4e158e605ecee7d67cf49fb7301f /vnd/firmware/qca6750/regdb.bin"
rm -f /tmp/fwbad
echo "$CHK" | while read h f; do
	[ "$($B sha256sum $f | cut -c1-64)" = "$h" ] && log "fw ok $f" || { log "fw HASH MISMATCH $f"; touch /tmp/fwbad; }
done
[ -e /tmp/fwbad ] && { log "firmware hash mismatch: STOP"; exit 1; }
D=/lib/firmware/ath11k/WCN6750/hw1.0
mkdir -p $D
ln -sf /vnd/firmware/qca6750/bdwlan.elf $D/board.bin
ln -sf /vnd/firmware/qca6750/regdb.bin $D/regdb.bin
log "board data: $D/board.bin -> bdwlan.elf, regdb.bin (own vendor, ro)"
# 3. remoteproc (PAS) modules: ADSP/CDSP auto-boot from the mounted apnhlos as in m2up dsp; WPSS
#    does not auto-boot (ath11k boots it)
for m in qcom_pil_info qcom_common qcom_q6v5 qcom_q6v5_pas; do
	grep -q "^$m " /proc/modules || insmod /extra/$m.ko || log "insmod $m failed"
done
sleep 2
for r in /sys/class/remoteproc/remoteproc*; do log "$(cat $r/name) $(cat $r/firmware) $(cat $r/state)"; done
# 4. ath11k_ahb: probe -> rproc_boot(WPSS) -> QMI -> BDF/regdb download -> FW ready -> wlan0
log "insmod ath11k_ahb"
insmod /extra/ath11k_ahb.ko || { log "insmod ath11k_ahb failed"; dmesg | tail -n 30; exit 2; }
i=0; while [ $i -lt 30 ] && ! ls /sys/class/ieee80211/ 2>/dev/null | grep -q phy; do sleep 1; i=$((i + 1)); done
for r in /sys/class/remoteproc/remoteproc*; do log "$(cat $r/name) $(cat $r/state)"; done
dmesg | grep -iE "ath11k|wpss|remoteproc|qmi|bdf|board|regdb|wlfw|firmware" | tail -n 50
ls /sys/class/ieee80211/ 2>/dev/null | grep -q phy || { log "no wiphy after ${i}s"; exit 3; }
log "wiphy after ${i}s: $(ls /sys/class/ieee80211/)"
/extra/nlscan dev; log "nlscan dev exit $?"
W=$(ls /sys/class/ieee80211/*/device/net/ 2>/dev/null | head -1)
[ -n "$W" ] || { log "no netdev"; exit 4; }
log "netdev $W mac $(cat /sys/class/net/$W/address)"
[ "$1" = noscan ] && exit 0
# 5. interface up + scan (passive listing only, nothing joined)
ip link set $W up; R=$?; log "ip link set $W up: $R"; sleep 2
ip link show $W
/extra/nlscan scan $W > /tmp/scan.txt; R=$?
log "scan exit $R: $(tail -n 1 /tmp/scan.txt)"
cat /tmp/scan.txt
dmesg | grep -iE "ath11k|wpss" | tail -n 15
log "done ($R)"
exit $R
