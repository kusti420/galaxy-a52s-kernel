# sdfat.ko: file system type "sdfat" on 6.12, forwarded to exfat / vfat (SPEC/03 G7, D15)

Status: **built, QEMU 55/55 (qemu-test/run.sh), not on a phone.** Not in any ramdisk; opt-in.

## Why

The 5.4 Samsung kernel has its own FAT/exFAT driver `sdfat` and no `exfat` type. One UI's vold
(`/system/bin/vold`, K4_UN1CA 9.3.173, strings) reads `/proc/filesystems`, logs
`Use "sdfat" instead of "exfat"` / `... instead of "vfat"` and mounts

    exFAT:  -t sdfat -o fs=exfat,adj_req,iocharset=iso8859-1,utf8,uid=%d,gid=%d,fmask=%o,dmask=%o
    FAT:    -t sdfat -o fs=vfat,smart,delay,adj_req,adj_hid,iocharset=iso8859-1,utf8,uid=%d,gid=%d,fmask=%o,dmask=%o
            (+ ",time_offset=%d")

The same binary also holds the AOSP strings (`uid=%d,gid=%d,fmask=%o,dmask=%o`,
`utf8,uid=%d,gid=%d,fmask=%o,dmask=%o,shortname=mixed`, type names `exfat`, ` vfat`), so it very
likely mounts natively when `sdfat` is not in `/proc/filesystems` (as on 6.12 today). That was read
from strings only, not disassembled: **test A below (no module) decides whether this module is
needed at all.** The module is the fallback for the case that One UI (vold, or something that
checks for sdfat) insists on it.

## What it does

Registers the NAME `sdfat` (`FS_REQUIRES_DEV`, so `/proc/filesystems` shows `\tsdfat`). A mount:

1. `fs=exfat` -> exfat, `fs=vfat|fat|msdos` -> vfat, no `fs=` / `fs=auto` -> exfat tried first, then vfat.
2. Options are filtered by a whitelist per target; everything else (sdfat-only: `smart delay adj_req
   adj_hid defrag symlink= namecase= ...`) is dropped.
   exfat: `uid gid umask dmask fmask allow_utime iocharset errors discard time_offset`
   vfat:  the same + `codepage shortname utf8 tz quiet showexec check flush usefree nonumtail rodir uni_xlate`
3. sdfat `utf8` (UTF-8 names whatever `iocharset` says): exfat gets `iocharset=utf8` (a given
   `iocharset=` is dropped), vfat gets `utf8` and keeps `iocharset=`. vfat also gets
   `shortname=mixed` unless one was given (sdfat keeps the case; same as AOSP vold).
4. `->get_tree()` builds a second fs_context for the target type, parses source + options into it,
   calls the target's `->get_tree()` and moves the root into the caller's context. The caller's
   `vfs_get_tree()` then does SB_BORN + `security_sb_set_mnt_opts()` once.

The superblock belongs to exfat / vfat: `/proc/mounts` shows `exfat` / `vfat`, remount and umount
never touch this module, a mounted card holds no module reference, no file data passes through it.

Imports (18, all GKI vmlinux, CRCs = `bsp612/out/lahaina/Module.symvers` and `out/gki`, 0 mismatches):
`register_filesystem unregister_filesystem get_fs_type fs_context_for_mount vfs_parse_fs_string
vfs_parse_fs_param_source put_fs_context kill_block_super logfc module_put kfree kstrdup strcmp strlen
kmalloc_caches __kmalloc_cache_noprof mem_alloc_profiling_key module_layout`. Exports none, depends none.

## Known differences from real sdfat (ROM side)

- SELinux: One UI labels `sdfat` mounts `vfat` (`genfscon sdfat / u:object_r:vfat:s0`). Through this
  module an exFAT card is an `exfat` superblock -> label `u:object_r:exfat:s0` (FAT stays `vfat`).
  `exfat` is in `sdcard_type` like `vfat`, but a Samsung domain allowed only `vfat` would get an avc
  denial: watch `dmesg | grep avc.*exfat`. ROM fix if it shows: `genfscon exfat / u:object_r:vfat:s0`.
  The same applies to vold's native fallback (test A).
- `/proc/mounts` type is `exfat` / `vfat`, not `sdfat`.
- sdfat's delayed allocation / defrag / `symlink=` are not there (upstream drivers).
- The security step was not exercised with a loaded SELinux policy (QEMU has none).

## Build

    drivers612/samsung-oneui/sdfat-alias/mk.sh      -> out-p1/sdfat.ko + SHA256SUMS

(scratch-copy build with ../build.sh against bsp612/out/lahaina; the bytes are stable for the
default build path: two runs gave the same sha256.)

