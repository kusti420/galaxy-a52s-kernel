# androidboot: Android userspace on the Qualcomm 6.12 GKI kernel (A52s)

Nothing here has run on a phone. Everything was built and checked offline on 2026-11-11.
Nothing in this directory flashes; the main session does that, on the test phones only.

## What is here

| File | What |
|---|---|
| `pack-android-612.sh` | builds the recovery-format Android TEST image from a ROM's partition dumps |
| `images/a52sxq-android612-los1-recovery.img` | built from `testdev-PHONE2` (LineageOS userdebug, test phone 2). NOT flashed |
| `a52init/a52init.c` | `/init` wrapper: forks the test helper, execs the ROM's first-stage init |
| `testguard/` | kernel module: userdata held, misc/metadata/EFS read-only, reboot-recovery redirect. Builds against bsp612, depmod clean |
| `adb_debug.prop` | property overrides (adb without keys), loaded through AOSP's debug-ramdisk path |
| `export-prebuilt.sh` | stages `out/prebuilt/6.12/` = the prebuilt kernel directory the ROM patches expect |
| `patches/0001..0003` | ROM device-tree patches (NOT applied; `patch -p1 --dry-run` passes in `$ANDROID_TREE/device/samsung`) |
| `GKI-COMPAT.md` | what a 5.4-era vendor + Android 16/17 system expect from the kernel, and where 6.12 GKI differs |

Build: `./pack-android-612.sh <name>` (options in the script header). `MODSET=all` packs all
372 loadable modules (ramdisk 20 MB, still inside the 81 MiB limit).

## Design of the test mode

Goal: boot the INSTALLED ROM's system/vendor/product from super with our kernel, from the
recovery partition, without being able to hurt that installation.

1. **Image format**: header v2, same offsets, dtb (`yupik.dtb`), recovery dtbo (bring-up
   overlay), AVB hash footer as `bsp612/mkimage-612.sh`. OS version / patch level are copied
   from the ROM's boot.img header.
2. **Ramdisk** = the ROM's `boot.img` ramdisk byte for byte (generic first-stage init, device
   nodes) followed by our overlay cpio. The kernel unpacks concatenated archives in order; this
   is the same mechanism as vendor_boot + boot on a normal boot. The overlay adds:
   - `/init` = `a52init`, `/init.android` = the ROM's first-stage init (extracted, unchanged);
   - `/lib/modules/` flat (what first-stage init reads when there is no `<uname -r>` directory):
     `*.ko`, `modules.load` (testguard.ko first, then the bsp612 bring-up order, zram, sec_core),
     `modules.load.recovery` (same), `modules.dep` (depmod, paths relative to the directory),
     `modules.alias`, `modules.softdep`, `modules.options` (`zram num_devices=3`,
     `sec_core clear_on_load=0`), `modules.blocklist`. GKI modules keep their signature
     (not stripped); vendor modules are stripped of debug info;
   - `/first_stage_ramdisk/fstab.qcom` and `/fstab.qcom` = first-stage fstab: ONLY the logical
     partitions (system, vendor, product, odm; ext4/f2fs/erofs alternatives as the ROM has them),
     read-only. No metadata (the ROM's entry is `formattable`: a failed mount on the new kernel
     would reformat the partition holding the userdata key), no avb (the ROM has none);
   - `/a52test/bind/fstab.qcom` = second-stage fstab, bound over `/vendor/etc/fstab.qcom`:
     `/data` = `/dev/block/zram1` ext4 `formattable`, `/metadata` = `/dev/block/zram2`, every
     real ext4 partition (cache, persist, efs, sec_efs, dsp) `ro,noload`, userdata absent;
   - `/force_debuggable` + `/adb_debug.prop`.
3. **Normal boot from the recovery partition.** First-stage init decides "recovery" by the
   presence of `/system/bin/recovery` in the ramdisk (`IsRecoveryMode()`), not by a bootloader
   flag. The boot.img ramdisk has no such file, so this IS a normal boot and
   `androidboot.force_normal_boot=1` is not needed (it exists for ramdisks that contain
   recovery: it makes init switch root into `/first_stage_ramdisk` and use `modules.load`
   instead of `modules.load.recovery`; `FNB=1` adds it). What the Samsung ABL adds when it
   boots the recovery partition (seen in `testdev-PHONE2/pstore-p2-first.txt`):
   `androidboot.boot_recovery=1` (becomes `ro.boot.boot_recovery`; AOSP init ignores it, the
   Samsung blobs may read it), `androidboot.fstab_suffix=default` (no `fstab.default` exists
   anywhere, so the lookup falls through to `androidboot.hardware=qcom`),
   `androidboot.boot_devices=soc/1d84000.ufshc`, `androidboot.verifiedbootstate=orange`,
   `androidboot.dtbo_idx/dtb_idx`, serial, revision. It replaces `console=`. Header v2 has no
   bootconfig; init reads `androidboot.*` from `/proc/cmdline` as well.
