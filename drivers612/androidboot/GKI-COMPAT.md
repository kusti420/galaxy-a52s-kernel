# What the userspace expects from the kernel: 5.4 vendor kernel vs GKI 6.12

Sources: `bsp612/out/dist/gki.config` (the built GKI config), `bsp612/out/dist/modules-*.list`,
the ROM tree (`device/samsung/sm7325-common`), AOSP sources in `$ANDROID_TREE`,
`research/blob-uapi-inventory.md`. "OK" = present in the 6.12 build as checked in those files;
nothing was run.

## Storage and boot

| Item | 5.4 ROM | GKI 6.12 | Action |
|---|---|---|---|
| dm-linear / logical partitions | built in | `BLK_DEV_DM=y` | none |
| dm-verity | unused (vbmeta flags 3, no avb in fstab) | `DM_VERITY=y` | none |
| dm-user / snapuserd | unused (non-A/B) | `DM_USER=y` | none |
| dm-default-key (metadata encryption of userdata) | built in | `DM_DEFAULT_KEY=y` (ACK only; confirmed in gki.config) | none |
| Inline crypto | `inlinecrypt`, `aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized`, no wrapped keys | `BLK_INLINE_ENCRYPTION=y` + `_FALLBACK=y`, `FS_ENCRYPTION_INLINE_CRYPT=y`, `SCSI_UFS_CRYPTO=y`; vendor modules `qcom_ice.ko`, `ufshcd-crypto-qti.ko`, `ufs-qcom.ko` (all in the first-stage list) | Verify on hardware that ufs-qcom registers the ICE keyslot manager (`/sys/block/sda/queue/crypto/`). If ICE fails, the blk-crypto fallback decrypts the same data in software (standard AES-XTS, raw keys), so the real /data is still readable; that is the reason wrapped keys matter and they are not used here |
| f2fs options of userdata | `fsync_mode=nobarrier,reserve_root=32768,resgid=5678,inlinecrypt,checkpoint=fs`, quota | all still valid in 6.12 f2fs | none. NOTE: a 6.12 mount may enable on-disk features lazily; never mount the daily phone's real /data with a test kernel (testguard) |
| ext4 options (metadata, efs, persist, cache) | `noauto_da_alloc,journal_checksum,data=ordered,errors=panic,sync` | valid | none; `errors=panic` + a 6.12 ext4 complaint = panic, watch the first real boot |
| `sysfs_path=/sys/devices/platform/soc/1d84000.ufshc` | | same platform device path with the 6.12 dtb | none |
| erofs/ext4/f2fs for system | ext4 | all three built in | none |
| zram | built in | `zram.ko` (GKI module, `ZRAM=m`) + `zsmalloc.ko` | must be in a modules.load before `swapon_all fstab.ramplus` (first stage here) |
| devtmpfs | on | off in GKI | none for Android (ueventd makes nodes) |
| tmpfs xattr / POSIX ACL | on | **off** | /data cannot be tmpfs on pure GKI (README item 8) |
| Boot header | v3 boot + vendor_boot, v2 recovery | no kernel requirement; bootconfig needs v4 which this ABL predates | stay on v3/v2, `androidboot.*` on the command line (init reads both places) |
| GKI built-in cmdline | | `console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig` | PSI per-cgroup files are off (system-wide `/proc/pressure` stays: lmkd OK). pKVM cannot start under Gunyah: harmless message |

## Modules

- The phone has no `vendor_dlkm` partition (super: system, vendor, product, odm) and its PIT is
  not to be changed. Plan: first-stage modules in the vendor_boot ramdisk (`/lib/modules`,
  ~90 files, 9.8 MB), ALL modules again in `/vendor/lib/modules` (43 MB stripped; vendor has
  the room: four partitions use about 4.5 GB of the 10.6 GB super), second-stage load by one
  `modprobe -a -b -d /vendor/lib/modules --all=/vendor/lib/modules/modules.load` in
  `init.target.rc` `on early-init` (patch 0001), replacing `vendor_modprobe.sh` (which probes
  a `5.4-gki` directory and loads in parallel without order). GKI `system_dlkm` is not needed:
  the GKI modules we use ship in the same two places.
- Order: `modules.load` order is the order of the file; libmodprobe loads each entry's
  dependencies from `modules.dep` first. First-stage init stops at the first failing module
  unless `androidboot.first_stage_console=1` on a debuggable build; so risky modules go last
  or to the second stage.
- Signatures: GKI has `MODULE_SIG=y` without `SIG_FORCE`; unsigned vendor modules load, but a
  GKI module that was stripped loses its signature and then cannot use protected symbols.
  Never strip GKI modules (`BOARD_DO_NOT_STRIP_*` in patch 0001; the scripts strip only vendor
  modules).
- Recovery: self-contained v2 image, needs the first-stage set + touch + display in its own
  ramdisk (`modules.load.recovery`); until display/touch are ported, recovery on 6.12 is adb-only.
- Never loaded: `qcom_edac` (LLCC ECC IRQ storm on the other SM7325 port), `qcom-dload-mode`
  (a crash would end in upload mode), `gh_virt_wdt`/`qcom_wdt_core` (units unproven here).

## Framework-facing kernel interfaces

