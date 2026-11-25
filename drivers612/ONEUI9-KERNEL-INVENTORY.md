# OneUI 9 port on 6.12: kernel-side inventory (what the 5.4 ROM kernel has, what UN1CA does to kernels, what 6.12 has instead)

2026-11-22, 18:52-19:40. OFFLINE, READ-ONLY audit. No phone was touched, nothing was built, nothing in
`~/git/MonsterROM` or `$ANDROID_TREE` was edited. This file complements `ONEUI9-READINESS.md` (interfaces OneUI
uses on top of LineageOS) and `ONEUI9-PARITY.md` (the measured 5.4-vs-6.12 sweep); it does not repeat their tables.

Evidence tags used in every table:

- **[S]** read from source or config on this PC (file named in the row or in section 1).
- **[M]** measured today by the sweep on broken screen, same ROM, both kernels:
  `logs/selftest/PHONE1-20261122-172724` (5.4.302-bone-machine) and `...-180146` (6.12.81, rbou4).
- **[N]** a note from the test sessions of 2026-11-22; not re-checked here.
- **[?]** not verified by anyone; the row says what check would settle it.

Status words: **present** (same interface on 6.12), **equivalent** (another mechanism gives userspace the same
result), **missing**, **n/a** (the 5.4 kernel does not have it either, or nothing in the ROM uses it).

## 0. Likely surprises, ranked (each with a check or a fix)

Ranked by (chance that it bites) x (cost when it does). "Known" = already hit today; listed so the fix is not lost.

