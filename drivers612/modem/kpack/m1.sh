#!/bin/busybox sh
# M1, kernel only (bsp612 busybox ramdisk, no Android, no rmt_storage): IPA + MSS bring-up with
# the PHONE'S OWN firmware, read from its own modem and apnhlos partitions mounted READ-ONLY.
# No firmware is carried in this pack (HARD RULE, 2026-11-13 incident).
# usage: sh /p/m1.sh [observe-seconds (default 100)] [nocrash] [therm] [m2] [nas] [data [probe]] [apn=<APN>] [qmap=5|9]
#   nas (needs m2; README section 12): once the modem has been up 30 s: bin/qmi-nas info,
#   --online (the radio transmits: cell search; without a SIM emergency-only scanning), 20 s,
#   info, network scan (150 s), --low-power. Output also in /tmp/nas.out.
#   data (needs m2; README section 12): UIM card status (read only; skipped unless the SIM
#   application is ready), --online, wait for registration (90 s), then ONE qmi-nas process
#   (netmgrd recipe, README section 12): DPM open_port (control port DATA5_CNTL + hardware data
#   port embedded:1 on the IPA pipes of GET_EP_PAIR), WDA data format (qmap=5 default, qmap=9 =
#   QMAPv5 as the ROM), rmnet_ipa0 WAN pipes + rmnet_data0 (mux 1) for what the modem applied,
#   WDS bind + ip family + call with apn=<APN> (default: the modem's default profile, then
#   "internet" on call-failed), dataup.sh (address, route, ping 1.1.1.1), stop, --low-power.
#   probe (with data): qmi-nas data-probe instead: the endpoint/DPM variants one at a time,
#   each logged, until the first call comes up (budget 420 s).
#   m2: test M2-K (README section 10): before the modem vote, copy the four EFS partitions into a
#   tmpfs (bin/efsdump: O_RDONLY + kernel read-only flag on the partitions) and start the open
#   RMTFS server on those RAM copies (bin/rmtfs, RAM-only build: never opens a block device, keeps
#   modem writes in its own memory) and tqftpserv (/readwrite in a tmpfs); then observe: no DOG
#   stall expected; QRTR services (bin/qrtr-lookup), modem state, SSR counts; with "therm" one T1
#   phase "up60" once the modem has been up for 60 s. At the end: efsdump verify (partitions
#   byte-identical to the copies taken before the run).
#   therm: Test T1 (drivers612/power/THERMISTOR-ADC.md): load the PMIC VADC and sample the
#   ap/pa/wf thermistors + PM7325 gpio1..4 registers (read only) before the modem starts, after it
#   is up, during the observe window and after it is stopped (therm.sh; lines "T1 ...")
#   - refuses to start the modem when the modem image's anti-rollback version is lower than the
#     ADSP image's on the same phone (the ADSP is known to load, so TZ's counter is at least
#     that): phone 2 after the 2026-11-13 incident (modem 2, adsp 5) - TZ would reject it
#     anyway (no harm, nothing to learn). M1_ANYPHONE=1 skips this check.
# Expected without rmt_storage: the MPSS boots, registers its early QRTR services, asks for
# RMTFS and, ~65 s later, crashes with "DOG detects stalled initialization" (as in run ab-s18).
# What this run must show: guard active, IPA ready, TZ accepts the image, QRTR servers on the modem's node,
# the crash handled as SSR (recovery, no kernel panic), and a clean shutdown at the end.
cd "${0%/*}"; . ./common.sh; chmod 755 qrtrls; chmod 755 bin/* 2>/dev/null
od() { /bin/busybox od "$@"; }
OBS=${1:-100}; [ $# -gt 0 ] && shift
NOCRASH=; THERM=; M2=; NAS=; DATA=; APN=; PROBE=; QMAP=5
for a in "$@"; do case "$a" in nocrash) NOCRASH=1;; therm) THERM=1;; m2) M2=1;; nas) NAS=1;; data) DATA=1;; probe) PROBE=1;; apn=*) APN=${a#apn=};; qmap=5|qmap=9) QMAP=${a#qmap=};; *) k "unknown argument $a";; esac; done
if { [ -n "$NAS" ] || [ -n "$DATA" ]; } && [ -z "$M2" ]; then k "nas/data need m2 (without RMTFS the modem dies at ~80 s): REFUSED"; exit 7; fi
if [ -n "$PROBE" ] && [ -z "$DATA" ]; then k "probe is a variant of the data step: add data"; exit 7; fi
RMTFS_PID=; TFTP_PID=; VOTE_T=0; UP60=
m2_status() { # m2_status <tag>: servers, logs, crash counters
	echo "M2 $1 t=$(cut -d' ' -f1 /proc/uptime) up_for=$(( $(cut -d. -f1 /proc/uptime) - VOTE_T ))s subsys3=$(cat /sys/bus/msm_subsys/devices/subsys3/state 2>/dev/null) DOG=$(dmesg | grep -c 'DOG detects stalled') crashes=$(dmesg | grep -c 'handling crash #') fatal=$(dmesg | grep -c 'fatal error received') rmtfs=$(kill -0 $RMTFS_PID 2>/dev/null && echo alive || echo DEAD) tftp=$(kill -0 $TFTP_PID 2>/dev/null && echo alive || echo DEAD)"
	echo "M2 $1 rmtfs: opens=$(grep -c '^\[storage\] open' /tmp/rmtfs.log) iovec=$(grep -c '^\[RMTFS\] iovec' /tmp/rmtfs.log) rd=$(grep -cE '^\[RMTFS\] +read ' /tmp/rmtfs.log) wr=$(grep -cE '^\[RMTFS\] +write ' /tmp/rmtfs.log) alloc=$(grep -c '^\[RMTFS\] alloc' /tmp/rmtfs.log) errors=$(grep -ciE 'fail|refus|unknown' /tmp/rmtfs.log)"
	echo "M2 $1 tftp: opened=$(grep -c 'opened for' /tmp/tqftp.log) rejected=$(grep -ciE 'reject' /tmp/tqftp.log)"
	rp | grep -i mss | sed "s/^/M2 $1 /"
}

qn() { # qn <qmi-nas args>: run bin/qmi-nas, output to stdout and /tmp/nas.out, rc in $QN_RC
	# streamed (2026-11-15): result lines go to /dev/kmsg AS THEY HAPPEN, so ramoops keeps them even if the
	# test kernel hangs before the PC collects /tmp/nas.out; UIM lines never go to the kernel log
	: > /tmp/qn.out
	{ ./bin/qmi-nas "$@" 2>&1; echo "QN_RC=$?"; } | while IFS= read -r l; do
		echo "$l" >> /tmp/qn.out
		case "$l" in UIM*|*\ UIM\ *) ;;
		*summary*|*start_network*|*FAILURE*|*"bytes from"*|*"packet loss"*|*ipv4*|*IPv4*|*registration=*|*DPM*|*WDA*) echo "a52sxq-init: qn: $l" > /dev/kmsg;; esac
	done
	QN_RC=$(sed -n 's/^QN_RC=//p' /tmp/qn.out | tail -1); sed -i '/^QN_RC=/d' /tmp/qn.out
	cat /tmp/qn.out; cat /tmp/qn.out >> /tmp/nas.out
	echo "## qmi-nas $* -> rc=$QN_RC" | tee -a /tmp/nas.out
}
nas_wait30() { # until the modem has been up 30 s (from the vote)
	while [ $(( $(cut -d. -f1 /proc/uptime) - VOTE_T )) -lt 30 ]; do sleep 1; done
}

mount -t debugfs none /sys/kernel/debug 2>/dev/null
sh ./mkdevs

k "m1: firmware from the phone's own partitions (vfat, read-only)"
mkdir -p /fw/modem /fw/apnhlos /lib/firmware
M=$(part modem); A=$(part apnhlos)
[ -n "$M" ] && [ -n "$A" ] || { k "FAIL: modem=$M apnhlos=$A partitions not found"; exit 1; }
mount -t vfat -o ro /dev/$M /fw/modem || { k "FAIL mount modem"; exit 1; }
mount -t vfat -o ro /dev/$A /fw/apnhlos || { k "FAIL mount apnhlos"; exit 1; }
for f in /fw/modem/image/modem.* /fw/modem/image/modemr.jsn /fw/apnhlos/image/yupik_ipa_fws.*; do
	[ -e "$f" ] && ln -sf "$f" /lib/firmware/
done
echo -n /lib/firmware > /sys/module/firmware_class/parameters/path
ls -la /lib/firmware | head -50
if [ -n "$THERM" ]; then . ./therm.sh; t1_setup; t1_phase early 1; fi
# signing metadata of what will be loaded (hash segment v6, OEM metadata, anti-rollback at 0xa4)
for g in modem yupik_ipa_fws; do
	echo "$g: hdr_ver=$(od -An -tu4 -j4 -N4 /lib/firmware/$g.b01 | tr -d ' ') rollback=$(od -An -tu1 -j164 -N1 /lib/firmware/$g.b01 | tr -d ' ')"
done
cat /fw/modem/verinfo/ver_info.txt 2>/dev/null | grep -E '"modem"|Meta_Build_ID'
RM=$(od -An -tu1 -j164 -N1 /fw/modem/image/modem.b01 | tr -d ' ')
RA=$(od -An -tu1 -j164 -N1 /fw/apnhlos/image/adsp.b01 | tr -d ' ')
k "anti-rollback: modem=$RM adsp=$RA"
# never let a modem image raise TZ's shared counter above the rest of the phone's firmware set
# (that is exactly the 2026-11-13 incident class); not overridable
if [ -n "$RM" ] && [ -n "$RA" ] && [ "$RM" -gt "$RA" ]; then
	k "modem image rollback $RM > adsp $RA: loading it could raise TZ's counter: REFUSED"; exit 4
fi
if [ -z "${M1_ANYPHONE:-}" ] && { [ -z "$RM" ] || [ -z "$RA" ] || [ "$RM" -lt "$RA" ]; }; then
	k "modem image older than this phone's accepted firmware set (TZ would refuse it): not running M1"; exit 3
fi

k "m1: dsp stage (remoteproc, glink, qrtr, sysmon, pdr, subsys_compat)"
ld dsp.list "frpc-adsprpc"
k "m1: modem stage (guard, sharedmem, memshare, glink_pkt, IPA, rmnet)"
ld modem.list
dmesg | grep -E "a52_modem_guard" | tail -5
k "m1: rmnet/IPA modules loaded (rmnet_core needs IPA3 headers, fix of 2026-11-14)"
grep -E "^(rmnet_ctl|rmnet_core|rmnet_offload|rmnet_shs|ipam|ipanetm|msm_memshare|msm_sharedmem) " /proc/modules | cut -d' ' -f1,3,5
dmesg | grep -E "rmnet_ctl_init|rmnet_(offload|shs): Unknown symbol" | tail -3
rp
cat /sys/kernel/debug/devices_deferred 2>/dev/null
k "m1: rmtfs uio"; for u in /sys/class/uio/uio*; do echo "$u name=$(cat $u/name) ver=$(cat $u/version) addr=$(cat $u/maps/map0/addr) size=$(cat $u/maps/map0/size)"; done
dmesg | grep -iE "memshare" | tail -8
ls -la /dev/ipa /dev/subsys_* /dev/smd* /dev/at_mdm0 /dev/uio* 2>&1

k "m1: IPA firmware (echo 1 > /dev/ipa, as ipa_fws.rc does)"
echo 1 > /dev/ipa
for i in $(seq 1 20); do dmesg | grep -qE "IPA driver initialization was successful|IPA FW loaded successfully" && break; sleep 1; done
dmesg | grep -iE "ipa|gsi" | grep -v "modem: insmod" | tail -25
ip link 2>/dev/null | grep -E "rmnet|ipa"

k "m1: QRTR before the modem"; ./qrtrls

if [ -n "$M2" ]; then
	k "m2: EFS RAM copies (efsdump: partitions O_RDONLY + kernel read-only flag, copies in a tmpfs)"
	[ -x bin/efsdump ] && [ -x bin/rmtfs ] && [ -x bin/tqftpserv ] || { k "FAIL m2: bin/efsdump, bin/rmtfs or bin/tqftpserv missing in the pack"; exit 5; }
	mkdir -p /tmp/efs /tmp/tqftp-rw
	mount -t tmpfs -o size=96m,mode=0700 tmpfs /tmp/efs || { k "FAIL m2: tmpfs /tmp/efs"; exit 5; }
	mount -t tmpfs -o size=16m,mode=0700 tmpfs /tmp/tqftp-rw || { k "FAIL m2: tmpfs /tmp/tqftp-rw"; exit 5; }
	for p in modemst1 modemst2 fsg fsc; do echo "m2: $p = $(part $p)"; done
	./bin/efsdump copy /tmp/efs || { k "FAIL m2: efsdump copy (modem not started)"; exit 5; }
	ls -la /tmp/efs
	for p in modemst1 modemst2 fsg fsc; do d=$(part $p); echo "m2: $p /sys/class/block/$d/ro=$(cat /sys/class/block/$d/ro)"; done
	# TFTP's /readonly/firmware/image/... = /lib/firmware/<file> (tqftpserv's lookup): link the
	# modem partition's non-image entries (modem_pr/ = mcfg, *.jsn, qdsp6m.qdb, ...); never another
	# signed image (.mdt/.bNN/.mbn), the modem.* set is linked above
	for f in /fw/modem/image/*; do
		b=${f##*/}
		case "$b" in *.mdt|*.mbn|*.b[0-9][0-9]|modem.*) continue;; esac
		[ -e "/lib/firmware/$b" ] || ln -s "$f" /lib/firmware/
	done
	ls -la /lib/firmware | grep -vE " modem\.b[0-9]" | head -30
	k "m2: start rmtfs (RAM copies) and tqftpserv"
	./bin/rmtfs -v -o /tmp/efs > /tmp/rmtfs.log 2>&1 & RMTFS_PID=$!
	./bin/tqftpserv -d > /tmp/tqftp.log 2>&1 & TFTP_PID=$!
	sleep 2
	kill -0 $RMTFS_PID 2>/dev/null || { k "FAIL m2: rmtfs exited (modem not started)"; cat /tmp/rmtfs.log; exit 6; }
	kill -0 $TFTP_PID 2>/dev/null || k "m2: tqftpserv exited (continuing without TFTP)"
	head -10 /tmp/rmtfs.log; head -5 /tmp/tqftp.log
	k "m2: QRTR after the servers started (14 = RMTFS, 4096 = TFTP, on the AP node)"; ./bin/qrtr-lookup
