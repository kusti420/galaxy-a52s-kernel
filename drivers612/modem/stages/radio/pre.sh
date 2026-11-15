# Stage "radio@adsp" pre-script. The test helper (helper2.sh) runs it in the background job of
# an @adsp stage: ~2 s after the ADSP runs, i.e. after Android's first stage mounted /vendor and
# well before "class core" starts rmt_storage, tftp_server, pm-service (which boots the modem).
# Runs as root in the helper's own mount namespace (busybox in PATH). Two jobs:
#
# 1. firmware: modem.mdt is in /vendor/firmware-modem/image, outside firmware_class.path
#    (/vendor/firmware_mnt/image). GKI 6.12 only asks ueventd (firmware_directories lists both)
#    when force_sysfs_fallback is set. (stage-wlan's pre.sh sets it too; idempotent.)
#
# 2. EFS in RAM. testguard holds modemst1, modemst2, fsg and fsc read-only at the block layer,
#    so rmt_storage's read-write open fails and the modem cannot load or sync its EFS (NV items,
#    IMEI, calibration). Those partitions must NEVER be written by a test kernel. So: copy each
#    into RAM (Android's /dev tmpfs), attach a loop device to the copy and bind that loop node
#    over the real /dev/block/sdXN in Android's mount namespace. rmt_storage then reads the
#    real contents and writes go to RAM; they are gone at the next reboot. The real partitions
#    stay read-only (testguard) whatever happens here: a failure only means no EFS for the modem.
log() { echo "a52sxq-init: radio: $*" > /dev/kmsg; echo "radio: $*"; }
F=/proc/sys/kernel/firmware_config/force_sysfs_fallback
[ -e $F ] && echo 1 > $F; log "force_sysfs_fallback=$(cat $F 2>/dev/null)"

BB=/proc/$$/root/bin/busybox            # our static busybox, reachable from any namespace
[ -x "$BB" ] || { log "EFS shim: no busybox at $BB"; exit 1; }

# 0. rollback guard (2026-11-13 incident class): the modem image must not carry a higher
#    anti-rollback version than the phone's ADSP image (which is known to load), or booting it
#    could raise TZ's shared counter. If it does, point the modem at a firmware name that does
#    not exist, so pm-service's boot request fails harmlessly (-ENOENT) instead.
R=/proc/1/root/vendor
RM=$($BB od -An -tu1 -j164 -N1 $R/firmware-modem/image/modem.b01 2>/dev/null | tr -d ' ')
RA=$($BB od -An -tu1 -j164 -N1 $R/firmware_mnt/image/adsp.b01 2>/dev/null | tr -d ' ')
log "anti-rollback: modem=${RM:-?} adsp=${RA:-?}"
if [ -z "$RM" ] || [ -z "$RA" ] || [ "$RM" -gt "$RA" ]; then
	echo a52-modem-refused > /sys/bus/msm_subsys/devices/subsys3/firmware_name 2>/dev/null
	log "modem image NOT safe to boot (rollback modem=${RM:-?} > adsp=${RA:-?} or unreadable): firmware name set to a52-modem-refused"
elif [ "$RM" -lt "$RA" ]; then
	log "modem image rollback $RM < $RA: TZ will refuse it (expected on phone 2): harmless -22 at boot"
fi
cat > /tmp/efs-shim.sh <<'EOS'
# runs inside PID 1's mount namespace (Android's /dev), applets through $BB
P="modemst1 modemst2 fsg fsc"; D=/dev/.a52efs; i=0; ok=0
log() { echo "a52sxq-init: radio: $*" > /dev/kmsg; echo "radio: $*"; }
$BB mkdir -p $D
for p in $P; do
	L=/dev/block/bootdevice/by-name/$p
	T=$($BB readlink -f $L)
	if [ ! -b "$T" ]; then log "EFS shim: $p: no block device behind $L"; i=$((i + 1)); continue; fi
	sec=$($BB cat /sys/class/block/${T##*/}/size)
	if [ "$sec" -gt 131072 ]; then log "EFS shim: $p is $sec sectors (> 64 MiB): refused"; i=$((i + 1)); continue; fi
	$BB dd if=$T of=$D/$p.img bs=65536 2>/dev/null
	idx=$((240 + i)); minor=$((idx * 8))      # loop.max_part=7 -> 8 minors per loop device
	$BB mknod $D/loop$idx b 7 $minor 2>/dev/null
	if ! $BB losetup $D/loop$idx $D/$p.img; then log "EFS shim: $p: losetup failed"; i=$((i + 1)); continue; fi
	if ! $BB mount -o bind $D/loop$idx $T; then log "EFS shim: $p: bind over $T failed"; $BB losetup -d $D/loop$idx; i=$((i + 1)); continue; fi
	log "EFS shim: $p ($T, $sec sectors) -> RAM copy on loop$idx: $($BB stat -L -c '%t:%T' $L)"
	ok=$((ok + 1)); i=$((i + 1))
done
log "EFS shim: $ok of 4 partitions in RAM"
EOS
BB=$BB nsenter -t 1 -m -- $BB sh -c "BB=$BB; . /proc/$$/root/tmp/efs-shim.sh"
# Android's later daemons live in the "default" namespace (apexd). /dev is a shared mount, so
# the binds above propagate; check from logd's namespace and say so if they did not.
L=$(/bin/busybox pidof logd | cut -d' ' -f1)
if [ -n "$L" ]; then
	for p in modemst1 modemst2 fsg fsc; do
		t=$(nsenter -t $L -m -- $BB stat -L -c '%t' /dev/block/bootdevice/by-name/$p 2>/dev/null)
		[ "$t" = 7 ] && log "default namespace: $p is the RAM copy" || log "default namespace: $p is NOT the RAM copy (major $t)"
	done
fi
