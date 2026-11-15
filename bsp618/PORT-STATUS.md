# 6.18 port tree: status after the mechanical, boot-path, sched-walt and remaining-modules passes

Date: 2026-11-14 (mechanical pass, boot-path pass in the afternoon, sched-walt pass in the
evening, remaining-modules pass at 19:30). Offline only:
nothing loaded, flashed or run on a phone. Follows `SURVEY.md` (the compile survey of the 6.12
module set against ACK android17-6.18.33).

## Headline

| | modules | built (.ko) | compiled, no .ko | failed |
|---|---:|---:|---:|---:|
| survey (6.12 sources unchanged, `out-survey/`) | 395 | 213 (54 %) | 2 | 180 |
| port pass 1: the five mechanical rules + -Werror relaxation + patches 0001-0004 | 395 | 334 | 2 | 59 |
| port, mechanical pass (morning) | 395 | 357 (90 %) | 2 | 36 |
| port, boot-path pass (afternoon) | 395 | 367 (93 %) | 2 | 24 (+ 2 dropped) |
| **port, sched-walt pass (`out-port/`)** | **395** | **369 (93 %)** | **2** | **22** (+ 2 dropped) |
| **port, display pass** (display changes only) | **395** | **371 (94 %)** | **2** | **19** (+ 3 dropped) |
| **port, audio/wlan/camera/video pass** (measured together with the display pass) | **395** | **376 (95 %)** | **2** | **14** (+ 3 dropped) |
| **port, remaining-modules pass** (19:30) | **395** | **385 (97 %)** | **0** | **0** (+ 10 dropped) |

- **Real boot at 6.12 parity (2026-11-15, offline, `drivers612/realboot/out/rb618-5`,
  README section 2g there)**: ramdisk `a10` (`android/mkrd-dcvs-618.sh` = a9 + 6.18 builds of
  governor_msm_adreno_tz/governor_gpubw_mon in stage kgsl + stage dcvs bwmon/memlat; stages
  `stage-618/kgsl2`, `dcvs` by mkstages-618.py), `android-r02-618.dtb` regenerated from the
  busdcvs-fixed 6.12 tree, `src/drivers612/conn/data` with dataipa patch 0002 (only ipam.ko
  rebuilt), modem pack `drivers612/modem/out-618/pack-modem-618-txfix.tgz`, sdhci-msm/cqhci from
  the dist, `fw_devlink.sync_state=timeout deferred_probe_timeout=30` (both parsed by ACK 6.18).
  None of these has run on 6.18 yet: rehearsals `rh-rh618p2` / `rh-rh618p1` first.
- **Remaining-modules pass (2026-11-14 19:30, section "Remaining-modules pass" below)**: every
  module of the set now either builds or is dropped on purpose. **Built (7 + 2):** `rmnet_core`,
  `rmnet_shs`, `rmnet_perf` (the 6.12/5.4 modem data path: the modem stage's rmnet_ctl/core/
  offload/shs are complete, and `rmnet_offload`/`rmnet_aps`/`rmnet_perf_tether`/`rmnet_wlan` no
  longer have unresolved imports), `slim-qcom-ngd-ctrl` (LPASS slimbus for Bluetooth audio,
  `bt_fm_slim`), `snd-usb-audio-qmi` (USB-C audio offload), `ucsi_qti_glink`, `mem-offline`
  (patches 0040-0046), plus `qca808x` and `qcom-phy-lib` (were "compiled, no .ko" behind
  aquantia). **Dropped (7):** `zram`, `zsmalloc`, `virtio_block` (GKI 6.18 ships its own and
  those are the ones loaded), `aquantia` (Ethernet PHY), `snd-soc-hdmi-codec` (HDMI bridges),
  `msm_show_resume_irq` (no DT node), `pci-msm-drv` (both PCIe RCs disabled on the A52s).
  Every .ko of the a8 Android package (first stage, dist, all 17 stages) has the same GNU
  build-id after the rebuild: nothing that already worked changed. Full incremental
  `build618.sh`: 392 of 402 built (395 + 7 `extra`), 0 failed, 10 dropped; symbols: 0 GKI gaps,
  only `mhi.ko` keeps 2 unresolved imports (`msm_pcie_allow/prevent_l1`, from the dropped
  pci-msm-drv; mhi is not loaded either) + the known 7 `ieee80211_nan_*` of `mac80211.ko`.

- **Android kexec test pack (2026-11-14 15:10, section "Android on 6.18" below)**: clean
  sequential rebuild (`PORT_ARGS=--fresh build618.sh`, 6 min): **383 built** = the 376 above +
  7 from the new `extra` sets (fingerprint x2, nfc, vibrator x2, realboot dspboot, hhwdt), still
  14 failed / 3 dropped, none of them loaded by the 6.12 boot. `bsp618/android/` assembles the
  6.12 Android test (first stage + all 17 stages) from 6.18 builds; offline insmod simulation of
  the best 6.12 run's order: 222 ok, 0 fail.

- **Display pass** (section below): the whole androidboot display stage (19 modules of
  `drivers612/androidboot/out/stage-display/load.list`) builds on 6.18. `msm_drm` (Qualcomm
  r7 + Samsung ss_dsi_panel framework + S6E3FC3_AMS646YD01, `sde_rsc` inside) is
  modpost-clean under strict modpost (patch 0030); `drm_display_helper` is now ACK 6.18's own
  `drivers/gpu/drm/display` (new `UPSTREAM` step); `lt9611uxc` dropped. UBWC r7 DT fix and
  Samsung panel code untouched.

- **Audio/Wi-Fi/camera/video pass** (section below): every module of the androidboot stages
  `audio`, `dsp`, `i2c`, `wlanb`, `wlan` and `camera` now has a 6.18 .ko: `platform_dlkm`,
  `machine_dlkm` (the removed ACK sound hook replaced inside the module), `wlan` (qcacld),
  `camera` and `msm-vidc` build and are modpost-clean (0 unresolved imports). New rule
  `asoc-dpcm-dir`, patches 0020-0024. `tas256x_dlkm` already built since the mechanical pass.

- **sched-walt pass** (section below): `sched-walt` and `qcom-cpufreq-hw` build; 0 unresolved
  symbols in either; the WALT cascade is gone, so `ufs-qcom`, `thermal_pause`,
  `msm_performance`, `bwmon` and `qcom_lpm` are modpost-clean. All 58 vendor hooks WALT
  registers exist and are still called in ACK 6.18 (one prototype changed). Boot argument
  **`android_arch_task_struct_size=512` is required** (WALT now refuses to initialise without
  it instead of corrupting memory); `sched_proxy_exec=0` is recommended (proxy exec is on by
  default in ACK 6.18, off on 6.12).

- **Boot-path pass** (section below): every listed boot-path blocker builds: `ufs-qcom`,
  `ufshcd-crypto-qti`, `qcom_ice`, `cqhci`, `arm_smmu`, `qcom_iommu_util`, `dwc3-msm`,
  `usb_notify_layer`, `msm_kgsl`, plus `minidump` (a load dependency of ufs-qcom, the watchdog
  and ipc logging). `hwmon` and `qcom_smmu_v2_v3_dispatcher` are **dropped** (new report status:
  taken out of the build on purpose, `port618.py` `DROPPED`, `out-port/dropped.json`). Every
  fork was kept except those two: with the vendor DT the 6.18 vendor boot will use (as on
  6.12), upstream drivers do not match the nodes or lack the APIs the vendor modules import.
  No new error appeared in any module that still fails (checked module by module against the
  morning report).
- **All 120 modules the survey classed as "mechanical only" build** (checked module by module
  against `out-survey/report.json`), and 24 of the 60 "real porting" modules build too,
  through small rename-class rules and one-to-five-line patches (list below).
- The two "compiled, no .ko" are unchanged: `qca808x` and `qcom-phy-lib` are cascade victims of
  the failing `aquantia` in the same `drivers/net/phy` directory. (Remaining-modules pass: aquantia dropped, both
  build now.)
- Symbols (`survey-symbols.py` on the port tree, 369 .ko): 0 GKI gaps; every unresolved symbol
  of a built .ko is exported by a module that still fails (cascade: 16 symbols in 5 modules,
  all from `rmnet_core` and `pci-msm-drv`; the afternoon's 25 in 10 included the 9 WALT ones),
  plus the known 7 `ieee80211_nan_*` of soc-repo `mac80211.ko`. No modpost namespace error is
  left. `ufs-qcom` is out of the cascade.
- Every remaining failure needs a real API port or a fork-vs-upstream decision. None is
  `-Werror`-only any more.

Per set (survey built -> port built / failed):

| set | modules | survey built | port built | failed |
|---|---:|---:|---:|---:|
| soc-repo | 272 | 157 | 263 | 0 (+ 9 dropped) |
| sec_core | 1 | 1 | 1 | 0 |
| qfprom-sys | 1 | 0 | 1 | 0 |
| testguard | 1 | 1 | 1 | 0 |
| debug/fnprobe | 1 | 1 | 1 | 0 |
| debug/seaprobe | 1 | 0 | 1 | 0 |
| hwbringup/pdmapper | 1 | 1 | 1 | 0 |
| secure/ioncompat | 1 | 0 | 1 | 0 |
| secure/securemsm | 18 | 6 | 18 | 0 |
| secure/adsprpc | 1 | 0 | 1 | 0 |
| display | 5 | 3 | 4 | 0 (+ 1 dropped) |
| touch | 8 | 5 | 8 | 0 |
| power | 22 | 8 | 22 | 0 |
| audio | 32 | 19 | 32 | 0 |
| audio/samsung | 2 | 0 | 2 | 0 |
| gpu (kgsl) | 1 | 0 | 1 | 0 |
| video (msm_vidc) | 1 | 0 | 1 | 0 |
| conn/subsys_compat | 1 | 1 | 1 | 0 |
| conn/rild/drb | 1 | 1 | 1 | 0 |
| conn/data | 13 | 2 | 13 | 0 |
| conn/bt | 2 | 1 | 2 | 0 |
| conn/wlan | 6 | 5 | 6 | 0 |
| camera | 3 | 1 | 3 | 0 |

## Reproduce

    bsp618/port/build618.sh            # = port soc drivers report
    PORT_ARGS=--fresh bsp618/port/build618.sh   # wipe bsp618/src first

- `port618.py` regenerates `bsp618/src/` (git-ignored, ~2.8 GB with soc-repo-staging) from
  `bsp612/soc-repo`, `bsp612/techpacks`, `drivers612/` and `samsung612/modules/`. The 6.12
  sources are never edited. `src/` mirrors the repo root like `survey-src/`, so the copied
  build.sh files run unchanged (`bsp612/kernel` -> `ack/`, `bsp612/out` -> `out-survey/`,
  `donors` -> `donors/`). Steps: rsync, `port/patches/*.patch` (in order, `-p1` against
  `src/`), build-script fixups, the source rules, the -Werror relaxation, then
  `build-survey.sh stage` (ACK 6.18 drivers/ net/ + the ported soc-repo).
- `build618.sh` runs the survey's own `soc` and `drivers` steps (`build-survey.sh` and
  `survey-report.py`/`survey-symbols.py` now take `SURVEY_SRC`, `SURVEY_LOGS`,
  `SURVEY_RESULTS`; their defaults still reproduce the survey byte for byte) against the
  survey's kernel: `out-survey/gki` (vmlinux, Module.symvers) and `out-survey/lahaina`
  (module config). Nothing in `out-ack/` or the bsp612 outputs is touched. soc-repo builds at
  -j$(nproc), then -j1 over what failed (clean diagnostics in `out-port/logs/soc.log`).
