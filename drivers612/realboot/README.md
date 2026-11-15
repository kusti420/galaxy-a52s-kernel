# realboot: the real boot path for LineageOS on the Qualcomm 6.12 kernel and the 6.18 port

> **NOTHING HERE HAS BEEN FLASHED OR RUN ON A PHONE.** Flashing any image of this directory
> needs the owner's explicit OK for that flash. Targets: test phone 2, **PHONE2**
> (LineageOS 24 / Android 17 userdebug, bit-2 bootloader A528BXXS2DWB5, unlocked), and since
> 2026-11-15 test phone 1, **PHONE1** (same LineageOS build, bit-5 A528BXXU5FWK4; section 2d). **Never on
> DAILYPHONE (owner's daily phone) or OTHERPHONE (One UI port).** Never raise the bootloader
> bit. Never load firmware from another phone (2026-11-13 incident).

Today Android 17 runs on 6.12 only through the test path: ABL -> 6.18 harness on `recovery` ->
kexec -> 6.12 with a test ramdisk (helper2.sh loads module stages, userdata held read-only,
/data on zram). This directory builds what a later flash puts on `boot`, `vendor_boot`, `dtbo`
and (a few added files) the vendor partition, so that the bootloader starts 6.12 directly with
the real /data.

    ./build-realboot.sh [name]               # 6.12, default rb-612 -> out/<name>/ (REPORT.txt has every check)
    KERNEL=618 ./build-realboot.sh [name]    # 6.18, default rb-618 (section 2b)

**2026-11-15 14:3x: `out/rb618-5` = 6.18 at parity with rb16** (MODEM=1, SDCARD=1, GPU/bus DCVS,
sync_state timeout, DIAG bootargs; 6.18 Wi-Fi by a bind over 5.4-gki so the 6.12 wlan.ko stays):
section 2g; rehearsal packages `out/rh-rh618p2`, `out/rh-rh618p1` (not run).

**2026-11-15: 5.4 sysfs paths (research/sepolicy/PATHS.md).** The tree is now in the 5.4 layout
(QUP I2C/SPI/UART nodes as /soc children with `qcom,wrapper-core`, /aliases i2c18..25 = the 5.4
bus numbers; `drivers612/boarddt/tools/sysfscompat.py`, same step in kexec/mkandroidtree.sh and
bsp618/android/mkdtb-618.sh) so the ROM's genfscon labels apply again (rb10: touch `enabled` and
SM5714 fuel-gauge denials). It needs the geni modules with `bsp612/patches/soc-repo/0009`: default
`REF` is now `s75` / `a9` (= s74 / a8 + those modules, `tools/rd-swap-ko.py`) and the build fails
on a geni module without the patch. `out/rb11` (DIAG=1, = rb10 + this) and `out/rb618-4` are
built, NOT flashed; rehearsal package `out/rh-rh612d` (rb11, phone 2); `out/rh-rh612p1` = the
same for phone 1 (section 2d: rb11 needs no phone-1 variant).

Current builds (2026-11-14 19:2x, all offline checks pass, **no blockers**, NOT flashed):

| Build | Kernel | Modules (tested ramdisk) | Tree (tested KEXEC_BASE) |
|---|---|---|---|
| `out/rb3/` | 6.12.81-4k-g8a69376da734 (bsp612, COMMAND_LINE_SIZE 4096) | `drivers612/androidboot/out/s74-rd.cpio.gz` (runs ab-s74/s74t) | `out-ack/kx/android-r02.dtb` |
| `out/rb618-2/` | 6.18.33-4k-g00c8666046c2-dirty (bsp618/android/out/dist) | `bsp618/android/out/a8-rd.cpio.gz` (runs ab618-a8/a8e) | `bsp618/android/out/android-r02-618.dtb` minus `a52ram` |

`out/rb1.SUPERSEDED-cmdline2048/` is the first build (2048-byte kernel, s68 modules): do not flash.
`out/rb2.SUPERSEDED-addon-moddep/`, `out/rb618-1.SUPERSEDED-addon-moddep/` (19:26): images identical in
function to rb3/rb618-2, but their vendor add-on's `modules.dep` had `name.ko: ` lines (trailing
blank); libmodprobe then adds the directory itself as a dependency and loads NOTHING (rehearsals
rh612a/rh618a: rc ran, modprobe exit 1, no sound card). rb3/rb618-2 (2026-11-14 20:3x): depmod
format, `modprobe -s` in the rc, empty `5.4-gki/modules.dep` (macloader only), and
`tools/modprobesim.py` (libmodprobe dry run) in the checks. Do not install the old add-ons.

**2026-11-14 21:2x-21:4x: rb4 and rb5 were flashed on phone 2 and FAILED identically** (18
boots: boot logo, "Warm Reset by Watchdog Bite" every 54-68 s, not one byte of 6.12 in ramoops,
i.e. dead before ~0.1 s). Analysis and the instrumented builds: **`kernel-diag/README.md`**.
`out/rb6` = rb5 + DIAG kernel (`bsp612/out/diag/Image`: same release and export CRCs + a52bc
breadcrumbs, hypervisor-watchdog STATUS, RAM console at 0xf0be0000 that the harness prints as
`/proc/a52ram`) + `a52ram` reservation + `keep_bootcon initcall_debug ignore_loglevel
softlockup_panic=1`; `out/rb6w` = rb6 + `a52bc.wdt=off`. Build: `kernel-diag/build-diag-kernel.sh`,
then `DIAG=1 ./build-realboot.sh rb6` (runs `kernel-diag/qemu-test.sh`, the QEMU smoke test of
that Image). Flash exactly like rb5 (section 3, `B=drivers612/realboot/out/rb6`); after a
failure read `/proc/a52ram` in the harness FIRST (kernel-diag/README.md, "Reading the result").
Each build has `REPORT.txt`, `SHA256SUMS`, `info/` (avbtool + unpack_bootimg dumps, dtbo table,
mkbootimg arguments), `insmod-simulation.txt`, `cmdline-predicted*.txt` (incl. a 2.8 KiB
bootloader-append worst case), `dtb-vs-tested.diff`, `module-plan.txt`, `vendor-addon/`.

## 1. How the installed LineageOS boots (phone 2, from testdev-PHONE2/ dumps)

| Partition | Size | Content (as dumped 2026-11-11) |
|---|---|---|
| `boot` | 100663296 | **header v3**, raw arm64 5.4 Image (47.8 MB), generic ramdisk (LZ4 legacy, 1.7 MB: first-stage `init` + empty dirs), cmdline **empty**, os 17.0.0 / patch **2026-10**; unsigned AVB hash footer (Algorithm NONE) |
| `vendor_boot` | 100663296 | **header v3** (no vendor ramdisk table, no bootconfig), page 4096, base 0, kernel 0x8000, ramdisk 0x01000000, tags 0x100, dtb 0x01f00000; **vendor ramdisk = only `first_stage_ramdisk/fstab.qcom`** (2.5 KB, no modules); dtb = 37 concatenated dtbs, the last one is Qualcomm's yupik base (`androidboot.dtb_idx=36`; the other 36 are unrelated boards); vendor cmdline below |
| `dtbo` | 25165824 | dtbo table, 3 Samsung overlay entries r00, r01, r02 (board-id `<0x22 N>`); the phone (rev 4) gets entry 2 (`androidboot.dtbo_idx=2`) |
| `vbmeta` | | **flags 3** (verification + hashtree disabled), SHA256_RSA4096 with AOSP's public test key (`external/avb/test/data/testkey_rsa4096.pem`, sha1 2597c218) |
| `recovery` | 81788928 | own header-v2 image (kernel + ramdisk + dtb + recovery dtbo), signed with the same test key. **Now holds the 6.18 harness** (kexec9-p2); LineageOS recovery is in `testdev-PHONE2/recovery.img` |
| `super` | 10643046400 | `system vendor product odm` only. **No vendor_dlkm, system_dlkm or odm_dlkm.** Non-A/B. |
| `apnhlos` | | `/vendor/firmware_mnt` (vfat): adsp, cdsp, a660_zap, vpu20_1v, yupik_ipa_fws, TAs; since the incident also the rollback-5 wpss from phone 1 (`fw-v5-from-p1/`) |

Boot flow on 5.4: ABL picks the yupik dtb from vendor_boot by `qcom,msm-id` + `qcom,board-id`
(`<0 0>`), applies the dtbo entry chosen by `<0x22 N>` with N <= hardware revision (its
libufdt needs `/__symbols__` in the base and `/__fixups__` in the overlay), applies the
hypervisor resource manager's own overlay (targets `/soc/qcom,wdt@17c10000`, `/soc/timer` by
path, adds `/hypervisor`), fills `/memory`, adds `uh_heap_region`/`uh_guest_region`, and
**appends** the command line to the dtb's `/chosen/bootargs`: live tree = stock dtb bootargs +
vendor_boot cmdline + ~2.7 KB of its own (`androidboot.*`, `msm_drm.dsi_display0`,
`msm_drm.lcd_id`, `sec_debug.*`, ...), 3195 bytes in total. Boot ramdisk + vendor ramdisk are
concatenated; `androidboot.force_normal_boot=1` comes from the ABL.

