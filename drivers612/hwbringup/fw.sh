# sourced: read-only firmware access. fwlink <glob>... links files from the phone's firmware partitions into /lib/firmware
part() { for u in /sys/class/block/*/uevent; do grep -q "^PARTNAME=$1\$" $u && basename ${u%/uevent}; done; }
fwmount() { mkdir -p /fw/apnhlos /fw/modem /fw/dsp /lib/firmware
  grep -q /fw/apnhlos /proc/mounts || mount -t vfat -o ro /dev/$(part apnhlos) /fw/apnhlos
  grep -q /fw/modem /proc/mounts || mount -t vfat -o ro /dev/$(part modem) /fw/modem
  cp -n fw/* /lib/firmware/ 2>/dev/null; }
fwlink() { for g in "$@"; do for f in /fw/apnhlos/image/$g /fw/modem/image/$g; do [ -e "$f" ] && ln -sf $f /lib/firmware/; done; done; }