fi

[ -n "$THERM" ] && t1_phase pre 3 2
R=$(mss); [ -n "$R" ] || { k "FAIL: no mss remoteproc (modem_pas disabled in the dtb? use the MODEM tree)"; exit 1; }
k "m1: boot the modem: open /dev/subsys_modem (= pm-service's vote)"
exec 3</dev/subsys_modem
VOTE_T=$(cut -d. -f1 /proc/uptime); UP60=
sleep 8; rp; cat /sys/bus/msm_subsys/devices/subsys3/state
dmesg | grep -iE "remoteproc|mss|modem|sysmon|ssctl|glink|qrtr|memshare|rmtfs|ipa.*(mpss|modem|qmi)" | grep -v "modem: insmod" | tail -40
k "m1: QRTR servers (20 s)"; ./qrtrls -w 20
[ -n "$M2" ] && { k "m2: qrtr-lookup"; ./bin/qrtr-lookup; m2_status early; }
[ -n "$THERM" ] && t1_phase up 3 2

k "m1: memshare requests (client 3 must be 'client not found', no page_alloc WARN)"
dmesg | grep -E "memshare_alloc|memshare_child|page_alloc|WARNING: CPU" | tail -12

if [ -n "$NAS" ]; then
	nas_wait30; : > /tmp/nas.out
	k "m2: nas: radio check without SIM data (qmi-nas info / --online / scan / --low-power)"
	qn lookup
	qn info
	qn --online
	sleep 20; m2_status nas-online20
	qn info
	k "m2: nas: network scan (timeout 150 s)"
	qn -t 150 scan
	m2_status nas-scan
	qn --low-power
	qn mode
