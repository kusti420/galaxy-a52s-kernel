# Hop 2 compile survey: the 6.12 module set against ACK android17-6.18

Date: 2026-11-13/14. Offline only, nothing loaded or flashed. Question: how far is the module set
that boots Android on 6.12 (`bsp612/`) from building on Android Common Kernel 6.18.33 (`ack/`)?
No module source was edited; every build ran on copies in `bsp618/survey-src/`.

## Headline

| | modules | built (.ko) | compiled, no .ko | failed |
|---|---:|---:|---:|---:|
| soc-repo (Qualcomm KP 5.0 r70 vendor modules) | 272 | 157 | 2 | 113 |
| drivers612/* + samsung612/modules (our ports) | 123 | 56 | 0 | 67 |
| **total** | **395** | **213 (54 %)** | **2** | **180 (46 %)** |

(395 module instances = every `.mod` the 6.12 builds left behind; 381 distinct names, because
ioncompat, smcinvoke_dlkm, tas256x_dlkm, sec_audio_sysfs, qce50/qcrypto are built in two places.)

- **64 of the 180 failures are only `-Werror` diagnostics** (62 of them only
  `-Wmissing-prototypes`): one Makefile flag away from building.
- **120 of 180 need only mechanical fixes**: the -Werror flag plus the four rename-class
  clusters (`.remove_new`, timer API, quoted `MODULE_IMPORT_NS`, `ida_simple_*`). All sed or
  Coccinelle work, no design.
- **60 modules need real porting** (API semantics changed). Of those, the ones on the Android
  boot path: `msm_drm`, `msm_kgsl`, `pinctrl-msm` / `pinctrl-spmi-gpio` / `pinctrl-spmi-mpp`,
  `arm_smmu` / `qcom_iommu_util` / `qcom_smmu_v2_v3_dispatcher`, `ufs-qcom` /
  `ufshcd-crypto-qti` / `qcom_ice`, `dwc3-msm`, `qcom_dma_heaps`, `secure_buffer`, `minidump`,
  `sched-walt`, `spi-msm-geni`, `msm_geni_serial`, `qcom-pdc`, audio `platform_dlkm` /
  `machine_dlkm`, `tas256x_dlkm`, `wlan`, `rmnet_core`, `camera`, `msm-vidc`. The full list is
  under "Real porting work" below.
- **Symbols**: none of the 213 built modules needs a GKI symbol that 6.18 stopped exporting. Every
  unresolved symbol (224 symbols in 79 modules) comes from another of our modules that failed
  to build (cascade). Exceptions: 7 `ieee80211_nan_*` symbols in soc-repo's `mac80211.ko`,
  because the soc-repo Makefile builds the ACK 6.18 mac80211 sources without the new
  `nan.c` object. See "Symbols and namespaces".
- Kconfig: the soc-repo Kconfig hooks into 6.18 after one edit to break a dependency loop. 4
  fragment symbols do not take (6.12: 1). One structural clash: **6.18 GKI now ships
  `coresight.ko`, funnel, replicator, etm4x and trbe itself**, while soc-repo builds its own
  copies with the same names. See "Kconfig / config".

## Ranked root causes (by failed modules that have at least one error of the cluster)

"Sole" = the modules where this cluster is the only blocker apart from -Werror warnings, so
fixing it alone (plus the flag) unblocks them. Counts come from `out-survey/clusters.json`
(survey-report.py). The upstream change is named from the 6.18 sources; `ack/` and `bsp612/kernel`
are depth-1 clones, so there is no history to take commit IDs from. Versions are from memory
unless a hash is given; check them before quoting.

| # | cluster | modules | sole | error sites | upstream / ACK change | suggested fix |
|---:|---|---:|---:|---:|---|---|
| 1 | **-Wmissing-prototypes is now an error** | 105 | 62 | 931 | Upstream v6.8 turned `-Wmissing-prototypes`/`-Wmissing-declarations` on by default (0fcb70851fbf, "Makefile.extrawarn: turn on missing-prototypes globally"). android16-6.12 kept them under `W=1` (ACK difference, see `bsp612/kernel/scripts/Makefile.extrawarn:115`). android17-6.18 has them on by default (`ack/scripts/Makefile.extrawarn:21-22`). With `CONFIG_WERROR=y` every Qualcomm/Samsung non-static function without a header declaration fails. | Quick: `ccflags-y += -Wno-error=missing-prototypes -Wno-error=missing-declarations` per techpack (or `KCFLAGS`). Proper: `static` or a header declaration. |
| 2 | **`platform_driver.remove_new` removed** | 31 | 24 | 32 | `.remove()` returns void since v6.11. v6.13 dropped the transitional `.remove_new` member (`ack/include/linux/platform_device.h` no longer has it). | `sed 's/\.remove_new\b/.remove/'`. The prototype is already `void (*)(struct platform_device *)`. |
| 3 | **Timer API renames and removals** | 24 | 18 | 54 | `del_timer[_sync]()` became `timer_delete[_sync]()` (v6.15, old names removed v6.16). `from_timer()` became `timer_container_of()` (v6.16). `hrtimer_init()` removed for `hrtimer_setup()` (v6.16). Alarm timer callbacks now return void (`enum alarmtimer_restart` gone, sec-battery). All checked against `ack/include/linux/{timer,hrtimer,alarmtimer}.h`. | Coccinelle / sed: timer_delete*, timer_container_of; hrtimer_init+.function becomes hrtimer_setup(t, fn, clk, mode); alarm callbacks return void. |
| 4 | **`MODULE_IMPORT_NS(FOO)` must be a string** | 15 | 10 | 17 | Upstream v6.13 cdd30ebb1b9f "module: Convert symbol namespace to string literal". 6.18: `#define MODULE_IMPORT_NS(ns) MODULE_INFO(import_ns, ns)`. 6.12 stringified. The error reads `expected ';' after top level declarator`. | `MODULE_IMPORT_NS("DMA_BUF")` etc. This is the reverse of the 6.12 fix (ioncompat had to be unquoted for 6.12): use a version-guarded macro if one tree must build on both. |
| 5 | **mm / struct page API** | 9 | 6 | 30 | `nth_page()` removed (v6.18). `page->flags` is now `memdesc_flags_t` (v6.18; use `.f`). `NR_BOUNCE` and `NR_WRITEBACK_TEMP` vmstat items removed. `linux/zpool.h` removed (zsmalloc). `__SetPageMovable`/`__ClearPageMovable` gone (movable_ops rework). `sections_per_block` now `unsigned int` in a core header. | `nth_page(p,n)` becomes `p + n` (or `folio_page`); `page->flags.f`; drop the removed counters; zsmalloc: use GKI's (zpool is gone, zram talks to zsmalloc directly). |
| 6 | misc driver-core / subsystem removals (grab bag) | 13 | 10 | 20 | `linux/blk-mq-virtio.h` gone. cpufreq `policy_has_boost_freq` / `cpufreq_enable_boost_support` gone. `sdhci_pltfm_free` gone (devm). `of_pci_parse_bus_range` no longer exported, `pci_dev.aer_stats` moved. `power_supply_config.of_node` gone (use `fwnode`). `platform_device.driver_override` became a generic device field. `nr_irqs` became a function. `SPI_CS_CNT_MAX` gone. `console_stop` gone. `wakeup_source_add` gone. gic and irqchip probe signatures changed (msm_show_resume_irq, qcom-pdc). | One by one, mostly a few lines each. Upstream qcom-pdc / spi-geni / sdhci-msm show the new form. |
| 7 | const-ified callbacks (sysfs bin_attribute, device_match_t) | 7 | 5 | 10 | `bin_attribute` read/write callbacks and `attribute_group.bin_attrs` take `const struct bin_attribute *` (v6.13 to v6.16 transition). `device_find_child()` match functions take `const void *`. | Add `const` to the callback prototypes (qfprom-sys, qti_battery_debug, kgsl snapshot, hwmon, slimbus, msm_drm). |
| 8 | GPIO / pinctrl | 6 | 3 | 61 | `PIN_CONFIG_OUTPUT` removed (now `PIN_CONFIG_LEVEL`). `gpio_chip.set` returns `int` (v6.17 conversion). `gpio_chip.valid_mask` moved into gpiolib internals. Legacy `struct gpio` + `gpio_request_array()` removed from `<linux/gpio.h>`, which blocks **all of camera.ko** through `compat/cam_compat_612.h`. | pinctrl-msm/spmi: rebase on 6.18 upstream `drivers/pinctrl/qcom` (same files). Camera: replace `struct gpio` arrays with a local struct + gpiod or loops. |
| 9 | IOMMU / io-pgtable / pKVM | 5 | 2 | 19 | iommu-pages API renamed (`__iommu_alloc_pages`/`__iommu_free_pages`). `iommu_ops.pgsize_bitmap` moved to the domain. `iommu_domain_ops.enable_nesting` removed. `iommu_domain_alloc()` removed (use `iommu_paging_domain_alloc()`). `iommu_present()` and `iommu_fwspec_free()` removed. ACK pKVM IOMMU header `kvm/iommu.h` and `pkvm_module_ops` hyp_va/hyp_pa members changed in android17-6.18. | Biggest design item after display: Qualcomm's arm-smmu fork + io-pgtable-fast must be rebased on 6.18 arm-smmu. Check whether 6.18 upstream arm-smmu + qcom impl is enough for yupik first. |
| 10 | `ida_simple_get/remove` removed | 5 | 4 | 16 | The `ida_simple_*` wrappers were removed upstream after 6.12 (`ack/include/linux/idr.h`). | `ida_alloc_range()` / `ida_free()`. |
| 11 | ASoC | 5 | 3 | 14 | Legacy `SND_SOC_DAIFMT_CBS_CFS`/`CBM_CFM` names removed (use `CBC_CFC`/`CBP_CFP`). Compress `pointer` takes `snd_compr_tstamp64`. DAI/PCM `pcm_new` and `pcm_construct` arg changes. ACK vendor hook header `trace/hooks/sound.h` dropped. | Rename constants; adapt callbacks; the machine driver loses the ACK sound hook (check what it did). |
| 12 | crypto / blk-crypto | 4 | 3 | 15 | `blk_crypto_key.raw` became `.bytes`, `BLK_CRYPTO_KEY_TYPE_STANDARD` became `_RAW` (upstream hardware-wrapped-key support, v6.15; ACK carried its own variant before). Legacy `crypto_comp` API removed (soc-repo zram copy). | ICE/cqhci/ufshcd-crypto: follow upstream `qcom_ice`. zram: use GKI zram (6.18) instead of the soc-repo fork. |
| 13 | dma-fence / dma-heap | 4 | 1 | 24 | `dma_fence_ops.timeline_value_str`, `fence_value_str`, `use_64bit_seqno` removed (dma-fence rework, 6.17/6.18). ACK `dma_heap_ops.get_pool_size` and `get_dmabuf_debugfs_data` removed. | kgsl/msm_drm sync code: new `dma_fence_*` helpers. qcom_dma_heaps: drop the pool-size hook. |
| 14 | DRM | 4 | 2 | 49 | soc-repo carries a 6.12-era copy of `drivers/gpu/drm/display` (`drm_display_helper`) that now conflicts with 6.18 `include/drm` (DP/eDP backlight, MST payload signatures). `drm_bridge_funcs.attach` gains the encoder, `mode_valid` takes a const mode, `.detect` takes the connector, `drm_driver.date` removed, `drm_device.struct_mutex` removed, `fb_create` takes `drm_format_info`, `linux/pfn_t.h` removed, `FB_EVENT_BLANK` removed, `mipi_dsi_dcs_set_tear_off` removed. | Use GKI 6.18's `drm_display_helper` (drop the soc-repo copy). msm_drm/lt9611uxc: mechanical signature updates (12 x `struct_mutex` is the main real one). |
| 15 | USB/UFS/UCSI core internals | 4 | 3 | 25 | dwc3-msm uses dwc3 core internals (`dwc3_ep.regs`, `DWC3_DEPCMD*` macros changed). ufs-qcom uses the UFS trace enum (now private to the core) and keeps a static `ufshcd_dme_rmw` that the core now exports. `ucsi_operations.sync_control` signature changed. | Rebase on 6.18 `drivers/ufs/host/ufs-qcom.c`. dwc3-msm: re-derive from 6.18 dwc3 core (it is a fork of core internals). |
| 16 | cfg80211 / netdev | 4 | 2 | 18 | cfg80211_ops key and station callbacks take `struct wireless_dev *` instead of `struct net_device *` (qcacld `wlan.ko`, 11 sites). `rtnl_link_ops.newlink` takes `rtnl_newlink_params` (v6.15). `softnet_data.dropped` moved. GRO/TCP helper arg changes (rmnet_perf). | qcacld has kernel-version shims (`CFG80211_*` ifdefs) for most of these; add the 6.18 cases. rmnet: mechanical. |
| 17 | other -Werror (clang 22 / real bugs) | 3 | 1 | 3 | New clang 22 warnings: `-Wuninitialized-const-pointer` (sm5714-charger), plus two real uninitialised-variable bugs (msm_drm `sde_rm.c:1292`, qcom-hv-haptics). | Fix the code (they are real bugs). |
| 18 | WALT scheduler internals | 2 | 1 | 18 | `cfs_rq.h_nr_running` / `nr_running` renamed (`h_nr_queued`, `nr_queued`, v6.14 delayed-dequeue accounting). `set_next_entity` signature changed. Binder vendor-hook prototypes changed. | WALT reads `kernel/sched` internals: port per field, or drop WALT (it is optional for bring-up). |
| 19 | V4L2 | 1 | 0 | 6 | `vidioc_g_ctrl/s_ctrl/queryctrl` removed from `v4l2_ioctl_ops` (control framework only), plus changed helper args. | msm_vidc (5.4 v1 dialect): move to `v4l2_ctrl_handler` ops. |

Two more causes do not appear in the module counts:
- **Cascade**: modules whose own objects all compile but whose siblings failed. `qca808x` and
  `qcom-phy-lib` compiled with no .ko, because `drivers/net/phy` (aquantia) failed, so their
  `modules.order` never reached modpost. The 224 cascade symbols are listed in
  `out-survey/symbols.json`.
- **Clustering caveat**: clang stops at 20 errors per file (camera uses `-ferror-limit=0`),
  so a few heavy files may hide more errors behind the first ones. The "sole" numbers are a
  lower bound on the work, not a promise.

## Real porting work (failed modules with causes beyond the mechanical five)

soc-repo (41): virtio_block, zram, qcom-cpufreq-hw, qcom_dma_heaps, drm_display_helper, hwmon,
qcom-hv-haptics, qcom_smmu_v2_v3_dispatcher, arm_smmu, qcom_iommu_util, msm_show_resume_irq,
qcom-pdc, cqhci, sdhci-msm, aquantia, pci-msm-drv, pinctrl-msm, pinctrl-spmi-gpio,
pinctrl-spmi-mpp, qti-battery-charger, sg, slim-qcom-ngd-ctrl, slimbus, gic_intr_routing,
mem-offline, minidump, qcom_ice, qcom_va_minidump, qti_battery_debug, secure_buffer,
spi-msm-geni, msm_geni_serial, ufs-qcom, ufshcd-crypto-qti, dwc3-msm, ucsi_qti_glink,
sched-walt, zsmalloc, snd-soc-hdmi-codec, snd-usb-audio-qmi.
Ours (19): qfprom-sys, seaprobe, display (lt9611uxc, msm_drm), power (sm5714-charger,
usb_notify_layer), audio (tas256x_dlkm x2, machine_dlkm, platform_dlkm, pinctrl_lpi_dlkm,
pinctrl_wcd_dlkm), msm_kgsl, msm-vidc, conn/data (rmnet_perf, rmnet_shs, rmnet_core),
qcacld wlan, camera.

Several soc-repo items are Qualcomm forks of upstream drivers (zram, zsmalloc, virtio_blk,
hwmon, sg, drm_display_helper, aquantia, arm_smmu, pinctrl-msm, ufs-qcom, sdhci-msm, slimbus,
spi/serial geni). For each, first check whether GKI 6.18 or 6.18 upstream already has what the
phone needs. Dropping the fork is often cheaper than porting it.

## Symbols and namespaces (`survey-symbols.py`, `gki-exports-diff.txt`)

- 6.18 build: unresolved symbols of the 213 built .ko against 6.18 GKI `Module.symvers` plus all
  survey symvers: **0 GKI gaps**, 224 cascade symbols (provided by our failed modules), and 7
  `ieee80211_nan_*` in soc-repo `mac80211.ko`. The soc-repo `net/mac80211/Makefile` (6.12)
  builds the 6.18 mac80211 sources but lacks the new NAN object.
  Fix: take the 6.18 Makefile, or use GKI's mac80211 if the vendor one is not needed.
- 6.12 binaries vs 6.18 exports (`gki-exports-diff.txt`): 56 GKI symbols imported by the
  6.12-built modules are not exported by 6.18 under the same name (170 modules). Most are
  renames that a recompile resolves (`alloc_workqueue` became a macro over
  `alloc_workqueue_noprof`, `debugfs_create_file` over `debugfs_create_file_full`,
  `init_timer_key`, `ioremap_prot`, `sg_next`, `__memcpy_fromio`/`toio`, `krealloc_noprof`).
  Real removals among them (most also appear as compile errors): `hrtimer_init`, `iommu_domain_alloc`,
  `iommu_present`, `iommu_fwspec_free`, `kthread_create_worker`, `sdhci_pltfm_free`,
  `console_stop`, `of_pci_parse_bus_range`, `wakeup_source_add/remove`, cpufreq boost
  helpers, `crypto_comp_*`, `__SetPageMovable`, `get_dmabuf_debugfs_data`,
  `__tracepoint_android_vh_snd_pcm_check_no_buffer`. Consequence: **no 6.12 binary module can
  be reused on 6.18**. Everything must be rebuilt (expected, different KMI).
- Namespaces: 7 imported GKI symbols LOST their namespace on 6.18 (`dma_heap_add/_get_*` were
  `DMA_BUF_HEAP`, `filp_open`/`close_fd` were the ANDROID GKI VFS namespace, `pcpu_nr_pages`/
  `vmalloc_nr_pages` were `MINIDUMP`). The existing `MODULE_IMPORT_NS` lines become no-ops.
  Not a blocker, but they must still be quoted (cluster 4).
- `kernel_read`, `kernel_write` and `kasan_flag_enabled` changed from EXPORT_SYMBOL to
  EXPORT_SYMBOL_GPL. All our modules are GPL, so this does not matter.

## Kconfig / config (`config-diff.txt`)

- gki_defconfig 6.12 to 6.18: 100 symbols set only on 6.12 and 154 only on 6.18, mostly
  renames and helpers. Relevant to the vendor set:
  - **`CONFIG_CORESIGHT`, `_LINKS_AND_SINKS`, `_SOURCE_ETM4X`, `_TRBE` are now `=m` in GKI.**
    GKI builds `coresight.ko`, `coresight-funnel.ko`, `coresight-replicator.ko`,
    `coresight-etm4x.ko` and `coresight-trbe.ko`; soc-repo builds the same names. Pick one: the
    vendor coresight stack (then do not ship GKI's) or GKI's (then drop soc-repo coresight core
    and links). This also makes soc-repo attempt `coresight-etm4x` (it fails on the
    `TRFCR_ELx_*` sysreg renames, v6.15 sysreg generation).
  - `CONFIG_CFI_CLANG` is now `CONFIG_CFI`. `CONFIG_DRM_DISPLAY_DP_HELPER` is gone from GKI
    (`drm_display_helper` is built differently). `CONFIG_HWMON=y` and `CONFIG_SW_SYNC=y` are now
    in GKI. `MEMCG_V1` is off. `ARM64_BTI_KERNEL=y`, `ARM64_GCS=y`.
- Vendor layer (lahaina_perf.fragment + soc-repo Kconfig on top of gki_defconfig): 394 symbols
  on 6.12, 392 on 6.18. Only `BRIDGE_EBT_BROUTE`/`BRIDGE_NF_EBTABLES_LEGACY` and
  `MEMORY_HOTPLUG_DEFAULT_ONLINE` (renamed upstream to `MHP_DEFAULT_ONLINE_TYPE_*`) are lost.
  New are `ARM_SMMU_MMU_500_CPRE_ERRATA`, `DRM_DISPLAY_DP_HELPER` and `GUNYAH_TIMER`.
- Fragment symbols that do not take on 6.18: `BRIDGE_EBT_BROUTE`,
  `MEMORY_HOTPLUG_DEFAULT_ONLINE`, `SOFTLOCKUP_DETECTOR=n` (now selected by the 6.18 GKI
  hard-lockup detector) and `UAPI_HEADER_TEST` (also on 6.12).
- Kconfig loop (fixed in the survey copy only): soc-repo `ARM_PARAVIRT_SMMU_V3` (`depends on
  QCOM_SCM`, `select IOMMU_API`) and 6.18 `VIDEO_QCOM_VENUS` (now `depends on IOMMU_API`,
  `select QCOM_SCM`) form a recursive dependency, and `make gki_defconfig` with the soc-repo
  hook aborts. Survey edit: `select IOMMU_API` became `depends on IOMMU_API`. For the real
  port, make that a soc-repo patch.
- soc-repo-staging: the three Qualcomm `.diff`s (fixed regulator, gpi, virtio_net) still apply
  to the 6.18 sources.

## How the survey was run (reproduce: `bsp618/build-survey.sh all`, then the two report scripts)

- Kernel: `ack/` (6.18.33 with the local uncommitted a52sxq changes), `O=bsp618/out-survey/gki`,
  gki_defconfig, clang **r596125** and rustc **1.91.1** (the ACK pins in
  `build.config.constants`; 1.91.1 was installed with rustup), CONFIG_RUST=y as in bsp612.
  Image + vmlinux + GKI modules + Module.symvers: under 10 min with -j24. `out-ack/` untouched.
- Module config: `out-survey/lahaina` = gki_defconfig + `bsp612/lahaina_perf.fragment` with
  the soc-repo Kconfig hooked in, then modules_prepare. Module.symvers and vmlinux are taken
  from gki, as in `bsp612/build.sh`.
- `survey-src/` mirrors the repo root so the copied build.sh files run unchanged.
  `bsp612/kernel` links to `ack/` and `bsp612/out` to `out-survey`. soc-repo, techpacks,
  drivers612 and samsung612/modules are copies. soc-repo-staging is re-assembled from ACK 6.18
  `drivers/`+`net/` with soc-repo laid over it (assemble.sh step 3). `donors` links to the
  real donors (read only).
- Build-system adjustments (survey copies only, no source edits):
  1. Copied scripts: absolute repo path, and clang-r547379 replaced by clang-r596125.
  2. bindgen 0.72.0 with libclang r596125 (clang 22.0.2) turns every struct with an embedded
     opaque type into an opaque one (`blk_mq_tag_set { _address: u8 }`), and `rust/` fails.
     libclang from **r584948b** (22.0.1) works, so the survey uses it. The real 6.18 build
     needs the same workaround or a newer bindgen.
  3. The Kconfig loop edit above.
  4. camera's Kbuild reaches soc-repo as `$(srctree)/../soc-repo`, so it is pointed at the
     survey copy.
  5. audio links against mm-drivers' Module.symvers, which is linked from the survey display
     build.
  6. `make -i -k KBUILD_MODPOST_WARN=1` for every set: kbuild then runs modpost (with `-n`)
     over whatever compiled, so .ko files and symvers exist despite failures. The soc-repo
     failures were re-run with -j1 for clean diagnostics (`logs/soc.log`; the interleaved -j24
     log is `logs/soc-j24.log`).
- Reports: `survey-report.py` (per-module status from the 6.12 `.mod` object lists + log
  parsing + clustering; writes `out-survey/{report,clusters}.json` and `modules.md`, which is
  the appendix below) and `survey-symbols.py` (`out-survey/symbols.json`).
- Not covered: link/load behaviour, KMI/CRC compatibility with a real android17-6.18 GKI
  build (our GKI is a plain-make gki_defconfig build), the dtbs, and the drivers612 pieces
  with no M= build (boarddt, androidboot packer, tools).

## Suggested order for the real hop

1. Add `-Wno-error=missing-prototypes -Wno-error=missing-declarations` to every vendor
   Kbuild, then mechanical sweeps (Coccinelle): `.remove_new`, timer API, quoted namespaces,
   `ida_simple_*`. This alone moves about 120 of the 180 failures to built.
2. Decide fork-vs-GKI per duplicated upstream driver (coresight, zram/zsmalloc, virtio_blk,
   drm_display_helper, mac80211, hwmon, sg). Dropping forks removes several clusters at once.
3. Boot-path ports: pinctrl-msm family, arm-smmu/io-pgtable, ufs-qcom + ICE, dwc3-msm,
   geni serial/spi, qcom-pdc, dma heaps/secure_buffer, then msm_drm/kgsl (dma-fence,
   struct_mutex), audio, wlan (cfg80211 wdev ops), camera (`struct gpio`), vidc (V4L2 ctrls).

## Appendix: per-module result (generated, `out-survey/modules.md`)

### soc-repo (`bsp612/soc-repo-staging`): 272 modules, 157 built, 2 compiled without .ko, 113 failed

Built: `altmode-glink`, `aux-bridge`, `bcl_soc`, `boot_stats`, `bwmon`, `camcc-sc7280`, `camcc-sm8350`, `cfg80211`, `charger-ulog-glink`, `clk-dummy`, `clk-rpmh`, `clk-scmi`, `cmd-db`, `coresight`, `coresight-csr`, `coresight-cti`, `coresight-qmi`, `coresight-remote-etm`, `coresight-tgu`, `coresight-tmc-sec`, `coresight-tpda`, `coresight-tpdm`, `coresight-trace-noc`, `cpu_hotplug`, `cpu_voltage_cooling`, `cpucp_log`, `dcc_v2`, `dcvs_fp`, `ddr_cdev`, `debug-regulator`, `debug_symbol`, `debugcc-sc7280`, `debugcc-sm8350`, `deferred-free-helper`, `dispcc-sc7280`, `dispcc-sm8350`, `eud`, `extcon-usb-gpio`, `f_fs_ipc_log`, `fsa4480_i2c`, `gcc-sc7280`, `gcc-sm8350`, `gdsc-regulator`, `gh_arm_drv`, `gh_ctrl`, `gh_dbl`, `gh_irq_lend`, `gh_mem_notifier`, `gh_tlmm_vm_mem_access`, `gh_virt_wdt`, `glink_probe`, `gpucc-sc7280`, `gpucc-sm8350`, `heap_mem_ext_v01`, `icc-bcm-voter`, `icc-clk`, `iommu-logger`, `kryo_arm64_edac`, `leds-qcom-lpg`, `mac80211`, `mdt_loader`, `mem_buf_msgq`, `memory_dump_v2`, `mhi_dev_uci`, `microdump_collector`, `msm_dma_iommu_mapping`, `msm_lmh_dcvs`, `msm_memshare`, `msm_performance`, `msm_qmp`, `msm_sharedmem`, `nb7vpq904m`, `nvmem_qcom-spmi-sdam`, `nvmem_qfprom`, `panel_event_notifier`, `pcie-pdc`, `phy-msm-snps-hs`, `phy-msm-ssusb-qmp`, `phy-qcom-emu`, `phy-qcom-ufs`, `phy-qcom-ufs-qmp-v4-lahaina`, `phy-qcom-ufs-qmp-v4-yupik`, `phy-qcom-ufs-qrbtc-sdm845`, `pinctrl-lahaina`, `pinctrl-yupik`, `pmic-glink-debug`, `pmic-pon-log`, `policy_engine`, `proxy-consumer`, `qca808x`, `qcom-amoled-regulator`, `qcom-cpufreq-hw-debug`, `qcom-dcvs`, `qcom-dload-mode`, `qcom-i2c-pmic`, `qcom-phy-lib`, `qcom-pm8008`, `qcom-pm8008-regulator`, `qcom-pon`, `qcom-reboot-reason`, `qcom-spmi-adc-tm5`, `qcom-spmi-adc5`, `qcom-spmi-pmic`, `qcom-spmi-temp-alarm`, `qcom-spmi-wled`, `qcom-vadc-common`, `qcom_cpu_vendor_hooks`, `qcom_cpucp`, `qcom_glink_smem`, `qcom_glink_spss`, `qcom_hwspinlock`, `qcom_iommu_debug`, `qcom_ipc_logging`, `qcom_llcc_pmu`, `qcom_pd_mapper`, `qcom_pdr_msg`, `qcom_pil_info`, `qcom_q6v5`, `qcom_scmi_client`, `qcom_scmi_vendor`, `qcom_soc_wdt`, `qmi_helpers`, `qnoc-lahaina`, `qnoc-qos`, `qpnp-lcdb-regulator`, `qrtr`, `qrtr-gunyah`, `qrtr-mhi`, `qrtr-smd`, `qsee_ipc_irq_bridge`, `qseecom_proxy`, `qti-fixed-regulator`, `qti-glink-adc`, `qti-regmap-debugfs`, `qti_amoled_ecm`, `qti_cpufreq_cdev`, `qti_devfreq_cdev`, `qti_pmic_glink`, `qti_qmi_cdev`, `qti_thermal_vendor_hooks`, `qti_userspace_cdev`, `rdbg`, `reboot-mode`, `redriver`, `refgen`, `rpmh-regulator`, `rq_stats`, `sdpm_clk`, `smp2p_sleepstate`, `spmi-pmic-arb-debug`, `sps_drv`, `stm_core`, `stm_ftrace`, `stm_p_ost`, `usb_f_qdss`, `videocc-sc7280`, `videocc-sm8350`, `virtio_console`, `wcd_usbss_i2c`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `adsp_sleepmon` | timer-api: 3 | 1 of 1 |
| `aquantia` | misc-api: 1 | 2 of 4 |
| `arm_smmu` | iommu: 6, werror-proto: 3, remove-new: 1 | 2 of 4 |
| `bam_dma` | remove-new: 1 | 1 of 1 |
| `bcl_pmic5` | werror-proto: 2 | 1 of 2 |
| `cap1296` | werror-proto: 9 | 1 of 1 |
| `cdsprm` | werror-proto: 2 | 1 of 1 |
| `clk-qcom` | werror-proto: 10 | 2 of 19 |
| `coresight-dummy` | remove-new: 1 | 1 of 1 |
| `coresight-funnel` | remove-new: 1 | 1 of 1 |
| `coresight-replicator` | remove-new: 1 | 1 of 1 |
| `coresight-stm` | remove-new: 1 | 1 of 1 |
| `coresight-tmc` | remove-new: 1 | 1 of 5 |
| `cqhci` | crypto-blk: 4 | 1 of 3 |
| `crm-v2` | werror-proto: 2 | 1 of 1 |
| `drm_display_helper` | drm: 15 | 5 of 8 |
| `dwc3-msm` | usb-ufs-internals: 13 | 1 of 3 |
| `gh_msgq` | werror-proto: 1 | 1 of 1 |
| `gh_rm_drv` | werror-proto: 1 | 1 of 3 |
| `gic_intr_routing` | werror-proto: 4, misc-api: 1 | 1 of 1 |
| `glink_pkt` | ida-simple: 4 | 1 of 1 |
| `governor_gpubw_mon` | werror-proto: 2 | 1 of 1 |
| `governor_msm_adreno_tz` | werror-proto: 4 | 1 of 1 |
| `gunyah_loader` | werror-proto: 11 | 3 of 4 |
| `hung_task_enh` | werror-proto: 2 | 1 of 1 |
| `hvc_gunyah` | werror-proto: 2 | 1 of 1 |
| `hwmon` | const-callbacks: 1, werror-proto: 1 | 1 of 1 |
| `i2c-msm-geni` | werror-proto: 6 | 1 of 1 |
| `icc-debug` | werror-proto: 2 | 1 of 1 |
| `icc-rpmh` | werror-proto: 1 | 1 of 1 |
| `leds-qcom-flash` | werror-proto: 1, remove-new: 1 | 1 of 1 |
| `leds-qpnp-vibrator-ldo` | timer-api: 1 | 1 of 1 |
| `leds-qti-flash` | timer-api: 1 | 1 of 1 |
| `llcc-qcom` | remove-new: 1 | 1 of 1 |
| `llcc_perfmon` | timer-api: 1 | 1 of 1 |
| `mem-offline` | mm-page: 1 | 1 of 1 |
| `mem_buf` | ns-string: 1 | 1 of 2 |
| `mem_buf_dev` | ns-string: 1 | 1 of 4 |
| `memlat` | timer-api: 1 | 1 of 1 |
| `mhi` | werror-proto: 5 | 2 of 5 |
| `minidump` | werror-proto: 6, mm-page: 6, sched-walt: 2, ns-string: 2, dma-fence-heap: 1 | 3 of 4 |
| `msm_geni_serial` | werror-proto: 5, misc-api: 1 | 1 of 1 |
| `msm_gpi` | werror-proto: 5 | 1 of 1 |
| `msm_show_resume_irq` | misc-api: 2 | 1 of 1 |
| `msm_sysstats` | ns-string: 1 | 1 of 1 |
| `pci-msm-drv` | misc-api: 4, werror-proto: 2 | 1 of 2 |
| `pdr_interface` | timer-api: 3 | 1 of 1 |
| `phy-generic` | remove-new: 1 | 1 of 1 |
| `pinctrl-msm` | gpio-pinctrl: 7 | 1 of 1 |
| `pinctrl-spmi-gpio` | gpio-pinctrl: 5, remove-new: 1 | 1 of 1 |
| `pinctrl-spmi-mpp` | gpio-pinctrl: 5, remove-new: 1 | 1 of 1 |
| `pm8941-pwrkey` | remove-new: 1 | 1 of 1 |
| `qcom-cpufreq-hw` | misc-api: 2, remove-new: 1 | 1 of 1 |
| `qcom-hv-haptics` | werror-proto: 1, werror-other: 1 | 1 of 1 |
| `qcom-ipcc` | remove-new: 1 | 1 of 1 |
| `qcom-pdc` | misc-api: 1 | 1 of 1 |
| `qcom-pmu-lib` | werror-proto: 1 | 1 of 1 |
| `qcom-scm` | werror-proto: 5 | 1 of 6 |
| `qcom_aoss` | remove-new: 1 | 1 of 1 |
| `qcom_dma_heaps` | werror-proto: 13, dma-fence-heap: 2 | 7 of 9 |
| `qcom_edac` | remove-new: 1 | 1 of 1 |
| `qcom_glink` | werror-proto: 5 | 2 of 3 |
| `qcom_ice` | crypto-blk: 1 | 1 of 1 |
| `qcom_iommu_util` | iommu: 6, mm-page: 6, werror-proto: 6 | 3 of 6 |
| `qcom_logbuf_boot_log` | werror-proto: 2 | 1 of 1 |
| `qcom_logbuf_vendor_hooks` | werror-proto: 1 | 1 of 1 |
| `qcom_lpm` | werror-proto: 2, timer-api: 2 | 2 of 3 |
| `qcom_q6v5_pas` | werror-proto: 2, timer-api: 1, remove-new: 1 | 1 of 1 |
| `qcom_ramdump` | ida-simple: 3, werror-proto: 1 | 1 of 1 |
| `qcom_rpmh` | werror-proto: 1 | 1 of 2 |
| `qcom_smd` | remove-new: 1 | 1 of 1 |
| `qcom_smmu_v2_v3_dispatcher` | iommu: 2 | 4 of 6 |
| `qcom_spss` | werror-proto: 1 | 1 of 1 |
| `qcom_stats` | remove-new: 1 | 1 of 1 |
| `qcom_sysmon` | timer-api: 6 | 1 of 1 |
| `qcom_tsens` | werror-proto: 1, remove-new: 1 | 1 of 5 |
| `qcom_va_minidump` | mm-page: 2 | 1 of 1 |
| `qcom_wdt_core` | timer-api: 9 | 1 of 1 |
| `qfprom-sys` | const-callbacks: 1 | 1 of 1 |
| `qnoc-yupik` | remove-new: 1 | 1 of 1 |
| `qti-battery-charger` | misc-api: 1 | 1 of 3 |
| `qti_battery_debug` | const-callbacks: 3 | 1 of 1 |
| `qti_qmi_sensor` | werror-proto: 1 | 1 of 2 |
| `rproc_qcom_common` | timer-api: 3, werror-proto: 2 | 1 of 2 |
| `rtc-pm8xxx` | remove-new: 1 | 1 of 1 |
| `sched-walt` | werror-proto: 31, sched-walt: 16 | 13 of 24 |
| `sdhci-msm` | misc-api: 2, werror-proto: 1, remove-new: 1 | 1 of 1 |
| `secure_buffer` | mm-page: 2 | 1 of 1 |
| `sg` | mm-page: 2 | 1 of 1 |
| `si_core_module` | werror-proto: 6, ns-string: 1 | 5 of 7 |
| `slim-qcom-ngd-ctrl` | remove-new: 2, misc-api: 1 | 1 of 1 |
| `slimbus` | const-callbacks: 2 | 1 of 4 |
| `smem` | remove-new: 1 | 1 of 1 |
| `smp2p` | remove-new: 1 | 1 of 1 |
| `snd-soc-hdmi-codec` | drm: 1, asoc: 1 | 1 of 1 |
| `snd-usb-audio-qmi` | iommu: 2 | 1 of 2 |
| `socinfo` | werror-proto: 2, remove-new: 1 | 1 of 1 |
| `spi-msm-geni` | werror-proto: 3, misc-api: 2 | 1 of 1 |
| `spmi-pmic-arb` | remove-new: 1 | 1 of 1 |
| `stub-regulator` | werror-proto: 1 | 1 of 1 |
| `sys_pm_vx` | werror-proto: 2 | 1 of 1 |
| `sysmon_subsystem_stats` | werror-proto: 3 | 1 of 1 |
| `thermal_config` | werror-proto: 2 | 1 of 1 |
| `thermal_pause` | werror-proto: 3 | 1 of 1 |
| `ucsi_qti_glink` | usb-ufs-internals: 1 | 1 of 1 |
| `ufs-qcom` | usb-ufs-internals: 11 | 1 of 1 |
| `ufshcd-crypto-qti` | crypto-blk: 3, usb-ufs-internals: 1, werror-proto: 1 | 1 of 1 |
| `usb_f_ccid` | ida-simple: 3 | 1 of 1 |
| `usb_f_cdev` | werror-proto: 8, ida-simple: 3 | 1 of 1 |
| `usb_f_gsi` | timer-api: 3, ida-simple: 3 | 1 of 2 |
| `virtio_block` | misc-api: 1 | 1 of 1 |
| `zram` | crypto-blk: 7, werror-proto: 1 | 2 of 2 |
| `zsmalloc` | mm-page: 1 | 1 of 1 |

### sec_core (`samsung612/modules/sec_core`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `sec_core`

### qfprom-sys (`drivers612/qfprom-sys`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `qfprom-sys` | const-callbacks: 1 | 1 of 1 |

### testguard (`drivers612/androidboot/testguard`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `testguard`

### debug/fnprobe (`drivers612/debug/fnprobe`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `fnprobe`

### debug/seaprobe (`drivers612/debug/seaprobe`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `seaprobe` | mm-page: 1 | 1 of 1 |

### hwbringup/pdmapper (`drivers612/hwbringup/pdmapper`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `qcom_pd_mapper`

### secure/ioncompat (`drivers612/secure/ioncompat`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `ioncompat` | ns-string: 1 | 1 of 1 |

### secure/securemsm (`drivers612/secure/securemsm`): 18 modules, 6 built, 0 compiled without .ko, 12 failed

Built: `qrng_dlkm`, `qrng_dlkm`, `qseecom_dlkm`, `qseecom_dlkm`, `tz_log_dlkm`, `tz_log_dlkm`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `hdcp_qseecom_dlkm` | werror-proto: 9 | 2 of 3 |
| `hdcp_qseecom_dlkm` | werror-proto: 9 | 2 of 3 |
| `qce50_dlkm` | timer-api: 2 | 1 of 1 |
| `qce50_dlkm` | timer-api: 2 | 1 of 1 |
| `qcedev-mod_dlkm` | werror-proto: 5 | 1 of 3 |
| `qcedev-mod_dlkm` | werror-proto: 5 | 1 of 3 |
| `qcrypto-msm_dlkm` | timer-api: 2 | 1 of 1 |
| `qcrypto-msm_dlkm` | timer-api: 2 | 1 of 1 |
| `smcinvoke_dlkm` | werror-proto: 4, ns-string: 2 | 2 of 2 |
| `smcinvoke_dlkm` | werror-proto: 4, ns-string: 2 | 2 of 2 |
| `smmu_proxy_dlkm` | werror-proto: 4 | 1 of 2 |
| `smmu_proxy_dlkm` | werror-proto: 4 | 1 of 2 |

### secure/adsprpc (`drivers612/secure/adsprpc`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `frpc-adsprpc` | ns-string: 1 | 1 of 1 |

### display (`drivers612/display`): 5 modules, 3 built, 0 compiled without .ko, 2 failed

Built: `lcd`, `msm_ext_display`, `sec_panel_notifier_v2`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `lt9611uxc` | drm: 6, werror-proto: 1 | 1 of 1 |
| `msm_drm` | drm: 27, dma-fence-heap: 6, iommu: 3, ns-string: 2, timer-api: 1, const-callbacks: 1, werror-other: 1 | 16 of 134 |

### touch (`drivers612/touch`): 8 modules, 5 built, 0 compiled without .ko, 3 failed

Built: `sec_common_fn`, `sec_secure_touch`, `sec_tclm_v2`, `sec_tsp_dumpkey`, `sec_tsp_log`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `sec_cmd` | werror-proto: 1 | 1 of 1 |
| `sec_input_notifier` | werror-proto: 4 | 1 of 1 |
| `stm_ts` | werror-proto: 17 | 5 of 6 |

### power (`drivers612/power`): 22 modules, 8 built, 0 compiled without .ko, 14 failed

Built: `a52sxq_usb_glue`, `mfd_sm5714`, `pca9468_charger`, `sb-core`, `sec_pd`, `switch_class`, `usb_notifier`, `vbus_notifier`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `common_muic` | werror-proto: 2 | 1 of 3 |
| `if_cb_manager` | werror-proto: 2 | 1 of 1 |
| `leds-sm5714-fled` | werror-proto: 2 | 1 of 1 |
| `muic_sm5714` | werror-proto: 4 | 2 of 3 |
| `pdic_notifier_module` | werror-proto: 3 | 2 of 5 |
| `pdic_sm5714` | werror-proto: 19 | 2 of 3 |
| `s2mpb03` | werror-proto: 6 | 1 of 1 |
| `sec-battery` | werror-proto: 21, timer-api: 3 | 6 of 11 |
| `sec-direct-charger` | werror-proto: 2 | 1 of 2 |
| `sec_thermistor` | werror-proto: 1 | 1 of 1 |
| `sm5714-charger` | werror-other: 1 | 1 of 2 |
| `sm5714_fuelgauge` | werror-proto: 5 | 1 of 1 |
| `usb_notify_layer` | werror-proto: 23, misc-api: 1 | 5 of 6 |
| `usb_typec_manager` | werror-proto: 3 | 1 of 2 |

### audio (`drivers612/audio/audio-kernel`): 32 modules, 19 built, 0 compiled without .ko, 13 failed

Built: `adsp_loader_dlkm`, `apr_dlkm`, `bolero_cdc_dlkm`, `hdmi_dlkm`, `mbhc_dlkm`, `q6_notifier_dlkm`, `q6_pdr_dlkm`, `rx_macro_dlkm`, `snd_event_dlkm`, `stub_dlkm`, `swr_dmic_dlkm`, `swr_haptics_dlkm`, `tx_macro_dlkm`, `va_macro_dlkm`, `wcd937x_slave_dlkm`, `wcd938x_slave_dlkm`, `wcd9xxx_dlkm`, `wsa883x_dlkm`, `wsa_macro_dlkm`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `machine_dlkm` | werror-proto: 3, asoc: 1 | 2 of 2 |
| `native_dlkm` | werror-proto: 33 | 16 of 27 |
| `pinctrl_lpi_dlkm` | gpio-pinctrl: 5, werror-proto: 3 | 1 of 1 |
| `pinctrl_wcd_dlkm` | gpio-pinctrl: 4 | 1 of 1 |
| `platform_dlkm` | werror-proto: 58, asoc: 10, timer-api: 1, ns-string: 1 | 18 of 22 |
| `q6_dlkm` | werror-proto: 48, ns-string: 1 | 11 of 17 |
| `sec_audio_sysfs` | remove-new: 1 | 1 of 1 |
| `swr_ctrl_dlkm` | werror-proto: 2 | 1 of 1 |
| `swr_dlkm` | werror-proto: 1 | 1 of 2 |
| `tas256x_dlkm` | werror-proto: 20, asoc: 1 | 7 of 11 |
| `wcd937x_dlkm` | werror-proto: 1 | 1 of 4 |
| `wcd938x_dlkm` | werror-proto: 2 | 1 of 4 |
| `wcd_core_dlkm` | werror-proto: 1 | 1 of 4 |

### audio/samsung (`drivers612/audio/samsung`): 2 modules, 0 built, 0 compiled without .ko, 2 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `sec_audio_sysfs` | remove-new: 1 | 1 of 1 |
| `tas256x_dlkm` | werror-proto: 20, asoc: 1 | 7 of 11 |

### gpu (kgsl) (`drivers612/gpu-video/gpu`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `msm_kgsl` | werror-proto: 21, dma-fence-heap: 15, mm-page: 9, const-callbacks: 1 | 17 of 79 |

### video (msm_vidc) (`drivers612/gpu-video/video`): 1 modules, 0 built, 0 compiled without .ko, 1 failed

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `msm-vidc` | werror-proto: 67, v4l2: 6, ns-string: 1 | 9 of 20 |

### conn/subsys_compat (`drivers612/conn/subsys_compat`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `subsys_compat`

### conn/rild/drb (`drivers612/conn/rild`): 1 modules, 1 built, 0 compiled without .ko, 0 failed

Built: `dev_ril_bridge`

### conn/data (`drivers612/conn/data`): 13 modules, 2 built, 0 compiled without .ko, 11 failed

Built: `ipanetm`, `rmnet_sch`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `gsim` | werror-proto: 6 | 3 of 4 |
| `ipam` | werror-proto: 43, timer-api: 1 | 16 of 55 |
| `rmnet_aps` | timer-api: 2, werror-proto: 1 | 1 of 2 |
| `rmnet_core` | werror-proto: 7, timer-api: 5, cfg80211-net: 1 | 6 of 16 |
| `rmnet_ctl` | werror-proto: 3 | 1 of 2 |
| `rmnet_mem` | werror-proto: 10, timer-api: 1 | 2 of 3 |
| `rmnet_offload` | werror-proto: 2 | 2 of 7 |
| `rmnet_perf` | werror-proto: 16, cfg80211-net: 2 | 2 of 3 |
| `rmnet_perf_tether` | werror-proto: 5 | 1 of 1 |
| `rmnet_shs` | werror-proto: 27, timer-api: 2, cfg80211-net: 1 | 4 of 9 |
| `rmnet_wlan` | werror-proto: 1 | 1 of 5 |

### conn/bt (`drivers612/conn/bt`): 2 modules, 1 built, 0 compiled without .ko, 1 failed

Built: `btpower`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `bt_fm_slim` | werror-proto: 1 | 1 of 3 |

### conn/wlan (`drivers612/conn/wlan`): 6 modules, 5 built, 0 compiled without .ko, 1 failed

Built: `cnss_nl`, `cnss_prealloc`, `cnss_utils`, `icnss2`, `wlan_firmware_service`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `wlan` | cfg80211-net: 14 | 3 of 654 |

### camera (`drivers612/camera`): 3 modules, 1 built, 0 compiled without .ko, 2 failed

Built: `sm5714_fled_stub`

| failed module | causes (cluster: error sites) | failing objects |
|---|---|---|
| `camera` | werror-proto: 193, gpio-pinctrl: 35, ns-string: 1 | 138 of 138 |
| `ioncompat` | ns-string: 1 | 1 of 1 |

