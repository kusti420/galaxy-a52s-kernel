# SUSFS on the 6.12 kernel (Image variant for the OneUI 9 port)

Status 2026-11-22: **built and QEMU-proven offline. Never booted on a phone.** The Image differs from every Image
that has booted on hardware, so the first use needs the covering rehearsal and a real boot on broken screen
(section 7). Nothing in this directory flashes anything.

## 1. What it is

`bsp612/out/susfs/Image` = the bsp612 GKI kernel (same source commit, same `.config` apart from `CONFIG_KSU*`,
release `6.12.81-4k-g8a69376da734`) with three additions:

| Part | Version | Source |
|---|---|---|
| ReSukiSU, **built in** (`CONFIG_KSU=y`) | 8770c7e3 = v4.2.0-rc3-32-g8770c7e3, version code 35203, name `v4.2.0-rc3-8770c7e3@ReSukiSU`, "Work mode: Built-in" | `donors/ReSukiSU` (cloned into the kernel copy as `KernelSU/`, `drivers/kernelsu` -> `../KernelSU/kernel`). Same commit as the LKM (`build.sh`) and as the port's 5.4 kernel |
| SUSFS kernel side | **v2.3.0**, variant `GKI` | `donors/susfs4ksu` = https://gitlab.com/simonpunk/susfs4ksu branch `gki-android16-6.12` at **b213c54126fb243595ce7876e91d84d6e0861fec** (2026-09-26): `kernel_patches/50_add_susfs_in_gki-android16-6.12.patch`, `fs/susfs.c`, `include/linux/susfs.h`, `susfs_def.h` |
| a52bc (breadcrumbs + RAM console at 0xf0be0000) | a52bc.c 7a6669fc... | `drivers612/realboot/kernel-diag`, as `bsp612/out/diag/Image` (the Image `build-realboot.sh DIAG=1` packs) |

The manager certificate allowlist is ReSukiSU's own built-in one (EXPECTED_HASH_RESUKISU d3469712...,
`KSU_MULTI_MANAGER_SUPPORT=y`), the same as in the LKM build and in the 5.4 kernel; nothing was changed in ReSukiSU.

### Why built in and not the LKM

SUSFS cannot work with ReSukiSU as a module. The SUSFS patch puts calls into vmlinux (`fs/exec.c`, `fs/open.c`,
`fs/stat.c`, `fs/read_write.c`, `kernel/sys.c`, `kernel/reboot.c`, `drivers/input/input.c`, selinux) to
`ksu_handle_execveat`, `ksu_handle_faccessat`, `ksu_handle_stat`, `ksu_handle_sys_read`, `ksu_handle_setresuid`,
`ksu_handle_sys_reboot`, `ksu_handle_input_handle_event` and reads KSU state (`susfs_ksu_sid`, static keys); vmlinux
cannot link against symbols of a module. ReSukiSU's Kconfig says the same: `KSU_SUSFS` is one of the three hook
methods (tracepoint / manual / SUSFS inline), and the LKM recipe is tracepoint only. So in this variant
**there is no kernelsu.ko, no /ksuinit and no `rdinit=`**; KernelSU starts from an initcall at ~0.7 s.

### Why this susfs4ksu commit

ReSukiSU's `tools/inline_hook_check.mk` fails the build when a hook is missing, and the link fails when the patch
calls something ReSukiSU does not export. Checked for every commit of the branch:

* b213c54 (2026-09-26) and older: every `ksu_*` symbol the patch calls exists in ReSukiSU 8770c7e3.
* acb92d4 (10-15) .. 291d571: need `my_security_*` (selinux_hide rework) -> not in 8770c7e3.
* 1ac091c (10-19) .. 746b92a (10-23): need `my_setprocattr`, `my_write_context`, `my_write_access` (static in
  ReSukiSU's selinux_hide.c) and `ksu_setup_preinit_file`, `ksu_preinit_handle_post_execveat` (absent). Tried:
  link fails with exactly these five.
* 97cbbaf (10-24) and later: priority_uid_filter, v2.4.0: newer than this ReSukiSU (no Kconfig for it).

b213c54 is also the state of the port's 5.4 patch (`k4-patches/0018-susfs-v2.3.0-for-5.4.patch`): its `susfs.h` is
identical to the 5.4 tree's up to one type fix, and like 5.4 it has no SUSFS selinuxfs hooks (ReSukiSU's own
selinux_hide does that through its auto hook: "registered handler for selinux_hide" in the log).