| # | Surprise | Why | Check / fix |
|---|---|---|---|
| 1 | **PROCA TA contract in the arm64 Image header** (known, open): vaultkeeper "no VK ID" loop, then cidmanager "vk read failed" and the CSC "Service provider update" dialog | 5.4 `arch/arm64/kernel/head.S:83-86`: header offset 0x28 = `_proca_conf_offset` with `CONFIG_PROCA`, else `.quad 0xecefecef` ("Magic number for proca ta"); the ROM kernel has PROCA off, so it carries the magic [S]. 6.12 `head.S` has `.quad 0` (reserved) there [S]. Two more header differences: text_offset is 0 on 6.12 (5.4: 0x80000), so the ABL loads the Image at another address [S, `od -j8 -N8` of `bsp612/out/diag/Image` = 0]. UN1CA `unica/patches/proca` only patches a value that is neither 0 nor the magic, so a ROM build that repacks a 6.12 Image leaves the 0 in place [S] | Check: `od -An -tx1 -j40 -N4 <kernel from boot.img>` must print `ef ec ef ec`. Fix in progress in the working tree (uncommitted `build-realboot.sh`: `PROCA_MAGIC=1`, `PROCA_TEXTOFF=1`, `PROCA_HDR_RES=<phys>`; rbou5c was built with `proca_magic=1`, result not written down yet). The same patch must go into every packaging path (`twrp/mk-ak-zips.sh`, the selector zip), with a build-time assert. Source note: `bsp612/kernel/arch/arm64/mm/init.c:323` reserves from `_text` and `mmu.c:700` keeps `[_text,_stext)` mapped read-only, so by source the header page is not freed on this tree; whether the TA finds it at the address it expects is [?] |
| 2 | **No watchdog on the OneUI 6.12 builds**: a hard hang is a frozen phone that needs the keys | rbou4 and rbou5c `BUILDINFO`: `wdt=0` [S]. 5.4 has `HH_VIRT_WATCHDOG=y` (bark 11 s, pet 9.36 s), `SOFT_WATCHDOG=y`, `DPM_WATCHDOG=y` (5 s) [S] | Build with `WDT=1` (proven on rb78 under load and idle; never run through a real suspend, never under OneUI). Check after boot: the hhwdt status line, then 15 min screen off without USB |
| 3 | **Features that switch themselves on because the kernel is newer.** Nobody tested them on this ROM, because 5.4 could not run them | [M] on 6.12 only: cgroup v2 freezer (`cgroup.freezer` row: `none+v1` -> `v2+v1`), so the AOSP cached-app freezer can run next to Samsung Freecess; `process_mrelease`, `pidfd_getfd`, `openat2`, `faccessat2`, `landlock`, `mseal`, `cachestat`, `futex_waitv` exist; new pinned BPF objects `prog_fuseMedia_fuse_media`, `dmabuf`, `memevents`, `kernelwakelockduration`; 26 more `netd_shared` maps including Samsung `semUidBPF_*` (net block, APE, DNS ring buffers); binder features `extended_error`, `transaction_report`; AF_VSOCK; EROFS big pcluster etc. | Per feature: `dumpsys activity settings \| grep -i freez` and `cat /sys/fs/cgroup/uid_*/pid_*/cgroup.freeze` after 10 min idle (delayed notifications, frozen sockets); `getprop \| grep fuse.bpf` and a large copy to /sdcard with MTP; Samsung "block network per app"/data saver with one app; `dumpsys netd` (5.4 printed `mOemUidOwnerMap ... Bad file descriptor`, 6.12 does not: those Samsung maps are live for the first time) |
| 4 | **Root stack is a different implementation** (ReSukiSU as LKM through `rdinit=/ksuinit`, tracepoint hooks) | Missing vs 5.4 [S]: SUSFS (0018), NoMount, Baseband-Guard LSM, the manual hooks incl. k4 0007 (native `newfstatat`/`statx` sucompat). `susfs_defaults` exits early without SUSFS. Visible to apps on 6.12: real uname (5.4 could spoof), `rdinit=/ksuinit androidboot.a52sxq.k612vb=1` in the command line (5.4 had `SPOOF_CMDLINE`), 280 modules, taint 12800 vs 1028 [M]. Manager is crowned by APK path (clean-install root, fixed ROM-side in 9.3.161+ [N]) | `su -c id` from a granted app (not adb) and from a 64-bit native binary using `stat()`; a detector app (same one) on 5.4 and 6.12; `ksud susfs show version`; decide whether the Settings text "root hiding (no SUSFS)" is enough |
| 5 | **`kernel_check` reports a healthy 6.12 as "differs"** | [M] `sys.kernel_check.minor=uvc_stream,uvc_inband_err,kernelsu,gpu_tuning`, `ok=1`. `kernelsu` is a false negative: the script reads `CONFIG_KSU` from config.gz, the GKI config has none (LKM), and it only falls back to kallsyms when config.gz is unreadable [S, `kernel_check` cfg()] | ROM: probe `/sys/module/kernelsu` or `ksud` for the 6.x line; give the three other items a 6.x expectation (section 5) |
| 6 | **The BPF loader choice hangs on one command-line word** | `ro.boot.a52sxq.k612vb=1` (vendor cmdline) selects Google's netbpfload + the APEX's netd.o; without it the ROM starts its 5.4 loader `netbpfload_a52b` under `reboot_on_failure`. Any 6.12 package without the marker (the IchthysOS any-ROM zip, an old alpha zip) on OneUI = wrong loader [S, `kernel_check` kernel_line, `kernel_6x_mode/customize.sh`] | Keep the installer's OneUI gate (`ALLOW_ONEUI9`) and add an assert on the marker in the zip builder; test once: boot the selector zip, `getprop init.svc.bpfloader_apex`, `mainline_diag` |
| 7 | **Boot image format traps** (known): gzip ROM ramdisk after an lz4 fragment (rbou2 loop), OS patch level, 16 zero bytes | ROM boot ramdisk is gzip (LineageOS: lz4); lz4-legacy needs the 4-byte end marker before it [N]. Header must stay v3, os 11.0.0 / 2023-11 (Keymaster 4 binds keys; raising it is one-way) [S, `kernel_bone_machine/customize.sh`]; the ABL rejects `SEANDROIDENFORCE` + a zeroed signature, the port appends 16 zero bytes (`TARGET_BOOT_SEANDROID_MAGIC=false`) [S, `config.sh`] | `tools/qemu-initrd-check.sh` gate (exists); assert `os patch level: 2023-11` and the trailer in every packaging path |
| 8 | **dmesg is 8x smaller and nothing survives a reset** | `LOG_BUF_SHIFT` 20 -> 17 (1 MiB -> 128 KiB) and no `log_buf_len=` on the OneUI vendor cmdline [S]; ring wraps in ~35 s under OneUI [N]; `/proc/last_kmsg`, `/proc/reset_reason`, `/proc/extra`, `/proc/sec_log` absent [M path failures] | Add `log_buf_len=1M` to the vendor cmdline (5.4 parity); read `/sys/fs/pstore/console-ramoops-0` after every unexplained reset |
| 9 | **USB host and storage classes a OneUI user expects** | Not in the 279-module ramdisk [S, `rbou5c/first-stage.modules.load`]: `usbnet`, `cdc_ether`, `cdc_ncm`, `r8152`, `ax88179_178a`, `asix`, `rtl8150` (5.4: built in) = USB-C Ethernet and dock Ethernet do nothing; no `hid-samsung` (keyboard covers, Samsung BT keyboards lose special keys); no NTFS driver (5.4 `NTFS_FS=y`, vold has an NTFS path); exFAT moves from sdfat to upstream exfat [M] and was not tried with a card under Samsung vold [?]; smsc75xx/95xx gone | Add the GKI usbnet modules to the load list (they are built); build `hid-samsung` as an external module; test one exFAT and one NTFS stick over OTG and one exFAT microSD |
| 10 | **Power-off charging (Samsung `lpm`) never ran on 6.12** | `lpm` and `resetreason` read `/proc/pwrsrc` and `/proc/extra`; health/charger read `/sys/power/rtc_status` [S, strings]; all three are Samsung sec_debug/rtc nodes that 6.12 lacks | Power off, plug a charger: animation, percentage, then power key boots. No adb in that mode, so film it or read pstore afterwards [?] |
| 11 | **Suspend path differs**: sync on every suspend, hibernation state visible | 5.4 `SUSPEND_SKIP_SYNC=y`; 6.12 not set, so each suspend runs a filesystem sync (tens of thousands of suspends per night on this phone) [S]; `/sys/power/state` now lists `disk` [M] | `write /sys/power/sync_on_suspend 0` from an rc (node exists in 6.12, `kernel/power/main.c`) [S]; compare `suspend_stats` and overnight drain with and without |
| 12 | **Scheduler / memory tuning surface moved** (smoothness, app retention, battery; not boot) | `FAIR_GROUP_SCHED` is on for the first time (5.4: off, so `/dev/cpuctl/*/cpu.shares` did nothing there) [S]; WALT sysctls and schedutil nodes moved ([M] ENOENT `sched_busy_hyst_ns`, `schedutil/pl`, `sched_ravg_window_nr_ticks`); rc sysctls with no 6.12 counterpart: `kswapd_threads`, `extra_free_kbytes`, `min_free_order_shift`, `tcp_default_init_rwnd`, `sched_latency_ns`, `sched_wakeup_granularity_ns`, `sched_tunable_scaling`, `swap_ratio*`, `reap_mem_on_sigkill` [S]; Samsung MM off: `PAGE_BOOST`, `RBIN`, `MULTIPLE_KSWAPD`, `SPECULATIVE_PAGE_FAULT`, `MEMCG_HEIMDALL`, `PROCESS_RECLAIM`, `ZRAM_LRU_WRITEBACK`; I/O scheduler `ssg` -> `mq-deadline` [M] | A/B on the same phone: app-launch times, `dumpsys meminfo` cached count after 1 h, lmkd kill count per day, jank during scroll; `BWCOMPAT=1` already covers part of the node names |
| 13 | **Cmdline words the 6.12 package drops** | 5.4 vendor cmdline has `swiotlb=0`, `cgroup.memory=nokmem,nosocket`, `lpm_levels.sleep_disabled=1`, `service_locator.enable=1`, `msm_rtb.filter`, `pcie_ports=compat`; ours has none of them [S, `rbou5c/info/*vendor_boot.unpack_bootimg.txt`]. `swiotlb=0` gone can cost 64 MB of RAM [?] | `grep -E 'MemTotal\|CmaTotal' /proc/meminfo` and `dmesg \| grep -i 'software IO TLB'` on both kernels; add `swiotlb=noforce` or `swiotlb=0` if the buffer is allocated and unused |
| 14 | **debugfs exists on 6.12** (5.4: `DEBUG_FS` not set) | [S]; more `/sys/kernel/debug` and tracefs surface for dumpstate, `LastMileLogger` ([M] ENOENT `tracing/instances/wifi`), and for apps that look for unusual mounts | `mount \| grep -E 'debugfs\|tracefs'` on a user build after boot; nothing to fix unless debugfs is mounted |
| 15 | **HDCP class missing** | 5.4 live list has `/sys/class/hdcp` [S, `research/blob-uapi-evidence/sys_class.txt`]; consumers: `libsdmcore.so`, `libhdcpsrm.so`, `init.qcom.early_boot.sh` [S]. `hdcp_qseecom_dlkm.ko` is built (`drivers612/secure/securemsm/out`) but not loaded | Only matters with an external display path; test Smart View with protected video once. Load the module if it fails |

Not surprises (checked, same on both): section 9.

## 1. What was compared (and one correction)

