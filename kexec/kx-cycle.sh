#!/bin/bash
# One hands-free kexec experiment on a test phone that has the kexec-capable 6.18 harness on
# `recovery` (PHONE=1 PHONE1 / PHONE=2 PHONE2). Flashes NOTHING to recovery:
#  1. from Android: copy the payload to the unencrypted ext4 `cache` partition (/cache/a52kx/);
#  2. boot the harness (test-cycle.sh NOFLASH HOLD), mount cache read-only;
#  3. /kexec-run with the watchdog net; 4. see what comes back:
#     - a kernel with a52.kexeced=<name> on its command line: SUCCESS, collect its dmesg;
#     - the harness in safe mode: the jump failed; fetch the previous boot's console;
#  5. /leave, Download round trip, back to Android.
# Usage: kexec/kx-cycle.sh <name> <Image> <ramdisk|-> <dtb|-|gen> "<next cmdline|-|+extra words>"
#   dtb gen: built now from KEXEC_BASE + KEXEC_OVERLAY (defaults: the bsp612 yupik.dtb and
#   bring-up overlay) and the harness's live tree of this boot
# Env: PHONE, KEXEC_WDT (default 60, 0 = none), HARNESS_EXTRA (shell commands run in the harness
#      before the jump), KX_EXTRA (shell commands run in the kexec'd kernel on success),
#      KX_WAIT (seconds to wait for something to come back, default 200), KX_HOLD=1 (on success
#      leave the kexec'd kernel running)
set -u
cd "$(dirname "$0")/.."
NAME="${1:?name}"; IMG="${2:?Image}"; RD="${3:?ramdisk or -}"; DTB="${4:?dtb or -}"; CMD="${5:--}"
case "${PHONE:-1}" in 1) S=PHONE1; export TSH_IP=172.16.42.1;; 2) S=PHONE2; export TSH_IP=172.16.43.1;; *) exit 1;; esac
PORT=""; for d in /sys/bus/usb/devices/*; do [ "$(cat "$d/serial" 2>/dev/null)" = "$S" ] && PORT=$d; done
[ -n "$PORT" ] || { echo "$S is not on USB"; exit 1; }
WDT="${KEXEC_WDT:-60}"; T=tools/tsh.py
L=logs/kx-$NAME-p${PHONE:-1}-$(date +%H%M%S); mkdir -p $L
# home = the phone's installed Android: 5.4, or a real 6.x boot (flashed rb; /data is the real
# encrypted f2fs, not the zram of a kexec test Android). Rebooting a real boot here looped phone 2.
is_home() { adb -s $S shell 'case $(uname -r) in 5.4.*) echo HOME;; *) awk '"'"'$2=="/data"{print $1}'"'"' /proc/mounts | grep -q zram || echo HOME;; esac' 2>/dev/null | grep -q HOME; }
say() { echo "[$(date +%T)] $*"; }
[ "$(adb -s $S get-state 2>/dev/null)" = device ] || { echo "$S is not in Android"; exit 1; }
adb -s $S shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
# root helper as in test-cycle.sh
if adb -s $S shell 'su -c id' 2>/dev/null | grep -q uid=0; then R='su -c'; else adb -s $S root >/dev/null 2>&1; timeout 30 adb -s $S wait-for-device; R='sh -c'; fi
stage() { # <local> <name>: skip if the same file is already there
  local want; want=$(sha256sum "$1" | cut -c1-64)
  local have; have=$(adb -s $S shell "$R 'sha256sum /cache/a52kx/$2 2>/dev/null'" | cut -c1-64)
  [ "$want" = "$have" ] && return 0
  adb -s $S push "$1" /data/local/tmp/kx.tmp >/dev/null || return 1
  adb -s $S shell "$R 'mkdir -p /cache/a52kx && cp /data/local/tmp/kx.tmp /cache/a52kx/$2 && sync'; rm -f /data/local/tmp/kx.tmp"
  [ "$(adb -s $S shell "$R 'sha256sum /cache/a52kx/$2'" | cut -c1-64)" = "$want" ]
}
stage "$IMG" Image || { echo "staging Image failed"; exit 1; }
RDA=-; [ "$RD" != - ] && { stage "$RD" rd || exit 1; RDA=/mnt/a52kx/rd; }
DTA=-; [ "$DTB" != - ] && [ "$DTB" != gen ] && { stage "$DTB" dtb || exit 1; DTA=/mnt/a52kx/dtb; }
# KX_PACK=<tar.gz>: extra files for the kexec'd kernel (modules, tools); it finds them on the
# cache partition: mount -t ext4 -o ro /dev/sda29 /mnt; tar xzf /mnt/a52kx/pack.tgz
[ -n "${KX_PACK:-}" ] && { stage "$KX_PACK" pack.tgz || { echo "staging pack failed"; exit 1; }; }
say "payload staged on $S:/cache/a52kx"
NOFLASH=1 HOLD=1 ./test-cycle.sh "${HARNESS_IMG:-images/a52sxq-ack618-kexec2-recovery.img}" 70 > $L/harness-boot.out 2>&1 || { tail -n 3 $L/harness-boot.out; echo "harness did not come up"; exit 1; }
python3 $T -t 20 'mkdir -p /mnt; mount -t ext4 -o ro /dev/disk/by-partlabel/cache /mnt 2>/dev/null || mount -t ext4 -o ro /dev/sda29 /mnt; ls -la /mnt/a52kx' > $L/stage.txt 2>&1
grep -q Image $L/stage.txt || { cat $L/stage.txt; echo "cache not mounted in the harness"; python3 $T /leave >/dev/null 2>&1; }
if [ "$DTB" = gen ]; then
  # dtb for a DIFFERENT kernel: its own base (+overlay) with this boot's bootloader and
  # hypervisor patches copied from the harness's live tree (kexec/mkkexecdtb.py)
  python3 $T -t 40 '/bin/busybox base64 /sys/firmware/fdt' | base64 -d > $L/harness-live.dtb 2>/dev/null
  python3 $T -t 10 'cat /proc/iomem' > $L/harness-iomem.txt 2>&1   # where the harness kernel itself lives
  python3 kexec/mkkexecdtb.py --base "${KEXEC_BASE:-bsp612/out/dist/dtb/yupik.dtb}" $( [ "${KEXEC_OVERLAY:-}" = none ] || echo --overlay "${KEXEC_OVERLAY:-bsp612/out/bringup/a52sxq-bringup.dtbo}" ) --live $L/harness-live.dtb -o $L/kexec.dtb > $L/mkkexecdtb.txt 2>&1 \
    && { for try in 1 2 3; do tools/tput.py $L/kexec.dtb /tmp/kx.dtb > $L/tput.txt 2>&1 && break; \
         echo "dtb push attempt $try failed: $(tail -n 1 $L/tput.txt)"; sleep 2; false; done; } \
    || { for f in $L/mkkexecdtb.txt $L/tput.txt; do tail -n 3 $f; done; echo "building or pushing the kexec dtb failed"; python3 $T -t 3 /leave >/dev/null 2>&1; }
  DTA=/tmp/kx.dtb
fi
# The harness refuses to jump in safe mode (previous boot not cleanly ended). That guard is for
# boots nobody watches; this script started from Android and watches the outcome, so it
# overrides it (KX_FORCE=0 keeps the guard).
[ "${KX_FORCE:-1}" = 1 ] && python3 $T -t 5 'touch /tmp/kexec-force' >/dev/null 2>&1
[ -n "${HARNESS_EXTRA:-}" ] && python3 $T -t 30 "$HARNESS_EXTRA" > $L/harness-extra.txt 2>&1
python3 $T -t 20 'dmesg' > $L/harness-dmesg.txt 2>&1
say "jump: /kexec-run $NAME (watchdog ${WDT}s)"
# a cmdline starting with "+" means: the harness's own command line plus these words.
# PREJUMP: shell commands run on the phone right before /kexec-run, in one detached shell
# (they may take USB down, so nothing is read back; everything is logged to kmsg instead).
case "$CMD" in
  +*) RC="\"\$(cat /proc/cmdline | sed 's/ a52\.kexeced=[^ ]*//') ${CMD#+}\"";;
  *)  RC="'$CMD'";;