Two hunks of the upstream patch do not apply on 6.12.81 (the include block of `fs/exec.c`, where our tree has
`dma-buf.h`, and `show_smap()` in `fs/proc/task_mmu.c`, `vma_data_pages`); both are re-done verbatim by
`susfs/0001-susfs-rejected-hunks-for-6.12.81.patch`. `build-susfs-image.sh` refuses any other reject.

## 2. Features (= the port's 5.4 `k4-source/susfs/susfs.config`)

| Option | 5.4 port | 6.12 variant |
|---|---|---|
| `CONFIG_KSU=y`, `KSU_MULTI_MANAGER_SUPPORT=y` | y | y |
| `KSU_TRACEPOINT_HOOK`, `KSU_MANUAL_HOOK`, `KSU_DEBUG`, `KSU_TOOLKIT_SUPPORT` | off | off |
| `KSU_SUSFS` (inline hooks) | y | y |
| `KSU_SUSFS_SUS_PATH` | y | y |
| `KSU_SUSFS_SUS_MOUNT` | y | y |
| `KSU_SUSFS_SUS_KSTAT` | y | y |
| `KSU_SUSFS_SPOOF_UNAME` | y | y |
| `KSU_SUSFS_ENABLE_LOG` | y | y |
| `KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS` | y | y (QEMU: 0 `susfs`/`ksu_` names in /proc/kallsyms) |
| `KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG` | y (/proc/cmdline, non-GKI) | y (**/proc/bootconfig**: the GKI variant spoofs that file, not /proc/cmdline) |
| `KSU_SUSFS_OPEN_REDIRECT` | y | y |
| `KSU_SUSFS_SUS_MAP` | y | y |