| Thing | Path | Note |
|---|---|---|
| The ROM's 5.4 kernel | `~/git/MonsterROM/prebuilts/kernel/bone-machine/bone-machine_k4btf_ringbuf_su_pt_uvc8_susfs_a52sxq.zip`, pinned by sha256 `6db9ab9a...` in `target/a52sxq/patches/kernel_bone_machine/customize.sh` | Linux 5.4.302-bone-machine-qgki; recipe `prebuilts/kernel/bone-machine/k4-source/k4_build.sh` + `k4-patches/0001-0016, 0018` |
| Its source | `~/git/kernel_a52sxq_bone`, HEAD `93b49d0ccd89` = the `SRC_COMMIT` of `SOURCE.txt` | **Yes, this is it.** The tree is dirty with k4 patch state (KernelSU, yupik-gpu.dtsi, battery, dwc3-msm ...) |
| Its config | `k4-source/susfs/susfs.config` (sha `aadaced1...`) | **Correction to ONEUI9-READINESS.md section 0:** `~/git/kernel_a52sxq_bone/out/.config` (11-15, sha `fd18ed01...`) is a later non-KSU build. It equals the pinned config except for 13 `CONFIG_KSU*` / `KSU_SUSFS*` lines, so every non-root row taken from it stays valid |
| 6.12 config | `bsp612/out/gki/.config` (6.12.81, sha `25a6bfdd...`) | 2376 symbols set; 5.4: 2269; 847 only in 5.4, 954 only in 6.12, 45 with another value. Vendor drivers are modules built outside this config, so "only in 5.4" alone proves nothing: each row below was checked against the module list |
| 6.12 modules actually shipped | `drivers612/realboot/out/rbou5c/first-stage.modules.load` (279, all in vendor_boot; REF `s99t`) | newest OneUI build dir at audit time |
| ROM tree | `~/git/MonsterROM` branch `feat/shoal-port` @ `5710e1bc`, version 9.3.166; work dir `out/target/a52sxq/work_dir` | 280 rc files, framework jars, vendor/system binaries scanned for `/proc` and `/sys` strings (12,280 hits) |
| Measured runs | `logs/selftest/PHONE1-20261122-{172724,180146}` | `oneui.tsv`, `props.txt`, `collect-*.txt` |

## 2. The k4 patch series (0001..0018) on top of bone-machine

| # | Patch | Why the ROM needs it | 6.12 |
|---|---|---|---|
| 0001 | CAP_PERFMON / CAP_BPF / CAP_CHECKPOINT_RESTORE (cap_last_cap 40) | zygote_next drops caps 0-40 and aborts on EINVAL for 38; `kernel_check` crit `caps` | present, native [M `cap_last_cap=40`] |
| 0002 | revert GPU NAP removal (`qcom,no-nap`) | stock GPU idle behaviour | n/a as a patch; the 6.12 line has its own KGSL tuning. `kernel_check` minor `gpu_tuning` [M] |
| 0003 | revert GPU undervolt + 180 MHz step, init level 315 MHz | stability | same row |
| 0004 | KGSL idle timeout 80 ms | stock value | same row; check `cat /sys/class/kgsl/kgsl-3d0/idle_timer` |
| 0005 | `DEBUG_INFO_BTF` with 5.4-safe pahole kinds | CO-RE `timeInState.bpf` = per-app CPU time | present, native (`DEBUG_INFO_BTF=y`, `_MODULES=y`) [M] |
| 0006 | `BPF_MAP_TYPE_RINGBUF` backport (map only, no helpers) | Google's Tethering APEX pins ring buffer maps; `kernel_check` crit | present, native with helpers [M] |
| 0007 | KSU: hook native `newfstatat` and `statx` for sucompat | `su: not found` for granted 64-bit apps | n/a as a patch (manual-hook code); the LKM uses tracepoint hooks. Behaviour [?]: top list 4 |
| 0008 | battery `pass_through` node | One UI "Pause USB Power Delivery" | present: `sb_pass_through` in sec-direct-charger + `samsung-oneui/battery_attrs` [N: switches charging on rbou4] |
| 0009 | UVC gadget function + `VIDIOC_ENUM_FMT/FRAMESIZES/FRAMEINTERVALS` | DeviceAsWebcam | present: `USB_CONFIGFS_F_UVC=y`, `uvc_v4l2_enum_format` in `uvc_v4l2.c:443` [S] |
| 0010 | UVC stream stop / unbind fixes | webcam unplug | equivalent: upstream 6.12 f_uvc; not run under OneUI [?] |
| 0011 | dwc3: report missed isoc per request | frame drops visible to f_uvc | equivalent in upstream dwc3 core; our glue is msm-dwc3 from soc-repo [?] |
| 0012 | UVC: start on idle isoc endpoint, `num_requests`, `drop_missed` params | stutter | missing as module params [M minor `uvc_stream`]; upstream sizes requests itself (`uvc_video.c:510`) |
| 0013 | dwc3-msm: quiet dbm lookup for non-dbm endpoints | log noise | n/a |
| 0014 | UVC: app may close the node before unbind | DeviceAsWebcam teardown | equivalent upstream [?] |
| 0015 | UVC: whole 1080p frames, 128 requests | 1080p | missing as a tunable; upstream scales request count [?] |
| 0016 | UVC: in-band flag for a frame that lost a payload (`inband_err`) | broken frames | missing [M minor `uvc_inband_err`] |
| 0017 | dm: resend KOBJ_ADD after the name hash insert (parked: reset at 7.5 s) | ueventd naming of APEX dm devices before 5.15 | present upstream (fix 89f871af1b26, 5.15); ROM workarounds `apex_dm_relabel`, `apexd_dm_mtime` become harmless |
| 0018 | SUSFS v2.3.0 (SUS_PATH, SUS_MOUNT, SUS_KSTAT, SUS_MAP, SPOOF_UNAME, SPOOF_CMDLINE_OR_BOOTCONFIG, OPEN_REDIRECT, ENABLE_LOG, HIDE_KSU_SUSFS_SYMBOLS) | root hiding; `susfs_defaults` turns on `hide_sus_mnts_for_non_su_procs` and `avc_log_spoofing` per boot | **missing** (needs hooks in the GKI Image). `susfs_defaults` logs "susfs not available" and exits [S] |

## 3. What bone-machine itself has that a stock / GKI kernel does not