4. **Logical partitions.** liblp + dm-linear, both satisfied by GKI (`BLK_DEV_DM=y`); no
   dm-verity (fstab has no avb flags, vbmeta flags 3), no snapuserd/dm-user (not A/B, no
   Virtual A/B). ext4, f2fs, erofs are built into GKI.
5. **SELinux**: `androidboot.selinux=permissive`. Honoured only by a userdebug/eng init
   (`ALLOW_PERMISSIVE_SELINUX`, compile time); LineageOS on phone 2 is userdebug. The helper
   NEEDS permissive: it stays in the kernel domain and its bind sources carry tmpfs labels.
   **User builds (the One UI port on phone 1) ignore the option**: there the shims would need
   labelled copies on a real filesystem before the policy loads (redwood put them on /metadata
   with xattrs); not implemented, and /metadata must not be written here.
6. **adb**: `adb_debug.prop` is loaded by second-stage init after all build.props
   (`/debug_ramdisk/adb_debug.prop`, needs `/force_debuggable` in the ramdisk and an unlocked
   bootloader): `ro.adb.secure=0`, `ro.debuggable=1`, `persist.sys.usb.config=adb`. The ROM's own
   `init.qcom.usb.rc` then builds the configfs gadget on `a600000.dwc3`
   (`androidboot.usbcontroller`); GKI has configfs + FunctionFS built in. dwc3-msm needs device
   mode requested by hand on this kernel: the helper writes `peripheral` to
   `/sys/devices/platform/soc/a600000.ssusb/mode` (bsp612/BRINGUP.md).
   **The phone then shows up with its normal serial**; tell it apart with
   `adb shell getprop ro.a52.androidtest` (= 1) and `uname -r`.
7. **Safety net** (`testguard.ko`, first module): refuses to run without `a52.androidtest=1`;
   claims userdata exclusively + block-level read-only (no mount, no dm-default-key table, no
   raw write); misc, metadata, efs, sec_efs, persist, cache, param, steady, persistent,
   keydata, keyrefuge, modemst1/2, fsg, fsc block-level read-only; `reboot recovery` becomes
   `reboot download`; if userdata or misc are not found within 30 s it restarts into Download
   mode. The helper restarts into Download mode if the fstab bind fails or after the dead-man
   time (`DEADMAN`, 600 s; stop it with `adb shell touch /dev/.a52test/keep`).
   Leaving: `adb shell reboot download` (init -> sec_core writes PON reason 0x15) then the
   harness's `heimdall print-pit`.
8. `/data` on zram, not tmpfs: pure GKI 6.12 has `TMPFS_XATTR` and `TMPFS_POSIX_ACL` off; the
   other SM7325 port needed the ACLs (vold's default ACL on `/data/media/0`; without it user 0
   was destroyed and apps crash-looped). ext4 on zram has both. zram0 is left to the ROM
   (`fstab.ramplus` swap). `DATA=tmpfs` exists for a kernel built with those options.

## Order of experiments (main session)

The harness (`test-cycle.sh`) expects the telnet ramdisk; for these images it must wait for an
adb device with `ro.a52.androidtest=1` instead, and fall back to the ramoops log
(`/sys/fs/pstore/console-ramoops-0` from the next normal boot) when nothing appears. Log lines
below are from the AOSP sources of this tree and from our own code; `a52test:` and
`testguard:` lines are exact.

Before step 1, one bring-up boot of the busybox ramdisk (`bsp612/mkimage-612.sh`) must have
shown: the 89 first-stage modules load, UFS partitions appear, USB device mode works,
`reboot download` works. This image depends on all four.