`susfsq` in QEMU (the same call as `ksud susfs show enabled_features`) lists exactly these nine `KSU_SUSFS_*`.
There is no `sus_su` and no `try_umount` option in v2.3.0 (umount = ReSukiSU's own kernel_umount feature, present).
Not part of this variant (5.4 has them, nothing in the ROM reads them): NoMount (`CONFIG_NOMOUNT`), Baseband-Guard
LSM (`CONFIG_BBG`), the k4 0007 native `newfstatat`/`statx` sucompat patch (the SUSFS inline hook in `fs/stat.c`
covers `ksu_handle_stat` on 6.12; a granted 64-bit app's `stat("/system/bin/su")` still has to be checked on the phone).

## 3. KMI / module compatibility: nothing to rebuild

* The patch touches **no header** (29 tracked files, all `.c`/Makefile/Kconfig; list in
  `bsp612/kernel-susfs/.a52-susfs-files`). SUSFS keeps its state in spare high bits of existing words (`inode->i_mapping->flags` bits 33-39,
  `thread_info.flags` bits 33-35: `susfs_def.h`), as upstream designed it for GKI, so no struct that a module
  sees changes. (Those bits are unused by GKI 6.12.81 and by our modules' sources; a module that started to use
  them would clash silently.) `pahole --sizes` over both vmlinux: the only types that differ are file-local ones in
  `fs/readdir.c` (`getdents_callback*`).
* `vmlinux.symvers` of the variant vs `bsp612/out/gki`: **19062 exports, 0 CRC changed, 0 missing, 0 new**
  (`bsp612/out/susfs/crc-changed.txt` is empty; ReSukiSU built in exports nothing).
* Every import of every module checked against the variant (`susfs/crc-compare.py`, reads `__versions`): the 279
  first-stage modules of rbou5d + the two LKM kernelsu.ko: **281 modules, 18122 imported symbols, 0 mismatches**.
* vermagic unchanged (same release string; the patched files are `assume-unchanged` in the copy's index).
* QEMU: the ROM's first-stage init loads the same 213 modules as on the diag Image, 0 "disagrees about version",
  0 "Unknown symbol".

So the existing module set (any `REF=` ramdisk built for 6.12.81-4k-g8a69376da734) is used unchanged; there is no
separate module dist dir. `build-susfs-image.sh` re-checks this on every build and writes the verdict into
`bsp612/out/susfs/BUILDINFO` (`modversion CRCs: ... identical`); the proposed build-realboot option refuses a
variant without that line. Rebuild-on-Image-change notes elsewhere (freecess: binder struct layouts) do not apply:
no layout changed.

What does differ: Image size 0x28b0000 -> 0x2920000 (+448 KiB; boot budget in the trial build: image + ramdisks
0x4237000 of 0x517e000), `/proc/version` build number and date (`#1 ... Nov 22 19:35:04`, diag: `#7 ... Nov 14`),
`/proc/config.gz` gains the `CONFIG_KSU*` lines.

## 4. QEMU smoke test (offline, `./qemu-susfs-test.sh`)

Results in `qemu-susfs-console.txt` and `qemu-susfs-initrd.txt` (final Image 4931de43...):

1. busybox initrd + `out/susfsq` (static Rust tool, `susfs/susfsq/susfsq.rs`: `reboot(0xDEADBEEF, 0xFAFAFAFA,
   CMD_SUSFS_SHOW_*, &buf)`, the supercall `ksud susfs show version|variant|enabled_features` makes; ksud itself is
   a bionic binary and is not run here): `KernelSU: Initialized with driver version: 35203, full_version:
   v4.2.0-rc3-8770c7e3@ReSukiSU, ... Work mode: Built-in`, `susfs is initialized! version: v2.3.0`,
   **`susfs version: v2.3.0`, `susfs variant: GKI`**, nine features, kallsyms hidden, **0 WARN/BUG/Oops**.
2. The initrd of a OneUI 9 build exactly as the ABL hands it over (vendor ramdisk + ROM boot ramdisk), no `rdinit=`:
   `Run /init as init process`, `init first stage started`, 213 modules loaded (= rbou5d on the diag Image), 0 module
   refusals, 0 WARN/BUG/Oops. Run for rbou5d's initrd (ksuinit/kernelsu.ko are dead files there) and for the trial
   package below (no such files).
3. a52bc: `kernel-diag/qemu-test.sh` on the variant (output redirected to `bsp612/out/susfs/qemu`): PASSED
   (breadcrumb page, RAM console, attempt counter).

## 5. Packaging: proposed `KSU_BUILTIN=1` for build-realboot.sh

`susfs/build-realboot-KSU_BUILTIN.proposed.diff` (NOT applied; build-realboot.sh belongs to the kernel line). It adds
`KSU_BUILTIN=1` (alias `SUSFS=1`; 6.12 + `DIAG=1` only):

* `IMAGE` defaults to `bsp612/out/susfs/Image`; refuses `KSU=1` (so no /ksuinit, no kernelsu.ko, no `rdinit=/ksuinit`;
  the existing `KSU=0` read-back already fails if either file is in the vendor ramdisk);
* checks: System.map has `susfs_init` + `ksu_handle_susfs_cmd`, the variant's BUILDINFO says the CRCs are identical;
  the other way round, a SUSFS Image without `KSU_BUILTIN=1` is refused;
* `ksu_builtin=1` in the build's BUILDINFO (flash-rb.sh / zip builders can key on it).

Without the diff the same package can be made today with `IMAGE=$PWD/bsp612/out/susfs/Image DIAG=1 KSU=0 ...` (the
Image passes every DIAG check); the option only adds the guards. Gotcha: `QEMU_TEST=1` (default) runs
`kernel-diag/qemu-test.sh "$IMAGE"`, which rewrites `bsp612/out/diag/qemu` with the variant's results.

Tried with a temporary patched copy of the script (deleted again): `KSU_BUILTIN=1 QEMU_TEST=0 DUMP=testdev-PHONE1/
oneui9-9.3.160 REF=s99tb ... build-realboot.sh susfs-trial-5d` -> `drivers612/realboot/out/susfs-trial-5d`, all
offline checks pass, vendor cmdline = rbou5d's minus `rdinit=/ksuinit`, modules.load identical, vendor ramdisk =
rbou5d's minus /ksuinit and /kernelsu.ko, boot.img kernel = the variant. **That directory is a packaging trial only**
(its option list was reconstructed from rbou5d's BUILDINFO, dtb and a52sxq_dsp_boot.ko differ from rbou5d): do not
flash it; build the real one with the kernel line's own command line, `KSU=1 KSU_DIR=...` replaced by `KSU_BUILTIN=1`.
`KSU_BUILTIN=1 KSU=1` exits with the refusal (tried).

`tools/qemu-initrd-check.sh` counts "Loaded kernel module" lines without `printk.devkmsg=on`; on a build without
ksuinit it prints a small number (4-9) although all modules load. `qemu-susfs-test.sh RB=<dir> BASE_N=213` counts
properly.

## 6. How the ROM finds it

Nothing in the ROM has to change.

* `susfs_defaults` (MonsterROM `target/a52sxq/patches/susfs_defaults`, runs in `u:r:ksu:s0` after boot_completed):
  `/data/adb/ksu/bin/ksud susfs show version` now succeeds (same supercall as `susfsq`), so it goes on instead of
  logging "susfs not available": `hide_sus_mnts_for_non_su_procs 1`, `enable_avc_log_spoofing 1`, one-time cleanup,
  one-time seed of ksud's persisted config. Its `set_uname 5.4.302-bone-machine-qgki` line stays skipped on 6.x
  (`ro.boot.a52sxq.k612vb=1`). The ROM's ksud (manager 35222) already talks to a v2.3.0 kernel on 5.4.
  Log: `/data/adb/.susfs_defaults.log` ("susfs v2.3.0", "hide_sus_mnts=1", "avc_log_spoofing=1").
* `kernel_check` (kernel_feature_check): reads `CONFIG_KSU` from /proc/config.gz; the variant has `CONFIG_KSU=y`
  there, so the `kernelsu` minor item of ONEUI9-KERNEL-INVENTORY.md top list 5 goes away (kallsyms shows no ksu
  symbols by design).
* `ksu_metamodule` / meta-overlayfs, `metamod_gate`, `pif_cleanup`, gpudrv guard: need only ksud + the ksu domain,
  as with the LKM.
* Visible changes vs the LKM boot: no `rdinit=/ksuinit` in /proc/cmdline any more (one tell less;
  `androidboot.a52sxq.k612vb=1` stays), no `kernelsu` in /proc/modules, `/sys/module/kernelsu` absent (anything
  that probes that path for the 6.x line must use `ksud` instead), `ksud susfs show version` = v2.3.0.
* Phone check after a boot: `verify-oneui9.sh <serial>` (init.svc.susfs_defaults and the other ksu-domain jobs), the
  log above, plus
  `su -c /data/adb/ksu/bin/ksud susfs show version` and `show enabled_features`.

## 7. Risks, and what has to happen before a phone sees it

* **boot.img changes.** Every 6.12 real boot so far used the diag Image (boot.img 7a94e8b0 on the Lineage line).
  This is a different kernel binary: `flash-rb.sh` rightly refuses it without `NEWBOOT_OK=1`. Order: (1) the kexec
  rehearsal of the KSU_BUILTIN build on broken screen (it executes this Image, the ROM first stage, ksud, the
  `u:r:ksu:s0` jobs and susfs_defaults), (2) only then a real boot on **broken screen** (PHONE1), restore path
  ready (/cache/a52rb-rollback, restore zip, odin tar), (3) never on the daily phone or a tester's phone before that.
* **No crash guard.** The LKM route has ksuinit's guard (a ramoops panic record = KernelSU skipped for one boot).
  Built in, KernelSU and the SUSFS hooks are always active; a boot loop caused by them is left only by restoring
  the previous boot.img. KernelSU safe mode (volume-down) disables modules, not the kernel hooks.
* **Hooks on hot paths, never run on this hardware**: inline hooks in execve, openat/faccessat, stat, read, readdir,
  namei, mount namespace/proc mounts, statfs, kallsyms, input events, avc logging. QEMU shows only that they do not
  break boot + first stage. Unknown on the phone: SUS_MOUNT's fake mnt_id window until /sdcard is decrypted (its
  sdcard monitor watches /data/media/0/Android) together with FBE/ICE_RAW, the Samsung security stack (PROCA, FIVE,
  Knox TIMA paths were never run with these hooks on 6.12), performance of the path hooks.
* **Root method changes for existing installs**: /data/adb stays, but the kernel now reports "Built-in" (GKI hook
  type inline) instead of LKM; manager 35222 handled the built-in 5.4 kernel, so this is expected to be fine.
* **Not the IchthysOS / any-ROM line**: that line keeps KernelSU-Next as LKM on the plain diag Image. A package
  with this Image on a ROM without the ReSukiSU manager still has root hooks active for whoever installs a manager
  with the allowlisted certificate; ship it only inside the OneUI 9 switcher slot.
* **Detection is not proven better.** SUSFS on = the ROM's defaults (hide sus mounts, avc log spoofing) work as on
  5.4. Still visible: real uname 6.12.81 (deliberately not spoofed, see susfs_defaults), 279 modules, taint,
  /proc/bootconfig untouched unless configured. Compare a detector app on 5.4, 6.12 LKM and this variant.
* susfs4ksu is pinned to a two-month-old commit because ReSukiSU is pinned; moving one means moving both (and the
  ROM's manager/ksud), as on 5.4.

## 8. Build steps

```
# once: donors/ReSukiSU (full history) exists after ./build.sh; donors/susfs4ksu is cloned by the script
drivers612/realboot/modules/resukisu/build-susfs-image.sh        # prepare + build, ~3 min clean, 30 s incremental
drivers612/realboot/modules/resukisu/qemu-susfs-test.sh          # ~15 s; RB=<build dir> BASE_N=213 for a KSU_BUILTIN build
```

* `prepare` (once): reflink copy `bsp612/kernel` -> `bsp612/kernel-susfs` (the main tree and `out/gki`, `out/diag`,
  `out/dist` are never touched), upstream SUSFS patch + `susfs/0001-...patch` + `fs/susfs.c` + headers, clone of
  ReSukiSU at 8770c7e3 as `KernelSU/` (rev-list count must be 4503) + `drivers/kernelsu` symlink + Makefile/Kconfig
  lines, a52bc files + hooks patch, then `git update-index --assume-unchanged` on the 29 patched tracked files
  (setup.h was already marked): `git status -uno` clean = release string without `-dirty`. Marker
  `.a52-susfs-applied`; delete `bsp612/kernel-susfs` to start over (e.g. after a kernel or pin change).
* `build`: `bsp612/out/gki/.config` + the options of section 2 (`scripts/config`, `olddefconfig`; fails if anything
  outside `CONFIG_KSU*` changes or an option does not take), `make Image` into `bsp612/out/gki-susfs` (clang
  r547379, rustc 1.82.0 as build.sh), checks: kernel.release and the Image's "Linux version" = `out/gki`'s, a52bc +
  susfs + KernelSU linked, CRC/import comparison (`MODDIRS=` to check other module dirs), then
  `bsp612/out/susfs/{Image,System.map,BUILDINFO,vmlinux.symvers,susfs.config,crc-changed.txt,crc-compare.txt}` +
  the a52bc sources (same layout as `out/diag`, so `IMAGE=` works in build-realboot.sh).
* Not in git: the Image, `out/susfsq`, the kernel copy, donors (see .gitignore).

Files here: `build-susfs-image.sh`, `qemu-susfs-test.sh`, `susfs/0001-susfs-rejected-hunks-for-6.12.81.patch`,
`susfs/crc-compare.py`, `susfs/susfsq/susfsq.rs`, `susfs/qemu-init.sh`,
`susfs/build-realboot-KSU_BUILTIN.proposed.diff`, `qemu-susfs-console.txt`, `qemu-susfs-initrd.txt`.

## 9. rbou8s defect: the manager's activities do not resolve (analysis 2026-11-24, offline)

Symptom (broken screen, rbou8s = rbou7 + this Image, clean 9.3.168 install, reproduced after a reboot over adb):
`cmd package resolve-activity --brief -a MAIN -c LAUNCHER com.resukisu.resukisu` = "No activity found" for shell AND
root, `am start -n com.resukisu.resukisu/org.bakasu.bakasu.ui.MainActivity[Alias]` = "does not exist", while
`dumpsys package` has both activities in the Activity Resolver Table, the package is installed / not disabled /
not hidden, and base.apk is readable by uid 1000. On rbou7 (LKM, same /data) it resolved (11-23 18:20).
(The release APK's classes are `org.bakasu.bakasu.ui.*`, not `com.resukisu.resukisu.ui.*`: a `-n .../.ui.MainActivity`
test fails on every kernel.)

**Result of the source audit: no kernel code in this variant can do that. No kernel change was made and the Image
(4931de43...) was not rebuilt; KMI as in section 3.** rbou7 and rbou8s differ only in the Image, `ksu=1 -> 0` and
`rdinit=/ksuinit` (BUILDINFO, vendor-cmdline, first-stage module list compared). What was read:

* Config: `bsp612/out/susfs/susfs.config` = the 5.4 `k4-source/susfs/susfs.config`, option for option (11 KSU + 9
  SUSFS lines). No AUTO_ADD_* / default sus_path / try_umount options exist in v2.3.0.
* Every hide/rewrite hook is gated to "zygote child marked umounted AND uid >= 10000": sus_path
  (`fs/susfs.c:191` `susfs_is_current_proc_umounted_app()`, used by all `fs/namei.c` + `fs/readdir.c` hooks), sus_map
  and open_redirect readlink (`include/linux/susfs_def.h:149-161`), sus_kstat in stat/fdinfo/statfs
  (`susfs_is_current_app_uid()`), selinux_hide (`security/selinux/hooks.c my_setprocattr`, `selinuxfs.c my_*`: uid >= 10000).
  system_server (uid 1000) gets only TIF_PROC_NO_SU at its setresuid (`KernelSU/kernel/hook/setuid_hook.c:134-179`), which
  just skips the su-compat hooks in open/stat/execve. No inode carries a sus flag unless ksud adds one, and neither
  `susfs_defaults` nor ksud's persisted config adds any path (`ksud susfs config` seeds: enable, hide_sus_mnts, avc).
* The one SUSFS effect uid 1000 does see: with `hide_sus_mnts_for_non_su_procs 1` every non-ksu-domain process reads
  /proc/*/mounts|mountinfo|mountstats without mounts whose mnt_id >= 2000000000 (`fs/proc_namespace.c`). PackageManager
  does not use those for resolution, and `__lookup_mnt` only skips such mounts for umounted processes (`fs/namespace.c`).
* Manager handling (throne_tracker, pkg_observer, apk_sign, dynamic_manager, `ksu_install_fd`) is the same code as in
  the LKM, reads only, and nothing in ReSukiSU 8770c7e3 hides or filters the manager package. The input hook only
  counts KEY_VOLUMEDOWN (`ksud_integration.c:789`), it does not change events or key state.
* How PackageManager reads the APK (open/fstat/mmap in system_server, parse cache keyed by path + mtime): nothing above
  touches it for uid 1000; and the log proves the boot scan parsed the package (PackageCacher line, components in the
  resolver table). A spoofed kstat or hidden mount would give a scan failure or a missing package, not this symptom.

So the filter is in system_server. What gives exactly this picture (components registered, package state normal,
nothing resolves even for root/shell):

1. **Android safe mode** (`ComputerEngine.updateFlagsForResolve` adds MATCH_SYSTEM_ONLY): every non-system app stops
   resolving, for every caller. On this clean install the manager is the ONLY /data/app package (see the package list
   in `logs/1124/rbou8s-soak/pm-boot.txt`), and the "Safe mode" watermark cannot be seen on the broken screen. Fits
   every observation. Why it would be on only with this Image is not known from source (WindowManager decides at boot
   from the key state of volume-down/menu/dpad-center/'S'/trackball on any input device, or persist.sys.safemode /
   ro.sys.safemode; nothing in ReSukiSU/SUSFS/ksud/the ROM scripts sets those props). The WindowManager line names the key.
2. The ROM's Hide-My-Applist patch (`unica/mods/hma`: ComputerEngine.shouldFilterApplicationCustom /
   filterHiddenActivities, ActivityStarter.canHideApp -> START_CLASS_NOT_FOUND; default list contains
   com.resukisu.resukisu, `sec_ext_hma` defaults to 1, active after boot_completed). By its code it exempts uid
   0/1000/2000, the HOME role holder and system apps, so it does not explain the shell/root result unless the uid
   system_server sees for the adb shell is something else on this kernel (the capture prints it).
3. Component/package state not shown by the greps used so far (quarantined/archived/frozen, a leftover of the
   SecManagerRepair reinstall: "Missing permission state" is logged on rbou7 too, so weak).

Same conclusion, independently: `drivers612/SPEC/proposed/rbou8s-manager-defect.md` (kernel-line agent).

### On-phone test (read-only; broken screen on rbou8s / any KSU_BUILTIN build; S = its serial, always `adb -s $S`)

```
M=com.resukisu.resukisu
adb -s $S shell 'id; uname -r; getprop ro.sys.safemode; getprop persist.sys.safemode; getprop sys.boot_completed'
adb -s $S shell 'dumpsys window | grep -iE "safe ?mode"'
adb -s $S shell 'logcat -b all -d | grep -iE "SAFE MODE|safe mode|volumeDown=" | head'
adb -s $S shell 'su -c "dmesg | grep -iE \"KEY_VOLUMEDOWN|safe ?mode|volumedown_pressed\" | tail -20"'
adb -s $S shell 'getevent -lp 2>/dev/null | grep -E "add device|name:|VOLUMEDOWN|KEY_MENU|BTN_MOUSE|DPAD_CENTER"'
adb -s $S shell 'pm list packages -3'
adb -s $S shell "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $M | tail -1"
adb -s $S shell "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER | grep /"   # safe mode: only system apps
adb -s $S shell "settings get system sec_ext_hma; settings get secure sec_ext_hma_list; settings get system sec_ext_hma_list"
adb -s $S shell "su -c 'dumpsys package $M' | grep -iE 'User 0:|quarantined|archive|frozen|disabledComponents|enabledComponents'"
adb -s $S shell "su -c 'sha256sum \$(pm path $M | cut -d: -f2)'"     # 29516aa9f4f72a688722f0e21ae0784cbd6b1aa255f76f27b459df0d18a7c66e
```

Verdict: `mSafeMode=true` / "SAFE MODE ENABLED (menu=.. s=.. dpad=.. trackball=.. volumeDown=..)" or a prop = 1, and
`query-activities` lists only system launchers -> cause 1; the non-zero field of that line is the key to look at
(`getevent -lp` shows the device owning it; check whether the same line appears on rbou7). If safe mode is off:
on the test phone only, `settings put system sec_ext_hma 0`, resolve again, put 1 back -> resolving now = cause 2.
Anything else: the `dumpsys package` user-state line names it.

Pass criteria once it resolves (release gate for the variant = rbou7 behaviour):

```
adb -s $S shell "a=\$(cmd package resolve-activity --brief $M | tail -1); echo \$a; am start -n \$a"   # .../org.bakasu.bakasu.ui.MainActivity, 'Starting: Intent'
adb -s $S shell "su -c '/data/adb/ksu/bin/ksud susfs show version; /data/adb/ksu/bin/ksud susfs show enabled_features | wc -w'"   # v2.3.0, 9
# manager home card (uiautomator dump or the user's eyes): Working, Built-in, hook type Inline, SuSFS v2.3.0, kernel 6.12.81
adb -s $S shell "su -c 'dmesg | grep -iE \"KernelSU.*(install fd|manager)\" | tail -5'"   # 'install fd for ksu manager(uid=...)' at app start
```