Modules on 5.4 (from the ROM tree `$ANDROID_TREE/device/samsung/sm7325-common`, same LineageOS
base; phone 2's vendor itself was not dumped): **no first-stage modules**. They live in
`/vendor/lib/modules` (vendor partition, 91 files). `vendor_modprobe.sh` (init.target.rc,
early-init) loads all of them in parallel and falls back to `/vendor/lib/modules/5.4-gki` if the
first one does not load; init.target.rc then modprobes the audio list (early-init) and
`qca_cld3_wlan` from both dirs (on boot); `macloader` (post-fs-data) writes
`/sys/kernel/icnss/wpss_boot` and finit_module()s `/vendor/lib/modules/qca_cld3_wlan.ko`, then
`.../5.4-gki/qca_cld3_wlan.ko`. init.qcom.rc writes `/sys/kernel/boot_adsp/boot` and
`boot_cdsp/boot` at early-boot. Firmware: `firmware_class.path=/vendor/firmware_mnt/image`, plus
ueventd (`/vendor/firmware_mnt/image /vendor/firmware-modem/image /spu` + AOSP defaults).

## 2. The real boot on 6.12 (what `build-realboot.sh` builds)

Principle: reproduce **exactly what ran in test run ab-s74** (phone 2, 2026-11-14 18:21: boot
completed with display, touch, GPU, audio incl. the QoS fix, Wi-Fi, BT, NFC, camera, video
record/decode, torch with the real SM5714 flash driver, fingerprint, vibrator, sensors,
charging, cpufreq; rb1 used ab-s68), minus the test scaffolding. Modules are taken byte for byte
from that run's ramdisk (`drivers612/androidboot/out/s74-rd.cpio.gz`); the device tree is rebuilt
from the same inputs as `kexec/mkandroidtree.sh` and diffed against the tested
`out-ack/kx/android-r02.dtb` (the only difference allowed is the USB extcon, below). The ROM's
own images are rebuilt first as a control and must come out byte-identical (they do, incl. the
AVB footer), which proves the packer arguments.

| Image | What is in it |
|---|---|
| `boot.img` | v3: bsp612 GKI `Image` 6.12.81-4k-g8a69376da734 (the s74 kernel, COMMAND_LINE_SIZE 4096) + **the ROM's generic ramdisk, unchanged**; **os_version/os_patch_level copied from the ROM's boot.img** (Keymaster binds the /data keys to them: never flash a boot.img with another patch level); unsigned footer with the ROM's salt and props |
| `vendor_boot.img` | v3, same header values as the ROM's. dtb: the merged board tree (one dtb). Vendor ramdisk = the ROM's own (fstab only, bytes unchanged) + an appended cpio: `/lib/modules` (190 first-stage modules, `modules.load` in test order, `modules.dep/alias` from depmod against System.map, empty `modules.softdep`, `modules.options`, `modules.blocklist`), `/force_debuggable` + `/adb_debug.prop` (one property, below) |
| `dtbo.img` | one entry: root props of the stock r02 entry (`<0x22 2>`, matches rev >= 2), one fragment `&soc { a52sxq,realboot = "<name>"; }` so that `__fixups__` exist; the board is already in the base |
| `vendor-addon/` | for the vendor partition (all new files): `lib/modules/6.12/` (32 audio modules), `lib/modules/5.4-gki/qca_cld3_wlan.ko` (= 6.12 `wlan.ko`), `etc/init/a52sxq-k612.rc` |

### Device tree
Base = `drivers612/boarddt/out/build/merged-r02.dtb` + gpu, video (fdtoverlay) + dma-heaps
`secure_cdsp`/`display` disabled + audio, FastRPC, camera, fingerprint, vibrator, NFC overlays +
pmic-glink `battery_charger` disabled + SoundWire master version 1.6 + `modem_pas` disabled
(phone 2's modem image is refused since the incident, and there is no IPA data path). These are
real fixes and stay. Left out: `kexec/mkfulltree.sh`'s test edit (ssusb `extcon` cut to the
EUD); the real tree keeps `<&eud>, <&a52sxq_usb_extcon>`, so dwc3 waits for the power stack's
extcon (both are first-stage). `USB_EXTCON=eud` builds the test variant. Not needed any more
(the ABL and the hypervisor do them on a real boot): every step of `kexec/mkkexecdtb.py`
(memory, `/hypervisor`, uh regions, watchdog status, timer) **and the rmtfs carry-over**: the
SIGBUS page range 0x9c900000 was assigned to the modem by the 6.18 harness's own
`qcom_rmtfs_mem`; the 5.4 tree has no fixed rmtfs region at all (it uses a dynamically
allocated `qcom,sharedmem-uio`), our tree has none, and nothing on a real boot assigns that
range (`msm_sharedmem` stays blocked while the modem is off). Added: `/soc/a52sxq-dsp-boot`
(below) and a marker property. `/chosen/bootargs` is replaced (next section). Root
`qcom,msm-id`/`qcom,board-id` stay the stock base's (`<0 0>`); checks: `__symbols__`, ABL and
hypervisor targets, labels `soc intc reserved_memory aliases firmware wdog arch_timer
qcom_tzlog`, `kaslr_region@A0001000`, `ramoops@F0B00000`, merged size < 0x201000 (660 KB).

### Command line
The Samsung ABL **appends** to the dtb's `/chosen/bootargs` (unlike kexec_file_load, which
replaced them; that is why `android_arch_task_struct_size=512` was missing in the cpufreq
crashes). Qualcomm's yupik bootargs would therefore apply on a real boot, including options no
test ever ran with (`fw_devlink.strict=1`, `cpufreq.default_governor=performance`,
`panic_on_rcu_stall`, `ftrace_dump_on_oops`, `slub_debug=-`, `swiotlb=0`, ...). The build
replaces them with the tested set; they come first in the final string, so they survive any
truncation.

| Where | Arguments |
|---|---|
| dtb `/chosen/bootargs` | `android_arch_task_struct_size=512 rcupdate.rcu_expedited=1 rcu_nocbs=0-7 kpti=0 arm64.nosme sysctl.kernel.sched_pelt_multiplier=4 no-steal-acc irqaffinity=0-1 kasan=off cgroup_disable=pressure restrict_cma_redirect=false` (all REQUIRED/tested, from `androidboot/out/android-cmdline.txt`) |
| vendor_boot cmdline | `console=null androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 loop.max_part=7 firmware_class.path=/vendor/firmware_mnt/image,/vendor/firmware iptable_raw.raw_before_defrag=1 ip6table_raw.raw_before_defrag=1 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused androidboot.a52sxq.k612=1 androidboot.first_stage_console=2` |
| kernel (CONFIG_CMDLINE, prepended) | `console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig` |
| ABL (appended) | `androidboot.verifiedbootstate/boot_devices/serialno/bootloader/revision/dtbo_idx/...`, `msm_drm.dsi_display0`, `msm_drm.lcd_id`, `sec_common_fn.lcd_id` (libmodprobe applies `module.param=` from /proc/cmdline, so the panel id is not hard-coded) |

What stays, changes, goes (test cmdline = `androidboot/out/android-cmdline.txt`):
- **Gone (test-only):** `a52.*` (helper), `loglevel=7`, `androidboot.selinux=permissive`
  (`SELINUX=permissive` re-adds it for a diagnostic build), every `androidboot.*` copied from
  the live tree (the ABL passes them itself), `log_buf_len=4M`.
- **Changed:** `firmware_class.path` now has two entries (`/vendor/firmware_mnt/image` first,
  then `/vendor/firmware`; the 6.12 loader takes up to 10, comma-separated). This replaces the
  helper's `force_sysfs_fallback` (wlan.pre; the ROM's own init.qti.kernel.rc sets
  `force_sysfs_fallback=1` at early-init anyway, as on 5.4: direct loads are still tried first, and
  in the rehearsals no request needed the fallback): GPU `a660_sqe/gmu`, wlan files and phone 2's
  original `wpss` are in `/vendor/firmware`; apnhlos stays first so the rollback-5 wpss that the
  TZ now requires is found before the refused rollback-2 copy.
- **Stay for now:** `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` (every test
  ran with them; redwood-6.12, a daily-driven SM7325 on the same BSP, keeps the first two
  because sync_state turns the splash display off; cost: heat/battery). `IGNORE_UNUSED=0`
  drops them for an experiment.
- **Dropped from the ROM's 5.4 cmdline:** `lpm_levels.sleep_disabled=1`, `video=vfb:...`,
  `msm_rtb.filter`, `service_locator.enable` (5.4 drivers), `swiotlb=0`,
  `cgroup.memory=nokmem,nosocket`, `pcie_ports=compat` (never tested on 6.12).
- **New:** `androidboot.a52sxq.k612=1` (gates the vendor rc on the 6.12 kernel only);
  `androidboot.first_stage_console=2` (IGNORE_FAILURE: a first-stage module whose init fails is
  logged and skipped instead of `LOG(FATAL)` -> reboot loop; userdebug init only;
  `MODULE_FAILURES=fatal` leaves it out). No `androidboot.selinux` = enforcing, as the ROM.