fi
if [ -n "$DATA" ]; then
	nas_wait30
	k "m2: data: SIM card status (read only)"
	qn card
	if ! grep -q "^UIM summary: card=present .* app=ready" /tmp/qn.out; then
		grep -q "pin1=enabled-not-verified" /tmp/qn.out && k "m2: data: SIM PIN1 is required and this tool does not enter it: data step skipped"
		k "m2: data: SIM application not ready: data step skipped"
	else
		qn --online
		qn wait-registered 90
		if [ "$QN_RC" != 0 ]; then
			k "m2: data: not registered within 90 s: no data call"
		else
			qn info
			# one qmi-nas process = one QMI client for every step (the modem drops a client's
			# DPM ports / bindings / calls when its socket closes); qmi-nas sets up the IPA WAN
			# pipes + rmnet_data0 itself, for the QMAP version the modem's WDA answer applied
			ip link set rmnet_ipa0 up; ip link show rmnet_ipa0
			qn ipa-pair rmnet_ipa0
			if [ -n "$PROBE" ]; then
				k "m2: data: data-probe (DPM/endpoint variants one at a time until a call comes up), qmap $QMAP"
				qn -t 20 data-probe --ipa rmnet_ipa0 --rmnet rmnet_data0 --wda 2:$QMAP:$QMAP:32:16384 --mux 1 \
					--budget 420 ${APN:+--apn "$APN"} --run "sh $PWD/dataup.sh"
			else
				k "m2: data: DPM open_port + WDA + IPA pipes + rmnet_data0 (mux 1) + WDS call (netmgrd recipe), qmap $QMAP"
				qn -t 20 data --dpm ctl --ep 4:1 --ipa rmnet_ipa0 --rmnet rmnet_data0 --wda 2:$QMAP:$QMAP:32:16384 \
					--mux 1 --ipfam --apn-fallback internet --call-timeout 60 ${APN:+--apn "$APN"} --run "sh $PWD/dataup.sh"
			fi
			ip link show rmnet_data0
			m2_status data
			qn rmnet-del rmnet_data0
		fi
	fi
	qn --low-power
	dmesg | grep -iE "rmnet_ipa|ipa_wan|wwan|rmnet_data|qmi_rmnet" | tail -20