- Results: `out-port/report.json`, `clusters.json`, `symbols.json`, `modules.md`, `dropped.json`
  (per-module table), `report.txt`, `port618.log` (rule counts, warnings, per-file edits).
- Wall time on this PC: about 1 min for port618.py (fresh), 2 min soc-repo, 2 min the rest.
- The mirror takes `drivers612/` as it is in the working tree, uncommitted files of other
  sessions included (they are only copied; no build step uses an unknown directory).

## What the port changes

### Source rules (`port618.py`, 6.18-only, no version guards; counts from the final run)

| rule | what | files | sites |
|---|---|---:|---:|
| `werror-relax` | `-Wno-error=missing-prototypes -Wno-error=missing-declarations` per kbuild makefile | 252 | 252 |
| `remove-new` | `.remove_new` -> `.remove`; int `.remove` callbacks that only `return 0` -> void | 102 | 103 |
| `timer-api` | `del_timer[_sync]` -> `timer_delete[_sync]`, `try_to_del_timer_sync` -> `timer_delete_sync_try`, `from_timer` -> `timer_container_of`; self-referencing compat aliases dropped | 43 | 132 |
| `hrtimer-setup` | `hrtimer_init` + `.function =` -> `hrtimer_setup(t, fn, clk, mode)` | 21 | 28 |
| `alarm-void` | alarm timer callbacks return void, `return ALARMTIMER_NORESTART` -> `return` | 4 | 7 |
| `ns-string` | `MODULE_IMPORT_NS(X)` / `EXPORT_SYMBOL_NS(s, X)` -> string literal | 52 | 56 |
| `ns-import` | add `MODULE_IMPORT_NS` for symbols the 6.18 GKI exports in a namespace (see notes) | 37 | 37 |
| `ida-simple` | `ida_simple_get` -> `ida_alloc_range/min/ida_alloc`, `ida_simple_remove` -> `ida_free` | 6 | 19 |
| `nth-page` | `nth_page(p, n)` -> `((p) + (n))` | 11 | 20 |
| `bin-attr-const` | sysfs bin_attribute read/write callbacks and `.bin_attrs` arrays const | 7 | 11 |
| `asoc-daifmt` | `SND_SOC_DAIFMT_CBM_CFM/CBS_CFS/...` -> `CBP_CFP/CBC_CFC/...` (same values) | 18 | 48 |
| `pinconf-level` | `PIN_CONFIG_OUTPUT` -> `PIN_CONFIG_LEVEL` | 5 | 19 |
| `gpio-set-int` | void `gpio_chip.set` callbacks -> int, `return 0` | 5 | 5 |
| `console-suspend` | `console_stop/start` -> `console_suspend/resume` | 1 | 1 |
| `sdhci-pltfm-free` | drop `sdhci_pltfm_free()` (pltfm host is devm in 6.18) | 1 | 2 |
| `blk-crypto-key` | `key->raw` -> `key->bytes`, `BLK_CRYPTO_KEY_TYPE_STANDARD` -> `_RAW` (files that use `blk_crypto_key`) | 5 | 11 |
| `dma-fence-ops` | `.fence_value_str`/`.timeline_value_str` initialisers dropped (callbacks kept `__maybe_unused`); `if (f->ops->fence_value_str)` call sites print `f->seqno` instead (what `dma_fence_describe()` shows), `timeline_value_str` call sites (fault dumps) go; `.use_64bit_seqno = true` -> `dma_fence_init64()` for that ops table; `__dma_fence_is_later(a, b, f->ops)` -> `(f, a, b)` | 14 | 34 |
| `cfs-h-nr-queued` | `cfs_rq.h_nr_running` -> `h_nr_queued`, `idle_h_nr_running` -> `h_nr_idle` (sched-walt) | 4 | 12 |
| `asoc-dpcm-dir` | `snd_soc_dai_link.dpcm_playback/.dpcm_capture` are gone: on a DPCM link a lone `dpcm_playback` -> `.playback_only = 1`, a lone `dpcm_capture` -> `.capture_only = 1`, both -> dropped; on non-DPCM links (no literal `.dynamic`/`.no_pcm`, ignored by 6.12) dropped with a warning | 13 | 1322 (dai_link blocks; lahaina.c 115 of them, 75 of those become `_only`; the other 12 files are machine drivers a52sxq does not build) |
| `dropped` | the `obj-` line of each `DROPPED` module is commented out (hwmon, qcom_smmu_v2_v3_dispatcher, lt9611uxc; remaining-modules pass: zram, zsmalloc, virtio_block, aquantia, snd-soc-hdmi-codec, msm_show_resume_irq, pci-msm-drv) | 10 | 10 |
| `upstream` | `UPSTREAM` soc-repo copies emptied except for ACK 6.18's Makefile, so staging keeps ACK 6.18's sources (drm_display_helper) | 1 | 1 |

Notes on the rules:
- `hrtimer_init(t, clk, mode)` + the `t->function = fn` assignment that follows in the same
  block become `hrtimer_setup(t, fn, clk, mode)`. Four timers set `->function` right before each
  `hrtimer_start()` instead (qcom-lpm x2, qcom-cluster-lpm, msm-pcm-afe-v2 where the callback
  depends on the stream direction): those keep their later assignments and are set up with the
  file's only callback for that timer, or `hrtimer_dummy_timeout` (listed in `port618.log`).
  `hrtimer.function` is `__private` in 6.18; the kept assignments still compile (sparse would
  flag them; `hrtimer_update_function()` is the clean form).
- `.remove` callbacks still returning int are turned void only when every `return` is `return 0`
  and no version-guarded void variant exists. Four audio codecs not in the a52sxq build (wcd9335,
  wcd934x, wcd9xxx-irq, msm_mdf) return error codes and are left alone (warning in the log).
