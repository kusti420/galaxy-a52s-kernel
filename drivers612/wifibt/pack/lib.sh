# sourced by the wifibt stage scripts (run from /p). Nothing here writes to a partition.
. ./common.sh
rp() { for r in /sys/class/remoteproc/remoteproc*; do echo "$(basename $r) $(cat $r/name) state=$(cat $r/state) recovery=$(cat $r/recovery 2>/dev/null) fw=$(cat $r/firmware)"; done; }
fwsetup() { mkdir -p /lib/firmware; cp -a fw/. /lib/firmware/; find /lib/firmware -type f | tr '\n' ' '; echo; }
