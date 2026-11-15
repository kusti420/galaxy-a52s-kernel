#!/bin/busybox sh
# stage 3: ADSP + CDSP (never the modem: no modem firmware is linked into /lib/firmware)
cd "${0%/*}"; . ./common.sh; . ./fw.sh; chmod 755 qrtrls
mount -t debugfs none /sys/kernel/debug 2>/dev/null
fwmount; fwlink 'adsp*' 'cdsp*'; ls /lib/firmware | tr '\n' ' '; echo
[ "$2" = nocdsp ] && rm -f /lib/firmware/cdsp*
ld s3 "$1"; k "insmod qcom_pd_mapper_a52 (patched copy)"; insmod m/qcom_pd_mapper_a52.ko 2>&1 || k "FAIL pd_mapper"
sleep 3; sh /p/mkdevs
rp() { for r in /sys/class/remoteproc/remoteproc*; do echo "$(basename $r) $(cat $r/name) state=$(cat $r/state) recovery=$(cat $r/recovery 2>/dev/null) fw=$(cat $r/firmware)"; done; }
k "remoteprocs"; rp
for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name)" in *adsp*|*lpass*|3700000*) [ "$(cat $r/state)" = offline ] && { k "start $(cat $r/name)"; echo start > $r/state 2>&1; };; esac; done
sleep 6; k "after ADSP start"; rp
for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name)" in *cdsp*|a300000*) [ "$2" != nocdsp ] && [ "$(cat $r/state)" = offline ] && { k "start $(cat $r/name)"; echo start > $r/state 2>&1; };; esac; done
sleep 6; k "after CDSP start"; rp
k "qrtrls"; ./qrtrls 2>&1 | head -80
k "subsys"; for s in /sys/bus/msm_subsys/devices/*; do echo "$(basename $s) $(cat $s/name) $(cat $s/state)"; done; ls /dev/subsys_* 2>&1 | tr '\n' ' '; echo
k "s3 done"; dmesg | grep -iE 'remoteproc|q6v5|pas|glink|qrtr|pdr|pd.mapper|sysmon|smp2p|subsys|adsp|cdsp' | grep -v 'hw: insmod' | tail -70
