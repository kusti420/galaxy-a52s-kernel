#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# On-phone check of the Samsung UFS sysfs nodes (5.4 kernel or 6.12 + ufs_sec_sysfs.ko).
#   adb -s <serial> push check.sh /data/local/tmp/ufs_sec_check.sh
#   adb -s <serial> shell /system/bin/su -c 'sh /data/local/tmp/ufs_sec_check.sh'        # UN as sha256 only
#   adb -s <serial> shell /system/bin/su -c 'sh /data/local/tmp/ufs_sec_check.sh full'   # also the raw UN
# Run it on the same phone under 5.4 and under 6.12: every line except LT/lc/telemetry must match.
# The UN is a device identifier: by default only its length, the non-unique first 6 digits
# (manufacturer id + manufacture date) and its sha256 are printed.
FULL=$1
S=/sys/class/sec/ufs
H=/sys/class/scsi_host/host0

echo "== kernel: $(uname -r)"
echo "== module: $(grep -c '^ufs_sec_sysfs ' /proc/modules) loaded (0 on 5.4: built in)"
[ -r /sys/module/ufs_sec_sysfs/parameters/legacy_shost_un ] && \
	echo "== legacy_shost_un=$(cat /sys/module/ufs_sec_sysfs/parameters/legacy_shost_un)"
echo "== realpath $S -> $(readlink -f $S)"
echo "== realpath $H -> $(readlink -f $H)"

echo "== ls -lZ $S"
ls -lZ $S/ 2>&1 | grep -v -e ' power$' -e ' subsystem ->'
echo "== ls -lZ $H (SEC/legacy nodes)"
for n in unique_number SEC_UFS_op_cnt SEC_UFS_uic_cmd_cnt SEC_UFS_uic_err_cnt SEC_UFS_fatal_cnt \
	 SEC_UFS_utp_cnt SEC_UFS_query_cnt SEC_UFS_err_sum sense_err_count sense_err_logging proc_name; do
	if [ -e $H/$n ]; then ls -lZ $H/$n; else echo "absent: $H/$n"; fi
done

un=$(cat $S/un 2>&1)
echo "== un: len=${#un} prefix=$(echo "$un" | cut -c1-6) sha256=$(printf '%s\n' "$un" | sha256sum | cut -d' ' -f1)"
echo "== un bytes incl. newline: $(cat $S/un | wc -c) (5.4: 21)"
[ "$FULL" = full ] && echo "== un raw: $un"
if [ -e $H/unique_number ]; then
	hu=$(cat $H/unique_number 2>&1)
	[ "$hu" = "$un" ] && echo "== host0/unique_number == un" || echo "== host0/unique_number DIFFERS from un"
fi
for n in lt lc man_id transferred_cnt sec_wb_enable; do
	echo "== $n: $(cat $S/$n 2>&1)"
done
for n in SEC_UFS_op_cnt SEC_UFS_uic_cmd_cnt SEC_UFS_uic_err_cnt SEC_UFS_fatal_cnt SEC_UFS_utp_cnt \
	 SEC_UFS_query_cnt SEC_UFS_err_sum sense_err_count sense_err_logging; do
	echo "== $n: $(cat $H/$n 2>&1)"
done
echo "== dmesg"
dmesg 2>/dev/null | grep -i -e ufs_sec_sysfs -e 'ufs lt' -e 'sec_ufs' | tail -n 10
echo "== avc (ufs/scsi_host)"
dmesg 2>/dev/null | grep 'avc:' | grep -e 'name="un"' -e 'unique_number' -e 'name="lt"' -e 'name="lc"' \
	-e 'man_id' -e 'SEC_UFS' -e 'sense_err' -e 'sec_wb_enable' | tail -n 10