esac
if [ -n "${PREJUMP:-}" ]; then
  python3 $T -t 8 "setsid sh -c 'sleep 1; $PREJUMP; /kexec-run $NAME /mnt/a52kx/Image $RDA $DTA $WDT $RC' >/tmp/kexec-run.log 2>&1 & echo detached" > $L/kexec-run.txt 2>&1
else
  python3 $T -t 12 "/kexec-run $NAME /mnt/a52kx/Image $RDA $DTA $WDT $RC" > $L/kexec-run.txt 2>&1
fi
grep -a -v "^$" $L/kexec-run.txt | tail -4
if grep -q -E "load failed|refusing|no support|missing" $L/kexec-run.txt; then
  python3 $T -t 20 'dmesg | tail -25' > $L/load-failed-dmesg.txt 2>&1
  say "the harness did not jump; its last kernel messages:"; grep -a -i -E "kexec|fdt|image|segment|hole|a52" $L/load-failed-dmesg.txt | tail -8 | cut -c1-160
  KX_WAIT=0
fi
# helpers for a kexec'd Android that answers on adb but not on telnet (2026-11-14, rh618b: its
# 6.18 Android had adb, no NCM; this loop saw nothing and the restart loop below rebooted it
# without saving a line), and for the previous boot's console once the phone is home again
adbkx() { [ "$(adb -s $S get-state 2>/dev/null)" = device ] && adb -s $S shell cat /proc/cmdline 2>/dev/null | grep -q "a52\.kexeced=$NAME"; }
adbdump() { # <prefix>: what the kexec'd Android has, before anything restarts it
  adb -s $S shell dmesg > $L/$1-dmesg.txt 2>&1
  adb -s $S shell 'logcat -d -b all' > $L/$1-logcat.txt 2>&1
  adb -s $S shell getprop > $L/$1-getprop.txt 2>&1
  say "saved over adb: $L/$1-{dmesg,logcat,getprop}.txt; USB lines:"
  grep -a -E 'rh: (usb|PASS usb|FAIL usb)|usbdiag' $L/$1-dmesg.txt | tail -6 | cut -c1-200
}
pstorefetch() { # back in the phone's own Android after a run that did not succeed: read FIRST
  adb -s $S root >/dev/null 2>&1; timeout 30 adb -s $S wait-for-device
  adb -s $S shell 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null || su -c "cat /sys/fs/pstore/console-ramoops-0"' > $L/pstore-console-ramoops-0.txt 2>&1
  say "previous boot's console (pstore): $L/pstore-console-ramoops-0.txt ($(wc -l < $L/pstore-console-ramoops-0.txt) lines)"
  grep -a -E 'Linux version|a52rh: (FAIL|SUMMARY)|rh: (FAIL|PASS) usb|usbdiag|dead-man|panic|Kernel panic' $L/pstore-console-ramoops-0.txt | tail -8 | cut -c1-200
}
T0=$(date +%s); RES=none
while [ $(( $(date +%s) - T0 )) -lt "${KX_WAIT:-200}" ]; do
  [ "$(cat $PORT/idProduct 2>/dev/null)" = 685d ] && RES=download
  [ $RES = download ] && break
  if O=$(python3 $T -t 4 'cat /proc/cmdline; echo; [ -e /tmp/crashed ] && echo A52_SAFE_MODE; uname -r' 2>/dev/null); then
    if echo "$O" | grep -q "a52\.kexeced=$NAME"; then RES=success; break; fi
    if echo "$O" | grep -q A52_SAFE_MODE; then RES=failed; break; fi
    # the harness again, but not in safe mode: the other kernel ran and ended with a
    # "clean exit" line (its own /leave or reboot) before the bootloader restarted us
    if echo "$O" | grep -q "6\.18\." && [ $(( $(date +%s) - T0 )) -gt 20 ]; then RES=returned; break; fi
  elif adbkx; then RES=adbonly; break
  fi
  python3 -c 'import time; time.sleep(2)'