| Item | State on 6.12 GKI | Action |
|---|---|---|
| binder | `ANDROID_BINDERFS=y`, devices binder,hwbinder,vndbinder; init mounts binderfs and links /dev/binder* | none. `rust_binder.ko` optional, not used |
| ashmem | **gone** (no `CONFIG_ASHMEM` in 6.12) | libcutils falls back to memfd for code built in this tree. Checked: no file under `vendor/samsung/{sm7325-common,a52sxq}/proprietary` contains the string `/dev/ashmem` |
| ION | **gone**; `/dev/ion` is what every closed allocator user opens | `modules/ioncompat` (verified on 6.18; rebuild for 6.12), must be in modules.load before the HALs; ueventd rule `/dev/ion 0664 system system` already in `ueventd.qcom.rc` |
| incfs | `INCREMENTAL_FS=y` | none |
| fuse-bpf / FUSE passthrough | `FUSE_BPF=y` | none (MediaProvider works with or without) |
| BPF | `BPF_SYSCALL`, `BPF_JIT_ALWAYS_ON`, `CGROUP_BPF`, `BPF_LSM` =y | none. Android 17 bpfloader/netd only require >= 5.4 features; `XT_MATCH_QUOTA2`, `IP_NF_RAW`, `NET_SCH_HTB`, `INET_UDP_DIAG` =y. The 5.4 cmdline's `iptable_raw.raw_before_defrag=1` is dropped (module parameters of a built-in that may not exist) |
| cgroup v2 / memcg | `CGROUPS`, `MEMCG=y`, `MEMCG_V1=y`, `CGROUP_FREEZER`, `UCLAMP_TASK_GROUP` =y | none; `androidboot.memcg=1` kept. `task_profiles.json` of the device writes 5.4 WALT/schedtune paths: with `sched-walt.ko` loaded the WALT sysctls exist under `/proc/sys/walt/`, not `/proc/sys/kernel/sched_*` (`init.target.rc` writes `/proc/sys/kernel/sched_boost`: harmless error) |
| PSI | `PSI=y` | none |
| USER_NS | off | none (Android does not need it) |
| 32-bit processes | `COMPAT=y` | none (32-bit blobs keep working; ioctl compat must be kept in forward-ported drivers) |
| SELinux | `SECURITY_SELINUX_DEVELOP=y`, no boot param (`enforcing=1` on the cmdline is ignored) | permissive is init's decision (`androidboot.selinux`), userdebug/eng only |
| USB gadget | `USB_CONFIGFS` + FunctionFS, ACM, NCM, MIDI, UVC, mass storage built in; UDC from `dwc3-msm.ko` | ROM's `init.qcom.usb.rc` uses Qualcomm functions (`gsi`, `diag`, `qdss`, `ccid`) that are vendor modules or missing: plain `adb`/`mtp` compositions work, the others fail to link |
| Firmware loading | `FW_LOADER_USER_HELPER=y`; `firmware_class.path=/vendor/firmware_mnt/image` kept; ueventd `firmware_directories /vendor/firmware_mnt/image/ /vendor/firmware-modem/image/` unchanged | Remoteproc on 6.12 asks for names from the DT (`firmware-name`), the 5.4 PIL asked for `adsp.mdt` by subsystem name: make the 6.12 overlay name the files that exist in apnhlos/modem |
| PIL sysfs / `/dev/subsys_*` | gone (remoteproc) | compat module needed (`subsys_compat` of the other port is the model): `libmdmdetect`, `vendor.qti.hardware...`, SSR props read `/sys/bus/msm_subsys/devices` |
| Thermal, power, battery sysfs | Samsung `sec-battery` class nodes, `/sys/class/sec/*` | forward-ported Samsung drivers (samsung612/) |

## VINTF

- Nothing at boot refuses a kernel: init has no VINTF check (verified: no libvintf use in
  `system/core/init`). The checks are `check_vintf` at build time and the OTA-time kernel
  requirement; both are already disabled in `common.mk`
  (`PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`, `PRODUCT_ENFORCE_VINTF_MANIFEST := false`).
- The device manifest says `target-level="7"`; level 7's kernel list is 5.10/5.15
  (`kernel/configs/t`), 6.12 belongs to level 202504 (`kernel/configs/b/android-6.12`).
  Patch 0003 adds `<kernel target-level="202504"/>` so the kernel is judged against its own
  level. The GKI config satisfies that level's fragments by construction (it is the ACK
  `gki_defconfig`).
- VTS/CTS-style runtime checks (`vts_treble_vintf`) are irrelevant for this ROM.

## Kernel command line / properties read by blobs

- From the ABL, unchanged by the kernel version (they become `ro.boot.*`): `serialno`,
  `revision`, `subpcb`, `sales_code`, `carrierid`, `debug_level`, `cp_debug_level`,
  `warranty_bit`, `*.param.offset`, `sec_atd.tty`, `dtbo_idx`, `boot_recovery`,
  `verifiedbootstate`, `bootdevice`, `boot_devices`, `baseband=msm`, `keymaster=1`.
- From the image: `androidboot.hardware=qcom`, `androidboot.usbcontroller=a600000.dwc3`,
  `androidboot.memcg=1`. Kept in patch 0001.
- Not UAPI but parsed by 5.4 Samsung drivers from the cmdline (`sec-battery.sales_code`,
  `sec_mparam.*`, `msm_drm.dsi_display0=`, `msm_drm.lcd_id=`, `sec_common_fn.lcd_id=`,
  `ccic_info`, `sec_debug.*`): the forward-ported modules must keep the same module names or
  the parameters are silently ignored (module parameters are matched by module name; e.g. the
  panel name arrives as `msm_drm.dsi_display0`).
- `ro.kernel.version` becomes 6.12; LineageOS/AOSP userspace uses it only for feature gates
  that go the right way on a newer kernel.
