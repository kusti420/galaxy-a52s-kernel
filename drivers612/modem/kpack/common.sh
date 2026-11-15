# sourced by the modem test scripts; run from the pack directory (/p). Writes to no partition.
k() { echo "a52sxq-init: modem: $*" > /dev/kmsg; echo "## $*"; }
ld() { # ld <list> [skip-regex]: insmod every module of <list> (already loaded ones are skipped)
	while read -r m args; do
		case "$m" in ''|'#'*) continue;; esac
		n=${m%.ko}; [ -n "$2" ] && echo "$n" | grep -qE "$2" && { k "SKIP $m"; continue; }
		[ -d /sys/module/$(echo $n | tr - _) ] && continue
		k "insmod $m $args"; insmod m/$m $args 2>&1 || k "FAIL $m"
	done < "$1"
	sh ./mkdevs
}
rp() { for r in /sys/class/remoteproc/remoteproc*; do echo "$(basename $r) $(cat $r/name) state=$(cat $r/state) recovery=$(cat $r/recovery 2>/dev/null) coredump=$(cat $r/coredump 2>/dev/null) fw=$(cat $r/firmware)"; done; }
mss() { for r in /sys/class/remoteproc/remoteproc*; do case "$(cat $r/name)" in *mss*) echo $r; return;; esac; done; }
# UFS partitions only (sd*): the microSD card is never looked at (HARD RULE, 2026-11-14)
part() { for u in /sys/class/block/sd*/uevent; do grep -q "^PARTNAME=$1\$" $u && { basename ${u%/uevent}; return; }; done; }