| # | Experiment | Expected log | If not |
|---|---|---|---|
| 1 | Flash `los1`, boot. First-stage init starts | `a52test: helper started`; `init: init first stage started!` | neither line: kernel died before the ramdisk or ramdisk rejected (check the lz4 legacy double-archive: unpack error `Initramfs unpacking failed`). Only the first: `/init.android` exec failed (`a52test: exec /init.android failed`) |
| 2 | Modules | `testguard: holding sdaNN (userdata) exclusively, read-only`; `testguard: armed (...)`; `init: Loaded 93 kernel modules took N ms`; `a52test: zram1 (/data) ...` | `testguard: ... restarting into download`: cmdline lost `a52.androidtest=1` or UFS never probed. A module error line `init: Failed to insmod` is not fatal here (`androidboot.first_stage_console=1` makes the load non-strict on userdebug) but everything after it in modules.load was skipped: fix the order |
| 3 | super, read-only | `init: [libfs_mgr] Created logical partition system on device /dev/block/dm-0` (vendor, product, odm likewise), `init: Switching root to '/system'` | `partition(s) not found after polling timeout: super` = no by-name links: UFS missing or `androidboot.boot_devices` not passed. `Failed to mount /system`: filesystem type (all three are in GKI) or dm. Either ends in init's fatal reboot -> `download` |
| 4 | Shims | `a52test: bound over /vendor/etc/fstab.qcom`, `a52test: shims in place`, `a52test: usb: peripheral mode requested` | `bind failed` -> the helper restarts into Download mode on purpose. `can't enter init's mount namespace`: kernel refused setns (should not happen as root in permissive) |
| 5 | Second stage | `init: init second stage started!`, `init: Loading /debug_ramdisk/adb_debug.prop`, SELinux `Permissive` in `SELinux: ... enforcing=0` | reboot right after policy load = enforcing ROM (user build) or the 5.4-era vendor policy fails to compile against Android 17's kernel classes; read the `selinux:` lines |
| 6 | Early mounts | `/dev/block/zram2` formatted and mounted on /metadata (`fs_mgr: ... formatting ... zram2`), efs/persist `ro,noload` mounted | `mount_all` errors for efs/persist are survivable. `zram2` missing: zram.ko or `num_devices=3` not applied (`cat /sys/block/zram2/disksize`) |
| 7 | Late mounts | `/data` on `/dev/block/zram1` (formatted on first boot), `vold` prepares user 0 | any attempt on userdata shows as `testguard`-caused `EBUSY`/read-only errors: the bind did not take. Encryption complaints: the test fstab has no `fileencryption`, /data is plain |
| 8 | adb | USB device with the phone's serial; `adb shell getprop ro.a52.androidtest` = `1`; `uname -r` = `6.12.81-4k-...` | no device: check `a52test: usb:` line, `/sys/class/udc` (must hold `a600000.dwc3`), `getprop sys.usb.config/state`, FunctionFS mount `/dev/usb-ffs/adb` |
| 9 | How far does Android get | `adb logcat -b all`, `dmesg`, `getprop sys.boot_completed`, `lshal` | expected to stop at the first HAL that needs a missing driver: servicemanager/hwservicemanager/vold/keymint(QSEECOM) first, then gralloc/composer (no display driver), audio. Each is a forward-port item of the other drivers612 agents; add their `.ko` with `EXTRA_MODULES=` and repeat |
| 10 | Leave | `adb shell touch /dev/.a52test/keep` to stay; `adb shell reboot download` to leave; or wait for `a52test: dead-man timer expired` | stuck in a loop back into this image: sec_core did not load (`a52test: sec_core never loaded`), so `download` was a plain restart and the ABL's sticky recovery flag re-enters; needs the keys once (Vol Down+Power, then Download mode round trip) |

Not covered by anything here, needs the keys if it happens: a kernel hang before the helper
starts, and a hard hang later (no watchdog is armed: `hhwdt` is petted by the busybox init
only; Qualcomm's `gh_virt_wdt` is blocked because its time units are unproven on this phone).

## Risks / unverified

- Never run on hardware: the concatenated-ramdisk layout, the helper's namespace switch and
  `modules.options` handling are from source reading (init, libmodprobe, kernel initramfs).
- The `ro,noload` mounts of efs/sec_efs/persist break anything that must write there (RIL NV
  backup, sensors calibration, Wi-Fi MAC cache). Fine for first boots; do not judge the modem
  from this mode.
- The test fstab is derived from the vendor_boot copy of fstab.qcom; LineageOS installs the same
  file in /vendor (checked against the ROM tree), a ROM where they differ needs `BIND=`.
- The ROM patches were only dry-run applied, never built (`$ANDROID_TREE` is read-only here).
  The LineageOS prebuilt-kernel variables were read from `vendor/lineage/build/tasks/kernel.mk`.