## QEMU test (offline)

    drivers612/samsung-oneui/sdfat-alias/qemu-test/run.sh    -> PASS (55 checks, 27 of them sdfat)

GKI Image + real 16 MiB exFAT / FAT32 loop images: both vold option strings mount (rc 0) with the
expected `/proc/mounts` line (`exfat rw,...,uid=1023,gid=1023,fmask=0007,dmask=0007,...,iocharset=utf8`
and `vfat rw,...,iocharset=iso8859-1,shortname=mixed,utf8,time_offset=120`), write + UTF-8 name +
owner/mode, native re-mount reads the data back, remount ro, ro mount, no-`fs=` probing, four
failure cases leave nothing mounted, 30 mount/umount rounds, rmmod while mounted, no WARN/BUG.
The same run covers `../sd_ioerror` and `../usb_moisture`.

## On-phone test (One UI on 6.12; LineageOS/IchthysOS never ask for sdfat: nothing to test there)

`$S` = the test phone's serial, always `adb -s $S`. The microSD in the broken-screen phone must never
be written by a test: steps A1 and B1-B3 only read `/proc` and use loop images under /data;
A2 and B4 need a SPARE card (hands).

A. Without the module (decides if it is needed)

    adb -s $S shell su -c 'grep -c sdfat /proc/filesystems; grep -E " (exfat|vfat|sdfat) " /proc/mounts; sm list-volumes public'
    adb -s $S logcat -d -s vold:V | grep -iE 'sdfat|exfat|vfat|mount' | tail -20

  A1 (card already in the phone, passive): expected `0`, a `/mnt/media_rw/XXXX-XXXX exfat|vfat` line and
  `public:179,N mounted XXXX-XXXX` = vold's native path works, **the module is not needed**.
  `unmountable` / no mount line = go to B.
  A2 (hands, spare exFAT card + spare FAT32 card): insert booted, same two commands.

B. With the module (hand push, nothing persistent; gone after reboot)

    adb -s $S push drivers612/samsung-oneui/sdfat-alias/out-p1/sdfat.ko /data/local/tmp/
    adb -s $S shell su -c 'insmod /data/local/tmp/sdfat.ko; grep sdfat /proc/filesystems; dmesg | grep -iE "sdfat|disagrees|Unknown symbol" | tail -3'

  B1 expected: a `sdfat` line without `nodev`, no symbol/CRC message.
  B2 (no card involved): make two images on the PC, mount them with vold's exact strings:

    truncate -s 64M ex.img fat.img; mkfs.exfat ex.img; mkfs.vfat -F 32 fat.img
    adb -s $S push ex.img fat.img /data/local/tmp/
    adb -s $S shell su -c 'mkdir -p /mnt/t1 /mnt/t2; L1=$(losetup -f -s /data/local/tmp/ex.img); L2=$(losetup -f -s /data/local/tmp/fat.img);
      mount -t sdfat -o fs=exfat,adj_req,iocharset=iso8859-1,utf8,uid=1023,gid=1023,fmask=7,dmask=7 $L1 /mnt/t1; echo rc=$?;
      mount -t sdfat -o fs=vfat,smart,delay,adj_req,adj_hid,iocharset=iso8859-1,utf8,uid=1023,gid=1023,fmask=7,dmask=7 $L2 /mnt/t2; echo rc=$?;
      grep -E " /mnt/t[12] " /proc/mounts; echo x > /mnt/t1/a; echo x > /mnt/t2/a; ls -lZ /mnt/t1 /mnt/t2;
      umount /mnt/t1 /mnt/t2; losetup -d $L1 $L2; dmesg | grep -E "avc.*(exfat|vfat|sdfat)|WARNING" | tail'

  expected: `rc=0` twice; `... /mnt/t1 exfat rw,...uid=1023,gid=1023,fmask=0007,dmask=0007,...iocharset=utf8...`;
  `... /mnt/t2 vfat rw,...shortname=mixed,utf8...`; files owned media_rw, labels `u:object_r:exfat:s0` /
  `u:object_r:vfat:s0`; no WARNING. (`su` is unconfined; the vold-domain avc check is B4.)
  B3: `adb -s $S shell su -c 'rmmod sdfat; grep -c sdfat /proc/filesystems'` -> `0`.
  B4 (hands, spare card): `insmod`, then insert the card; `logcat -s vold` shows
  `Use "sdfat" instead of "exfat"`, `sm list-volumes public` = `mounted`, the Files app lists the card,
  copy a file to it and back, eject from Settings, pull. `dmesg | grep avc` must show nothing for vold.

Shipping it (only if A fails and B passes): add `sdfat.ko` to the One UI ramdisk module list
(rd-add-ko.py; any position, it has no dependencies). Not for LineageOS/IchthysOS.