done
case $RES in
  success)
    say "SUCCESS: kexec'd kernel is up: $(echo "$O" | tail -1)"
    python3 $T -t 25 dmesg > $L/kexeced-dmesg.txt 2>&1
    [ -n "${KX_EXTRA:-}" ] && python3 $T -t "${KX_EXTRA_TIMEOUT:-60}" "$KX_EXTRA" > $L/kexeced-extra.txt 2>&1
    [ -n "${KX_EXTRA:-}" ] && python3 $T -t 30 dmesg > $L/kexeced-dmesg-after.txt 2>&1
    [ -n "${KX_HOLD:-}" ] && { python3 $T 'touch /tmp/keep' >/dev/null 2>&1; say "KX_HOLD: left running"; exit 0; } ;;
  failed)
    python3 $T -t 25 'cat /tmp/prev-console.txt' > $L/prev-console.txt 2>&1
    python3 $T -t 25 'cat /proc/a52ram' > $L/a52ram.txt 2>&1
    [ -s $L/a52ram.txt ] && { say "early log of the kexec'd kernel: $L/a52ram.txt ($(wc -l < $L/a52ram.txt) lines); last lines:"; tail -12 $L/a52ram.txt | cut -c1-160; }
    say "FAILED: back in the harness (safe mode). Previous console: $L/prev-console.txt ($(wc -l < $L/prev-console.txt) lines)"
    grep -a -n -E "kexec|Bye|Starting new kernel|Linux version|a52\.kexeced|panic|Unable to handle|Internal error" $L/prev-console.txt | tail -8 | cut -c1-150 ;;
  returned)
    python3 $T -t 25 'cat /tmp/prev-console.txt' > $L/prev-console.txt 2>&1
    say "RETURNED: the kexec'd kernel ran and restarted the phone cleanly. Its console: $L/prev-console.txt ($(wc -l < $L/prev-console.txt) lines)"
    grep -a -E "a52sxq-init" $L/prev-console.txt | grep -v "insmod [a-z0-9_-]*$" | tail -12 | cut -c1-170 ;;
  adbonly)
    say "ADB ONLY: the kexec'd kernel is up ($(adb -s $S shell uname -r 2>/dev/null | tr -d '\r')) and answers on adb, but not on telnet $TSH_IP"
    adbdump kexeced
    [ -n "${KX_HOLD:-}" ] && { say "KX_HOLD: left running (adb only)"; exit 0; } ;;
  download) say "phone went to Download mode by itself (nothing answered in between)";;
  none) say "nothing came back within ${KX_WAIT:-200}s";;
esac
python3 $T -t 3 /leave >/dev/null 2>&1
T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt 300 ]; do
  if [ "$(adb -s $S get-state 2>/dev/null)" = device ]; then
    if is_home; then say "back in Android (direct restart); result=$RES; logs in $L"; [ $RES = success ] || pstorefetch; [ $RES = success ]; exit $?; fi
    case x in
      *) say "a kexec'd Android ($(adb -s $S shell uname -r 2>/dev/null | tr -d '\r')) answers on adb: saving its logs, then restarting it"
         adbdump before-reboot; adb -s $S shell 'reboot' >/dev/null 2>&1;;
    esac
  fi
  if [ "$(cat $PORT/idProduct 2>/dev/null)" = 685d ] && tools/dlexit.sh $PORT; then
    timeout 180 adb -s $S wait-for-device && { say "back in Android; result=$RES; logs in $L"; [ $RES = success ] || pstorefetch; [ $RES = success ]; exit $?; }
  fi
  python3 $T -t 3 /leave >/dev/null 2>&1
  python3 -c 'import time; time.sleep(2)'
done
say "did NOT get back to Android (needs the keys)"; exit 21
