# KernelSU-Next on the 6.12 real boot (LKM mode, GKI Image unchanged)

State 2026-11-19: proven on broken screen (PHONE1, IchthysOS user build), build rbich20 =
rbich19 (s95w + VOLKEY=1 + DEBUG=1) + this, installed with the any-ROM zip.

* Version: KernelSU-Next **v3.4.0** (kernel version 33294). The ROM's 5.4 kernel has v3.4.0-legacy built
  in (`$ANDROID_TREE/kernel/samsung/sm7325/KernelSU-Next`, CONFIG_KSU=y); the manager is
  `com.rifsxd.ksunext` v3.4.0 (33294), upstream release APK
  `KernelSU_Next_v3.4.0_33294-release.apk` (sha256 50339a93c0f8...), official signature = the hash the
  module expects by default. Which manager version the daily phone has was not read (not this
  agent's phone): check it is 3.4.x.
* Why not a first-stage insmod: `kernelsu.ko` uses 10 symbols the GKI does not export (path_umount,
  strncpy_from_user_nofault, kallsyms_lookup_size_offset, __tracepoint_sys_enter, init_mm, __set_fixmap,
  copy_to_kernel_nofault, dcache_clean_inval_poc, selinux_blob_sizes, mntns_operations). Upstream's
  loader `ksuinit` rewrites them to absolute addresses from /proc/kallsyms before init_module.
* How it is started here: `/ksuinit` and `/kernelsu.ko` sit in the root of OUR vendor_boot ramdisk
  fragment; the vendor cmdline has `rdinit=/ksuinit`. The kernel runs ksuinit as PID 1; it loads the
  module and execs the ROM's own `/init` (boot ramdisk, not replaced: upstream replaces /init in the boot
  image, which the any-ROM zip must not do). Then as upstream: second-stage hook, sepolicy rules, init.rc
  injection, ksud from the manager in /data/adb.
* Crash guard (our patch): a ramoops panic record of the previous boot (`/sys/fs/pstore/dmesg-*`) means
  that boot died: kernelsu.ko is NOT loaded for this one boot and the record is removed. A module that
  kills the kernel therefore cannot loop the phone (every second boot comes up, without root). Side
  effect: after ANY kernel panic the next boot has no root; reboot once more. The panic text stays in
  console-ramoops (previous console) for that boot. Seen working: the first rbich20 boot skipped
  KernelSU because rbich15's panic record was still in ramoops; the next boot loaded it.
* Proof: QEMU boot of the exact diag Image with rdinit=/ksuinit (`qemu-console.txt`: module loads, real
  init runs as PID 1). Phone: manager 'Working, LKM (GKI2), v3.4.0 (33294), hook mode Tracepoint';
  `/system/bin/su -c id` from the adb shell = `uid=0(root) ... context=u:r:ksu:s0` after enabling
  Superuser for Shell in the manager; SELinux Enforcing; bench subset 11/11, 0 kernel WARN. (`su`
  without a path finds the ROM's /system/xbin/su first in the adb shell.)
* Cosmetic: the ROM's init logs with the tag "ksuinit" (argv[0] is passed on unchanged).
* Not available in LKM mode: SUSFS and anything else that needs kernel-source patches (Image rebuild).
  Manager modules: not tried (no metamodule installed).
* Build: `./build.sh` (needs donors/KernelSU-Next; clones it). Package by hand: `./mkimg.sh <base rb
  dir> <name>` then `twrp/mk-ak-zips.sh`. Wanted: `KSU=1` in build-realboot.sh doing what mkimg.sh does.
* Built-in route (not needed): CONFIG_KSU=y in the GKI = a new Image = unproven kernel; only if SUSFS
  is required.
