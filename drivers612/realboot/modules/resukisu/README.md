# ReSukiSU on the 6.12 real boot (LKM mode, GKI Image unchanged)

The root flavour for the **OneUI 9 port** (K4_UN1CA, ~/git/MonsterROM): its 5.4 bone-machine kernel has
ReSukiSU built in and the ROM preinstalls the ReSukiSU manager and runs boot jobs in `u:r:ksu:s0`. With this
module the 6.12 kernel offers the same root, so the ROM needs no change. The IchthysOS line keeps
KernelSU-Next (`../kernelsu`).

* Version: ReSukiSU **8770c7e3** (v4.2.0-rc3-32-g8770c7e3), the commit the ROM's 5.4 kernel is built from
  (MonsterROM prebuilts/kernel/bone-machine/SOURCE.txt). Version code 35203 = 30700 + `git rev-list
  --count` 4503: donors/ReSukiSU needs the full history (build.sh refuses a shallow clone). Version name
  `v4.2.0-rc3-8770c7e3@ReSukiSU`. The ROM's manager: com.resukisu.resukisu **35222** (works with a 35203
  kernel, proven on 5.4); its certificate hash d3469712... is the module's built-in EXPECTED_HASH_RESUKISU.
* Config = upstream's own LKM recipe (kernel/build-all.sh): `CONFIG_KSU=m CONFIG_KSU_TRACEPOINT_HOOK=y
  CONFIG_KSU_MULTI_MANAGER_SUPPORT=y`, against bsp612/out/lahaina (vermagic 6.12.81-4k-g8a69376da734).
* 59 unexported kernel symbols (KSU-Next: 10): selinux internals (policydb_*, avtab_*, ebitmap_*,
  sidtab_*, mls_*, symtab_*, selinux_state ...), kallsyms_*, path_mount/umount, alloc_uid,
  set_cred_ucounts, seccomp_filter_release, __arm64_sys_close/setns, init_mm, __set_fixmap,
  copy_to_kernel_nofault, __tracepoint_sys_enter ... All 59 are present exactly once, under the exact name,
  in System.map of both bsp612/out/diag and bsp612/out/dist (CONFIG_KALLSYMS_ALL=y); ksuinit resolves them
  from /proc/kallsyms before init_module.
* ksuinit = ReSukiSU's userspace/ksuinit + `ksuinit-a52-rdinit-crash-guard.patch` (the same change as
  ../kernelsu: started as rdinit=/ksuinit from our vendor_boot ramdisk, the ROM's /init is not replaced,
  a ramoops dmesg-* record of the previous boot = KernelSU not loaded for that one boot). ReSukiSU's ksuinit
  also passes `block_modules=vr,vklp,oplus_secure_guard,oplus_secure_guard_new,mkp` (module_load_filter
  hooks init_module/finit_module; none of those names is one of our modules).
* Proof offline: QEMU boot of the diag Image with rdinit=/ksuinit (`qemu-console.txt`): 'Initialized with
  driver version: 35203, ... Work mode: LKM', tracepoint + syscall hooks registered, the real init runs as
  PID 1, 0 WARN/BUG/Oops.
* Crash guard proof offline: `./qemu-test.sh` (3 boots in one QEMU run, ramoops above mem= survives the
  guest reset): ReSukiSU loads -> deliberate sysrq panic -> 'a52: previous boot left a panic record:
  kernelsu.ko NOT loaded this boot' -> next boot loads it again ('GUARD PASS', `qemu-crashguard-console.txt`).
* Build: `./build.sh` -> out/kernelsu.ko + out/ksuinit. Package: `KSU=1
  KSU_DIR=$PWD/drivers612/realboot/modules/resukisu/out drivers612/realboot/build-realboot.sh <name>`.
* Phone check: `./verify-oneui9.sh <serial>` (read-only apart from a mute).
* The ROM's jobs in u:r:ksu:s0 (init `seclabel`/`exec`, allowed by the KernelSU rule `allow init ksu * *`):
  init.rc `on post-fs-data exec u:r:ksu:s0 ... gpudrv guard`, `metamod_apply` (after `metamod_gate`, which
  runs in the ROM's own metamod domain and reports `sys.metamod_gate=ksu` when /data/adb/ksud exists),
  `pif_cleanup`, `susfs_defaults`. They need only ksud + the ksu domain; meta-overlayfs needs ext4 loop
  images + overlayfs (GKI: built in).
* SUSFS: see **SUSFS.md** (2026-11-22): a separate Image variant with ReSukiSU built in + SUSFS v2.3.0
  (`build-susfs-image.sh` -> bsp612/out/susfs/Image, same release + export CRCs, QEMU-proven, never on a phone).
  The rest of this file is the LKM route, which has no SUSFS:
* Not available in LKM mode: SUSFS (a GKI Image patch). The ROM's `susfs_defaults` checks `ksud susfs show
  version` first and exits 0 when SUSFS is missing; its uname re-set (5.4.302-bone-machine-qgki) only runs
  behind that check. Without SUSFS: no hide_sus_mnts_for_non_su_procs and no avc log spoofing (root-hiding
  checks such as Duck Detector will see more); ReSukiSU's own selinux_hide and kernel_umount still work.