- `ns-import` reads the 6.18 GKI `Module.symvers`: 252 symbols are exported in a namespace, and
  several were not on 6.12 (`dma_heap_add/get_drvdata/get_name` -> `DMA_BUF_HEAP`, `close_fd`
  -> `ANDROID_GKI_VFS_internal_...`, `MINIDUMP`, `PWM`, ...). A use without
  `MODULE_IMPORT_NS` is a modpost ERROR that `KBUILD_MODPOST_WARN` does not downgrade: it
  stops `Module.symvers` for the whole M= set (qcom_dma_heaps took the entire soc-repo set down
  the first time it compiled), and the loader would refuse the module. The rule adds the
  imports per .c file that calls such a symbol. **Correction to SURVEY.md** ("7 imported GKI
  symbols LOST their namespace on 6.18"): it is the other way round, 6.18 ADDED namespaces to
  them; the survey's .ko files linked only because those modules did not compile yet.
- `werror-relax` appends `ccflags-y += -Wno-error=missing-prototypes
  -Wno-error=missing-declarations` to every kbuild makefile that assigns `obj-*` (marked
  `bsp618/port:`). About 1000 distinct `-Wmissing-prototypes`/`-declarations` warning sites remain; making those functions
  static or declaring them in headers is the proper follow-up, not needed to build.

### Build-script fixups (`scripts`, 40 files)
clang-r547379 -> r596125, the absolute repo root -> `bsp618/src`, camera's
`$(srctree)/../soc-repo` -> `src/bsp612/soc-repo` (the survey's three hand edits).
`secure/securemsm/build.sh` (donor rsync + patch loop) and `conn/wlan/build.sh prepare`
(rebuild `work/` from donors) are neutralised in the copy: both trees are in git already, and
re-running them would overwrite the ported sources.

### Patches (`port/patches/`, applied to the 6.12 sources before the rules)

| patch | what | why |
|---|---|---|
| 0001 | soc-repo `ARM_PARAVIRT_SMMU_V3`: `select IOMMU_API` -> `depends on IOMMU_API` | Kconfig loop with 6.18 `VIDEO_QCOM_VENUS` (survey hand edit, now a patch). IOMMU_API=y in gki_defconfig, no value changes. |
| 0002 | **msm_drm `sde_rm.c`: uninitialised `pp_cfg`** | real bug: `_sde_rm_check_lm_and_get_connected_blks()` passed its never-set local by value; the callee overwrote its copy before use, so harmless in practice but UB. Now a local of `_sde_rm_reserve_pp()`. |
| 0003 | **qcom-hv-haptics `haptics_get_status_data()`: uninitialised `name`** | real bug: for an unlisted selector the tracepoint copied a wild string pointer. Falls back to `"UNKNOWN_STS"`. |
| 0004 | **sm5714-charger `_check_slow_rate_charging()`: uninitialised propval** | clang 22 `-Wuninitialized-const-pointer`; sec-battery ignores the value, zeroed. |
| 0005 | slimbus core: const `device_match_t` callbacks | same as upstream 6.18 |
| 0006 | seaprobe: `folio->flags.f` | `memdesc_flags_t` (our debug probe) |
| 0007 | qcom-pdc: probe takes the `platform_device` | 6.18 `platform_irq_probe_t`, as upstream |
| 0008 | spi-msm-geni: `SPI_CS_CNT_MAX` gone | `SPI_DEVICE_CS_CNT_MAX` for the `cs_index_mask` walk, `SPI_NUM_CHIPSELECT` (the 4 lines the SE has) for the range check |
| 0009 | pinctrl-msm: `gpiochip_line_is_valid()` | `gpio_chip.valid_mask` is gpiolib-private now (deep-sleep register save/restore loops) |
| 0010 | gic_intr_routing: `irq_get_nr_irqs()` | `nr_irqs` is no longer a variable |
| 0011 | qti-battery-charger: `psy_cfg.fwnode` | `power_supply_config.of_node` removed |
| 0012 | qcom dma heaps: drop `.get_pool_size` | ACK 6.18 removed the hook |
| 0013 | **ufs-qcom fork on the 6.18 UFS core** | trace enum header moved; core exports `ufshcd_dme_rmw()`; MCQ resource table moved out of `struct ufs_hba` (kept in `ufs_qcom_host`); `__msi_lock_descs()`; `ufs_stats.last_intr_*` gone; `UFS_DEVICE_QUIRK_DELAY_AFTER_LPM` gone -> `hba->vcc_off_delay_us = 5000`; `pwr_change_notify` negotiation split into `.negotiate_pwr_mode`; `.program_key` op gone (unused under CUSTOM_CRYPTO_PROFILE) |
| 0014 | **arm_smmu + qcom_iommu_util forks on the 6.18 IOMMU core** | `iommu_fwspec_free()` gone; `pgsize_bitmap` per domain at allocation (as upstream), the global ops bitmap goes; `enable_nesting` op gone; local `__iommu_alloc_pages()`/`__iommu_free_pages()` over `iommu_alloc_pages_node_sz()`/`iommu_free_pages()` |
| 0015 | **dwc3-msm: `dwc3_ep.regs` gone** | `DWC3_DEPCMD*(n)` are offsets from `dwc->regs`; same addresses |
| 0016 | usb_notify: `wakeup_source_add/remove` gone | `wakeup_source_register(NULL, "usb_notify")` |
| 0017 | **minidump: 6.18 names** | `cfs_rq.nr_queued`; `NR_BOUNCE`/`NR_WRITEBACK_TEMP` print 0 (as 6.18 meminfo); `page->flags.f`; ACK dropped `get_dmabuf_debugfs_data()` -> local walker over `dma_buf_iter_begin/next()` |
| 0018 | **sched-walt on the 6.18 scheduler and binder** | `pick_task(rq, rf)` + `RETRY_TASK` in the core_ctl drain loop; `android_vh_binder_restore_priority` lost its task argument (-> `current`); `binder_transaction.need_reply` gone (-> `!is_reply && !is_async`); `set_next_entity(..., bool first)`; **load-time guard** for the per-task vendor area (`android_arch_task_struct_size`). See the sched-walt section. |
| 0019 | qcom-cpufreq-hw: boost and sysfs attrs | `cpufreq_enable_boost_support()` gone -> `.set_boost = cpufreq_boost_set_sw`; the core makes `scaling_{available,boost}_frequencies` itself and no longer exports their `freq_attr`s -> no `.attr` table (as upstream) |
| 0020 | audio platform_dlkm: 6.18 compress API | `.pointer` fills `snd_compr_tstamp64`; `compress_new(rtd)` / `snd_soc_new_compress(rtd)` (device = `rtd->id`) |
| 0021 | **audio machine_dlkm: the removed ACK sound hook** | `android_vh_snd_pcm_check_no_buffer` gone: hostless FE links get a `.prepare` that sets the PLAYBACK `stop_threshold` to the boundary (same links, same effect on `snd_pcm_pre_start()`). See the audio/Wi-Fi/camera/video section. |
| 0022 | **wlan qcacld: cfg80211 ops take a wireless_dev** | wrappers for the key/station ops + `remain_on_channel(..., rx_addr)`; `cfg80211_new_sta/del_sta(wdev, ...)` |
| 0023 | camera: compat `struct gpio` | removed from `<linux/gpio.h>` in 6.18; defined again in `compat/cam_compat_612.h` (all 138 objects were blocked by it) |
| 0024 | msm-vidc: control ioctls, `v4l2_fh_add/del(fh, filp)` | `vidioc_g/s_ctrl`/`queryctrl` gone: ext-ctrl ops over vidc's own handlers; fh added/removed in the v4l2 open/close |
| 0030 | **msm_drm on the 6.18 DRM core** | bridge `.attach(bridge, encoder, flags)`; const `.mode_valid` mode; `drm_driver.date`; const `device_match_t`; `iommu_present()` -> `msm_iommu_present()`; `mipi_dsi_dcs_set_tear_off()` -> its body; `pfn_t`; `drm_get_format_info(dev, fmt, mod)` + `fb_create(..., info, ...)`; `drm_device.struct_mutex` -> driver mutex; `FB_EVENT_BLANK` kept for the Samsung notifier; **refcounted bridges** (`kref_init` + `msm_drm_first_bridge()`); DP `drm_dp_dpcd_read_link_status()` returns 0. See the display section. |
| 0040 | **rmnet_core: `rtnl_link_ops.newlink(dev, struct rtnl_newlink_params *, extack)`** | `src_net` = `rtnl_newlink_link_net(params)` (= 6.12's `link_net ? : net`, as upstream rmnet), `tb`/`data` from the params |
| 0041 | rmnet_shs: `softnet_data.dropped` gone | `numa_drop_add(&sd->drop_counters, 1)` (as `enqueue_to_backlog()`) |
| 0042 | rmnet_perf: TCP established lookups lost the hashinfo argument | netns hash table (`&tcp_hashinfo` in init_net) |
| 0043 | slim-qcom-ngd-ctrl: `platform_device.driver_override` gone | `device_set_driver_override()` (as upstream 6.18) |
| 0044 | snd-usb-audio-qmi: `iommu_domain_alloc(bus)` gone | `iommu_paging_domain_alloc(dev)`, `IS_ERR` |
| 0045 | ucsi_qti_glink: `sync_control(ucsi, cmd, cci, data, size)` | the op reads CCI and MESSAGE_IN itself now (6.12 `ucsi_run_command()` order) |
| 0046 | mem-offline: private `sections_per_block` vs the core's exported one | private copy renamed |

## Boot-path pass: fork or upstream, per target (2026-11-14, afternoon)

Method: for each fork, (a) which 6.12 modules import its symbols (`llvm-nm -u` over every 6.12
`.ko` in `bsp612/soc-repo-staging`, `drivers612/`, `samsung612/modules`, `bsp612/techpacks`,
matched against the 6.12 soc-repo `Module.symvers`), (b) which DT binding it serves: the 6.18
vendor boot is planned like the working 6.12 one, kexec'd with the **vendor** DT
(`bsp612/devicetree/qcom/yupik*.dtsi` + the a52sxq overlay), not the harness's mainline DT, and
(c) what upstream 6.18 would need instead. The harness boots upstream drivers only because it
also runs the mainline DT and upstream clock/PHY/SMMU drivers built in.

| target | decision | why (evidence) | changed | remains |
|---|---|---|---|---|
| `ufs-qcom` | **keep fork** | Vendor DT `ufsphy_mem` is `qcom,ufs-phy-qmp-v4-yupik`; its PHY driver (soc-repo `phy-qcom-ufs*`) applies per-UFS-vendor tables keyed by `ufs_qcom_phy_set_device_id()` and gets lane-enable / RX line-config / hibern8 clock-source calls (`ufs_qcom_phy_*`, 9 symbols) that only the fork makes. Upstream ufs-qcom would drive it through generic phy ops only (vendor-specific table entries silently skipped), or would need the upstream QMP PHY + new DT nodes. Nothing in the vendor stack imports ufs-qcom. | patch 0013 (8 API classes, below) | needs `sched-walt` at load (`sched_set_boost`, `walt_{,un}set_enforce_high_irq_cpus`): **resolved** by the sched-walt pass (walt ported, `CONFIG_SCHED_WALT=m` kept). |
| `ufshcd-crypto-qti` | keep fork | only `ufs-qcom` imports it; with `SCSI_UFS_CRYPTO_QTI=m` the fork sets `UFSHCD_QUIRK_CUSTOM_CRYPTO_PROFILE` and this module owns the keyslots (the core's `program_key` op is gone in 6.18, so without it there is no ICE path at all) | rule `blk-crypto-key` | see the FBE finding below |
| `qcom_ice` | keep fork | `ufs-qcom`, `ufshcd-crypto-qti`, `sdhci-msm` (builds on 6.18 already) and `cqhci` import its **vendor** API (`of_qcom_ice_get`, 7-arg `qcom_ice_program_key`, `qcom_ice_program_key_hwkm`). Upstream 6.18 `ice.c` has a different API and calls `qcom_scm_has_wrapped_key_support`/`generate/prepare/import_ice_key` and a pointer-based `qcom_scm_derive_sw_secret`, none of which the soc-repo `qcom-scm` exports. The vendor DT uses the legacy `ice` reg range in the UFS node + `qcom,ice-use-hwkm`. | rule `blk-crypto-key` (`key->raw` -> `key->bytes`, 1 site) | - |
| `cqhci` | keep fork (not dropped) | eMMC/SD command queueing, but `sdhci-msm` (SD card, built) links `cqhci_init/irq/deactivate/pltfm_init`, so it has to exist for `sdhci-msm` to load | rule `blk-crypto-key` | - |
| `arm_smmu` | **keep fork** | Vendor DT SMMUs are `qcom,qsmmu-v500` (+ `qcom,adreno-smmu` for the GPU one): upstream arm-smmu does not match `qcom,qsmmu-v500`. The fork registers the `qcom_iommu_ops` behind every `qcom_iommu_util` API. 16 nodes set `qcom,iommu-dma` (5 fastmap, 7 atomic, 3 bypass, 1 disabled), handled by the fork + `qcom_iommu_util`. | patch 0014 | runtime only |
| `qcom_iommu_util` | **keep fork** | imported by `msm_kgsl` (9 symbols: `qcom_alloc_io_pgtable_ops`, `qcom_arm_lpae_map_sg/unmap_pages`, `qcom_iommu_get_asid_nr/context_bank_nr`, `set_fault_model`, `set_secure_vmid`, `qcom_skip_tlb_management`, ...), `msm_drm` (`qcom_iommu_sid_switch`, `enable_s1_translation`), `camera` (`get_fault_ids`), `coresight-tmc`/`ipam` (`get_mappings_configuration`), `qcom_iommu_debug`, and `arm_smmu` itself (fastmap, io-pgtable alloc). Upstream has no equivalent (drm/msm's `adreno_smmu_priv` is a different interface). | patch 0014 | runtime only |
| `qcom_smmu_v2_v3_dispatcher` | **dropped** | pKVM nested SMMU (`kvm/iommu.h`); this phone runs Gunyah; never loaded on 6.12 | `DROPPED` in port618.py | - |
| `dwc3-msm` | **keep fork** | Vendor DT `usb0` is `qcom,dwc-usb3-msm` with a `snps,dwc3` child and legacy `usb-phy` phandles to the vendor HS/QMP PHY drivers; GKI 6.18's built-in `USB_DWC3_QCOM` matches `qcom,snps-dwc3` with generic PHYs. Imported by `usb_f_gsi`, `usb_f_qdss` (`msm_ep_*`, `usb_gsi_ep_op`), `msm_drm` (`dwc3_msm_set_dp_mode`), `snd-usb-audio-qmi` (`dwc3_msm_get_qsram`). The UDC name (`a600000.dwc3`, ROM `GADGET_NAME`) is the same either way. Builds on the GKI's built-in dwc3 core; no unresolved symbol. | patch 0015 (`dwc3_ep.regs` gone: `DWC3_DEPCMD*(n)` from `dwc->regs`, same addresses) | runtime only |
| `hwmon` | **dropped** | GKI 6.18 has `HWMON=y` (6.12 GKI had it off, hence the soc-repo module); a module copy would clash with the built-in class. Its users `sec_thermistor` and `qti_amoled_ecm` resolve `devm_hwmon_device_register_with_groups` from vmlinux. | `DROPPED` | - |
| `usb_notify_layer` | port | Samsung code, no upstream equivalent | patch 0016 (`wakeup_source_register()`) | - |
| `msm_kgsl` | port | Adreno blob driver | rule `dma-fence-ops` (also used by msm_drm's `sde_fence`, the rotator, the techpacks copy) | - |
| `minidump` (added) | port | not in the target list, but a load dependency of boot-path modules: `ufs-qcom`, `qcom_ipc_logging`, `qcom_wdt_core`, `qcom-dload-mode`, `qcom_logbuf_*`, `memory_dump_v2`, `dcc_v2`, `qcom_va_minidump`, `frpc-adsprpc` | patch 0017 | - |

**FBE finding (needs an owner decision, not a build fix):** `ufshcd-crypto-qti` advertises
`key_types_supported = BLK_CRYPTO_KEY_TYPE_HW_WRAPPED` only, but the ROM's fstab
(`device/samsung/sm7325-common/init/fstab.qcom:50`) uses raw keys
(`fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized`, no `wrappedkey_v0`, no
metadata encryption). By the code, `/data` on the 6.12 vendor stack is therefore encrypted by
`blk-crypto-fallback` (software AES on the CPU), not by ICE, and the 6.18 port keeps that.
Check on the 6.12 boot: `ls /sys/block/sda/queue/crypto/` (and its `raw_keys` /
`hw_wrapped_keys` files where present; not run: no phone in this pass). Choices: leave it (works, CPU cost on I/O);
switch the ROM to `wrappedkey_v0` (HWKM path in the vendor ICE; changes key storage, needs a
data wipe and TZ support); or give the fork a raw-key profile (upstream ufs-qcom's
`ufs_qcom_ice_*` keyslot ops) so raw keys reach ICE.

## sched-walt pass (2026-11-14, evening)

Decision (owner): **port** `sched-walt` (soc-repo `kernel/sched/walt`) rather than build the
6.18 module set without `CONFIG_SCHED_WALT`: `ufs-qcom` (storage boost), `msm_performance`,
`thermal_pause`, `bwmon` and `qcom_lpm` import it, and 6.12 runs with it.

**Compile level, the whole fix:** 18 errors at `-ferror-limit=0` in 5 of 24 objects, five
causes:

| what | 6.18 | fix |
|---|---|---|
| `cfs_rq.h_nr_running` (12 sites, also `trace.h`) | `h_nr_queued` (v6.14 rename; on android16-6.12 both names were one KMI union, so the count is identical, delayed-dequeue entities included) | new rule `cfs-h-nr-queued` (also maps `idle_h_nr_running` -> `h_nr_idle`) |
| `pick_task(rq)` in the core_ctl CPU drain loop (`walt_halt.c` `migrate_tasks`) | `pick_task(rq, rf)`, may return `RETRY_TASK` (only sched_ext's balance does) | pass `rf`, pick again on `RETRY_TASK` (patch 0018) |
| `android_vh_binder_restore_priority(t, task)` | `(t)` | hook uses `current`: both remaining 6.18 call sites are the 6.12 ones that passed `current`; the third 6.12 call (NULL transaction) became `android_vh_binder_before_restore_priority`, and the hook did nothing for NULL (0018) |
| `binder_transaction.need_reply` | gone | `!t->is_reply && !t->is_async`: 6.12 set `need_reply` for exactly the synchronous non-reply transactions (0018) |
| `extern set_next_entity(cfs_rq, se)` | `(cfs_rq, se, bool first)` | prototype fixed; WALT never calls it (0018) |

Modpost: `sched-walt.ko` has 310 imports, **all resolve** (309 from the 6.18 GKI vmlinux, incl. `ksize` for the guard; 1
`socinfo_get_id_string` from soc-repo). Every vmlinux one is in the union of the ACK 6.18 KMI
symbol lists (`ack/gki/aarch64/symbols/*`) except `__stack_chk_guard`, so a real Kleaf GKI
built with those lists exports them too. Its own exports (`sched_set_boost`,
`walt_{,un}set_enforce_high_irq_cpus`, `walt_pause_cpus`/`walt_resume_cpus`,
`core_ctl_notifier_{,un}register`, `should_boost_bus_dcvs`, `sched_lpm_disallowed_time`) now
resolve for ufs-qcom, thermal_pause, msm_performance, bwmon and qcom_lpm.

Also ported, because WALT needs it at run time: **`qcom-cpufreq-hw`** (soc-repo fork, patch
0019: `policy_has_boost_freq()`/`cpufreq_enable_boost_support()` are gone; the driver gets
`.set_boost = cpufreq_boost_set_sw` as upstream has). `walt_init()` requires a cpufreq policy
on every CPU (`WALT_PANIC(!policy)`) and is triggered only once all of them exist; the 6.18 GKI
does not build `ARM_QCOM_CPUFREQ_HW`, and the fork is the driver the 6.12 boot uses with the
vendor DT (`qcom,cpufreq-epss`).

### Vendor-hook audit (every hook WALT registers)

Method: `register_trace_android_{vh,rvh}_*` in all WALT sources (58 hooks; 51 in
`sched-walt.ko`, the other 7 only in the debug/stats objects that the lahaina config does not
build: `preemptirq_long.c` 4, `walt_debug.c` 1, `sysctl_walt_stats.c` cpu_idle_enter/exit),
checked against `ack/include/trace/hooks/*` (declaration; the prototype is type-checked by the
`register_trace_*` call, so a compiling module proves it) and against every
`trace_android_*()` call site in `ack/` vs `bsp612/kernel/` (is it still called, and from the
same place; the call-site contexts were diffed).

- **All 58 are declared and still called in ACK 6.18.** None vanished; no replacement needed.
  Changed prototype: only `android_vh_binder_restore_priority` (above).
- Call sites moved but same meaning: `android_rvh_cpu_capacity_show` (`drivers/base/topology.c`
  now), `android_vh_update_topology_flags_workfn` (still fired from
  `update_topology_flags_workfn()` after the `CPUFREQ_CREATE_POLICY` notifier has seen every
  CPU: the WALT init trigger is unchanged), `android_vh_scx_ops_enable_state` (enum
  `scx_enable_state` renamed, values unchanged: WALT tests 1 = ENABLED, 2 = DISABLING).
- Changed context, checked: `android_rvh_update_misfit_status` (6.18 no longer zeroes
  `misfit_task_load` before the hook; WALT's handler sets it on every path, and
  `rq->misfit_reason` is gone but unused by WALT), `android_rvh_replace_next_task_fair` (6.18
  passes `prev = rq->donor`, re-read after a lock drop), `android_rvh_check_preempt_wakeup_fair`
  (preempt/ignore outputs honoured the same way; the EEVDF logic after it changed upstream).
- The three plain tracepoints (`sched_switch`, `sched_overutilized_tp`,
  `cpu_frequency_limits`) are type-checked the same way.
- Structs read directly (`struct rq`, `cfs_rq`, `sched_entity`, `task_group`, `root_domain`,
  `binder_transaction`, `mutex_waiter`): WALT includes ACK 6.18's own `kernel/sched/sched.h`,
  `kernel/locking/mutex.h`, `drivers/android/binder_internal.h` (soc-repo-staging carries ACK
  6.18 `drivers/`), so offsets follow the kernel it is built for. The only `extern` prototype
  of a kernel function WALT declares itself is `set_next_entity` (fixed); `__migrate_task` and
  `rebuild_sched_domains` are also declared by 6.18 headers, so the compiler checks them.
  `__migrate_task()` is byte-identical to 6.12. `task_group` vendor data: compile-time checked
  by WALT's own `WALT_VENDOR_DATA_SIZE_TEST`.

### Per-task data contract and the required boot argument

- 6.18 ACK keeps the 6.12 mechanism unchanged: `CONFIG_GKI_DYNAMIC_TASK_STRUCT_SIZE=y`,
  `CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1280`, early param `android_arch_task_struct_size=<n>`
  (0..1280, set before `setup_arch()`), `android_task_vendor_data(p) = p + 1` (init_task:
  `vendor_data_pad`), the vendor area is zeroed in `dup_task_struct()` before
  `android_vh_dup_task_struct`.
- Sizes (pahole): 6.18 `task_struct` **4736** bytes (6.12: 5184), `walt_task_struct` **456**
  (same as 6.12). `hung_task_enh`, `cpu_mpam` and `minidump_log` read the same
  `walt_task_struct`, so one area serves all.
- **Required boot argument on 6.18: `android_arch_task_struct_size=512`** (expected
  `task_struct` slab objsize 5248 = 4736 + 512). As on 6.12 it must be on the kernel command
  line itself: kexec replaces `/chosen/bootargs`, and the Samsung ABL is not known to keep DT
  bootargs (bsp612/CPUFREQ-ANALYSIS.md).
- **New guard (patch 0018):** at load `sched-walt` compares `ksize(current)` with
  `sizeof(task_struct) + sizeof(walt_task_struct)`. Without the area it prints
  `sched-walt: task_struct objects are N bytes, WALT needs M ...: boot with
  android_arch_task_struct_size=512; WALT stays disabled` and returns 0 without registering a
  hook or scheduling `walt_init()`, i.e. the state the 6.12 boot was in before cpufreq came up
  (importers load; their WALT calls see `walt_disabled`). The ab-s60..s62 corruption can no
  longer happen silently.
- **Recommended boot argument: `sched_proxy_exec=0`.** ACK 6.18 turns proxy execution ON by
  default (`DEFINE_STATIC_KEY_TRUE(__sched_proxy_exec)`); ACK 6.12 had it OFF and nothing in our
  6.12 boot enabled it, so WALT's proxy paths (`task_is_blocked()`, proxy-migration accounting
  in `walt.c` `migrate_busy_time_subtraction()`, `walt_lb`/`walt_storage_lb` donor checks) never ran on this
  phone. 6.18 also changed `task_is_blocked()` (6.12: `blocked_on && blocked_on_state !=
  BO_RUNNABLE`; 6.18: `blocked_on.lock != NULL`). With `sched_proxy_exec=0` it returns false
  and WALT runs as tested on 6.12.
- Keep the rest of the 6.12 Qualcomm set (`android-cmdline.txt`): `rcu_nocbs=0-7`,
  `sysctl.kernel.sched_pelt_multiplier=4` (still an ACK 6.18 sysctl), `irqaffinity=0-1`, etc.

### WALT features: verified by build vs at risk at run time

Verified by build (compile + modpost + hook prototypes): all of `sched-walt.ko`'s objects
(window-based load tracking, cpufreq_walt governor, core_ctl and CPU halt/pause, walt_lb
(newidle/nohz balance, busiest-queue), walt_rt, walt_cfs (task placement, MVP queues, binder
boost), input boost, sched boost, pipeline, smart_freq, storage boost, cycle-counter drivers,
sysctls), and the imports of the five dependent modules.

At risk at run time (not testable offline):
1. **Boot args missing** -> WALT inert (guard) or, with proxy exec on, untested paths (above).
2. **core_ctl CPU drain** (`walt_halt.c` `migrate_tasks`, a copy of the old hotplug drain
   loop): 6.18 `pick_task()` walks the new `ext_server`/`fair_server` dl servers and may drop the
   rq lock in a class balance; `RETRY_TASK` now loops. Watch the first core_ctl pause/unpause
   (halting CPUs 4-7 under low load) for WARNs or a stuck stopper.
3. **Binder boost** (`TASK_BOOST_STRICT_MAX` hand-over through
   `binder_transaction.android_vendor_data1`): mapping of `need_reply` and the new hook
   argument is reasoned from binder.c, not observed.
4. **EEVDF changes 6.12 -> 6.18** around WALT's fair-class hooks (slice protection, delayed
   dequeue, `PREEMPT_WAKEUP_*`): WALT's MVP preemption and `replace_next_task_fair` sit on top
   of changed upstream code; a mis-pick would show as `WALT_BUG` (`REPLACE_NEXT_TASK_FAIR`
   sanity check) or scheduling latency.
5. **sched_ext**: enabling a BPF scheduler puts WALT in `walt_quiet_state` (unchanged logic);
   not expected on Android.
6. **cpufreq**: WALT initialises only when `qcom-cpufreq-hw` (fork, now built) has created all
   three policies; the boost change (0019) only affects the `boost` sysfs knob.
7. GKI/KMI caveat as everywhere here: built against the survey's plain-make vmlinux, not a Kleaf
   GKI image.

## Display pass (2026-11-14, afternoon)

Target: the androidboot display stage, `drivers612/androidboot/out/stage-display/load.list`
(19 modules: the stage that gave the boot animation on 6.12, msm_drm loaded with
`dsi_display0=ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD: lcd_id=80000A`). **All 19 build on 6.18**;
two had failed (`drm_display_helper`, `msm_drm`), the other 17 already built in earlier passes.
Every stage module's `depends` is satisfied inside the 6.18 tree; `msm_drm`'s depends list (17
modules) is the same as on 6.12. Strict modpost (no `KBUILD_MODPOST_WARN`) and clang
`-ferror-limit=0` on the whole techpack: nothing unresolved, nothing hidden.

| module | result | how |
|---|---|---|
| `msm_drm` (134 objects: SDE, DSI, DP, `sde_rsc`, Samsung `ss_dsi_panel_*`, `S6E3FC3_AMS646YD01`) | built, modpost-clean | patch 0030 (16 .c files + `msm_drv.h`, none under `msm/samsung`) |
| `drm_display_helper` | built, 0 unresolved, no depends | soc-repo copy replaced by ACK 6.18's `drivers/gpu/drm/display` (`UPSTREAM` in port618.py) |
| `msm_ext_display`, `lcd`, `sec_panel_notifier_v2`, `panel_event_notifier`, `qfprom-sys`, the glink/pdr/pmic-glink/altmode/fsa4480 deps, `refgen`, `qcom_va_minidump` | built (unchanged) | - |
| `lt9611uxc` (not in the stage) | **dropped** | Lontium DSI-to-HDMI bridge of Qualcomm reference boards; no such chip or DT node on the A52s, never loaded on 6.12 |

KMI (as for sched-walt): vmlinux imports `msm_drm` 641, `drm_display_helper` 140, `lcd` 22,
`msm_ext_display` 19, `sec_panel_notifier_v2` 4; all are in the union of the ACK 6.18 symbol
lists (`ack/gki/aarch64/symbols/*`) except `__stack_chk_guard`.

### drm_display_helper: replaced by GKI 6.18's, not re-forked (evidence)

- **The soc-repo copy is not a fork.** Against ACK 6.12's own `drivers/gpu/drm/display`, 9 of
  its 14 source files are identical; the 5 that differ (`drm_dp_helper.c` 59 lines,
  `drm_dp_mst_topology.c` 170, `drm_dp_cec.c` 14, `drm_dp_tunnel.c` 10,
  `drm_dp_dual_mode_helper.c` 4) differ only by **lacking later upstream changes**
  (`drm_dp_dump_lttpr_desc()`, `drm_dp_mst_topology_queue_probe()`, `guid_gen()`, the
  `msg_len < 1` sideband check, the RAD unpack fix, `reset_rx_state`): an older snapshot of
  upstream. No Qualcomm code; the Makefile only regroups the same objects. Re-forking it
  against 6.18 would just freeze another copy.
- **No clash with the GKI:** the 6.18 GKI does not build `DRM_DISPLAY_HELPER` (absent from
  `out-survey/gki/.config`; no `drm_display_helper.ko` among the GKI modules), so the vendor
  side has to ship it, as on 6.12. Same module name and place in soc-repo-staging, so load
  lists are unchanged.
- **What it provides:** built with the lahaina config: DP helpers, bridge connector, HDMI
  (audio, CEC, CEC notifier, state, SCDC) helpers. Unlike 6.12 it has no DSC and HDCP helpers:
  6.18 builds `drm_dsc_helper.o` only under `DRM_DISPLAY_DSC_HELPER` (6.12: under DP_HELPER),
  and nothing selects that or `DRM_DISPLAY_HDCP_HELPER` (=y on 6.12). No module of either tree
  imports `drm_dsc_*`/`drm_hdcp_*` (checked with llvm-nm over the 6.12 msm_drm.ko and every
  6.18 .ko; msm_drm has its own `sde_dsc_helper`/`sde_hdcp_*`), so nothing is lost. The report
  lists `drm_hdcp_helper.o` as "missing" only because the 6.12 build's `.mod` file has it.
  CEC/HDMI imports resolve from vmlinux.
- **What msm_drm uses of it:** 33 exports, all DP/MST (`drm_dp_aux_register`,
  `drm_dp_dpcd_*`, link training helpers, the MST topology manager and payload helpers). The 33
  function bodies were diffed 6.12 vs 6.18: one changed its contract,
  `drm_dp_dpcd_read_link_status()` (returns 0 instead of the byte count 6; fixed in msm_drm's
  dp_ctrl/dp_link, patch 0030); `drm_dp_dpcd_read/write` probe a different register
  (`DP_TRAINING_PATTERN_SET`) and only when needed; `set_mst`/`check_act_status` are internal
  refactors with the same results. The DSI panel path does not use the helper at all.

### DRM core changes 6.12 -> 6.18 that msm_drm hit (patch 0030)

| change | msm_drm sites | fix |
|---|---|---|
| `drm_bridge_funcs.attach(bridge, encoder, flags)` | dsi, dp, dp_mst bridges | extra argument (unused) |
| **bridges are refcounted**: `drm_bridge_attach()` takes a reference, `drm_bridge_chain_get_first_bridge()` returns one | 3 kzalloc'd bridges, 9 getter calls | `kref_init()` before attach (a kzalloc'd refcount of 0 would WARN "addition on 0; use-after-free" at the first attach and saturate); `msm_drm_first_bridge()` drops the getter's reference at once. msm_drm keeps owning and kfree-ing the memory; the core never sees 0. |
| connector helper `.mode_valid` takes a const mode | `sde_connector` | const hook; cast for the `c_conn->ops.mode_valid` chain (dsi/dp/Samsung callees unchanged; modes are probed_modes entries) |
| `drm_device.struct_mutex` gone | 7 places in 5 files (GEM frees in reg-dma/DSI ctrl/DSI display, the MADVISE ioctl and its WARN, postclose) | one driver mutex `msm_drm_struct_mutex` (one msm_drm device) |
| `mode_config_funcs.fb_create(..., const drm_format_info *, ...)`, `drm_get_format_info(dev, fmt, mod)`, `drm_helper_mode_fill_fb_struct(dev, fb, info, cmd)` | msm_fb, WB encoder | pass format + modifier[0] / the core's info |
| `drm_driver.date` gone | msm_drv | dropped |
| `device_match_t` const data | `compare_name_mdp` (MDP5 path) | const |
| `iommu_present()` gone | 4 (VRAM carveout, address space, prime import, GEM new) | `msm_iommu_present()` = `IS_ENABLED(CONFIG_IOMMU_API)`: the SMMU is a load dependency and the SDE context banks are components of the display device, so the old call was always true when msm_drm bound |
| `mipi_dsi_dcs_set_tear_off()` gone | POMS TE work | its body: `mipi_dsi_dcs_write(dsi, MIPI_DCS_SET_TEAR_OFF, NULL, 0)` |
| `linux/pfn_t.h` gone | GEM fault | `vmf_insert_mixed(vma, addr, pfn)` (6.12 passed PFN_DEV without PFN_MAP: same special PTE) |
| `FB_EVENT_BLANK` left `<linux/fb.h>` | Samsung suspend/resume notifier (`msm_drm_register_notifier_client`, exported) | old value 0x09 kept locally; no in-tree listener |
| DP: `drm_dp_dpcd_read_link_status()` returns 0 | dp_ctrl, dp_link | test `< 0` (else every read "fails" and the ACT wait bails) |

Checked, no change needed: dma-fence (`sde_fence`, rotator: the `dma-fence-ops` rule, two
`timeline_value_str` debug prints dropped), DSI/MIPI (msm_drm drives its own DSI host; the
panel's `mipi_dsi_dcs_write` path is unchanged), legacy bridge hooks
(`.pre_enable/.enable/.disable/.post_disable` are still called by the 6.18
`drm_atomic_bridge_chain_*`), fbdev (`msm_fbdev_*` stubbed as on 6.12; `lcd_class` builds),
drm_edid/drm_dsc (DP-only / header types, compile-checked). The techpack's own Kbuild has
`-Wno-int-conversion -Wno-format`: a build with both re-enabled shows only 168 printf-format
diagnostics in debug prints, no int-conversion, i.e. no 6.18 change hides behind them.

**UBWC r7 fix and Samsung panel:** the UBWC fix is device tree
(`drivers612/display/dts/yupik-sde.dtsi`, `qcom,sde-ubwc-version = <0x30000000>`), not part of
the module port; the catalog parser and the SSPP UBWC programming it feeds are not touched by
any rule or patch. No file under `msm/samsung` (mDNIe, ACL, gamma, VRR, panel commands) and no
panel config header is changed; the insmod arguments stay the same.

### At risk at run time (not testable offline)

1. **Bridge refcounting** is new in 6.18. Watch the first mode-set for `refcount_t` WARNs and
   the unbind path (`drm_encoder_cleanup()` detaches the bridges before msm_drm frees them).
2. 6.18 DRM core behaviour that compiles the same (atomic helpers, vblank, connector probing,
   client setup) was not audited line by line; msm_drm runs its own commit path
   (`msm_atomic.c`) on a small set of core helpers. First 6.18 load: mode-set,
   `kmsfill`, 60/120 Hz VRR switch, brightness, doze/AOD, TE, then the composer with UBWC on
   (the 2026-11-13 colour check).
3. `msm_iommu_present()` is constant: if the SDE SMMU banks are missing, msm_drm fails at
   address-space setup instead of falling back to a VRAM carveout (not usable on this phone
   on 6.12 either).
4. The new `drm_display_helper` matters only for DP, which the A52s does not use.
5. Same GKI/KMI caveat as everywhere: plain-make vmlinux, not a Kleaf GKI.

Reproduce: `python3 bsp618/port/port618.py && bsp618/port/build618.sh soc`, then
`cd bsp618/src/drivers612/display && KEEP=1 ./build.sh` (strict modpost). The full
`build618.sh soc drivers report` at 14:30 together with the audio/wlan/camera/video pass
(patches 0020-0024) in the tree: 376 built, 2 compiled, 14 failed,
3 dropped.

## Audio / Wi-Fi / camera / video pass (2026-11-14, evening)

Scope: the androidboot stage lists `audio` (34 .ko), `dsp` (19), `i2c`, `wlanb` (9), `wlan`,
`camera` (36) and `msm-vidc`. Result: every .ko those lists name exists in the 6.18 port build
(`cfg80211.ko` = soc-repo-staging's build of ACK 6.18 `net/wireless`, same object list as
ACK's Makefile; `rfkill.ko` from the GKI; `qcom_pd_mapper_a52.ko` is `hwbringup/pdmapper`'s
`qcom_pd_mapper.ko` renamed by the packer). None of their .ko has an unresolved import
(`symbols.json`; for Wi-Fi also `conn/wlan/build.sh check`: "unresolved: none" for all six).
Measured on the shared tree in one `build618.sh` run together with the display pass
(376/395 built; the display work is its own patch 0030 / section).

| module | 6.12 -> 6.18 change | fix |
|---|---|---|
| `machine_dlkm` (lahaina.c) | `<trace/hooks/sound.h>` and `android_vh_snd_pcm_check_no_buffer` are gone from ACK 6.18 | patch 0021: the hostless FE links (VoiceMMode1/2, LSM1-7, "Secondary MI2S_TX Hostless Capture", same test as the 6.12 hook handler) get a dai_link `.prepare` that sets the PLAYBACK `stop_threshold` to the boundary, so `snd_pcm_pre_start()` accepts the empty host buffer as the hook made it do |
| `machine_dlkm` | `snd_soc_dai_link.dpcm_playback/dpcm_capture` removed (v6.14) | rule `asoc-dpcm-dir` (115 links in lahaina.c, 75 become `_only`): on DPCM links (`.dynamic`/`.no_pcm`) a lone `dpcm_playback` -> `.playback_only = 1`, a lone `dpcm_capture` -> `.capture_only = 1`, both -> nothing (6.12 `soc_get_playback_capture()` semantics; 6.18 takes the directions from the CPU DAI exactly as 6.12 did for DPCM links). The three AFE-proxy links without `.dynamic`/`.no_pcm` just lose the flags (6.12 ignored them there) |
| `platform_dlkm` | compress `.pointer` fills `snd_compr_tstamp64`; `compress_new(rtd)` / `snd_soc_new_compress(rtd)` lost the device number (rtd->id) | patch 0020 |
| `wlan` (qcacld) | cfg80211 key/station ops take `struct wireless_dev` (add/get/del_key, set_default_mgmt/beacon_key, add/del/change/get/dump_station), `remain_on_channel` gets `rx_addr`, `cfg80211_new_sta()/del_sta()` take the wdev | patch 0022: wrappers in front of the ops table hand the unchanged handlers `wdev->netdev` (-EOPNOTSUPP without one); radio_idx/tx-power/antenna changes were already covered by qcacld's own version checks |
| `camera` | legacy `struct gpio` removed from `<linux/gpio.h>` (blocked all 138 objects) | patch 0023: `compat/cam_compat_612.h` defines it again (6.12 layout, `LINUX_VERSION_CODE >= 6.17` guard). There was no second layer: all 138 objects compile, only `-Wmissing-prototypes` warnings (202). The 6.12 CPAS fix (`of_get_child_by_name` for `qcom,axi-port-mnoc`/`camnoc`) is in the work tree and kept |
| `msm-vidc` | `vidioc_g_ctrl/s_ctrl/queryctrl` gone from `v4l2_ioctl_ops`; `v4l2_fh_add/del(fh, filp)` | patch 0024: ext-ctrl ops that call vidc's own g/s/query handlers per control; `v4l2_fh_add()` moved into `msm_v4l2_open()`, `v4l2_fh_del()` into `msm_v4l2_close()` |

Not covered by this pass (not in the survey's module set at all, so never built against 6.18):
the stage lists `fingerprint` (drivers612/fingerprint), `nfc` (drivers612/nfc) and `vibrator`
(drivers612/vibrator). (Since 15:10 they are: `build-survey.sh extra`, all build without a
source change; see "Android on 6.18".) `hwmon.ko` of `power`/`powerpd` is dropped on purpose (GKI built-in).
`mac80211.ko` still lacks the 6.18 NAN object (7 unresolved `ieee80211_nan_*`); qcacld is a
fullmac driver and the 6.12 boot does not load mac80211.

### Run-time risks (compile and modpost only; nothing loaded)

1. **Voice-call start** (hostless FE): the `stop_threshold` override is set in `.prepare`. If
   the closed audio HAL issues `SNDRV_PCM_IOCTL_SW_PARAMS` again after PREPARE, it is undone
   and START of the VoiceMMode playback FE fails with -EPIPE (6.12 hook: never). It also
   means the core never reports an xrun on those streams (wanted: nothing is written to
   them). Check on the first 6.18 call or loopback: `pcm_start` errors in the HAL log.
2. **PCM directions**: compare `/proc/asound/pcm` on 6.18 with 6.12 (53 PCMs, same
   playback/capture split); a link that 6.12 turned into a one-direction DPCM link through an
   unusual flag combination would show up there.
3. **ASoC core 6.12 -> 6.18 behaviour** that does not show at compile time (DPCM trigger
   ordering, BE hw_params fixups, the new `soc-dapm` locking): untested; mixer control names
   are unchanged (frozen ABI for the Samsung HAL).
4. **Compress offload**: legacy `SNDRV_COMPRESS_TSTAMP` truncates the now 64-bit counters to
   32 bit, which is what 6.12 returned anyway; `SNDRV_COMPRESS_TSTAMP64` is new. Compress
   device numbers = `rtd->id` = the 6.12 `num`.
5. **Wi-Fi**: the wrappers assume every wdev that reaches a key/station op has a netdev (true
   for STA/SAP/P2P-GO/client; nl80211 6.18 may now route wdev-only calls, which get
   -EOPNOTSUPP). qcacld's existing `LINUX_VERSION_CODE` branches for other 6.1x changes were
   picked by thresholds written for other kernels: compile-checked, not run. The firmware
   rule stands: only the phone's own WPSS image (rollback incident 2026-11-13).
6. **Camera**: the source is the same as on 6.12 (where it works); risks are 6.18 media /
   V4L2 core changes underneath (subdev, media request API) and the `camcc` clock WARN seen on
   6.12.
7. **Video**: `VIDIOC_QUERYCTRL` now returns the control's real `type`/`name` (6.12 echoed the
   caller's input) and `VIDIOC_{G,S}_EXT_CTRLS`/`VIDIOC_QUERY_EXT_CTRL` answer instead of
   -ENOTTY; a HAL that probes them may take a different path than on 6.12.

## Remaining-modules pass (2026-11-14, 19:30): nothing fails any more

Before: 14 failed (+ 2 "compiled, no .ko"). Priority = what a real phone uses, checked against
the 6.12 real-boot first stage (`drivers612/realboot/out/rb1/work/plan/first.load`), the 6.12
Android stage lists (`drivers612/androidboot/out/stage-*/load.list`), the 6.12 modem stage
(`drivers612/modem/out/stage-modem/load.list`), the 5.4 phone (`research/blob-uapi-evidence/
lsmod.txt`, `vendor_modules.txt`, `sys_module.txt`; 5.4 `lineage-a52sxq_defconfig`) and the
nodes of the 6.18 Android tree (`android/out/android-r02-618.dtb`). "6.12" = loaded by a 6.12
boot, "5.4" = loaded/built in on the phone's 5.4 kernel.

| module | 6.12 | 5.4 | DT node | result | how / why |
|---|:-:|:-:|---|---|---|
| `rmnet_core` | modem stage | ✔ | - | **built** | patch 0040 (`newlink(dev, params, extack)`); its 7 exports now resolve `rmnet_offload` (modem stage), `rmnet_aps`, `rmnet_perf_tether`, `rmnet_wlan` |
| `rmnet_shs` | modem stage | ✔ | - | **built** | patch 0041 (`softnet_data.drop_counters`) |
| `rmnet_perf` | - | - | - | **built** | patch 0042 (TCP lookups without hashinfo); not loaded on 5.4 or 6.12 |
| `slim-qcom-ngd-ctrl` | - | ✔ (`slimbus_ngd`) | `slim@3ac0000` ok, `btfmslim-driver` child | **built** | patch 0043; with `slimbus` + `bt_fm_slim` (both built since the mechanical pass) = Bluetooth SCO/A2DP audio over the LPASS slimbus, as on 5.4. Not in any 6.12 stage yet: BT audio has not been tried on 6.12 either |
| `snd-usb-audio-qmi` | - | ✔ (`=y`) | `usb_audio_qmi_dev` | **built** | patch 0044; USB-C audio offload via the ADSP (needs GKI `SND_USB_AUDIO=y`, dwc3-msm, qmi_helpers) |
| `ucsi_qti_glink` | - | ✘ (`QTI_PMIC_GLINK` off) | `qcom,ucsi` under pmic_glink, enabled | **built** | patch 0045; compile fix only. Do NOT add it to a stage: the A52s USB-C/PD stack is SM5714 (`pdic_sm5714`), a second Type-C port driver over the ADSP charger PD is untested on any kernel here |
| `mem-offline` | - | ✘ | `mem-offline` | **built** | patch 0046; compile fix only (it offlines DDR blocks at probe; not used on 5.4/6.12, keep it out of stages) |
| `qca808x`, `qcom-phy-lib` | - | - | - | **built** (were "compiled, no .ko") | nothing changed in them: the failing `aquantia` in the same directory stopped the directory link; aquantia is dropped. Ethernet PHYs, never loaded |
| `zram` | GKI's | built in | - | **dropped** | older Qualcomm copy (no multi-backend zcomp); the 6.12 real boot and the 6.18 package load GKI's `zram.ko` (pack-kexec-rd-618.sh copies it from the GKI dist) |
| `zsmalloc` | GKI's | built in | - | **dropped** | same; the soc-repo copy still includes `<linux/zpool.h>` (gone in 6.18) |
| `virtio_block` | - | ✘ | - | **dropped** | virtio block for Qualcomm guest VMs (+ QTI crypto); Android runs on the host; GKI has `virtio_blk.ko` |
| `aquantia` | - | ✘ | - | **dropped** | Ethernet PHY; soc-repo `aquantia_main.c`/`aquantia.h` against ACK 6.18 `aquantia_leds.c` (`leds_active_high`) |
| `snd-soc-hdmi-codec` | - | ✘ | - | **dropped** | ASoC HDMI codec for DSI/DP-to-HDMI bridges (lt9611uxc, dropped); no HDMI; Qualcomm's own path is audio-kernel `hdmi_dlkm` (builds) |
| `msm_show_resume_irq` | - | different (built-in 5.4 variant) | none (`qcom,show-resume-irqs` absent) | **dropped** | debug aid; never probes on this board; copies the GIC driver's private `gic_chip_data` (drivers612/suspend/README.md); 6.18 has `/sys/power/pm_wakeup_irq` |
| `pci-msm-drv` | - | built in, no device | pcie0/pcie1 **disabled** | **dropped** | no PCIe device on the A52s (modem on-die, WCN6750 on AHB). A port would also have to re-derive its private copy of the AER core's per-device stats (`pci_dev.aer_stats` -> `aer_info`, layout changed) and `of_pci_parse_bus_range()` (now static). Its only importer `mhi.ko` (`msm_pcie_allow/prevent_l1`) keeps those 2 unresolved imports; mhi is not loaded either |

All seven built modules: vermagic `6.18.33-4k-g00c8666046c2-dirty`, every import resolves
(survey-symbols). No GKI 6.18 module has the same name (no `slim*`, `*ucsi*`, `rmnet*`,
`snd-usb-audio*` .ko in the GKI dist: SLIMBUS/NGD off, TYPEC_UCSI=y, SND_USB_AUDIO=y).

Unchanged modules: the build was incremental over the rebuilt tree (port618 rewrites every
transformed file), and every vendor .ko the a8 package uses (`android/out/dist` soc-repo
modules + all `stage-618/*` files) has the same GNU build-id afterwards (only the GKI copies
under `dist/.../kernel/` and the GKI `rfkill.ko` in stage wlanb are not from this tree).
`coresight-etm4x` sources of ACK 6.18 still error in `logs/soc.log` (TRFCR_ELx_* names): that
object is not part of the 6.12 module set and not counted (see item 13 below, GKI coresight).

What it means for the Android stages and the real boot (not done here, nothing loaded):
1. **Modem stage on 6.18**: `drivers612/modem/out/stage-modem/load.list` (a52_modem_guard,
   msm_sharedmem, memshare, glink_pkt, rmnet_mem, gsim, ipam, ipanetm, rmnet_ctl, rmnet_core,
   rmnet_offload, rmnet_shs) can now be mapped by `android/mkstages-618.py` the way the other
   17 stages are (all its files exist in the 6.18 tree); needed for cellular data once a modem
   test runs on 6.18.
2. **Bluetooth audio** (both kernels): a stage after `audio@adsp` with `slimbus.ko`,
   `slim-qcom-ngd-ctrl.ko`, `bt_fm_slim.ko` (5.4 loads exactly these; the NGD needs the ADSP
   running, so `@adsp`). Then test a BT headset (SCO call audio, A2DP).
3. **USB-C audio offload**: `snd-usb-audio-qmi.ko` in the audio stage (`@adsp`, after
   dwc3-msm), and in the real boot's vendor add-on audio list; test with a USB-C DAC.
4. Not to be added: `ucsi_qti_glink`, `mem-offline`, `rmnet_perf` (not loaded on 5.4).

## Next steps for the real-port modules (boot path first)

The morning plan assumed upstream drivers could replace most forks because the 6.18 harness
(`ack/` + `a52sxq_gki.fragment`) boots this phone with upstream pinctrl, arm-smmu-qcom,
ufs-qcom and dwc3-qcom. The boot-path pass (above) found that holds only together with the
mainline DT and the upstream clock/PHY drivers; with the vendor DT the vendor modules need,
the forks stay. Items 2-4 and 8 are done at compile level.

1. **pinctrl / GPIO** (`pinctrl-msm`: builds). Done unless loading shows a difference; the
   yupik soc data module (`pinctrl-yupik`) already built. Check the fork's extras (tile save,
   `qcom,gpios-reserved`, wakeup/MPM) still behave with gpiolib-managed valid masks.
2. **UFS + inline crypto: builds** (forks kept, patch 0013 + rule `blk-crypto-key`). Open:
   (a) done: `sched-walt` builds, so ufs-qcom's imports resolve (item 6), (b) the FBE finding (raw keys are not
   offered to ICE: software fallback), (c) runtime check of the 6.18 power-mode split
   (`negotiate_pwr_mode` before PRE_CHANGE) on the first 6.18 boot.
3. **IOMMU: builds** (forks kept, patch 0014; dispatcher dropped). All `qcom_iommu_util`
   imports of kgsl/msm_drm/camera/coresight/ipam/iommu_debug resolve. `snd-usb-audio-qmi`
   builds (patch 0044).
4. **USB: `dwc3-msm` and `usb_notify_layer` build** (patches 0015, 0016). `ucsi_qti_glink`
   builds (patch 0045; not loaded on 6.12 or 5.4, keep it out of the stages). The GKI's built-in upstream dwc3-qcom stays unused with the vendor DT.
5. **DMA heaps / secure buffers**: `qcom_dma_heaps` builds (pool-size hook dropped).
   `minidump` builds (patch 0017); it could not stay out of the boot list after all: ufs-qcom,
   `qcom_ipc_logging`, `qcom_wdt_core`, `qcom-dload-mode` and others import it.
6. **Scheduler** (`sched-walt`): **builds and modpost-clean** (owner decision: port, keep
   `CONFIG_SCHED_WALT=m`; rule `cfs-h-nr-queued`, patch 0018; `qcom-cpufreq-hw` fork too,
   patch 0019). Hook audit, boot arguments (`android_arch_task_struct_size=512` required,
   `sched_proxy_exec=0` recommended) and run-time risks: sched-walt section.
7. **Display: builds** (`msm_drm` patch 0030, `drm_display_helper` = ACK 6.18 via `UPSTREAM`,
   `lt9611uxc` dropped). Whole display stage modpost-clean; run-time checks for the first 6.18
   load: display section.
8. **GPU** (`msm_kgsl`): **builds** through the `dma-fence-ops` rule alone (no further layer
   of errors behind it); all its `qcom_iommu_util` imports resolve.
9. **Audio: builds** (`platform_dlkm` patch 0020, `machine_dlkm` patch 0021 + rule
   `asoc-dpcm-dir`; the whole androidboot audio stage is modpost-clean). Run-time checks:
   audio/Wi-Fi/camera/video section. `snd-soc-hdmi-codec` (no HDMI on the A52s): dropped.
10. **Connectivity**: `wlan` **builds** (patch 0022; the wlanb/wlan stages are complete).
    rmnet_core, rmnet_shs, rmnet_perf **build** (patches 0040-0042): the modem stage is complete
    on 6.18. `slim-qcom-ngd-ctrl` builds (0043): BT audio path with `bt_fm_slim`.
11. **Camera: builds** (patch 0023, compat `struct gpio`; no further layer of errors).
12. **Video** (`msm-vidc`): **builds** (patch 0024: ext-ctrl ops over vidc's own handlers,
    `v4l2_fh_add/del(fh, filp)`).
13. **Not loaded on 6.12 today: decided in the remaining-modules pass** (section above):
    `virtio_block`, `zram`, `zsmalloc`, `aquantia`, `pci-msm-drv`, `msm_show_resume_irq`,
    `snd-soc-hdmi-codec` dropped; `mem-offline`, `slim-qcom-ngd-ctrl` build. (`qcom-cpufreq-hw` moved out of this list: the 6.12
    boot loads the fork and WALT needs its policies; it builds now, patch 0019.)
    Also still open from the survey: GKI 6.18 ships `coresight.ko` + funnel/replicator/etm4x/
    trbe with the same names as soc-repo's (pick one stack), and soc-repo `mac80211.ko` lacks the
    6.18 NAN object (take the 6.18 Makefile or GKI's mac80211).

## Android on 6.18: the kexec test pack (`bsp618/android/`, 2026-11-14)

Same path as the working 6.12 Android test (ab-s68: `drivers612/androidboot/pack-kexec-rd.sh`,
helper2.sh, stages, `kexec/kx-cycle.sh`), with every kernel-side piece from 6.18. The 6.12
scripts are not changed; `pack-kexec-rd-618.sh` is a copy of the 6.12 packer with 6.18 inputs.
One command (after `build618.sh`): `bsp618/android/build-android-618.sh <name>`.

| step | script | result |
|---|---|---|
| dist | `mkdist-618.sh` | `out/dist`: survey Image + GKI and soc-repo modules (modules_install, stripped) + one depmod; `first-stage.a52sxq.list` by the bsp612 rule (94 modules, same 8 "not built" names as 6.12) |
| first stage | `mkramdisk-618.sh` | `out/bringup/ramdisk-618.cpio.gz`: same DROP/ADD as `bsp612/mkramdisk-612.sh`, qcom-cpufreq-hw before sched-walt, GKI built-ins dropped automatically (none hit). **90 modules, identical names and order to the 6.12 load.list** (`out/bringup/compare-612.txt`); + 6.18 hhwdt.ko, sec_core.ko |
| stages | `mkstages-618.py` | `stage-618/<name>/` for all 17 6.12 stages: each 6.12 stage file traced to its 6.12 build by GNU build-id, the same path taken from the 6.18 tree, same file names, 6.12 load.list unchanged. 191/193 files ok; `hwmon.ko` (power, powerpd) commented out: GKI 6.18 has HWMON=y. Nothing missing or renamed. `stage-618/MAP.txt` lists every file |
| dtb | `mkdtb-618.sh` | `out/android-r02-618.dtb` = `out-ack/kx/android-r02.dtb` + `/reserved-memory/a52ram@f0be0000` (no-map), so `earlycon=a52ram,0xf0be0000` can be used (the 6.12 tree had shortened ramoops for this area but never reserved it) |
| pack | `pack-kexec-rd-618.sh <name>` | `out/<name>-rd.cpio.gz` (ROM ramdisk + 6.18 first stage + overlay). Overlay byte-identical to s68 except the modules and `adb_debug.prop` (`ro.bpf.kver_override=6.18.33`; `BPF_KVER=6.12.81` restores the 6.12 value); netd.rc shim bound as in s68. Runs `check-load.py` and refuses to pack on a failure |
| cmdline | `android-cmdline-618.txt` | 6.12 `android-cmdline.txt` (phone 2 serial/bootloader, `android_arch_task_struct_size=512` etc.) + `sched_proxy_exec=0 earlycon=a52ram,0xf0be0000` |

**`check-load.py`** simulates helper2.sh's insmods offline (hhwdt, testguard, first stage, zram,
then the a52.mods stages; `@adsp` ones last): vermagic, every undefined symbol exported by
vmlinux or an already loaded module, every modversion CRC equal to the exporter's
(`__versions`/`__version_ext_*` vs Module.symvers / `__kcrctab`), no duplicate exports. On the
6.12 s68 pack it reports 223 ok / 40 already / 0 fail (matches the hardware run). On 6.18 it
found one real load failure, now fixed: **camera.ko was linked against
`camera/deps/ioncompat`'s Module.symvers** while the test loads `secure/ioncompat`; 6.18's
gendwarfksyms gives the two copies different CRCs for `ion_alloc` (different includes, different
DWARF expansion of `struct dma_buf`; genksyms on 6.12 gave both the same) -> "disagrees about
version of symbol". `build-survey.sh` now links camera against `secure/ioncompat` (port618 tree
only, `ION_SYMVERS`). Result: 222 ok, 40 already loaded, 0 fail (hwmon is the 1 module fewer).

Kernel Image = `out-survey/gki` (ACK android17-6.18.33 gki_defconfig + Rust), release
`6.18.33-4k-g00c8666046c2-dirty`. "-dirty" is the uncommitted bring-up patch set in `ack/`
(`COMMAND_LINE_SIZE` 4096: `boot_command_line` is 0x1000 in vmlinux; `a52ram.c`; the kexec
alternative-fdt patch, only used when this kernel kexecs). The 6.18 harness (out-ack) is built
from the same tree and has the SAME release string: vermagic cannot tell harness modules from
these, the CRC check can; take modules only from `bsp618/`. If `ack/` changes, rebuild the gki
step and everything after it. `CONFIG_PANIC_TIMEOUT=-1`, `PANIC_ON_OOPS=y`, hung-task and
soft/hard-lockup detectors are built in (helper2.sh arms their panics), `KEXEC_FILE` is off (not
needed in the target), module signing config identical to 6.12 (`MODULE_SIG_FORCE` off). No DT
compatible of the android tree is matched by a 6.18 built-in that 6.12 did not have (string
diff of both vmlinux against the tree's 374 compatibles).

First 6.18 boot, what to read first (telnet 172.16.43.1, `tools/tsh.py`; after a reset:
kx-cycle's `prev-console.txt`, `a52ram.txt`):
1. Did it start at all: `a52ram.txt` (earlycon) / `Linux version 6.18.33`; `CFI failure` (kCFI,
   not permissive: a prototype the port changed behind a cast traps), `Unable to handle`, `BUG:`.
2. First stage: `a52sxq-init: modules done: N loaded, M failed`, `/tmp/insmod-failed.txt`. UFS
   (ufs-qcom fork, patch 0013, `negotiate_pwr_mode` split: no `sda*` = no Android), SMMU
   (arm_smmu fork, 0014: context faults), USB (dwc3-msm 0015: no UDC = no telnet/adb; the
   helper's 600 s dead-man then restarts into the harness).
3. Scheduler: `sched_proxy_exec disabled via boot arg`; no `sched-walt: task_struct objects are`
   guard line; `task_struct` objsize 5248 in /proc/slabinfo; /proc/sys/walt; 3 cpufreq policies.
   Watch core_ctl pause/unpause (WARNs, stuck stopper).
4. Stages: `insmod FAILED` lines per stage; display: refcount_t WARNs at the first mode-set
   (bridge refcounting is new), boot animation, UBWC colours; kgsl; then Android:
   `an getprop sys.boot_completed`, netd1shot (if it aborts: repack with `BPF_KVER=6.12.81`).
5. Later stages, run-time risks as listed per section above: audio (hostless FE `.prepare`,
   `/proc/asound/pcm` = 53 PCMs), Wi-Fi (wdev wrappers), camera/video (V4L2 core), binder boost.

Correction to the audio/Wi-Fi section above: the dsp stage's `qcom_pd_mapper_a52.ko` is the
soc-repo `qcom_pd_mapper.ko` with patches 0005/0006 (build-id), not `hwbringup/pdmapper`'s.
Verified carried through from the 6.12 sources: soc-repo 0004-0008 (incl. 0007 BT serial
TIOCPM, 0008 si_core TASK_IDLE), audio `a52-import-cma-map-fix` and
`a52-wcd938x-amic-direct-routes`, camera CPAS `of_get_child_by_name`.

### First boots: dwc3 SMMU write fault = no TLB invalidation on unmap (patch 0031, 2026-11-14)

Runs ab618-a2s1 (phone 2) and ab618-p1s1 (phone 1), same package: all stages load, UDC up,
then ~0.19 s after `USB_STATE=CONFIGURED` apps-smmu reports a context fault from a600000.dwc3:
FAR 0xeff87000 (both phones), FSR 0x40000408 [PF W SS], FSYNR0 PLVL 3 + WNR, SID 0xe0, CB 0x22,
soft walk = ATOS (ATS1PR) = a mapped page whose phys differs per boot (0x126516000 /
0x13491f000) -> `BUG_ON(!fault_model.non_fatal)` (soc-repo arm-smmu.c:1021) -> panic.

**Root cause** (6.18 IOMMU core vs the fork, not dwc3): ACK 6.18 `include/linux/iommu.h:1008`
`iommu_iotlb_sync()` calls `->iotlb_sync` only if `iotlb_gather->start < iotlb_gather->end`
(6.12, `bsp612/kernel/include/linux/iommu.h:896`: unconditionally). The fork's unmap is
`arm_smmu_unmap_pages` -> `qcom_arm_lpae_unmap_pages` (soc-repo `qcom-io-pgtable-arm.c:1244`),
which never puts a range in the gather: it clears the PTEs and only sets `deferred_flush` via
`tlb_add_inv` (`arm-smmu.c:1297`), relying on `arm_smmu_iotlb_sync` -> `arm_smmu_flush_iotlb_all`
(TLBIASID + sync, `arm-smmu.c:2503-2572`) to invalidate. On 6.18 that callback was skipped for
every strict-mode unmap (`dma-iommu.c:821 __iommu_dma_unmap`, `iommu_unmap`), so the SMMU never
invalidated anything after an unmap (all apps-smmu clients of the fork: USB, UFS, kgsl, display,
camera ...; stale entries could also have sent DMA to freed pages). Upstream arm-smmu (the 6.18
harness) is not hit: its io-pgtable issues TLBIVAL per page from `tlb_add_page` inside the
unmap, only the final sync is lost.
The dwc3 instance: the composite ep0 buffer (`cdev->req->buf`, kzalloc 4096 = page aligned, so
FAR ends in 000) is mapped DMA_TO_DEVICE (IOMMU_READ) for an IN control transfer, unmapped, and
remapped at the same IOVA (rcache) DMA_FROM_DEVICE for the next OUT data stage (cdc_ncm
SET_NTB_INPUT_SIZE / cdc_acm SET_LINE_CODING right after configuration); the walk shows the new
RW PTE, the TLB still held the read-only one -> write permission fault. Same IOVA on both phones
because the allocation sequence is deterministic.

Ruled out on the way: patch 0015 (DEPCMD offsets: 6.12 `dep->regs + DWC3_DEPCMD` = 6.18
`dwc->regs + DWC3_DEPCMD(n)`, both `0xc80c + n*0x10` from the global base; GSI doorbell address
the same), 6.18 dwc3 ep0/gadget mapping directions (`ep0.c:984 __dwc3_ep0_do_control_data` maps
with `dep->number`, unchanged), `usb_gadget_map_request_by_dev` (unchanged),
`dma_info_to_prot` (only DMA_ATTR_MMIO added), IOMMU_* prot bits (identical), qcom pgtable
quirk bits (29-31, no clash with 6.18's 0-10), dwc3 DT props (dma-coherent, "atomic" = GKI
dma-iommu ops; same tree as 6.12), u_ether/f_ncm/f_acm/composite (no relevant change).

**Fix** `port/patches/0031-arm_smmu-6.18-iotlb_sync-needs-gather-range.patch`: after a
successful unmap, `arm_smmu_unmap_pages` adds the range to a non-queued gather
(`iommu_iotlb_gather_add_range`, static inline, no new import), so the core calls
`arm_smmu_iotlb_sync` again, which flushes the context as on 6.12.

**Test safety**: `android/mkdtb-618.sh` now sets `qcom,iommu-faults = "non-fatal"` on
`/soc/ssusb@a600000/dwc3@a600000` (the fork's existing per-client DT switch, parsed in
`arm_smmu_setup_default_domain`; several vendor nodes already carry it). A dwc3 context fault
is then still printed in full (ratelimited) and the stalled transaction terminated, instead of
BUG(). `A52_SMMU_FATAL=1 mkdtb-618.sh` leaves it out. Faults of every other client stay fatal.

Also fixed: `port618.py` tried to apply `patches/ack-0001-*.patch` (an ACK-tree patch, applied
to `ack/` by hand) to bsp618/src and aborted; `ack-*.patch` are skipped now.

Built offline: `build618.sh port soc` (arm_smmu.ko rebuilt, build-id 25152720...), then
`android/build-android-618.sh a3`: dist, first stage (90 modules, 6.12 order), 17 stages, dtb with
the non-fatal switch, `out/a3-rd.cpio.gz`; insmod simulation 222 ok / 40 already / 0 FAIL.
Next hardware run: package a3 (`kx-cycle.sh ab618-a3s1 ... a3-rd.cpio.gz`, a52.stage=1 as in
a2s1). Pass: no "context fault from a600000.dwc3", telnet 172.16.43.1 answers, NCM link up on
the PC. If a fault is still printed (now non-fatal), the stale-TLB explanation does not cover
it: the session stays up, so read FAR/FSR/soft-vs-ATOS from dmesg over telnet.

## Caveats

- Compile and modpost only. Nothing here says the modules load or work on 6.18; the next
  milestone is loading the 6.12 boot module list built from this tree under the 6.18 kernel
  (kexec from the harness on the third test device, when the owner names it).
- clang stops at 20 errors per file (camera excepted), so a few heavy files may hide more.
  (The boot-path targets were checked with `-ferror-limit=0`: nothing was hidden behind them.)
- The fork-vs-upstream decisions assume the 6.18 vendor boot uses the vendor DT, as the 6.12
  one does. If the owner ever prefers a mainline-binding DT for UFS/SMMU/USB, the upstream
  drivers become the better base, but the vendor modules that import fork APIs (kgsl, msm_drm,
  camera, usb_f_gsi, sdhci-msm) would then need shims.
- `lahaina` module config and GKI vmlinux come from the survey build (plain-make gki_defconfig,
  not a Kleaf android17-6.18 GKI): no KMI/CRC guarantee against a real GKI image.
- The ported tree builds only against 6.18 (no `LINUX_VERSION_CODE` guards); the 6.12 sources
  stay the place to edit, and `port618.py` re-derives the 6.18 tree from them.