| Item | What / why | 6.12 |
|---|---|---|
| ReSukiSU 8770c7e3 built in (`CONFIG_KSU=y`, driver 35203), manual hooks, `KSU_MULTI_MANAGER_SUPPORT` | root for the ROM's 3 services in `u:r:ksu:s0` (GPU-driver guard, metamodule, PIF cleanup), manager preload | equivalent: same commit as LKM (`drivers612/realboot/modules/resukisu`, `CONFIG_KSU=m`, `KSU_TRACEPOINT_HOOK=y`), loaded by `/ksuinit`. Root on rbou3 [N] |
| `path_umount` backport, `struct seccomp.filter_count` patch | ReSukiSU needs them on 5.4 | present natively |
| NoMount (`CONFIG_NOMOUNT=y`, `fs/nomount`) | mount hiding for KSU modules | missing; no ROM patch references it [S grep] -> n/a for the ROM |
| Baseband-Guard LSM (`CONFIG_BBG=y`, `baseband_guard` last in `CONFIG_LSM`) | blocks writes to modem/EFS partitions from root | missing. Protection only; nothing reads it. Decide if wanted |
| MGLRU backport (`LRU_GEN=y`, `LRU_GEN_ENABLED=y`) | memory behaviour | present natively [M `mglru=0x0003` on both] |
| `close_range` backport | A17 posix_spawn; hotspot dnsmasq | present natively [M] |
| 5.4.302 stable merge, A73 backports (squashfs, kernfs, venus, mmc), lz4 1.10 | maintenance | n/a |
| `LZ4KD` (`CRYPTO_LZ4KD`, compress/decompress) | optional zram algorithm | missing; ROM uses `lz4` on both [M `algo=[lz4]`] -> n/a |
| sec_debug memory reclaimed, lockscreen USB restriction off by default, `usb_sl` accepts integers | custom-ROM comfort | `usb_sl` attr present in `usb_notify_layer.ko` [S readiness 1a]; behaviour with One UI's `UsbHostRestrictor` [?]: lock the screen, plug a USB stick |
| Samsung platform features kept ON in 5.4 | `SAMSUNG_FREECESS`, `SDP` + `FSCRYPT_SDP`, `CPU_FREQ_LIMIT`, `SEC_INPUT_BOOSTER`, `ARGOS`, `SDFAT_FS`, `USB_F_SS_MON_GADGET`, `USB_F_CONN_GADGET`, `BLK_SEC_STATS`, `MQ_IOSCHED_SSG`, `SEC_PM`, `SEC_ABC`, `SEC_PARAM`, `SEC_QUEST`, `SEC_PERF_MANAGER`, `PAGE_BOOST`, `RBIN`, `HDCP_QSEECOM`, `HH_VIRT_WATCHDOG`, `DEV_RIL_BRIDGE`, `SPU_VERIFY`, `MST_LDO` | section 7 (ports) and section 6 |
| Knox kernel features OFF in 5.4 | PROCA, FIVE, DEFEX, DSMS, RKP/KDP/UH, HDM, KnoxGuard, TIMA; `/dev/proca_config`, `/dev/dek_kek` absent on both [M "broken on both"] | n/a, except the PROCA header magic (top list 1) |

## 4. Everything UN1CA and the port do to kernels and boot images