fi

if [ -z "$NOCRASH" ]; then
	k "m1: observe ${OBS}s (DOG stall expected without rmt_storage; must end as SSR, no panic)"
	if [ -n "$THERM" ] || [ -n "$M2" ]; then # every 20 s: T1 sample / M2 status (covers the DOG stall time)
		W=0; while [ $((W + 20)) -le "$OBS" ]; do
			sleep 20; W=$((W + 20))
			[ -n "$THERM" ] && t1_sample obs$W 1
			[ -n "$M2" ] && m2_status obs$W
			if [ -n "$THERM" ] && [ -n "$M2" ] && [ -z "$UP60" ] && [ $(( $(cut -d. -f1 /proc/uptime) - VOTE_T )) -ge 60 ]; then
				UP60=1; t1_phase up60 3 2
			fi
		done
		[ "$W" -lt "$OBS" ] && sleep $((OBS - W))
	else
		sleep "$OBS"
	fi
	if [ -n "$M2" ]; then
		k "m2: after ${OBS}s: QRTR services, rmtfs/tftp logs"
		./bin/qrtr-lookup; m2_status end
		echo "----- rmtfs.log (head 60, tail 40)"; head -60 /tmp/rmtfs.log; echo ...; tail -40 /tmp/rmtfs.log
		echo "----- tqftp.log (head 60)"; head -60 /tmp/tqftp.log
		find /tmp/tqftp-rw -type f 2>/dev/null | head -20
	fi
	dmesg | grep -iE "rproc crash|fatal error|watchdog|recover|a52_modem_guard|crash #|request_firmware" | tail -30
	rp
	k "m1: deliberate SSR (debugfs crash, type watchdog): stop + reload by the AP"
	N=$(basename $R); echo 1 > /sys/kernel/debug/remoteproc/$N/crash
	sleep 15; rp
	dmesg | grep -iE "handling crash|recover|a52_modem_guard|Booting fw|is now up" | tail -12
	[ -n "$THERM" ] && t1_phase ssr 1
	[ -n "$M2" ] && { m2_status ssr; tail -20 /tmp/rmtfs.log; }
fi

if [ -n "$NAS" ] || [ -n "$DATA" ]; then k "m2: radio back to LOW_POWER before the release"; qn --low-power; fi
k "m1: release the vote (close = rproc_shutdown)"
exec 3<&-
sleep 3; rp; cat /sys/bus/msm_subsys/devices/subsys3/state
[ -n "$THERM" ] && { t1_phase off 1; sleep 10; t1_phase off10 1; }
if [ -n "$M2" ]; then
	sleep 3; m2_status off
	kill $RMTFS_PID $TFTP_PID 2>/dev/null; sleep 1
	k "m2: efsdump verify (real partitions vs the copies taken before the run)"
	./bin/efsdump verify /tmp/efs
	tail -5 /tmp/rmtfs.log
fi
k "m1 done"
