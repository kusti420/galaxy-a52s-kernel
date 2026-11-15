#!/bin/bash
# Stage a kernel in the RAM of a phone that is running the 6.18 harness (image kexec1 or later)
# and start it by kexec with the watchdog safety net. Talks to the harness's telnet shell only
# (tools/tsh.py): NO adb, NO heimdall, flashes nothing, touches no partition.
#
#   kexec/kexec-test.sh <Image> <ramdisk or -> <dtb | - | gen> "<cmdline or ->"
#     dtb -    the harness's own FDT (harness -> harness)
#     dtb gen  build it now: the harness's live /sys/firmware/fdt (this boot's bootloader and
#              hypervisor patches) merged into KEXEC_BASE + KEXEC_OVERLAY by mkkexecdtb.py
#              (defaults: the bsp612 yupik.dtb + a52sxq-bringup.dtbo). Preferred for 6.12.
#     dtb file a dtb made by kexec/mkkexecdtb.py
#     cmdline - = the harness's own command line
#   env: TSH_IP (172.16.42.1; phone 2: 172.16.43.1), KEXEC_NAME (log marker, default: Image's
#        directory name), KEXEC_WDT (seconds, default 120, 0 = none), KEXEC_WAIT (seconds to
#        watch for the result, default WDT+120), KEXEC_PORT (8099)
set -u
cd "$(dirname "$0")/.."
[ $# -eq 4 ] || { sed -n 2,16p "$0"; exit 2; }
IMG=$(realpath "$1"); RD="$2"; DTB="$3"; CMD="$4"
export TSH_IP="${TSH_IP:-172.16.42.1}"
NAME="${KEXEC_NAME:-$(basename "$(dirname "$IMG")")}"; NAME=$(echo "$NAME" | tr -c 'A-Za-z0-9._\n-' _)
WDT="${KEXEC_WDT:-120}"; WAIT="${KEXEC_WAIT:-$((WDT + 120))}"; PORT="${KEXEC_PORT:-8099}"
T=tools/tsh.py
say() { echo "[$(date +%T)] $*"; }
[ -f "$IMG" ] || { echo "no Image $IMG"; exit 2; }
[ "$RD" = - ] || [ -f "$RD" ] || { echo "no ramdisk $RD"; exit 2; }

# 1. the phone must be a harness with kexec support, not in safe mode
INFO=$(python3 $T 'uname -r; ls /kx /kexec-run /sys/firmware/kexec_fdt 2>&1; [ -e /tmp/crashed ] && echo SAFE_MODE; cat /proc/cmdline') || { echo "no harness shell on $TSH_IP"; exit 1; }
echo "$INFO"
echo "$INFO" | grep -q "No such file" && { echo "this harness has no kexec support (needs image kexec1 or later)"; exit 1; }
echo "$INFO" | grep -q SAFE_MODE && { echo "harness is in safe mode after a crashed boot: not starting anything (it leaves by itself)"; exit 1; }

# 2. stage directory + HTTP server on the USB network (busybox wget on the phone fetches)
NET=$(echo "$TSH_IP" | cut -d. -f1-3)
PCIP=$(ip -4 -o addr show | grep -o "inet $NET\.[0-9]*" | head -1 | cut -d' ' -f2)
[ -n "$PCIP" ] || { echo "the PC has no address in $NET.0/24"; exit 1; }
D=$(mktemp -d); trap 'kill $SRV 2>/dev/null; rm -rf "$D"' EXIT
ln -s "$IMG" "$D/Image"
[ "$RD" = - ] || ln -s "$(realpath "$RD")" "$D/rd"
printf '%s' "$CMD" > "$D/cmdline"
python3 -m http.server "$PORT" --bind "$PCIP" --directory "$D" >/dev/null 2>&1 & SRV=$!
sleep 1
if [ "$DTB" = gen ]; then
	# the harness serves its live FDT with busybox-extras httpd for a moment
	python3 $T 'mkdir -p /tmp/fdtsrv; cp /sys/firmware/fdt /tmp/fdtsrv/fdt; /bin/busybox-extras httpd -p 8098 -h /tmp/fdtsrv; sleep 1; echo ok' >/dev/null
	curl -s --max-time 20 -o "$D/harness-live.dtb" "http://$TSH_IP:8098/fdt" || { echo "could not fetch the live FDT"; exit 1; }
	python3 $T 'pkill httpd; echo' >/dev/null
	OVL=${KEXEC_OVERLAY-bsp612/out/bringup/a52sxq-bringup.dtbo}
	python3 kexec/mkkexecdtb.py --base "${KEXEC_BASE:-bsp612/out/dist/dtb/yupik.dtb}" ${OVL:+--overlay "$OVL"} \
		--live "$D/harness-live.dtb" -o "$D/dtb" || { echo "mkkexecdtb failed"; exit 1; }
	mkdir -p logs; cp "$D/dtb" "logs/kexec-$NAME-last.dtb"; cp "$D/harness-live.dtb" "logs/kexec-harness-live-last.dtb"
elif [ "$DTB" != - ]; then
	[ -f "$DTB" ] || { echo "no dtb $DTB"; exit 2; }
	cp "$DTB" "$D/dtb"
fi

# 3. fetch on the phone and verify sha256
fetch() { # <served name> <path on phone> <local file>
	local want got
	want=$(sha256sum "$3" | cut -d' ' -f1)
	got=$(python3 $T -t 180 "/bin/busybox wget -q -O $2 http://$PCIP:$PORT/$1 && /bin/busybox sha256sum $2 | cut -d' ' -f1")
	got=$(echo "$got" | tr -d ' \n')
	[ "$want" = "$got" ] || { echo "sha256 mismatch for $1: PC $want, phone '$got'"; exit 1; }
	say "staged $1 -> $2 ($(stat -Lc %s "$3") bytes, sha256 ok)"
}
fetch Image /tmp/kx-Image "$D/Image"
PRD=-; [ "$RD" = - ] || { fetch rd /tmp/kx-rd "$D/rd"; PRD=/tmp/kx-rd; }
PDTB=-; [ -f "$D/dtb" ] && { fetch dtb /tmp/kx-dtb "$D/dtb"; PDTB=/tmp/kx-dtb; }
fetch cmdline /tmp/kx-cmdline "$D/cmdline"

# 4. trigger: detached, 3 s after this shell command returns (the jump kills the connection)
say "starting kexec to '$NAME' (watchdog ${WDT}s)"
python3 $T "setsid sh -c 'sleep 3; /kexec-run $NAME /tmp/kx-Image $PRD $PDTB $WDT \"\$(cat /tmp/kx-cmdline)\" >/tmp/kexec-run.log 2>&1' >/dev/null 2>&1 & echo launched"
kill $SRV 2>/dev/null
sleep 8
if R=$(python3 $T 'cat /tmp/kexec-run.log 2>/dev/null; echo; echo STILL_OLD_KERNEL' 2>/dev/null) && echo "$R" | grep -q STILL_OLD_KERNEL; then
	echo "$R"
	if echo "$R" | grep -qE "kexec-run: .*(failed|refus|missing|differs|no support|must be)|^usage:"; then say "RESULT: kexec was NOT started (see above); the phone is still in the harness, watchdog not armed"; exit 1; fi
	say "kexec-run has not finished yet; watching"
fi

# 5. watch what comes back on the USB network
say "waiting up to ${WAIT}s for a shell on $TSH_IP"
END=$((SECONDS + WAIT))
while [ $SECONDS -lt $END ]; do
	if R=$(python3 $T -t 8 'echo UNAME $(uname -r); cat /proc/cmdline; [ -e /tmp/crashed ] && echo SAFE_MODE; [ -e /tmp/kexec-run.log ] && echo OLD_BOOT; dmesg | grep -E "a52sxq-(init|harness)" | tail -8' 2>/dev/null); then
		if echo "$R" | grep -q OLD_BOOT; then sleep 3; continue; fi
		echo "$R"
		if echo "$R" | grep -q "a52\.kexeced=$NAME"; then
			say "RESULT: the kexec'd kernel '$NAME' is up and has a shell. Leave with: TSH_IP=$TSH_IP python3 $T /leave"
			exit 0
		fi
		say "RESULT: back in the harness booted from flash (the kexec'd kernel reset or was bitten)."
		echo "$R" | grep -q SAFE_MODE && say "crash guard: safe mode, it leaves for Download mode by itself within 90 s" \
			|| say "WARNING: crash guard did NOT flag the previous boot; run: python3 $T 'cat /tmp/prev-console.txt | tail -50'"
		mkdir -p logs; python3 $T -t 30 'cat /tmp/prev-console.txt' > "logs/kexec-$NAME-prev-console-$(date +%H%M%S).txt" 2>/dev/null
		exit 3
	fi
	sleep 3
done
say "RESULT: nothing answered within ${WAIT}s (kernel '$NAME' may be running without USB network, or the phone is on its way through Download mode)."
exit 4