| Where | What it does | Meaning for a 6.12 package |
|---|---|---|
| `unica/patches/proca/customize.sh` | Unpacks boot.img, gunzips the kernel if gzip, then (a) if header bytes 40..43 are neither `00000000` nor `ecefecef`, writes `ef ec ef ec` (removes the PROCA config offset), (b) renames the string `proca_config\0` to hide the device node, repacks with the original mkbootimg args, appends `SEANDROIDENFORCE` or 16 zero bytes | Top list 1. On the bone kernel it is a no-op (magic already there, PROCA off). On a 6.12 Image it is also a no-op, which is the trap |
| `target/a52sxq/patches/kernel_bone_machine` | Takes only the kernel Image from the pinned zip, keeps the ROM's ramdisk, cmdline, header v3 and OS patch level 2023-11; uses the zip's `vendor_boot.img` (84 modules + dtb) and `dtbo.img` as they are | A 6.12 package replaces all three images; it must keep header v3, 11.0.0 / 2023-11 and the ROM's boot ramdisk bytes (rbou5c read-back does) [S REPORT.txt] |
| `target/a52sxq/config.sh` `TARGET_BOOT_SEANDROID_MAGIC=false` | 16 zero bytes after boot.img instead of `SEANDROIDENFORCE` (this ABL rejects the magic with a zeroed signature and vbmeta after the image) | keep the same trailer |
| `scripts/extract_fw.sh` | `vbmeta_patched.img`: byte 123 = 0x03 (verity + verification disabled) | not a kernel item; a kernel zip must not touch vbmeta |
| `scripts/unsign_bin.sh` | removes AVB footers and Samsung `SignerVer02/03` header/footer signatures from stock images | n/a |
| `scripts/utils/install_utils.sh`, `kernel_selector/package.sh`, `installer/customize.sh` | AVB hash footers (SHA256_RSA4096, the port's key) on boot / vendor_boot / dtbo; the selector's `kernel-5.4.zip` holds byte-identical images to the ROM zip | our images carry footers as the ROM's do (`rbou5c/info/*.avbtool-info.txt`); the BL only passes orange |
| `installer/customize.sh` | dtbo: keeps the bone-machine dtbo while that patch is enabled (else A528N dtbo from `A528NKSS7GYI1_kernel.tar`) | 6.12 ships its own dtbo; a ROM dirty flash writes the 5.4 boot/vendor_boot/dtbo back (expected; the user re-selects 6.12) |
| `target/a52sxq/patches/knox_kernel_compat` | preloads the ReSukiSU manager 35222 as `/system/preload/ReSukiSU/base.apk` (KSU only accepts a manager under `/data/app` named `base.apk` whose directory name starts with the package name; `first_boot_defaults` reinstalls it through a session so the path is right) | same manager works with the LKM [N]. The path rule lives in the kernel (`apk_sign.c get_pkg_from_apk_path`, `throne_tracker.c`): it applies to the LKM too |
| `target/a52sxq/patches/kernel_6x_mode` | 8 genfscon lines (wakeup dirs of remoteproc mss/adsp/cdsp/wpss, rtc alarmtimer, pon pwrkey/resin, hall_keys) appended to `vendor_sepolicy.cil`; `(allow kernel self (perf_event (cpu)))`; the runtime switch is `ro.boot.a52sxq.k612vb=1` | present in the tree. [M] 6.12 still logs 5 `system_suspend` read denials on plain `sysfs` wakeup attributes: at least one wakeup directory is not in the list (find it: `ls -lZ /sys/class/wakeup/*/` for label `sysfs`) |
| `target/a52sxq/patches/kernel_selector` | Settings > Kernel: `5.4 (default)` (this build's own images) and `6.12 (experimental)` (`prebuilt/6.12/a52s-k612-oneui9-twrp.zip`, recognised by uname `6\.12\.[0-9]+.*` or the marker prop) | the zip in that slot is still the rbou3/s99q one [N]: without Freecess, sdp_dek, argos, and without `PROCA_MAGIC` |
| `target/a52sxq/patches/kernel_feature_check` | section 5 | |
| `susfs_defaults`, `ksu_metamodule` | per-boot SUSFS toggles; meta-overlayfs 1.3.1-r3 (ext4 loop image + `ksud kernel nuke-ext4-sysfs`) | SUSFS: no-op on 6.12. Metamodule: `modules: meta-overlayfs` on both [M]; `nuke-ext4-sysfs` on the LKM [?] (`ls /sys/fs/ext4` must not show the loop device) |
| `unica/patches/selinux`, `compat_sepolicy_mapping` | drops source-only types, restores the API 30 mapping | policy only. Kernel side: section 9 |
| 5.4 workarounds that stay harmless on 6.12 | `__desixtification` (close_range nop), `zygote_next_kernel54` (inactive), `cgroups` (schedtune/sfreezer optional), `virt` (5.4-mountable EROFS), `apex_dm_relabel`, `apexd_dm_mtime`, `perf_tuning` (`ro.dalvik.vm.enable_uffd_gc=false`), `ion_label`, `ueventd`, `suspend_hidl`, `seccomp`, `file_capabilities` | keep all. `enable_uffd_gc=false` must stay while the preopted boot image is CC: [M] `gc=CC` on both even though 6.12 has userfaultfd |

## 5. `kernel_check` (target/a52sxq/patches/kernel_feature_check), item by item

Result on 6.12 rbou4 [M]: `sys.kernel_check.ok=1 missing=none minor=uvc_stream,uvc_inband_err,kernelsu,gpu_tuning`.

| Check | Level | Probe | 5.4 | 6.12 |
|---|---|---|---|---|
| `bpf_ringbuf` | crit (when `a52_netd.o` pins ring buffers) | kallsyms `ringbuf_map_alloc` | ok | ok (`kernel/bpf/ringbuf.c:190`) |
| `kernel_line` | crit | uname vs `ro.boot.a52sxq.k612vb` | unset = ok | `=1` = ok; top list 6 |
| `cgroups` | crit | `/proc/cgroups`: cpuset cpu cpuacct blkio memory freezer enabled | ok | ok (+ net_cls, net_prio) |
| `btf` | feat | `/sys/kernel/btf/vmlinux` | ok | ok |
| `uvc_gadget` | feat/minor | `CONFIG_USB_CONFIGFS_F_UVC` or `functions/uvc.0` | ok | ok |
| `uvc_enum_formats` | feat/minor | kallsyms `uvc_v4l2_enum_format` | ok | ok |
| `uvc_stream` | minor | `/sys/module/usb_f_uvc/parameters/num_requests` | ok | **missing** (k4-only param) |
| `uvc_inband_err` | minor | `.../parameters/inband_err` | ok | **missing** (k4-only param) |
| `pass_through` | feat/minor | `/sys/class/power_supply/battery/pass_through` | ok | ok since s99t |
| `pd_disable` | feat | `/sys/class/power_supply/battery/pd_disable` | ok | ok |
| `caps` | crit | `cap_last_cap >= 40` | ok | ok |
| `kernelsu` | minor | `CONFIG_KSU=y`, kallsyms `ksu_handle_stat` only if config.gz is unreadable | ok | **false "missing"**: LKM, no `CONFIG_KSU` in the GKI config |
| `close_range` | minor | kallsyms `__arm64_sys_close_range` | ok | ok |
| `gpu_tuning` | minor | `idle_timer=80`, DT `qcom,no-nap`, no 180 MHz step | ok | **differs** (6.12 KGSL has its own values) |

## 6. Config differences a OneUI user or service can observe

Only real differences with a consumer. Whole areas that turned out identical are in section 9.

### 6a. Boot, command line, logging

| Item | 5.4 | 6.12 | Consumer | Status / action |
|---|---|---|---|---|
| Image header 0x28 | `0xecefecef` | 0 (patched by `PROCA_MAGIC=1`) | PROCA TA -> vaultkeeper | top list 1 |
| Image text_offset | 0x80000 | 0 | ABL load address; PROCA TA [?] | top list 1 |
| Boot ramdisk compression | gzip (ROM) | same bytes; our fragment is lz4 + end marker | kernel initramfs unpack | fixed [N] |
| Vendor cmdline | `swiotlb=0 cgroup.memory=nokmem,nosocket lpm_levels.sleep_disabled=1 service_locator.enable=1 msm_rtb.filter=0x237 pcie_ports=compat video=vfb:...` | none of these; adds `clk_ignore_unused pd_ignore_unused regulator_ignore_unused androidboot.a52sxq.k612vb=1 androidboot.first_stage_console=2 rdinit=/ksuinit`, `firmware_class.path` with 3 dirs | memory size, memcg accounting, what `/proc/cmdline` shows | top list 13 |
| Built-in `CONFIG_CMDLINE` | `cgroup_disable=pressure` | `console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig` | PSI per cgroup off on both; KVM does not start (no EL2) | same result |
| `LOG_BUF_SHIFT` | 20 | 17 | dmesg, dumpstate | top list 8 |
| `CONSOLE_LOGLEVEL_DEFAULT` | 4 | 7 | none with `console=null` | n/a |
| Watchdogs | `HH_VIRT_WATCHDOG`, `SOFT_WATCHDOG`, `DPM_WATCHDOG` 5 s | `SOFTLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` 120 s (warn only), `WQ_WATCHDOG`; hypervisor wdt only with `WDT=1` | recovery from hangs | top list 2 |
| `STATIC_USERMODEHELPER_PATH` | `/vendor/bin/umh/usermode-helper-replica` | `""` | none found | n/a |
| Module signing | off | `MODULE_SIG=y`, taint E/O for our modules | `tainted` 1028 -> 12800 [M] | info |

### 6b. cgroups, scheduler, memory

| Item | 5.4 | 6.12 | Consumer | Status |
|---|---|---|---|---|
| `FAIR_GROUP_SCHED`, `CFS_BANDWIDTH` | off | on | task_profiles, Samsung power HAL `cpu.shares` | new behaviour, top list 12 |
| cgroup v2 freezer | absent (v1 only) | present | ActivityManager cached-app freezer, Freecess | top list 3 |
| `CGROUP_NET_CLASSID`, `NET_PRIO` | off | on | none in the ROM | n/a |
| `SCHED_WALT` | built in | `sched-walt.ko` (soc-repo) | perf HAL, HYPER, post_boot | equivalent with moved nodes [M] |
| `MEMCG_SWAP`, `MEMCG_KMEM`, `MEMCG_FORCE_USE_VM_SWAPPINESS`, `MEMCG_HEIMDALL` | on | memcg v1+v2 without the Samsung parts | lmkd (`memcg=0` on both [M]), `services.jar` reads `/sys/fs/f2fs/features/sec_heimdallfs` | missing; lmkd works [M] |
| Samsung MM: `PAGE_BOOST(_RECORDING)`, `RBIN` + `ION_RBIN_HEAP`, `MULTIPLE_KSWAPD` (`KSWAPD_CPU=0x7F`), `SPECULATIVE_PAGE_FAULT`, `PROCESS_RECLAIM`, `BALANCE_ANON_FILE_RECLAIM`, `MMAP_READAROUND_LIMIT`, `INCREASE_MAXIMUM_SWAPPINESS` | on | absent (`a52sxq_mm_boost.ko` gives the `mem_boost_mode` nodes; lmkd still got ENOENT on `/sys/kernel/sec_mm/mem_boost_mode` [M]) | lmkd, camera HAL, `services.jar` (`/sys/kernel/rbin/refill_mode`, `/proc/reclaimer_log`), HYPER (`kswapd_perftune_cpumask`, `am_app_launch`) | missing, tuning only |
| zram | built in; `ZRAM_LRU_WRITEBACK` (Samsung kernel thread, limit 5120), `zram_balance_ratio` param | `zram.ko` + `zsmalloc.ko`; upstream `ZRAM_WRITEBACK=y`, `ZRAM_MULTI_COMP`, default `lzo-rle` | fstab.ramplus (`zramsize`), `services.jar` NandswapManager (`backing_dev`, `idle`, `writeback`, `writeback_limit`, `bd_stat` = upstream names), `init.memory.rc` | equivalent [M 8 GiB, lz4, swap on]. RAM Plus writeback [?]: `cat /sys/block/zram0/bd_stat` after a day |
| THP | off | `TRANSPARENT_HUGEPAGE_MADVISE` | `init.memory.rc` writes khugepaged/defrag off | present, harmless |
| KFENCE, `KASAN_HW_TAGS`, MTE, BTI, PAC, SCS, CFI, KPTI | off | on in config (MTE unused on this SoC; `kpti=0 kasan=off` on the cmdline) | none directly | info; small RAM/CPU cost [?] |
| `UCLAMP_BUCKETS_COUNT` | 5 | 20 | none | n/a |

### 6c. Filesystems and block

| Item | 5.4 | 6.12 | Consumer | Status |
|---|---|---|---|---|
| exFAT | `SDFAT_FS` (also offers `exfat`), `SDFAT_UEVENT`, `/sys/fs/sdfat/statistics` | upstream `EXFAT_FS=y` | Samsung vold + `fsck.exfat_sec` | equivalent by type [M]; card test [?] |
| NTFS | `NTFS_FS=y` (read-only) | none (`NTFS3_FS` not set) | vold ("detected NTFS file system", "Use ntfs3 instead of ntfs") | **missing** |
| `TMPFS_XATTR` | y | not set | overlay on a tmpfs upper/lower with `trusted.*` (Magisk-style module mounts); the ROM's meta-overlayfs uses an ext4 image, so it is not affected [S] | missing; matters only for third-party modules |
| `FAT_UEVENT`, `FAT_SUPPORT_STLOG`, `FUSE_SUPPORT_STLOG`, `PROC_STLOG/FSLOG/DLOG` | on | absent | vold, fsck, init, update_engine write `/proc/fslog/stlog` [M ENOENT] | missing, logging only |
| F2FS Samsung parts (`F2FS_SEC_SUPPORT_DNODE_RELOCATION`, sec sysfs, ioctls 0xf514/0xf522/0xf528) | on | absent; 6.12 adds `checkpoint_merge`, `nogc_merge`, `discard_unit=block`, `linear_lookup`, `F2FS_FS_LZ4HC`, `F2FS_IOSTAT` | vold (`sec_lfo_alloc` EACCES, `mp_uid` ENOENT [M]), `services.jar` (`features/sec_dnode_relocation`), `checkpoint_gc` | missing, features report "unsupported"; /data mounts with the same fstab [M] |
| f2fs casefold, compression (lzo/lz4/zstd), quota (`QFMT_V2`), fs-verity, inline crypt | on | on | vold, installd | present |
| `FS_VERITY_BUILTIN_SIGNATURES`, integrity keyring | on | off | `/proc/sys/fs/verity/require_signatures` is referenced, A17 does not rely on it | n/a |
| EROFS | no big pcluster / compr_cfgs, `CLUSTER_PAGE_LIMIT=1` | all 10 features, zstd | APEX payloads; ROM `virt` rebuild | present, better |
| FUSE | plain | `FUSE_BPF=y`, `FUSE_PASSTHROUGH=y` | MediaProvider; `prog_fuseMedia_fuse_media` pinned on 6.12 [M] | top list 3 |
| dm targets (`DM_CRYPT`, `DEFAULT_KEY`, `VERITY`+FEC, `SNAPSHOT`, `BOW`) | on | on, + `DM_USER` | vold, apexd, fs_mgr; 36 dm devices on both [M] | present. `DM_ANDROID_VERITY_AT_MOST_ONCE_DEFAULT_ENABLED` absent: n/a (vbmeta has verity off) |
| Inline encryption | `SCSI_UFS_CRYPTO_QTI`, wrapped keys possible | `qcom_ice.ko` + `ufshcd-crypto-qti.ko`, `ICE_RAW=1`, boot KAT | vold `inlinecrypt_optimized`, no wrappedkey in `fstab.qcom` | present [M kat_state=1]; the installer refuses a wrappedkey fstab |
| I/O scheduler | `ssg` default (`MQ_IOSCHED_SSG=m`), `BLK_SEC_STATS` | `mq-deadline`; `blk_sec_stats.ko` port | `init.qti.kernel.rc` (bfq lines commented out), dumpstate reads `queue/iosched/*_latency` (ssg only) | equivalent; ssg nodes missing |
| loop | `BLK_DEV_LOOP_MIN_COUNT=16`, `loop.max_part=7` | same | apexd | present |
| pstore | ram + console + pmsg, deflate, `PSTORE_PMSG_SSPLOG` | ram + console + pmsg (+ blk as module) | dumpstate, `/sys/fs/pstore/*` | present; Samsung ssplog missing |

### 6d. Networking, BPF, netfilter, IPsec

| Item | 5.4 | 6.12 | Consumer | Status |
|---|---|---|---|---|
| Every `NETFILTER_XT_*`, `IP_NF_*`, `IP6_NF_*`, conntrack helper symbol of 5.4 | on | on (+ `XT_MATCH_CONNBYTES`, `XTABLES_COMPAT`) | netd, Samsung firewall | present |
| `IP_NF_MATCH_AH`, `INET6_AH`, `BRIDGE_NF_EBTABLES`, `BRIDGE_EBT_BROUTE` | on | off | none found in the ROM's rules or binaries | n/a |
| `SYN_COOKIES` | on | off | nothing writes `tcp_syncookies` [S] | n/a |
| TCP | default `bic`; `tcp_htcp`, `tcp_westwood` modules; `tcp_default_init_rwnd`, `tcp_delack_seg`, `tcp_use_userconfig` | `cubic` (+ bbr); those sysctls absent | `init.rc`/post_boot writes (fail quietly) | missing, tuning |
| Samsung net: `NET_ANALYTICS`, `/proc/sys/net/core/support_dropdump`, `tcp_netpm`, `/proc/sys/net/optr` | `NET_ANALYTICS=y`; the other three are not in the 5.4 config either | absent | `libsec-ril.so` | n/a (absent on both) |
| ARGOS | built in | `sec_argos.ko` + DT overlay | argosd | present [N] |
| BPF | ringbuf map backport, BTF, JIT | native ringbuf + helpers, `BPF_LSM`, `BPF_JIT_DEFAULT_ON`, kprobe/tracepoint/uprobe events as 5.4 | netbpfload, lmkd memevents, uprobestats, gpuMem, timeInState | present, more programs load [M] |
| XFRM / IPsec algorithms | ESP v4/v6, xfrm user/interface, NET_KEY | same, + `XFRM_MIGRATE`, `CRYPTO_XCBC`; twofish gone | IMS/ePDG | present |
| tun, veth, wireguard | tun, veth | + `WIREGUARD=y`, vsock, ifb, more qdiscs | VpnService | present, more |
| PPP, PPTP, L2TP, MPPE | built in | GKI modules, not shipped | legacy VPN types (`/dev/ppp`) | missing; add modules if any OneUI VPN type still uses mtpd |
| Kernel Bluetooth (`BT`, `RFCOMM`, `HIDP`), rfkill | built in | `rfkill.ko` shipped; `bluetooth.ko` not (the closed HAL owns the UART) | none (userspace stack + `btpower`) | n/a |
| cfg80211 | built in | `cfg80211.ko` + `wlan.ko` (qcacld) | Wi-Fi HAL, semwifi | present; 4 private commands missing (READINESS) |
| Wi-Fi RX wakelock | timeout 0 in 5.4 qcacld | patched to 0 (qcacld-0003) | AOD drain | fixed [N, M `active_count 0`] |

### 6e. USB, HID, input

| Item | 5.4 | 6.12 | Consumer | Status |
|---|---|---|---|---|
| Gadget functions | 29 names | 19 names; missing `audio_source.gs3 ccid.ccid cser.dun.0 cser.dun.2 cser.nmea.1 diag.diag diag.diag_mdm diag.diag_mdm2 qdss.qdss qdss.qdss_mdm` [M] | `init.qcom.usb.rc` factory/DM configs | missing; no normal USB mode needs them (`samsung-oneui/usb_funcs`) |
| `ss_mon`, `conn_gadget` | built in | `usb_f_ss_mon_gadget.ko`, `usb_f_ss_conn_gadget.ko` | MTP monitor, Smart Switch | present; `ss_mon` bound in MTP mode [?] (sweep skipped: not in MTP mode) |
| MTP/PTP kernel functions (`USB_F_MTP/PTP`) | on | off | none (stock rc uses `ffs.mtp`) | n/a |
| Accessory, MIDI, UAC2, UVC, NCM, ECM, RNDIS (gsi) | on | on | UsbDeviceManager | present; `f_rndis/ethaddr` ENOENT is the legacy android_usb path [M] |
| USB host Ethernet | built in | modules not shipped | EthernetService, DeX docks | **missing**, top list 9 |
| `USB_HOST_SAMSUNG_FEATURE`, `USB_STORAGE_DETECT`, `USB_AUDIO_ENHANCED_DETECT_TIME` | on | off | Samsung host tweaks | missing, minor |
| HID: samsung, ntrig, saitek, acrux, holtek, keytouch, lcpower, ortek, primax, speedlink, tivo, waltop, zydacron, ems_ff, aksys | built in | absent (hid-generic) | keyboards, old gamepads | **missing** (samsung is the one that matters) |
| `UHID`, uinput | on | on | BT HID host, Samsung DeX | present |
| Input names | `qpnp_pon`, `sec_touchpad` | `pmic_pwrkey` + `pmic_resin`; no `sec_touchpad` [M] | key layout files (`qpnp_pon.kl`), SemInputDeviceManager | check that the power / vol-down key layout resolves: `dumpsys input \| grep -A3 pmic_` |
| `SEC_INPUT_BOOSTER` | built in | `input_booster.ko` | HYPER | present |

### 6f. Security, tracing, /proc surface

| Item | 5.4 | 6.12 | Consumer | Status |
|---|---|---|---|---|
| SELinux policy version max | 31 | 33 | init compiles the split policy for the kernel's version (vendor has no precompiled policy) | present; boots enforcing [N] |
| SELinux policycaps known to the kernel | subset | 9 names up to `userspace_initial_context`; **no** `netlink_xperm` in this 6.12.81 tree | the ROM policy declares `network_peer_controls open_perms extended_socket_class nnp_nosuid_transition netlink_xperm` | same effective set on both: `netlink_xperm` is ignored by both kernels. It becomes live with a kernel that knows it (upstream 6.13+): the A14 vendor domains would then need `nlmsg` rules |
| `CONFIG_LSM` | `lockdown,yama,loadpin,safesetid,integrity,selinux,...,baseband_guard` | `landlock,lockdown,yama,loadpin,safesetid,selinux,...,ipe,bpf` | none directly | info |
| `USER_NS`, `PID_NS` | off | off | Chrome/WebView sandbox layer | same |
| `SECURITY_DMESG_RESTRICT`, `DEVMEM`, `DEVKMEM`, `KCOV`, `KGDB`, kmemleak | off | off | integrity-type checks | same |
| `DEBUG_FS` | off | on | top list 14 | differs |
| `IKCONFIG_PROC`, `KALLSYMS_ALL`, `UID_SYS_STATS`, `CPU_FREQ_TIMES`, wakeup_reasons, `PM_WAKELOCKS`, PSI | on | on | kernel_check, BatteryStats, system_suspend, lmkd | present |
| `/proc/uid_time_in_state` | present | absent | `framework.jar` fallback; A17 uses the BPF map | equivalent |
| `IKHEADERS` | y | m | bcc-style tools only | n/a |
| Audit, seccomp filter, perf events, hw breakpoints, io_uring, kprobe/uprobe events | on | on | logd, minijail, simpleperf, debuggerd | present |
| userfaultfd | off | on | ART (forced off by prop) | no effect while the prop stays |
| sysrq | `MAGIC_SYSRQ_DEFAULT_ENABLE=0x1` | same | `init.rc` writes `kernel/sysrq` | same |
| Hibernation | off | on (`disk` in `/sys/power/state`) | none | info |

## 7. Samsung drivers: status of today's module ports (`drivers612/samsung-oneui`)

| 5.4 feature | ROM consumer | 6.12 | Evidence |
|---|---|---|---|
| `CPU_FREQ_LIMIT` (`/sys/power/cpufreq_{min,max}_limit`, table, `cflm`) | SSRM, thermal HAL, bauth, HYPER | `cpufreq_limit.ko` | [M] same table and limits |
| `SEC_INPUT_BOOSTER` | HYPER | `input_booster.ko` | [M] |
| `SAMSUNG_FREECESS` (netlink 27, binder/signal hooks) | FreecessHandler / MARs | `freecess.ko` (vendor hooks; rebuild with every Image change) | [N] "mIsKernelSupportFreecess = true"; 3 freecess error lines on 6.12 [M], read `collect-freecess_errors.txt` |
| `SDP` (`/dev/dek_*`, netlink 28/29) | vold libepm | `sdp_dek.ko` | [N]; `dek_kek` absent on both [M] |
| `FSCRYPT_SDP` (sensitive-file hooks in fscrypt) | Knox SDP / Secure Folder file classes | **missing** (needs the Image) | framework side is stubbed in the port per `sdp_dek` notes [N]; Secure Folder create/lock/reboot/unlock [?] |
| UFS sec sysfs (`/sys/class/sec/ufs/un` ...) | vaultkeeperd, wvkprov, engmode | `ufs_sec_sysfs.ko` | [M] UN hash identical |
| `USB_F_SS_MON_GADGET`, `USB_F_CONN_GADGET` | MTP monitor, Smart Switch | both modules | [M] function names present |
| `ARGOS` | argosd | `sec_argos.ko` + `ARGOS=1` overlay | [N] |
| `BLK_SEC_STATS` | io_stats, SSRM | `blk_sec_stats.ko` | [M] one ENOENT left: `/sys/kernel/blk_sec_stats/cpufreq_min` |
| sec class dirs (hall_ic, sdcard, sdinfo, ...) | Storage, cover, diagnostics | `a52sxq_sec_class.ko` (2 real, rest 5.4-format stubs) | [M] `sd_class` all present |
| grip `sx9360` | SAR backoff | `sx9360.ko` + i2c-gpio | [N]; SensorsGrip still ENOENT on `grip_sensor/country_code`, `grip_notifier`, `sec_touchproximity` [M] |
| `vrr_state`, `panel_vcom_type` | display services | `a52sxq_vrr_state.ko` | [N] |
| battery `pass_through`, `sub_bat_temp_raw` | Pause USB PD | sec-battery patch | [N]; `wc_param_info` missing on both [M] |
| sec_debug family (`/proc/reset_reason`, `last_kmsg`, `extra`, `pwrsrc`, `sec_log`, `boot_stat`), `SEC_PARAM`, `SEC_QUEST`, `SEC_ABC`, `SEC_PM` | dumpstate, hqm, `lpm`, `resetreason`, rdxd | **missing** | [M] ENOENT rows; top list 8 and 10 |
| `HDCP_QSEECOM` (`/dev/msm_hdcp`, class `hdcp`) | SDM, `libhdcpsrm` | built, not loaded | top list 15 |
| `HH_VIRT_WATCHDOG` | - | `WDT=1` option, off in rbou builds | top list 2 |
| `SPU_VERIFY`, `MST_LDO` / `MST_ARCH_QCOM` | spu partition check; MST pay | missing | n/a: no `mstldo` class on the 5.4 live list of this phone; `spu` is mounted by fstab without kernel help |
| PROCA / FIVE config for the PROCA TA | vaultkeeper TA client authentication | header magic only | top list 1 |

## 8. Behaviour that changes because syscalls and kernel features now exist

All [M] from `quirk.*`, `bpf.*`, `cgroup.*`, `kernel.binder` rows unless marked.

| Feature | 5.4 | 6.12 | Who changes behaviour |
|---|---|---|---|
| `openat2`, `faccessat2`, `pidfd_getfd`, `process_mrelease`, `futex_waitv`, `cachestat`, `mseal`, `landlock_*` | ENOSYS | ok | bionic, lmkd (`process_mrelease` after kills), ART/Chrome (mseal, landlock where used) |
| userfaultfd | ENOSYS | ok | nobody while `ro.dalvik.vm.enable_uffd_gc=false` |
| AF_VSOCK | EAFNOSUPPORT | ok | traced relay (the port removed it for 5.4) |
| cgroup v2 freezer | absent | present | CachedAppOptimizer freezer + binder freeze |
| net_cls / net_prio v1 controllers | absent | present | none found |
| BPF objects | 15 top-level pins, 82 netd maps | 19 pins, 108 netd maps | fuse-bpf, dmabuf/memevents/wakelock stats, Samsung `semUidBPF` |
| bpfloader service | `bpfloader` (5.4 loader) | `bpfloader_apex` | Tethering trains: the stock loader + the APEX's own `netd.o` |
| dma-heaps | none (`/dev/ion` only) | 10 heaps + ioncompat `/dev/ion` | gralloc/codec2 of the A17 system may pick dma-buf heaps where 5.4 forced ION; labels exist [M] |
| binder features | `freeze_notification oneway_spam_detection` | + `extended_error transaction_report` | libbinder |
| EROFS features | none | 10 | stock `com.android.virt` would mount; the port's rebuilt one still works |
| f2fs mount options | `no_heap` ... | + `checkpoint_merge nogc_merge discard_unit=block flush_merge barrier` | fsync and checkpoint timing |
| modem subsystem view | 7 `ONLINE` under `/sys/bus/msm_subsys` | 4 `running` remoteprocs + `subsys_compat.ko` | libmdmdetect (12 EACCES on `subsysN/name` [M]): label, not kernel |

## 9. Checked and found the same (no need to look again)

- Netfilter/xtables: every 5.4 match and target the config has is in the 6.12 config; only AH and ebtables differ, no consumer.
- cgroup v1 controllers cpuset, cpu, cpuacct, blkio, memory, freezer; PSI (`cgroup_disable=pressure` on both).
- binderfs, three binder devices, ashmem (6.12: Rust driver), memfd, `/dev/ion` (ioncompat), incfs, overlayfs.
- dm-default-key, dm-verity (+FEC), dm-bow, dm-snapshot, dm-crypt; loop count and `loop.max_part`.
- Crypto used by vold/keystore: adiantum, aes-xts (ARMv8 CE), blake2b, zstd, lz4, sha2; 6.12 adds hctr2, sha3, xctr, polyval.
- f2fs casefold, compression, quota, checkpoint, fs-verity; `UNICODE`.
- seccomp filter, audit, perf events, hw breakpoints, io_uring, kprobe/uprobe events, BTF.
- `USER_NS` and `PID_NS` off, `DEVMEM`/`DEVKMEM`/`KCOV`/`KGDB` off, sysrq default 0x1, `PANIC_ON_OOPS=y`, `PANIC_TIMEOUT=-1`, `HZ=250`.
- SELinux: enforcing on both, 7 avc groups on 6.12 (5 of them `system_suspend` on unlabelled wakeup attributes); netlink error lines in logcat are equal on both (37 vs 39 `error{-2}`).
- UFS unique number hash, IMEI presence, zram size and algorithm, `/proc/cgroups` set, cap_last_cap, Tethering APEX version.
- `/proc/simslot_count`: `GPIO_DS_DETECT` is not set in 5.4, the node is absent on both.
- MST: not on this model's 5.4 live class list.

## 10. Not verified by this audit

- Whether `PROCA_MAGIC=1` (alone or with `PROCA_TEXTOFF=1` / `PROCA_HDR_RES`) ends the vaultkeeper loop: a manual test, result not written down when this file was made.
- Everything tagged [?] above: exFAT/NTFS media, power-off charging, ss_mon binding in MTP mode, RAM Plus writeback, HDCP, Secure Folder with `FSCRYPT_SDP` missing, `su` from apps on the LKM, `nuke-ext4-sysfs`, the freezer interplay, swiotlb memory.
- The Wi-Fi nl80211 vendor command table was not re-diffed here (READINESS: 95 of 100 private commands, 4 named missing).
- `/sys` and `/proc` strings come from `strings`; a path in a binary is not proof that the code runs on this phone.
