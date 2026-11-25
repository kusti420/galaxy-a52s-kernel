# ntfs3.ko for the 6.12 line (external module, no KMI change)

Offline only (2026-11-22): built + QEMU-tested, never loaded on a phone, not in any ramdisk yet.

## Result
- GKI 6.12.81 has `# CONFIG_NTFS3_FS is not set` (5.4: `NTFS_FS=y`, read-only driver). `mk.sh` copies the
  UNMODIFIED `bsp612/kernel/fs/ntfs3` sources (tree hash `src.sha`) into `src/` (gitignored) and builds them with
  `../build.sh` as an external module: `out/ntfs3.ko`, 459800 bytes stripped, sha256 73732081c9b78ef5, depends = none,
  vermagic 6.12.81-4k-g8a69376da734.
- Options (`Kbuild.src`): LZX/XPRESS on (reads Windows "compact" files), POSIX ACL off, 64-bit clusters off.
- KMI: 229 imported symbols (`imports.txt`), ALL exported by the GKI vmlinux in `bsp612/out/lahaina/Module.symvers`
  (0 missing; modpost clean). What Kconfig would `select` is already =y in the GKI config: `BUFFER_HEAD`, `NLS`,
  `LEGACY_DIRECT_IO` (`__blockdev_direct_IO` exported), `NLS_UTF8`. `TRIM_UNUSED_KSYMS` is off and
  `MODULE_SIG_PROTECT_LIST=""`, so there is no symbol-list enforcement for an unsigned module: the insmod on the real
  dist Image proves it (no "Protected symbol", only the usual out-of-tree/unsigned taint lines).
  No kernel header, no Image, no other module changes. Rebuild only if the GKI CRCs change.

## QEMU test (`qemu/run.sh`, bsp612/out/dist/Image, virtio-blk disk) = 24/24 PASS
32 MiB image from host `mkntfs` (NTFS 3.1) with two files put in by `ntfscp`:
insmod, ntfs3 in /proc/filesystems, ro mount, read text file, 5 MB file sha256 == host, rw mount with vold-like options
(`rw,nosuid,nodev,noatime,uid=1023,gid=1023,fmask=0007,dmask=0007,iocharset=utf8`), create + write, 3 MB write,
mkdir + rename, UTF-8 file name, unlink, umount, mount again: all read back identical, uid/gid/masks applied,
rmmod, no WARN/BUG. Host cross-check of the image the kernel wrote: `ntfscat` reads the new file, `ntfsls` shows the
UTF-8 name, `ntfsfix -n` reports the volume consistent.

Seen in the test, worth knowing: files CREATED by ntfs3 keep their own owner/mode in WSL extended attributes
($LXUID/$LXGID/$LXMOD), so they show the creator's uid and umask mode (test: `-rw-r--r-- 0 0`) instead of the
mount's uid=/fmask=; files from Windows/mkntfs follow the mount options (`-rwxrwx--- 1023 1023`). Under Android the
creator is the FUSE daemon (MediaProvider); check on a phone that a file written there is readable after a reinsert
and on another device.

## vold side (strings of the port's vold, MonsterROM/out/target/a52sxq/work_dir/system/system/bin/vold)
`system/vold/fs/Ntfs.cpp`: "detected NTFS file system", reads `/proc/filesystems`, " using ntfs3" with
`uid=%d,gid=%d,fmask=%o,dmask=%o,iocharset=utf8`, otherwise " using ntfs3g" -> `/system/bin/ntfs-3g`
("NTFS mount OK using mount.ntfs tool"); check = `/system/bin/ntfsfix`, format = `/system/bin/mkntfs`.
The port's /system/bin has no ntfs-3g/ntfsfix/mkntfs, so on 6.12 without this module an NTFS card or USB drive cannot
mount at all (5.4 mounts it read-only with the old driver; whether this vold accepts plain "ntfs" there was not checked).
vold does NOT modprobe: "ntfs3" must already be in /proc/filesystems when the volume appears.

## Shipping (proposal, not done)
OneUI's vendor is read-only EROFS, so the module cannot be dropped into /vendor/lib/modules: it has to ride in
vendor_boot (our ramdisk fragment) and be loaded at boot, e.g. appended to stage `vibrator` like the other
samsung-oneui modules:
`python3 -I drivers612/samsung-oneui/rd-add-ko.py <in>-rd.cpio.gz <out>-rd.cpio.gz vibrator drivers612/samsung-oneui/ntfs3/out/ntfs3.ko`
Cost: +460 KB uncompressed in vendor_boot, ~0.5 MB kernel memory when loaded, no boot-time work (registers a filesystem).

## Not proven
- Nothing on a phone: vold really choosing ntfs3, SELinux (genfscon/fs_use for "ntfs3" in the OneUI policy: an
  unlabelled filesystem type would mount as `unlabeled`; check `grep ntfs /sys/fs/selinux/...` or the ROM's
  genfs_contexts), MediaProvider/FUSE on top, the WSL-attribute ownership point above, eject while writing.
- Dirty volumes (Windows fast-startup/hibernated, journal replay), compressed and sparse files, large (> 4 GB) files,
  4K-sector USB drives: not tested. ntfs3 refuses a dirty volume rw without `force`.
- insmod order/first-stage simulation with the module inside a real s99x ramdisk (rd-add-ko not run).