- **RESOLVED (was the rb1 blocker):** GKI 6.12 had `COMMAND_LINE_SIZE` 2048; the kernel would
  have cut 45 ABL arguments (`androidboot.bootloader`, `em.model`, `sales_code`, `kg.*`, ...).
  bsp612/kernel now carries `patches/bsp612-kernel-0001-*.patch` (4096; header marked
  `assume-unchanged` so the release stays 6.12.81-4k-g8a69376da734 = the modules' vermagic),
  rebuilt 14:23 and run since ab-s70. System.map: `boot_command_line` 4103 bytes. Predicted
  /proc/cmdline 3395 bytes (headroom 700); with a 2.8 KiB bootloader append 3587 (headroom 508).

### Modules: where each test stage goes
| Stage (test) | Real boot | Why |
|---|---|---|
| bsp612 base (90), zsmalloc + zram (GKI; the ROM's swap) | first stage | as tested |
| secure, display, kgsl, video, i2c, nfc, touch, fingerprint, powerpd, vibrator, camera (with the real `leds-sm5714-fled`), dsp, wlanb (95) | first stage, same order | loaded before Android's init in every test |
| `a52sxq_dsp_boot.ko` (new, after the dsp stage) | first stage | replaces the helper's `@adsp` job, below |
| audio (32; `msm_ext_display`, `fsa4480_i2c` already in display) | `/vendor/lib/modules/6.12`, `a52sxq-k612.rc` | must load after the ADSP runs |
| wlan (`wlan.ko`) | `/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko` | the path macloader and init.target.rc already use |
| debug (`seaprobe`), susp (`a52susp`), `testguard`, `hhwdt` | dropped | test-only (a52susp refuses every suspend the test did not start) |

Duplicates across stages (40, all byte-identical) are loaded once (in the test the second copy
got EEXIST). Parameters: `msm_drm dsi_display0/lcd_id` and `sec_common_fn lcd_id` come from the
ABL; `sec_core clear_on_load=0` (test) is dropped, so the module default (clear the IMEM restart
reason at load: a later crash does not leave Samsung's upload-mode magic) applies; the
helper's background `sec-battery.ko &` (its probe waits up to 20 s for the four chargers listed
after it) becomes `options sec_battery async_probe=1`, so first-stage init does not block.
`modules.softdep` is left empty on purpose: libmodprobe would honour the 10 `pre:` softdeps
(e.g. qcom_hwspinlock before smem) and change the tested order; the depmod result is kept as
`modules.softdep.depmod`. Blocklist = the modules no test ever loaded (`qcom-dload-mode`,
`gh_virt_wdt`, `qcom_wdt_core`, `tz_log_dlkm`, `sdhci-msm`, `cqhci`, `phy-msm-ssusb-qmp`,
`msm_sharedmem`, `qcom_edac`). vendor_dlkm would be the textbook place for the late modules,
but the ROM has none and adding a partition means repartitioning super; header-v4 vendor
ramdisk fragments would need a v4-capable Samsung ABL (untested) and bootconfig.

### What the test helper did, and what does it now
| helper2.sh / test ramdisk | Real boot |
|---|---|
| boots the ADSP via `/sys/class/remoteproc/*/state` every 3 s until firmware is mounted, then the CDSP (`@adsp`) | `a52sxq_dsp_boot.ko` (`modules/dspboot`, DT node `a52sxq,dsp-boot` with the two rproc phandles): retries `rproc_boot()` every 2 s (fails with -ENOENT until `/vendor/firmware_mnt` is mounted), then boots the CDSP (`cdsp=0` to skip), creates `/sys/kernel/a52sxq_dsp/{adsp,cdsp}_running`. Needed because the yupik ADSP has no auto_boot, the CDSP's auto_boot fires at probe time before the firmware is there, adsp_loader (owner of `boot_adsp`) is itself in the late set, and init may not write generic sysfs under enforcing SELinux |
| loads the audio stage once the ADSP runs | `a52sxq-k612.rc`: `on early-boot && property:ro.boot.a52sxq.k612=1` -> `wait /sys/kernel/a52sxq_dsp/adsp_running 20` (init may stat any sysfs file) -> `exec_background u:r:vendor_modprobe:s0 -- /vendor/bin/modprobe -a -d /vendor/lib/modules/6.12 <list>`, the same pattern the ROM uses for its 5.4 audio list. Qualcomm/Lineage normally modprobe audio from vendor init rc at early-init (before the ADSP); on 6.12 that was seen to leave the codecs deferred, so the wait stays until proven otherwise |
| `wlan.pre`: `force_sysfs_fallback=1`, `wpss_boot`=1, wait for FW ready, then `wlan.ko` | macloader does `wpss_boot` + finit_module itself (6.12 icnss2 provides `/sys/kernel/icnss` -> `wpss_boot`); firmware by the two-entry `firmware_class.path`. `5.4-gki/modules.dep` is empty on purpose (rb3/rb618-2): libmodprobe sees no module there, so neither vendor_modprobe.sh (early-init) nor init.target.rc's `modprobe -d 5.4-gki` (on boot) can load wlan before/beside macloader; the blocklist stays as a second guard |
| `testguard` (userdata/misc/... read-only), test fstab bound over `/vendor/etc/fstab.qcom`, /data and /metadata on zram | gone: the ROM's own fstab, real userdata and metadata (**first time on 6.12**, see risks) |
| `adb_debug.prop`: adb insecure, root, setup wizard off, verbose composer log, `ro.bpf.kver_override=6.12.81` | only `ro.bpf.kver_override=6.12.81` remains: the ROM sets 5.10.239 for its 5.4 kernel, and on 6.12 netd then aborts (`getsockoptTest`) -> `netd1shot` `reboot_on_failure` -> reboot loop (run ab-s4). Delivered by AOSP's debug-ramdisk hook (`/force_debuggable`, honoured only with an unlocked bootloader and a userdebug init), so the 5.4 boot keeps its 5.10.239. A user build would instead need the ROM's prop line changed to `${ro.boot.a52sxq.bpf_kver:-5.10.239}` |
| `netd.rc` shim without `reboot_on_failure` | not needed once kver is right (run ab-s6 on: netd stays up) |
| `sys.use_memfd=true` | gone since the Rust/ashmem kernel |
| a52init PID 1, hhwdt pet/disable, hang/oops -> panic, dead-man, own USB gadget + telnet | gone. Hypervisor watchdog: not armed by the ABL as far as known (the 6.18 harness, booted by the ABL without petting, survived busy 4-minute transfers); Qualcomm's `gh_virt_wdt` stays blocked (never tested) |

## 2b. The 6.18 variant (`KERNEL=618`, build `rb618-2`)

Same script, same ROM images, same dtbo, same packer arguments and footers, same vendor cmdline
except the gate property; everything kernel-specific comes from the tested 6.18 Android run
(ab618-a8, endurance ab618-a8e: 33 min, 5/5 s2idle, 0 crashes):
- **Kernel:** `bsp618/android/out/dist/Image` 6.18.33-4k-g00c8666046c2-dirty (ACK android17-6.18
  `ack/` + survey config). `ack/` already has `COMMAND_LINE_SIZE` 4096 (saved in
  `patches/ack-6.18/0001-a52sxq-tracked-changes.diff`; the `-dirty` comes from those tracked
  harness changes and is identical in every module's vermagic): **no new kernel patch, no
  rebuild**. System.map `boot_command_line` 4103 bytes. `drivers/of/fdt.c` prepends
  CONFIG_CMDLINE exactly as on 6.12 (CONFIG_CMDLINE_EXTEND).
- **Modules:** byte for byte from `bsp618/android/out/a8-rd.cpio.gz`: 189 first stage (6.18 GKI
  has `hwmon` built in, the only difference to 6.12's 190), 32 audio modules in
  `/vendor/lib/modules/6.18`, `wlan.ko` as `5.4-gki/qca_cld3_wlan.ko`. `a52sxq_dsp_boot.ko` is
  built by the script against `bsp618/out-survey/lahaina` (make line of `bsp618/build-survey.sh`,
  Kbuild from the port tree).
- **Tree:** rebuilt from the same inputs as 6.12 (the vendor DT does not depend on the kernel) and
  diffed against `bsp618/android/out/android-r02-618.dtb` with its kexec-only
  `/reserved-memory/a52ram@f0be0000` (earlycon ring) removed: only the extcon differs. Kept from
  `mkdtb-618.sh`: dwc3 `qcom,iommu-faults = "non-fatal"` (as tested; `SMMU_NONFATAL=0` drops
  it). The rmtfs carry-over and every `mkkexecdtb.py` step are absent, as on 6.12 (checked).
- **Command line:** DT bootargs = the 6.12 set + `sched_proxy_exec=0` (ACK 6.18 has proxy
  execution on by default; every 6.18 run used it). `earlycon=a52ram,...` is a kexec artefact (and
  the ABL strips earlycon anyway). Vendor cmdline gate `androidboot.a52sxq.k618=1`. Predicted
  /proc/cmdline 3414 bytes (headroom 681), 3606 with a 2.8 KiB ABL append (headroom 489).
- **Properties:** `ro.bpf.kver_override=6.18.33` (as in the 6.18 test ramdisk).
- **Vendor add-on:** `lib/modules/6.18/`, `etc/init/a52sxq-k618.rc` (gate `ro.boot.a52sxq.k618`),
  `lib/modules/5.4-gki/qca_cld3_wlan.ko` = the 6.18 `wlan.ko` (up to rb618-4). The 6.12 and 6.18
  rc files and module dirs coexist; the 5.4-gki wlan file is the ROM's fixed macloader path and
  holds only one kernel's module. SUPERSEDED since rb618-5 (section 2g): the 6.18 wlan.ko lives in
  `lib/modules/6.18-wlan/`, bind-mounted over 5.4-gki by the 6.18 rc, so both kernels have Wi-Fi.
- 6.18-specific risks on top of section 6: ack 6.18 was never booted by the ABL with this Image
  (only kexec'd from the harness; the harness itself, also ack 6.18, is booted by the ABL from
  `recovery` in every test, so Image header/KASLR acceptance are proven for this kernel family); proxy-exec/WALT interplay is covered
  only by `sched_proxy_exec=0`; the forked arm_smmu fixes (0031 gather range) are as tested.

## 2c. Rehearsal by kexec (`rehearse.sh`, nothing flashed)

    ./rehearse.sh 612 <name>     # rb11 (RB= to pick another) -> out/rh-<name>/ (REPORT.txt, HOWTO.txt), prints the kx-cycle line
    ./rehearse.sh 618 <name>     # rb618-5  (RUN=1 also runs it: owner's OK)
    PHONE=1 ./rehearse.sh 612 <name>   # on phone 1 (default PHONE=2): section 2d

Runs the never-run parts of the real boot on phone 2 through the harness: `a52sxq_dsp_boot.ko`
(no `@adsp` job), the real Samsung USB extcon in dwc3, the two-entry `firmware_class.path`
without `force_sysfs_fallback`, `sec_battery async_probe=1`, the vendor add-on rc/modules, plus
the ROM's first-stage init loading the vendor_boot `/lib/modules` itself and the full bootloader
argument set (incl. `androidboot.force_normal_boot=1`). Built from the `out/rb*` images:
Image = boot.img kernel; ramdisk = ROM boot ramdisk + harness tools + the vendor_boot vendor
ramdisk (bytes as in the image) + overlay (`rehearsal/`: helper, `a52ovl`, checks, add-on);
dtb = vendor_boot dtb + `realboot.dtbo` (+ a52ram on 6.18), `gen` adds the kexec patches incl.
the rmtfs carry-over (checked offline against the newest phone-2 harness live tree);
cmdline = DT bootargs + vendor_boot cmdline + ABL part (measured, `cmdline-predicted-4096.txt`)
+ test words, handed to `/kexec-run` by binding it over the harness's `/proc/cmdline`
(`HARNESS_EXTRA`; 3.4 KB never goes through telnet; on failure the jump is refused).
Harness-imposed differences: modules 1..92 (to zram.ko) are insmod'ed by the helper in the same
order (testguard needs UFS before Android starts; init then gets EEXIST for them), zram has 3
devices, userdata held by testguard, /data + /metadata on zram, test fstab, the add-on is a RAM
overlay on /vendor/lib/modules + /vendor/etc/init (copied into init's /dev tmpfs), test
adb_debug.prop, SELinux permissive, dead-man 480 s + hang->panic. Results: the helper logs
`a52rh: PASS|FAIL|INFO ...` after boot_completed (`dmesg | grep a52rh:`); list in HOWTO.txt.
No USB (extcon broken): helper logs `rh: FAIL usb`, forces `mode=peripheral` once if a bound
gadget is never configured; otherwise the dead-man restarts the phone (sec_core loaded -> its
own LineageOS).

**USB binding (2026-11-14, rh618b analysis; helper of rh612c/rh618c).** Who binds the UDC:
dwc3-msm creates the dwc3 core (= the UDC `a600000.dwc3`) only on the first role event
(`usb-role-switch` in the node: no core init at probe), i.e. when the glue reports VBUS, and
usb_notify holds that event for its 10 s booting delay after `usb_notifier` probes. So on
**both** kernels init's first `write /config/usb_gadget/g1/UDC ${sys.usb.controller}` runs
before the UDC exists and fails ("UDC core: g1: couldn't find an available UDC or it's busy":
present in rh612a/b and rh618a/b2 alike, not a 6.18 symptom). adbd then times out waiting for
FUNCTIONFS_BIND every second, re-opens its ffs, sets `sys.usb.ffs.ready=1` again, and init
rewrites UDC: the first rewrite after the UDC appears binds g1 (rh612b +0.23 s, rh618b2 +0.12 s,
before the helper looked). That is the only binder on a real boot, and it works on 6.18.
rh618b was NOT a USB failure of the kernel: the phone came back 38 s after kx-cycle's 300 s
wait ended (the dead-man would have fired at ~490 s), the time an `adb reboot` takes; kx-cycle's
restart loop had found the 6.18 Android on adb and rebooted it without logging. Telnet was
missing: the old helper's one-shot NCM hand-over raced init/adbd (unbind g1 -> adbd restarts its
ffs, which unbinds g1 again -> init rebinds; configfs refuses a link into a bound gadget, an
unlink unbinds it) and a lost race left g1 with adb only, never retried. Since rh*c: the helper
pre-links its NCM into g1 while g1 is unbound, waits `a52.rhwait=10` s for Android's own bind
(check `usb-android`), repairs any state every 3 s, and logs `rh: usbdiag` lines (10 s for 3 min,
then 30 s, and at the dead-man). kx-cycle: `ADB ONLY` result, adb log dump before it restarts a
kexec'd Android, automatic pstore read once back in LineageOS.
Real-boot caveat (both kernels, unchanged): the late UDC is only bound because adbd retries; with
USB debugging off and a non-ffs function set (e.g. kernel `mtp.gs0`) nothing would rewrite UDC
after the booting delay. Phone 2 runs with adb on, so the flash test is not affected.
**After a failed rehearsal read pstore FIRST**, before any other reboot or kx-cycle (the next
boot replaces it; the console record holds only the last 256 KiB):
`adb -s PHONE2 root; adb -s PHONE2 shell cat /sys/fs/pstore/console-ramoops-0 > logs/<name>-pstore.txt`.
CORRECTION (2026-11-14 22:xx): LineageOS's 5.4 ramoops uses the 1 MiB layout (console zone at
0xf0b40000), our 6.x trees and the harness 0xe0000 (console at 0xf0b20000): what 5.4 shows
there is its OWN previous console, never the 6.x one. Read a 6.x console from the harness
(`/tmp/prev-console.txt`, `/sys/fs/pstore`) or from a later 6.x boot.

## 2d. Phone 1 (PHONE1) with the same builds (2026-11-15, offline analysis)

Phone 1 (USB 1-5.3, ABL **A528BXXU5FWK4 = bit 5, never raise it**, hw rev 3, its own working
modem + the owner's SIM, a **microSD = mmcblk1 that nothing may touch**) runs the same
lineage-24.0-20261028 build as phone 2 since 2026-11-15 11:40. `boot.img`, `vendor_boot.img`,
`dtbo.img` of `~/Downloads/lineage-a52sxq-20261028/lineage-24.0-20261028-nightly-a52sxq-signed.zip`
(its updater-script writes all three unconditionally) are byte-identical to phone 2's
`testdev-PHONE2/backup-2026-11-14-prerealboot/` dumps and to `out/rb11/rollback/SHA256SUMS`
(the zip's recovery.img also has the same kernel, dtb and dtbo). No dump of phone 1's partitions
under LineageOS exists yet: install step 0 compares them on the phone.

What differs between the phones (measured; nothing of it is in rb11's images):
- The bootloader's own arguments only (phone 1 `logs/kx-m2data3-p1-*/harness-live.dtb` vs phone 2
  `logs/kx-rh612d-p2-*`, same harness build): `androidboot.serialno`, `bootloader` A528BXXU5FWK4 /
  A528BXXS2DWB5, `revision` 3 / 4, `subpcb` 2 / 4, `ap_serial`, `kg.ap`, `em.did`, `rp` 5 / 2,
  `wb.snapQB` (+ `cm.param.offset` in another position). Phone 1's NERV-era normal-boot tree
  (`testdev-PHONE1/live.dtb`) agrees except the ROM's dtb/dtbo index and the charger state.
- `/memory`: the ABL/hypervisor place the 0xba.. bank 4 MiB apart (filled in by the ABL on a real
  boot, by mkkexecdtb.py on kexec). `/hypervisor`: same nodes, other RM-RPC address.
- Reserved memory: **identical** between the two harness trees; rb11's tree has the carveouts of
  LineageOS's own stock tree (vendor_boot dtb + dtbo entry r02, which phone 1 now boots: mpss
  0x8b800000+0xf600000, adsp, cdsp, wlan, removed_region 0xc0000000+0x6a00000, ... identical;
  rb11 differs only by dynamic pools (debug_kinfo, dump_mem, va_md, non_secure_display), ramoops
  0xe0000 instead of 0x100000, a52ram (DIAG), modem_shared_mem 8 MiB at 0xd0000000 instead of
  0 bytes (inside the 0xd0000000 TrustedVM range) and two disabled nodes) and exactly those of the kexec tree with
  which 6.12 ran phone 1's modem (LTE data, run m2data3-p1) except the kexec-only nodes. NERV's
  tree had removed_region 0x5f00000: a ROM difference, not a firmware one.
- dtbo: the ABL picks `<0x22 N>` with N <= revision; phone 1's own ABL took NERV's `<0x22 2>`
  entry (dtbo_idx=0 = that entry) and LineageOS's table has the same r00/r01/r02 entries, so
  rb11's single `<0x22 2>` entry applies on rev 3. ABL merge (tools/ufdt-host/check.sh): fits,
  65399 B slack; phone 1's RM overlays have the same size as the phone-2 stand-in.
So **rb11 is used unchanged on phone 1** (no rb11p1). rb11 keeps MODEM=0 (modem remoteproc off,
as in every real-boot test): phone 1 will show "No service" on 6.12 until a MODEM=1 build.

Rehearsal (key-free, nothing flashed; Rooted debugging must be ON in phone 1's LineageOS, which
has no su): `PHONE=1 drivers612/realboot/rehearse.sh 612 rh612p1` -> `out/rh-rh612p1/` with the
ABL part re-targeted to phone 1 (`tools/abl-retarget.py`, report in `abl-retarget.txt`), NET 42,
harness `images/a52sxq-ack618-kexec9-recovery.img`, and the kx-cycle line in REPORT/HOWTO:

    cd ./ && D=drivers612/realboot/out/rh-rh612p1; PHONE=1 HARNESS_IMG=images/a52sxq-ack618-kexec9-recovery.img KEXEC_BASE=$D/rh-base.dtb KEXEC_OVERLAY=none KX_PACK=$D/pack.tgz HARNESS_EXTRA="$(cat $D/harness-extra.sh)" KX_HOLD=1 KX_WAIT=300 kexec/kx-cycle.sh rh612p1 $D/Image $D/rd.cpio.gz gen -
    # results: adb -s PHONE1 shell dmesg | grep -E 'a52rh:|a52sxq-init: rh:'
    # end:     TSH_IP=172.16.42.1 tools/tsh.py /leave; PHONE=1 kexec/kx-finish.sh rh612p1

Real boot of rb11 on phone 1: section 3 with `S=PHONE2` replaced by **`S=PHONE1`**,
`B=drivers612/realboot/out/rb11 V=6.12 K=k612` and the rollback images from
`D=testdev-PHONE2/backup-2026-11-14-prerealboot` (same build; step 0 must show
`out/rb11/rollback/SHA256SUMS` on the phone, else stop). Harness rollback: `TSH_IP=172.16.42.1`,
`tools/dlexit.sh 1-5.3`. odin4 rollback (Download mode entered by the owner):
`testdev-PHONE1/odin-rollback-lineage-20261028/AP.tar` (`tools/mk-odin-rollback.sh`,
ustar of the three images, read back + SHA256SUMS), `odin4 -a <AP.tar> -d /dev/bus/usb/BBB/DDD`
of port 1-5.3 (`odin4 -l`; `-d` keeps phone 2 out of it).
Phone 1's own ABL has not yet started rb11 from `boot`: it is the bit-5 binary, not the bit-2
one of the rb9/rb10 proof, so the first direct boot needs the owner's window like rb10 did.

## 2e. rb12 = rb11 + the modem (`DIAG=1 MODEM=1`, phone 1 only; 2026-11-15, offline)

    DIAG=1 MODEM=1 drivers612/realboot/build-realboot.sh rb12                   # ~35 s, all checks
    RB=drivers612/realboot/out/rb12 PHONE=1 drivers612/realboot/rehearse.sh 612 rh612p1m   # -> out/rh-rh612p1m

rb12 is rb11 byte for byte (same Image, same boot.img, same first 190 lines of modules.load,
same vendor add-on except the build name in the rc comment) plus phone 1's cellular stack for the
ROM's OWN radio userspace. Built from phone 2's dumps like rb11 (= the Lineage zip's images;
section 2d); for phone 1 only: on phone 2 pm-service would try its TZ-refused modem (harmless
-22 at init, but no reason to). On phone 2 keep rb11/rb10.

**Modules (first stage, appended after wlanb; 204 = 190 + 14).** The modem stage of the
kernel-only runs that brought LTE data up on 6.12 (`drivers612/modem/out/pack-modem.tgz` =
the pack of kx-m2k / kx-m2data3, its `m/` files byte for byte, its `modem.list` order), minus the
test-only `a52_modem_guard`, plus `dev_ril_bridge.ko` (`/dev/drb`, rild):
`msm_sharedmem heap_mem_ext_v01 msm_memshare glink_pkt rmnet_mem gsim usb_f_gsi ipam ipanetm
rmnet_ctl rmnet_core rmnet_offload rmnet_shs dev_ril_bridge` (`qcom_va_minidump` of the pack is
already in the first stage, same file). The remoteproc/QRTR side (qcom_q6v5_pas, sysmon, pdr,
qrtr-smd, glink, smp2p, subsys_compat, qcom_pd_mapper_a52) was already first stage in rb11.
`msm_sharedmem` leaves `modules.blocklist`. Why first stage and not the vendor rc: `/dev/ipa`
must exist before `ipa_fws.rc`'s `on early-boot write /dev/ipa 1` (else init creates a plain
file, run ab-s18), `/dev/uio*` "rmtfs" and `/dev/subsys_modem` before class core (rmt_storage,
pm-service), rmnet_core before rild's netlink "rmnet" links; and the ROM's own 5.4 loaders
(`vendor_modprobe.sh`, `netmgrd.rc` "on boot" `modprobe -d /vendor/lib/modules rmnet_ctl
rmnet_core`, `-d .../5.4-gki`) only find the ROM's 5.4 rmnet files (vermagic refusal = log
noise; our 5.4-gki/modules.dep is empty) - on 5.4 the four rmnet modules load at early-init,
everything else is built in. Checks: insmod simulation 237 ok (first 204, late 32, wlan 1),
libmodprobe dry run 204/204, the modem files must be the last 14 lines in pack order and
byte-identical to the pack, none in the add-on.
Not added (no user in this ROM or not on the modem/data path): `rmnet_perf` (netmgrd.rc loads it
only on `persist.vendor.data.perf_ko_load`, set by netmgrd, which this ROM does not run:
service commented out, binary absent, `ro.vendor.use_data_netmgrd=false`), `rmnet_wlan`,
`rmnet_aps`, `rmnet_sch`, `rmnet_perf_tether`, `tipc` (no qcrild), `cdsprm` (CDSP), `rdbg`,
modem thermal mitigation `qti_qmi_cdev`/`qti_qmi_sensor` (thermal-engine use; the qmi-sensor
DT zones could trip on bad readings: test separately).

**Device tree.** After the tested-tree comparison (unchanged), `drivers612/modem/dt/mkmodemtree.sh`
(the kernel-only runs' edit: `modem_pas` okay, memshare `client_4` (id 3) disabled = what 5.4 ends
up with, plus its checks: mpss/IPA GSI regions, IPA/rmnet/glinkpkt/memshare nodes,
`/soc/qcom,rmtfs_sharedmem@0` qcom,sharedmem-uio "rmtfs" 0x280000 enabled, no upstream
qcom,rmtfs-mem, no qcom,sc7280) and the IPA IOVA fix (`dt/ipa-iova-fix.sh`, POLISH.md item: it
DID affect 6.12: every modem run logged `ipa_smmu_ap/uc: Cannot reserve IOVA region of 0 size`
x6/x4, because the 2+2-cell iommu-addresses were read with /soc's 1+1 cells, leaving one
[0, 1 GiB) reservation; the fastmap AP domain then allocated from [0x40000000, 4 GiB), where the
IPA driver identity-maps SMEM 0x80900000 and maps its own buffers from 0x40000000 upwards). Fix:
`#address-cells`/`#size-cells` = 2 on the IPA node and only the two entries below 4 GiB (the
0x1_0000_0000 entry is truncated to 0 by the 1-cell /soc translation and would reserve
everything); `tools/iommu-resv-sim.py` (the kernel's parse, reproduces the logged warnings on the
old tree) gives [0x20000000, 0x3fffffff] = the 5.4 pool for both cbs. Whole-tree delta to the
tested tree: exactly 6 properties (`tools/dtcompare.py`); modem subtrees (mss + glink edge,
memshare, IPA + cbs, partitions, rmnet-ipa, msm_gsi, rmtfs UIO, glinkpkt, smp2p-modem, the four
reserved regions) = those of the kx-m2data3 kexec tree except the 4 IPA-fix properties. ABL
libufdt check unchanged (65399 B slack). Never a fixed rmtfs region (the harness's 0x9c900000 is
a kexec carry-over only).

**Command line.** `firmware_class.path=/vendor/firmware_mnt/image,/vendor/firmware,/vendor/firmware-modem/image`
(modem.mdt from the phone's own `modem` partition directly; 5.4 went through the sysfs fallback
+ ueventd's firmware_directories, which the ROM also keeps: `force_sysfs_fallback=1` in
init.qti.kernel.rc). Predicted /proc/cmdline 3487 bytes (headroom 608; 416 with a 2.8 KiB ABL).

**/dev owners (ueventd).** `tools/ueventd-check.py`: the ROM's `/vendor/etc/ueventd.rc` (=
`device/samsung/sm7325-common/init/ueventd.qcom.rc`, identical to the one in the zip's vendor
image) after AOSP's system one, last match wins, lines with an unknown AID dropped as ueventd's
parser does (`smd4 ... system_ext_bridge_rw` -> 0600 root, as on 5.4): ipa, ipaNatTable,
ipa_odl_ctl, wwan_ioctl 0660 radio:radio; ipa_adpl 0660 system:2905; uio0..2 0660 system:system;
drb 0660 system:radio; subsys_modem 0640 system:system; at_mdm0 0640 system:radio; smdcntl8 0640
radio; smd11 0660 radio; smd7 0660 bluetooth; smd4/smd8/apr_apps2 0600 root; rmnet_ctrl/dpl_ctrl
0660 usb (new: usb_f_gsi). Every node that existed on 5.4 (`research/blob-uapi-evidence/dev_lZ.txt`)
gets the same mode/uid/gid. Names come from the same drivers/DT nodes as on 5.4, so the
file_contexts labels match too; sysfs paths of the uio and msm_subsys nodes are the 5.4 ones
(research/sepolicy/PATHS.md). `modem-devnodes.txt` goes into the rehearsal for the on-phone check.

**What the ROM's userspace provides (lineage-24.0-20261028 vendor, read from the zip; all present).**
`vendor.rmt_storage` (root, class core; `/sys/class/uio/uio*/name` = rmtfs, mmap, then
`/dev/block/bootdevice/by-name/modemst1/modemst2/fsg/fsc` read-write = the phone's own EFS: normal
phone behaviour on the real boot), `vendor.tftp_server`, `vendor.pd_mapper` (+ the kernel's
qcom_pd_mapper_a52: two locators, R3 of modem/README, already so in rb10/rb11), `vendor.qrtr-ns -f`
(+ the in-kernel ns, as on 5.4), `vendor.per_mgr` + `per_proxy` (pm-service opens
`/dev/subsys_modem` = the boot), `ipa_fws.rc` (`write /dev/ipa 1`), `vendor.ipacm`, Samsung
`ril-daemon` (`/vendor/bin/hw/rild` + libsec-ril.so: data itself through librmnetctl + the
rmnet_ipa0 ioctls; the QC `vendor.ril-daemon*` are overridden to rild-dummy, which is not even
shipped), `irsc_util`, `secril_config_svc`, `sehradiomanager`, thermal-engine, time_daemon,
xtra-daemon. Not in this ROM: netmgrd (commented out, no binary), qcrild, any IMS daemon (no
VoLTE on this LineageOS build on either kernel; calls via CSFB), so no further kernel module is
needed for them. SSR: subsys_compat starts RELATED (recovery on), rproc coredump is off by
default (kzalloc'd `dump_conf` = DISABLED), a failed recovery panics as on stock 5.4.

**Rehearsal (`rh612p1m`, key-free, phone 1, nothing flashed).** Additionally to section 2c:
the helper refuses the modem at switch root (`subsys3 firmware_name a52-modem-refused`) and
restores `modem` only if `modem.b01`'s anti-rollback byte equals `adsp.b01`'s (m1.sh's rule);
the EFS is served from RAM: efsdump (O_RDONLY + BLKROSET, refuses mmcblk) copies the four
partitions into a tmpfs, a second copy each backs loop240..243, bound over `/dev/block/sdXN` in
init's namespace once ueventd created the node (before class core); `efsdump verify` at the end
must say "all 4 partitions unchanged". New pass checks (`a52rh:` lines): modem-guard, efs (bound
before rmt_storage started), the radio services running, MSS running + subsys ONLINE, no DOG
stall/SSR, IPA FW + init, `rmnet_ipa0`, rmtfs UIO, every `/dev` node of modem-devnodes.txt with
the ueventd owner, voice/data IN_SERVICE (waits 120 s; only the reg-state fields of
`dumpsys telephony.registry` are read, never SIM identifiers), an IPv4 on `rmnet_data*` (address
not printed) + `ping -I`, and every SELinux denial of a radio/data domain (permissive here,
enforcing on the real boot: each one would be a blocked access). Run (owner's OK; Rooted debugging on):

    cd ./ && D=drivers612/realboot/out/rh-rh612p1m; PHONE=1 HARNESS_IMG=images/a52sxq-ack618-kexec9-recovery.img KEXEC_BASE=$D/rh-base.dtb KEXEC_OVERLAY=none KX_PACK=$D/pack.tgz HARNESS_EXTRA="$(cat $D/harness-extra.sh)" KX_HOLD=1 KX_WAIT=300 kexec/kx-cycle.sh rh612p1m $D/Image $D/rd.cpio.gz gen -
    # results: adb -s PHONE1 shell dmesg | grep -E 'a52rh:|a52sxq-init: rh:'
    # end:     TSH_IP=172.16.42.1 tools/tsh.py /leave; PHONE=1 kexec/kx-finish.sh rh612p1m

Rehearsal limits: /efs and /mnt/vendor/efs are mounted read-only (test fstab), /data is a fresh
zram (default settings: mobile data on), SELinux permissive; the first IPA + modem run under
Android at all (the kernel-only runs had no ipacm/rild), and the first run of the IPA IOVA fix.

**Real boot of rb12 on phone 1:** section 3 with `S=PHONE1 B=drivers612/realboot/out/rb12
V=6.12 K=k612`, rollback dumps `D=testdev-PHONE2/backup-2026-11-14-prerealboot` (step 0 must
show `out/rb12/rollback/SHA256SUMS` on phone 1), EFS backups of 2026-11-15 in
`testdev-PHONE1/backup-2026-11-15-pre-lineage` (modemst1/2, fsg, fsc), harness rollback
`TSH_IP=172.16.42.1`, `tools/dlexit.sh 1-5.3`, odin4 rollback
`testdev-PHONE1/odin-rollback-lineage-20261028/AP.tar`. If the first enforcing boot shows
"No service" while the rehearsal had service, the rehearsal's selinux lines name the accesses;
`SELINUX=permissive` is one rebuild away (owner's call).

## 2f. rb14 = rb13 + GPU/bus DCVS (`DIAG=1 MODEM=1`, phone 1; 2026-11-15, offline, NOT flashed)

`REF` is now `s76` (run ab-s76): its `kgsl` stage loads `governor_msm_adreno_tz` +
`governor_gpubw_mon` before `msm_kgsl`, and stage `dcvs` (`bwmon`, `memlat`) is planned right
after `kgsl` (the test order). First stage 204 -> 208 modules (rb13 + exactly those four);
the build fails if a governor comes after `msm_kgsl` or bwmon/memlat before `qcom-dcvs`,
`sched-walt`, `qcom-pmu-lib`, `qcom_llcc_pmu`, `qcom_scmi_client`. Plus
`drivers612/busdcvs` (README there): `dt-fix.sh` removes the SCMI vendor-protocol nodes (same
step in `kexec/mkandroidtree.sh`, so the tree still equals the tested `android-r02.dtb` except
the extcon), and the vendor rc gets 56 `write`s on `sys.boot_completed` (bwmon/memlat tunables,
`boost_freq` -> hw min, interconnect `state_synced`), each path checked against the final dtb
(`busdcvs/check-conf.py`). The tunables and the DT fix have NOT run on a phone yet: kexec test
with ramdisk `s77` first (`drivers612/busdcvs/README.md`).

## 2g. rb618-5 = 6.18 at parity with rb16 (`KERNEL=618 DIAG=1 MODEM=1 SDCARD=1`; 2026-11-15, offline, NOT flashed, NOT run)

    KERNEL=618 DIAG=1 MODEM=1 SDCARD=1 drivers612/realboot/build-realboot.sh rb618-5

Same script, same steps as rb16; only the inputs differ. All offline checks pass, no blockers:
insmod simulation 242 ok (first 209, late 32, wlan 1), libmodprobe dry run 209/209 + 32/32,
libufdt emulation slack 65399 B, predicted /proc/cmdline 3562 B (headroom 533; 3754 with a 2.8 KiB
ABL append), vermagic 6.18.33-4k-g00c8666046c2-dirty everywhere. Against rb16 the first stage
differs only by `hwmon.ko` (built into GKI 6.18), the vendor cmdline only by the gate
(`androidboot.a52sxq.k618=1`), the DT bootargs only by `sched_proxy_exec=0`. boot.img = rb618-4's.
The 6.12 output of the changed script is byte-identical to rb16 (images + add-on, rebuilt and compared).

| rb16 (6.12) | rb618-5 (6.18) |
|---|---|
| REF `s76` (s74 + 0009 geni + GPU governors in `kgsl` + stage `dcvs`) | REF `a10` = `a9` (a8 + 0009 geni) + the same four modules as 6.18 builds: `bsp618/android/mkrd-dcvs-618.sh` (a9 byte for byte + an appended cpio; the other kgsl files are checked identical to a9's; also carries the s77 dcvs post script for a kexec test). Stages from `mkstages-618.py` (`stage-618/kgsl2`, `dcvs`) |
| sysfscompat tree + 0009 geni modules | same (`i2c-msm-geni`, `msm_geni_serial` with 0009, as in rb618-4) |
| MODEM=1: `pack-modem-txfix.tgz`, 6.12 `dev_ril_bridge.ko` | `drivers612/modem/out-618/pack-modem-618-txfix.tgz` = the kx-m2k618 pack with only `m/ipam.ko` replaced by the 6.18 build with `conn/data/patches/0002` (applied to `bsp618/src/drivers612/conn/data/src/dataipa`, rebuilt: only ipam.ko changed, CRC sections identical; `drivers612/modem/mk-txfix-pack.sh`, which also reproduces the 6.12 txfix ipam), `dev_ril_bridge.ko` = bsp618 port build (stripped). Modem subtrees checked against the 6.12 data run's tree AND the 6.18 modem run's tree (kx-m2k618) |
| IPA IOVA DT fix (mkmodemtree.sh) | same |
| busdcvs dt-fix, 56 rc writes, check-conf | same (`bsp618/android/mkdtb-618.sh` regenerated `android-r02-618.dtb` from the busdcvs-fixed 6.12 tree: diff = the two SCMI nodes + 2 symbols; old one kept as `android-r02-618-pre-busdcvs.dtb`) |
| `fw_devlink.sync_state=timeout deferred_probe_timeout=30` | same (both parsed by ACK 6.18 `drivers/base/core.c` / `dd.c`; `state_synced` is writable there too), + `sched_proxy_exec=0` |
| SDCARD=1: dist `cqhci.ko`, `sdhci-msm.ko` | same (6.18 dist `drivers/mmc/host/`, soc-repo modules; GKI 6.18 has only mmc_core/mmc_block/sdhci/sdhci-pltfm built in) |
| DIAG=1: a52bc diag Image + a52ram node + DIAG_BOOTARGS | DIAG_BOOTARGS only (no 6.18 a52bc kernel; the dist Image; no a52ram node: nothing would write it) |
| wlan.ko in `/vendor/lib/modules/5.4-gki` | wlan.ko in `/vendor/lib/modules/6.18-wlan`, bound over `5.4-gki` by the rc (below) |

**Wi-Fi with both kernels installed.** macloader (wifi_sec.rc, started on `post-fs-data`) loads
`/vendor/lib/modules/qca_cld3_wlan.ko` (5.4) and then the fixed path
`/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko`, which holds ONE 6.x module; the phones carry the
6.12 one there. The 6.18 add-on therefore ships **no file in 5.4-gki**: its wlan dir is
`lib/modules/6.18-wlan/` (qca_cld3_wlan.ko + the same empty modules.dep / blocklist / load as a
5.4-gki dir), and `a52sxq-k618.rc` (from `vendor-addon/wlan-bind.rc.in`) does
`on post-fs && property:ro.boot.a52sxq.k618=1` -> `mount none /vendor/lib/modules/6.18-wlan
/vendor/lib/modules/5.4-gki bind`. macloader then loads the 6.18 wlan.ko by the same path and in
the same wpss_boot -> finit_module order as on 6.12; the 6.12 files under the bind are untouched,
and 5.4 / 6.12 never make the bind. Why it works under enforcing SELinux: init runs `mount` itself
(builtins.cpp: not a vendor_init subcontext command), init may `mounton` `vendor_file` dirs
(system/sepolicy private/init.te), the add-on dirs are `vendor_file` (restorecon), macloader keeps
`vendor_file:system module_load`; `/` is MS_SHARED in both init mount namespaces (set up before the
rc files are parsed), so macloader sees it. Precondition: `/vendor/lib/modules/5.4-gki` exists as a
directory (it does wherever the 6.12 add-on is installed; else `mkdir -p` it, empty). The build
fails if the 6.18 add-on would carry files in 5.4-gki. Not proven on a phone: the rehearsal
(phones carry the 6.12 add-on, which shows through the RAM overlay) is the first test.

**6.18 add-on install** = section 3 step 2 with `V=6.18 K=k618`, except: push
`lib/modules/6.18` AND `lib/modules/6.18-wlan`, do NOT push `lib/modules/5.4-gki` (it would not
replace anything, it is empty, but never overwrite the 6.12 wlan.ko there); `mkdir -p
/vendor/lib/modules/5.4-gki`; `restorecon -R /vendor/lib/modules/6.18 /vendor/lib/modules/6.18-wlan
/vendor/etc/init/a52sxq-k618.rc`; compare with `vendor-addon.SHA256SUMS`. Vendor rw remount only
from 5.4 (6.12/6.18 cannot remount the dm vendor rw).

**Rehearsal packages (built, NOT run; the owner's OK per run):**

    RB=drivers612/realboot/out/rb618-5 PHONE=2 drivers612/realboot/rehearse.sh 618 rh618p2   # -> out/rh-rh618p2
    RB=drivers612/realboot/out/rb618-5 PHONE=1 drivers612/realboot/rehearse.sh 618 rh618p1   # -> out/rh-rh618p1

The kx-cycle line is in each `HOWTO.txt` / `REPORT.txt`. rehearse.sh now also handles SDCARD=1
builds (`RH_SD=off` default on phone 1: test word `module_blacklist=sdhci_msm`, the kernel refuses
that one module and init goes on, so the owner's card is never seen; `RH_SD=on` default on phone 2:
sdhci-msm probes) and the 6.18 Wi-Fi dir (BUILDINFO `wlan=`), and rh-checks.sh got checks for
`sd`, `dcvs` (msm-adreno-tz, bwmon, memlat, boost dropped by the rc, interconnect synced) and
`wlan-bind`. Phone 2 with MODEM=1: its TZ refuses the modem (expected modem/radio FAILs; the
point is that rild does not crash-loop). Phone 1: modem + LTE data on 6.18 for the first time
with the ROM's userspace (EFS in RAM), the IPA TX fix on 6.18 for the first time.

**What blocks a real 6.18 flash** (nothing offline): (1) rh618p2 / rh618p1 must pass: on 6.18
never run so far are bwmon/memlat/GPU governors, the busdcvs tree and rc writes, the sync_state
timeout bootargs, sdhci-msm/cqhci, the ROM's radio userspace + LTE data (only the kernel-only
modem test kx-m2k618 ran, no data call) incl. the 6.18 ipam TX fix and dev_ril_bridge, and the
wlan bind; (2) the 6.18 add-on must be installed from 5.4 (vendor rw) next to the 6.12 one;
(3) owner's OK + hands-on window (the ABL->kernel jump of 6.18 from `boot` is new: ack 6.18 only
ever started from `recovery` as the harness or by kexec; the rb9 dtbo fix applies to both).

## 3. Install plan (for later; every step needs the owner's OK; phone 2 only)

Preconditions
1. Done: bsp612 rebuilt with `COMMAND_LINE_SIZE` 4096 and run through the kexec test path
   (ab-s70 ... ab-s74); `REF=s74`. 6.18 needs nothing (already 4096).
2. `adb devices` shows PHONE2; always `adb -s PHONE2`. Phone in its own LineageOS
   (5.4), "Rooted debugging" on (`adb root` works), battery > 60 %, the owner present.
3. The dumps still match the phone: `adb -s PHONE2 shell 'for p in boot vendor_boot dtbo;
   do sha256sum /dev/block/by-name/$p; done'` must equal `out/<name>/rollback/SHA256SUMS`
   (dumps of 2026-11-11). If not (LineageOS update), dump again (read-only `dd ... | adb exec-out`)
   into `testdev-PHONE2/` and rebuild: the boot patch level must be the installed one.
4. Backups the owner decides on (this is the first 6.12 boot with the real /data): `metadata`
   (holds the vold metadata key), `persist`, `efs`, `sec_efs`, `modemst1/2`, `fsg`, `fsc`
   (`dd` to the PC, kept local only); user data on /sdcard. Do not accept any "wipe"/"factory
   reset" prompt in recovery afterwards.
5. Free space: `adb shell df /vendor /cache` (vendor add-on ~29 MB; /cache staging ~450 MB).
6. A way back that does not depend on the new images (below) is staged first.

Steps
1. **Stage the rollback on /cache** (ext4, readable from the 6.18 harness):
   `adb push testdev-PHONE2/{boot,vendor_boot,dtbo}.img /cache/a52rb-rollback/` and
   compare `sha256sum` with `rollback/SHA256SUMS.phone-dumps`.
2. **Vendor add-on** (harmless on 5.4: rc gated by `ro.boot.a52sxq.k6xx`, 6.x modules are
   refused by 5.4). `<V>` = 6.12 / 6.18, `<K>` = k612 / k618: `adb root && adb remount` (note
   whether it says in-place or overlayfs; overlayfs is mounted by first-stage init, so it should
   apply on 6.x too: CHECKLIST), then
   `adb push out/<name>/vendor-addon/lib/modules/<V> /vendor/lib/modules/`,
   `adb push out/<name>/vendor-addon/lib/modules/5.4-gki /vendor/lib/modules/`,
   `adb push out/<name>/vendor-addon/etc/init/a52sxq-<K>.rc /vendor/etc/init/`,
   `adb shell restorecon -R /vendor/lib/modules/<V> /vendor/lib/modules/5.4-gki /vendor/etc/init/a52sxq-<K>.rc`,
   `adb shell ls -Z ...` (vendor_file / vendor_configs_file), compare sha256 with
   `vendor-addon.SHA256SUMS`. Reboot into 5.4 once and check nothing changed (Wi-Fi, sound).
3. **Images** (from the running 5.4 with `adb root`): `adb push out/<name>/{boot,vendor_boot,dtbo}.img
   /cache/a52rb/`, check sha256 against `out/<name>/SHA256SUMS`, then
   `dd if=/cache/a52rb/dtbo.img of=/dev/block/by-name/dtbo bs=1M conv=fsync`, same for
   `vendor_boot` and `boot`; read back each partition and compare its sha256. Nothing else is
   written: not vbmeta, recovery, super, misc, param.
4. `adb reboot` (never `adb reboot recovery`: sticky). Watch: boot animation, `adb` (the ROM's
   own gadget, needs the USB extcon path), then CHECKLIST.md.

### Exact commands (NOT run; owner's OK first; phone 2 = PHONE2 only; from the repo root)
Pick ONE build: `B=drivers612/realboot/out/rb3 V=6.12 K=k612` or
`B=drivers612/realboot/out/rb618-2 V=6.18 K=k618`. Phone in its own LineageOS (5.4), Rooted
debugging on, battery > 60 %, owner present, phone 1 not in Download mode.

    S=PHONE2; D=testdev-PHONE2
    adb -s $S root
    # 0. the phone still has the dumped images (else re-dump + rebuild), space, 5.4-gki not in the ROM
    adb -s $S shell 'for p in boot vendor_boot dtbo; do sha256sum /dev/block/by-name/$p; done'   # = $B/rollback/SHA256SUMS
    adb -s $S shell 'df /cache /vendor; ls -la /vendor/lib/modules/5.4-gki /vendor/etc/init/a52sxq-* 2>&1'
    # 1. rollback staged on /cache
    adb -s $S shell mkdir -p /cache/a52rb-rollback /cache/a52rb
    adb -s $S push $D/boot.img $D/vendor_boot.img $D/dtbo.img /cache/a52rb-rollback/
    adb -s $S shell 'cd /cache/a52rb-rollback && sha256sum boot.img vendor_boot.img dtbo.img'   # = $B/rollback/SHA256SUMS
    # 2. vendor add-on (adb remount may ask for one reboot first; then adb root + remount again)
    adb -s $S remount
    adb -s $S push $B/vendor-addon/lib/modules/$V /vendor/lib/modules/
    adb -s $S push $B/vendor-addon/lib/modules/5.4-gki /vendor/lib/modules/   # 6.12 only; 6.18: push lib/modules/6.18-wlan + mkdir -p 5.4-gki instead (2g)
    adb -s $S push $B/vendor-addon/etc/init/a52sxq-$K.rc /vendor/etc/init/
    adb -s $S shell "restorecon -R /vendor/lib/modules/$V /vendor/lib/modules/5.4-gki /vendor/etc/init/a52sxq-$K.rc; ls -Z /vendor/etc/init/a52sxq-$K.rc /vendor/lib/modules/5.4-gki"
    adb -s $S shell "cd /vendor && find lib/modules/$V lib/modules/5.4-gki etc/init/a52sxq-$K.rc -type f | sort | xargs sha256sum"  # = $B/vendor-addon.SHA256SUMS
    adb -s $S reboot      # 5.4 once with the add-on: Wi-Fi + sound unchanged? then adb root again
    # 3. the three images
    adb -s $S push $B/boot.img $B/vendor_boot.img $B/dtbo.img /cache/a52rb/
    adb -s $S shell 'cd /cache/a52rb && sha256sum boot.img vendor_boot.img dtbo.img'   # = $B/SHA256SUMS
    adb -s $S shell 'for p in dtbo vendor_boot boot; do dd if=/cache/a52rb/$p.img of=/dev/block/by-name/$p bs=1M conv=fsync || exit 1; done; sync'
    adb -s $S shell 'for p in boot vendor_boot dtbo; do sha256sum /dev/block/by-name/$p; done'   # = $B/SHA256SUMS
    adb -s $S reboot      # never "reboot recovery"

Rollback (section 4 has the reasoning):

    # a) the new kernel boots with adb
    adb -s $S root
    adb -s $S shell 'for p in dtbo vendor_boot boot; do dd if=/cache/a52rb-rollback/$p.img of=/dev/block/by-name/$p bs=1M conv=fsync || exit 1; done; sync'
    adb -s $S shell 'for p in boot vendor_boot dtbo; do sha256sum /dev/block/by-name/$p; done'   # = $B/rollback/SHA256SUMS
    adb -s $S reboot
    # b) it does not boot: Vol-down+Power ~7 s, then Vol-up+Power with USB = recovery = 6.18 harness;
    #    TSH_IP=172.16.43.1 tools/tsh.py '<cmd>' (or telnet 172.16.43.1), in the harness shell:
    pn() { for d in /sys/class/block/sd*; do grep -qx "PARTNAME=$1" $d/uevent && echo /dev/${d##*/}; done; }
    mkdir -p /mnt/rb && mount -o ro $(pn cache) /mnt/rb && cd /mnt/rb/a52rb-rollback && sha256sum *.img
    for p in dtbo vendor_boot boot; do dd if=$p.img of=$(pn $p) bs=1M conv=fsync || break; done; sync
    for p in boot vendor_boot dtbo; do sha256sum $(pn $p); done     # = rollback/SHA256SUMS
    /leave                                    # PC: tools/dlexit.sh <port> if it stops in Download mode
    # c) last resort: Download mode entered from software + heimdall/odin4 -d <port> with the three
    #    dumps in $D (PIT names of boot/vendor_boot/dtbo to be read first); keys-entered Download
    #    mode may refuse unofficial images.
    # vendor add-on removal (optional; 5.4 ignores it). Only if step 0 showed no ROM 5.4-gki dir:
    adb -s $S remount && adb -s $S shell rm -r /vendor/lib/modules/6.12 /vendor/lib/modules/6.18 /vendor/lib/modules/5.4-gki /vendor/etc/init/a52sxq-k612.rc /vendor/etc/init/a52sxq-k618.rc

What is overwritten: `boot`, `vendor_boot`, `dtbo` (complete partitions, with footers) and new
files on vendor (`/vendor/lib/modules/6.1x/`, `/vendor/lib/modules/5.4-gki/`,
`/vendor/etc/init/a52sxq-k61x.rc`). The vendor add-on can stay for the 5.4 kernel.

## 4. Roll back to the LineageOS 5.4 kernel
The ROM itself is untouched, so going back is writing the three dumped partitions again
(the full 100/100/25 MB dumps, footers included; patch level identical, so Keymaster is fine).
- 6.12 boots with adb: `adb root`, `dd if=/cache/a52rb-rollback/<p>.img of=/dev/block/by-name/<p>`
  for dtbo, vendor_boot, boot; reboot.
- 6.12 does not boot (hangs, loops, black screen): Vol-down + Power ~7 s to restart, then Vol-up
  + Power with USB connected = recovery = the 6.18 harness (does not read boot, vendor_boot or
  dtbo). Telnet 172.16.43.1, `mount -o ro` the cache partition (`PARTNAME=cache` in
  `/sys/class/block/sd*/uevent`), find boot/vendor_boot/dtbo the same way and `dd` the
  rollback images onto them, then `/leave` (Download mode round trip clears the sticky
  recovery flag; `tools/dlexit.sh <port>`). The harness's dead-man timer leaves for Download
  mode by itself if nobody logs in.
- Last resort: Download mode entered from software (`/rb download` in the harness) +
  `heimdall`/`odin4 -d <port>` with the three dumps. Download mode entered after a refused boot
  or by the keys may refuse unofficial images (seen on phone 1, 2026-10-03); have an official
  bit-2 recovery/AP ready before the first flash (none is downloaded yet).
- The vendor add-on needs no rollback; to remove it: `adb remount`, `rm -r` the three paths.

## 5. AVB / vbmeta (unlocked, orange)
vbmeta has flags 3: neither the ABL nor first-stage init checks the digests of boot,
vendor_boot, dtbo, system or vendor, so vbmeta is **not** rewritten (its boot/vendor_boot/dtbo
digests just become stale). The new images carry unsigned hash footers made exactly like the
ROM's (same salt and props; the recipe reproduces the ROM's boot.img bit for bit). The vendor
add-on does not need verity changes (already off). If vbmeta ever had to change, it is signed
with AOSP's public test key (sha1 2597c218), so it could be regenerated; recovery has its own
signature with the same key and is not touched here. Do not flash a vbmeta with flags 0.
`/force_debuggable` only works because the bootloader is unlocked (`AvbHandle::IsDeviceUnlocked`).

## 6. Risks
1. **First 6.12 mount of the real userdata/metadata** (all tests used zram): metadata
   encryption (dm-default-key, inlinecrypt, ICE without wrapped keys), Keymaster through
   qseecom, f2fs on 6.12 writing a filesystem that 5.4 mounts again afterwards. `metadata` is
   `formattable` in the ROM fstab: if 6.12 failed to mount it, init would format it and the
   /data keys would be gone. Backups first; never wipe from recovery.
2. ABL acceptance of a 0.66 MB fully merged base + minimal dtbo was checked offline only
   (fdtoverlay, libufdt was not run). Refusal = Download mode before the kernel: recovery
   path above.
3. `COMMAND_LINE_SIZE`: resolved on both kernels (4096; 2.8 KiB append checked offline).
4. SELinux enforcing on 6.12 was never run: renamed sysfs/DT paths (e.g. `remoteproc-wpss@8a00000`
   instead of `qcom,wpss@8a00000/subsys2` in genfs_contexts), new nodes. A HAL may die where
   the permissive tests passed. `SELINUX=permissive` is one rebuild away (owner's call).
5. USB: dwc3 waits for the Samsung extcon of the power stack (first stage); if that stack fails,
   no USB and no adb. `USB_EXTCON=eud` is the tested fallback.
6. Audio waits up to 20 s at early-boot (init is blocked meanwhile); if the ADSP never comes up,
   the audio set loads anyway, the codecs stay deferred and system_server can hang in
   StartAudioService (seen in run s17 without audio).
7. Sequential first stage: 190 (6.12) / 189 (6.18) modules (the test loaded the same set). With
   `first_stage_console=2` a failing module is skipped, which may hide a broken driver.
8. Not in the boot (known gaps, as in the tests): modem in MODEM=0 builds (phone 2's modem
   image is refused; no IPA): RIL crash loop, telephony wakelock, no suspend (MODEM=1 = rb12,
   phone 1: section 2e); `sec_thermistor` (wrong ADC values,
   left out): Samsung thermal HAL reads fewer zones; microSD (`sdhci-msm` blocked);
   `clk/pd/regulator_ignore_unused`: warmer idle (48 C CPU), more drain; deep sleep untested;
   Wi-Fi never joined a network; fingerprint never enrolled; no hardware watchdog petting.
9. `/force_debuggable` side effects: `ro.force.debuggable=1`; if the ROM ships
   `/system_ext/etc/selinux/userdebug_plat_sepolicy.cil` init uses it (same as in all tests).
10. 5.4 leftovers run on 6.12: vendor_modprobe.sh's probe module, the 5.4 audio list,
   macloader's first path: all refused by vermagic (log noise only).
11. LineageOS OTA: an update rewrites boot (and maybe vendor_boot/dtbo) with 5.4 again, and the
   next realboot build must use the new boot patch level.

## 7. Open questions
- Does the ADSP really have to run before the audio modules load? The rule comes from the
  2026-11-13 Android runs (codecs deferred when the stage loaded before the ADSP); the exact
  cause was not pinned down (the 5.4 ROM loads its audio at early-init, before the ADSP). If a
  test shows it works early, the audio set moves into the first stage and the vendor rc goes
  away (CHECKLIST experiment).
- Does `adb remount` on this LineageOS go in place or through overlayfs, and does the overlay
  show up under 6.12?
- Where does the ROM set `ro.bpf.kver_override` (needed only for a user-build variant)?
- Is the hypervisor watchdog armed after an ABL boot under long CPU load?
- Should `sec_core clear_on_load` stay at the default (clear) for daily use? (yes unless
  upload mode is wanted).
- Phone 1 (One UI dtbo body, removed_region 0x5f00000) is NOT covered: this build is for
  phone 2's memory map and firmware only.
- An official bit-2 (A528BXXS2DWB5-compatible) firmware for last-resort recovery is not
  downloaded yet.

## Files
| File | What |
|---|---|
| `build-realboot.sh` | the build, all checks, REPORT.txt |
| `tools/modplan.py` | test stages -> first stage / vendor 6.12 / 5.4-gki, dedupe, params |
| `tools/cpiox.py` | unpacks concatenated newc cpio (gzip/lz4/raw) without root |
| `tools/cmdline-sim.py` | predicts /proc/cmdline from the live tree and finds what the kernel cuts (`--abl-min` = worst-case append) |
| `tools/loadsim.py` | insmod simulation of the real boot order (first stage, vendor rc, macloader); ELF checks from `bsp618/android/check-load.py` |
| `modules/dspboot/` | `a52sxq_dsp_boot.ko` source (built by the script against bsp612) |
| `dts/a52sxq-realboot-dtbo.dts` | the dtbo entry |
| `vendor-addon/a52sxq-kernel.rc.in` | vendor init rc template (both kernels: `a52sxq-k612.rc`, `a52sxq-k618.rc`) |
| `vendor-addon/wlan-5.4-gki.rc.in`, `wlan-bind.rc.in` | Wi-Fi part of the rc: 6.12 (wlan.ko in 5.4-gki itself) / 6.18 (bind `6.18-wlan` over 5.4-gki on post-fs; section 2g) |
| `patches/bsp612-kernel-0001-arm64-COMMAND_LINE_SIZE-4096.patch` | the 6.12 cmdline fix (applied in bsp612/kernel 14:23, assume-unchanged) |
| `CHECKLIST.md` | what hardware must still prove |
| `rehearse.sh`, `rehearsal/` | kexec rehearsal of the real boot (section 2c): helper copy, `a52ovl.c` (RAM overlay in init's namespace), `rh-checks.sh` (on-phone pass checks); MODEM=1: EFS RAM shim + modem rollback guard + modem checks (2e) |
| `tools/dtcompare.py` | subtree comparison of two dtbs (phandles compared by target path, allow-list) |
| `tools/iommu-resv-sim.py` | the 6.12 kernel's reading of iommu-addresses for one device + the fastmap IOVA range |
| `tools/ueventd-check.py` | /dev owners from the ROM's ueventd rules for the modem/data nodes vs the 5.4 /dev listing |
| `../modem/dt/ipa-iova-fix.sh` | the IPA IOVA window fix (2e), used by mkmodemtree.sh and MODEM=1 |
