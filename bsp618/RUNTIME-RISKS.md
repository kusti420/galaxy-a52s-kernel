# 6.18 port: runtime-risk pre-audit (2026-11-14)

Source reading only (bsp612/kernel = ACK android16-6.12 vs ack/ = ACK android17-6.18.33, plus
the 6.12 vendor sources and bsp618/port/patches). Nothing was built, loaded or flashed. The aim
is fewer hardware iterations: each risk the porting passes listed in PORT-STATUS.md gets a
verdict and file:line evidence. Where something will break, or is cheap to harden, there is a
proposed patch in `bsp618/port/proposed/`.

The proposed patches are NOT in `port/patches/` and port618.py does not apply them. Each one is
`-p1` against `bsp618/src`. Each applies with `patch --dry-run` both on the 6.12 source with
its base patch applied (pre-rules) and on the current bsp618/src (post-rules). To adopt one,
move it into `port/patches/` and rebuild.

## Verdict summary

| area | verdict | proposed |
|---|---|---|
| Display: bridge refcount (0030) | safe | 0130 (error-path UAF, pre-existing) |
| Display: atomic/vblank/probe/client/GEM/prime | safe | 0131 (teardown kfree, pre-existing) |
| Audio: hostless `.prepare` (0021) | safe, one latent bug | **0140** |
| Audio: ASoC DPCM/trigger/compress/ctl limits | safe; one new open-time check (risky, low) | - |
| Wi-Fi: wdev wrappers (0022), locking, `__counted_by`, wiphy_register | safe | - |
| Wi-Fi: NAPI teardown | risky (WARN only) | 0150 |
| WALT: proxy exec, drain loop, delayed dequeue, binder, guard | safe with the cmdline; risky without it | **0160**, **0161** |
| Camera (0023), V4L2 subdev/media | safe | 0172 (icc UAF, pre-existing) |
| **msm-vidc on 6.18** | **will break** (every codec open fails, no oops) | **0170 + 0171** |
| kgsl dma-fence / mm | safe | - |
| Legacy GPIO API (all vendor modules) | safe (`GPIOLIB_LEGACY=y`, real exports) | - |
| Cross-cutting: cmdline, CFI/UBSAN, UFS 0013, vendor hooks, FBE, cgroups | safe | - |

Bold = recommended before the first full Android run on 6.18.

## Most likely to stop Android booting on 6.18 (ranked)

Status while this audit ran:
- 15:45, run ab618-a3: Android booted on 6.18 (boot_completed=1). This was after patch 0031
  fixed the dwc3 SMMU fault; 0031 is not one of these proposals.
- 15:50: the same run went down at 121 s with a hung_task panic in kgsl workers.
  `kthread_create_worker()` stopped waking the worker in 6.14, and port618.py now has the
  rule `kthread-run-worker` for it.
- Cross-check for that rule: no vendor code calls `kthread_bind`, sets affinity or calls
  `wake_up_process` on these workers after creating them (kgsl x5, q2spi). So the rename
  cannot trip the `WARN_ON_ONCE(kthread->started)` in `kthread_bind[_mask]`
  (`ack/kernel/kthread.c:588, 605`).

The ranking below is therefore "most likely to bring a running 6.18 Android down or keep it
from booting". The audit found no other item that will certainly oops. By likelihood:

1. **A WALT_BUG sanity check trips on changed 6.18 scheduler behaviour and panics.** Qualcomm's
   default `panic_on_walt_bug` = 0x4544de1b (print + panic, `walt_config.c:48`).
   `PANIC_ON_OOPS=y`, and sched-walt is in the first stage
   (`android/out/bringup/load.list:34`), so it runs for the whole boot. There are 43 WALT_BUG
   sites. The only proven 6.18 path is per-task CFS throttling, which calls
   `dequeue_task_fair()`/`enqueue_task_fair()` directly (`ack/kernel/sched/fair.c:6059/6189`)
   and bypasses WALT's en/dequeue hooks; it needs `cpu.max` quotas, which the ROM does not set.
   -> **0160**: WALT-BUG prints instead of panicking. Re-arm with
   `echo 1162141211 > /proc/sys/walt/panic_on_walt_bug`.
2. **The cmdline does not reach the kernel.**
   - `sched_proxy_exec` defaults ON in ACK 6.18 (`ack/kernel/sched/core.c:145`; 6.12: off,
     `bsp612/kernel/kernel/sched/core.c:138`). The 6.18 recovery boots log it enabled
     (`logs/a52sxq-ack618-wdt11-recovery-200143/dmesg.txt:688`). With it on, WALT runs proxy
     paths never exercised on this phone (walt.c in_proxy_migration rq lock, donor != curr).
   - Parsing of `sched_proxy_exec=0` checked: `__setup` at core.c:242 runs `kstrtobool(str+1)`
     and then `static_branch_disable`. It is parsed after `jump_label_init`.
   - -> **0161**: WALT stays inert (logged pr_crit) when proxy exec is on. Same path as 0018's
     task_struct guard. `__sched_proxy_exec` is exported (core.c:234, Module.symvers).
   - Residual: `/sys/kernel/sched_proxy_exec/enable` (0664, one-way on) can switch proxy exec
     on after WALT has initialised. Nothing in the ROM writes it (grep of rootdir, device/samsung,
     vendor/lineage).
3. **SurfaceFlinger: SDE buffer mapping through the arm_smmu fork / qcom_iommu_util.**
   - The SMMU fault seen on dwc3 is the same class of problem; another agent is on it, and
     patch 0031 exists.
   - The DRM core side is clean (display section below). With `msm_iommu_present()` now
     constant there is no carveout fallback, so a failed SDE map means a black screen.
   - Watch for msm_smmu / context-fault lines at the first gralloc import.
4. **First Wi-Fi association / data / SAP.** These paths never ran on 6.12 either and now run
   under UBSAN array-bounds trap + kCFI + PANIC_ON_OOPS, built with a newer clang (r596125).
   Not judgeable from source; do the first connect test with ramoops/a52ram capture. This does
   not block boot: qcacld comes up from the icnss2 FW-ready callback, not from insmod.
5. **Audio card or HAL behaviour.** This does not block boot.
   - The 6.18 core moved the "no backend DAIs enabled" -EINVAL from FE prepare
     (`bsp612/kernel/sound/soc/soc-pcm.c:2592-2601`) to FE open
     (`ack/sound/soc/soc-pcm.c:2768-2777`).
   - A HAL path that opens before routing now fails at open. CAF HALs route first, so this is
     unlikely. Grep dmesg for "no backend DAIs enabled".

Not a boot risk but will break: **hardware video codecs** (msm-vidc, 0170 + 0171). Every open
of the decoder/encoder nodes fails with a WARN on 6.18, so media playback falls back to
software decode.

## 1. Display (msm_drm, patch 0030)

- **Bridge refcounting: safe.**
  - The free path is `__drm_bridge_free` (`ack/drivers/gpu/drm/drm_bridge.c:208-215`:
    `funcs->destroy` + `kfree(bridge->container)`), and it runs only at refcount 0.
  - attach takes a reference (:422) and returns it on failure (:482); detach drops one (:503);
    `drm_encoder_cleanup` detaches the chain (`drm_encoder.c:188-200`).
  - `devm_drm_bridge_alloc` is only enforced by a DRM_WARN in `drm_bridge_add` (:303-304), and
    msm_drm never calls `drm_bridge_add`.
  - `drm_bridge_chain_get_first_bridge` takes a reference (`drm_bridge.h:1294-1299`); the
    next-bridge and for-each helpers take none; core gets and puts are balanced
    (`drm_atomic_helper.c:455-458, 528-531, 1225-1227`; `drm_probe_helper.c:118-122`).
  - Lifecycle: kref_init = 1, attach = 2, each `msm_drm_first_bridge()` 3 -> 2, detach = 1.
    It never reaches 0, and `container` is NULL anyway.
  - Pre-existing error-path UAF: `sde_kms.c:2093-2106, 2178-2183` free the bridge before
    `sde_encoder_destroy()` detaches it (same on 6.12) -> **0130**.
- **Atomic, vblank, probe and client: safe.**
  - msm uses its own `msm_atomic_commit` (`msm_drv.c:196`, `msm_atomic.c:839-989`) and never
    goes through `drm_atomic_helper_commit`.
  - The split modeset helpers call in the same order for one connector per encoder.
  - The vblank diff is timer renames only.
  - colorop: a zero-length array, inactive.
  - No new unconditional callback (drm_panic is off and needs `get_scanout_buffer`).
  - No fbdev client is auto-started (`DRM_FBDEV_EMULATION` unset, no `drm_client_setup`).
  - Teardown: the embedded kms_client has no `.unregister`, so `drm_client_dev_unregister()`
    would `kfree()` an interior pointer (`drm_client_event.c:32-50`; same on 6.12) -> **0131**.
- **struct_mutex -> driver mutex: safe.** The 6.12 core only initialised and destroyed it
  (`bsp612/kernel/drivers/gpu/drm/drm_drv.c:595, 636`).
- **GEM / prime / dma-buf: safe.**
  - `dma_buf_vunmap` without the resv lock (`msm_gem.c:851`) is the same as on 6.12 and only a
    lockdep issue (`PROVE_LOCKING` off).
  - The sgt caching removal is harmless: msm builds a fresh table
    (`msm_gem_prime.c:41-50`).
  - The dma-fence flag bits shift (new bit 0, `dma-fence.h:100-106`); Qualcomm flags are bits
    16/17/31, so no collision.
- DP `read_link_status`: the `< 0` fix is right (`dp_ctrl.c:276`, `dp_link.c:903`); DP is
  unused on the A52s.

## 2. Audio (patches 0020, 0021, rule asoc-dpcm-dir)

- **Hostless `.prepare` (0021): safe.**
  - 6.12 called the hook only at `bsp612/kernel/sound/core/pcm_native.c:1449` (the only
    `trace_android_*` under sound/), and it skipped only the PLAYBACK -EPIPE check (:1451-1454).
  - 6.18 `snd_pcm_pre_start` (`ack/sound/core/pcm_native.c:1438-1450`) passes when
    `stop_threshold >= boundary` (`ack/include/sound/pcm.h:921-928`).
  - Ordering: hw_params resets the threshold (:846-851), sw_params sets it (:992), and the FE
    `.prepare` runs after both via `dpcm_fe_dai_prepare` -> `__soc_pcm_prepare` ->
    `snd_soc_link_prepare` (`ack/sound/soc/soc-pcm.c:2502-2535, 929`).
  - Capture needs nothing: there is no buffer check on capture start.
  - Residual: a HAL that sends SW_PARAMS after PREPARE gets -EPIPE on START. The voice call
    itself starts in prepare (`msm-pcm-voice-v2.c:409-413`), so the likely symptom is a HAL log
    error, not a dead call.
- **Latent bug in 0021 -> 0140.**
  - `qcom_link_is_hostless()` matches `link->id` across all links. Eight BE links carry
    `MSM_BACKEND_DAI_*` ids equal to the LSM1-7/VOICEMMODE1-2 ids (`lahaina.c:6861, 6874,
    6909, 6922, 6957, 6973, 7037, 7049`).
  - Today that only gives 8 warnings per probe, because those links have their own ops.
  - **0140** restricts the match to `.dynamic` links, which is exactly the 6.12 scope.
- **asoc-dpcm-dir: safe.**
  - 6.18 `soc_get_playback_capture` (`soc-pcm.c:2791-2857`) masks the CPU-DAI directions with
    `_only`, and fails the whole card with -EINVAL when neither direction is left.
  - All 75 converted links were checked against their CPU DAI drivers (24 FE DAIs in
    msm-dai-fe.c, plus q6-dev/mi2s/tdm/auxpcm/dp); each supports the direction it keeps.
  - Compress links: `soc-compress.c:605-640` gives the same result.
- **Trigger order, BE fixup, DAPM, kcontrols: safe.** Equivalent or textually identical; the
  vendor code takes no core mutexes.
- **Control limits: safe.** `MAX_CONTROL_COUNT` 1028 per element (`control.c:27`); the 8 MB
  limit is for user controls only.
- **Compress (0020): safe.**
  - Legacy TSTAMP is truncated to the same 32-bit values 6.12 returned.
  - `snd_codec` keeps its size.
  - Device numbers: `rtd->id = num_rtd++`, same order as 6.12, so `/proc/asound/pcm` should
    show 53 entries.

## 3. Wi-Fi (qcacld, patch 0022)

- cfg80211 is ACK's own net/wireless on both kernels: the 6.12 soc-repo-staging copy is
  identical to ACK 6.12 apart from the Makefile, and the 6.18 copy is identical to ack/.
  CFG80211_WEXT=n on both.
- **Wrappers: safe.**
  - The handlers get `wdev->netdev`, and link_id is passed through.
  - rx_addr: nl80211 refuses NL80211_ATTR_MAC without ROC_ADDR_FILTER before the driver is
    called (`ack/net/wireless/nl80211.c:14220-14226`).
  - The wdev-only -EOPNOTSUPP branch is unreachable:
    - P2P_DEVICE keys get -EINVAL (`nl80211.c:1836-1875`);
    - get_station refuses `!wdev->netdev` (:8404);
    - every qcacld wdev, p2p0 and NAN included, has a netdev (`wlan_hdd_main.c:6353-6356,
      7865-7869`);
    - the MLO wdev-only unregister is not built.
- **Locking: safe.** The lockdep/RTNL requirements of all 40 imported cfg80211 symbols are
  identical 6.12 vs 6.18 (only the internal `cfg80211_leave` changed).
- **New 6.18 traps checked:**
  - `cfg80211_scan_done` now does a `container_of` into `cfg80211_scan_request_int`
    (`ack/net/wireless/scan.c:1184-1189`). Only cfg80211-allocated NL scans reach it; vendor
    scans go to `wlan_vendor_scan_callback` (`wlan_cfg80211_scan.c:1124-1127, 1342-1345`).
    Safe, but any qcacld change that reports a driver-allocated request there would corrupt
    memory.
  - `cfg80211_sinfo_release_content` also frees `links[]` (`cfg80211.h:9371-9381`); qcacld
    does not overwrite sinfo.
  - New `__counted_by` vs 6.12: only `nan_channels` was added; `scan_request.channels[]` is not
    annotated.
- **NAPI: risky (WARN only).** 6.18 `__netif_napi_del_locked` WARNs on a napi that is still
  enabled (`ack/net/core/dev.c:7603-7604`; 6.12 had no check, dev.c:6868).
  `dp_rx_tm_thread_napi_deinit` deletes an enabled napi (`dp_rx_thread.c:829/843`) -> **0150**
  (napi_disable before del).
  - Unpatched: `alloc_netdev_dummy()` failure is unchecked at 4 sites (NULL deref, only on
    ENOMEM at load).
- **wiphy_register: safe.** The only new checks cover iftypes/caps that qcacld cannot set
  (`ack/net/wireless/core.c:853-866, 941-958`).

## 4. WALT (patch 0018, rule cfs-h-nr-queued)

- **proxy exec: safe with `sched_proxy_exec=0`.** With proxy off, `rq_set_donor(rq, next)` runs
  before `rq->curr = next` (`ack/kernel/sched/core.c:7871-7873`) and `task_is_blocked()` is false
  (`sched.h:2353-2358`). Without the argument: see top risk 2, and **0161**.
- **core_ctl drain loop: risky, practically unreachable at boot.**
  - 6.18 `pick_task(rq, rf)` (core.c:6740-6755) is the 6.12 loop; RETRY_TASK only comes from
    sched_ext; `pick_task_fair`/dl_server do not drop the rq lock.
  - core_ctl is disabled by default (`core_ctl.c:1898`, `apply_limits` returns num_cpus at
    :1102), the ROM's post_boot never enables it, the SBT pause mask is 0, and
    thermal_pause/hyp_core_ctl are not loaded.
  - Watch the first real pause.
- **Delayed dequeue: safe.**
  - 6.12 already had DELAY_DEQUEUE (features.h:58 in both trees).
  - WALT skips delayed en/dequeues (walt.c:5276, 5376).
  - `h_nr_queued` is the 6.12 KMI union partner of `h_nr_running` (`bsp612 sched.h:714-717`).
- **Vendor-area guard: safe.**
  - The parameter is at `init/main.c:930`; `fork_init` creates the cache later (main.c:1207,
    fork.c:833).
  - `ksize()` >= object size.
- **Binder: safe.**
  - `is_async`/`is_reply` are set before the priority code runs (binder.c:3347-3348).
  - `ANDROID_VENDOR_DATA(1)` is still present (binder_internal.h:600).
- **Struct fields: safe.** WALT never compares `sched_class` pointers (walt.h:1466 uses prio +
  `task_on_scx`).

## 5. Camera / video (patches 0023, 0024)

- **msm-vidc: will break, two independent faults; each one fails every open.**
  1. 6.18 `vb2_core_queue_init` has `WARN_ON(!q->lock && !q->ops->wait_prepare)` -> -EINVAL
     (`ack/drivers/media/common/videobuf2/videobuf2-core.c:2661`); 6.12 had no such check.
     vidc sets neither (`msm_vidc.c:1276-1307`), so the first `vb2_bufq_init` (:1587) fails.
     -> **0171**: no-op wait_prepare/finish. vidc serialises with its own buf_queue.lock and
     dqbuf is non-blocking (:490).
  2. `msm_v4l2_open()` clears `V4L2_FL_USES_V4L2_FH` (`msm_v4l2_vidc.c:257`). 6.18 WARNs and
     returns -ENODEV for that (`ack/drivers/media/v4l2-core/v4l2-dev.c:437-441`).
     -> **0170**: keep the flag; 6.18 ignores it otherwise.
  - 0024 itself is right:
    - `v4l2_fh_add` sets `private_data = fh` (`v4l2-fh.c:48`), which is what vidc's
      `container_of` expects;
    - the core does not bypass the ext-ctrl ops, because vidc sets no
      `vdev->ctrl_handler`;
    - 6.18 passes `fh = NULL` to all ioctl ops, and vidc ignores that argument.
- **Camera: safe.**
  - The req-mgr node uses `v4l2_fh_open/release` (`cam_req_mgr_dev.c:116/196`).
  - Subdev registration is idempotent (`v4l2-device.c:205`), state is allocated without
    `init_state` (`v4l2-subdev.c:66-117`), and custom ioctls go via `core.ioctl` (:1112).
  - No vb2 and no request API.
  - `struct gpio` compat (0023): a local table, with `gpio_free_array` as a loop over
    `gpio_free`.
  - Pre-existing: `cam_icc_get_np()` calls `put_device()` on the device the interconnect core
    keeps (`ack/drivers/interconnect/core.c:187`, read at :73 and in trace.h:26/62) -> **0172**.
- **Legacy GPIO: safe.** `GPIOLIB_LEGACY` is `def_bool y` (`ack/drivers/gpio/Kconfig:6`) and =y
  in out-survey; `gpio_request`, `gpio_request_one`, `of_get_named_gpio` etc. are vmlinux
  exports. About 25 module dirs use them.

## 6. kgsl (rule dma-fence-ops)

- **Fence ops: safe.**
  - `fence->ops` is never detached in ACK 6.18 (assigned only at init, `dma-fence.c:1028`).
  - The new name helpers only swap the strings of signalled fences under RCU (:1106-1148).
  - kgsl's direct `ops->get_timeline_name()` (`kgsl_drawobj.c:311`, `kgsl_sync.c:858`) behaves
    as on 6.12.
  - The `signal_locked` callers hold the fence lock.
- The rule must turn `kgsl_timeline.c` `.use_64bit_seqno` into `dma_fence_init64` and rewrite
  `__dma_fence_is_later(..., ops)`. Otherwise 64-bit timeline fences compare only 32 bits; only
  Vulkan timeline semaphores use them. **Check `kgsl_timeline.c:198/339` in the regenerated
  bsp618/src** (it was in flux during this audit).
- **mm: safe.** GUP FOLL_WRITE, `vmf_insert_*`, `vm_flags_*` and
  `dma_buf_map_attachment_unlocked` are unchanged.

## 7. Cross-cutting checks (the "Android on 6.18" checklist)

- **Cmdline (`android/android-cmdline-618.txt`).** Every parameter exists in 6.18:
  - `android_arch_task_struct_size` (`init/main.c:930`), `sched_proxy_exec` (core.c:242);
  - `restrict_cma_redirect=` (`mm/page_alloc.c:234`), `cgroup_disable=` (cgroup.c:7041);
  - `no-steal-acc` (`arch/arm64/kernel/paravirt.c:50`), `kpti` (`cpufeature.c:1968`);
  - `rcu_nocbs` (`tree_nocb.h:71`), `irqaffinity=` (`irqdesc.c:39`);
  - the `sched_pelt_multiplier` sysctl (`pelt.c:525`), earlycon `a52ram`
    (`arch/arm64/kernel/a52ram.c:70`).
  - Note: 6.18 GKI dropped `RCU_NOCB_CPU_DEFAULT_ALL`, so `rcu_nocbs=0-7` now matters.
- **kCFI / UBSAN: no new exposure.**
  - Both kernels have strict CFI (6.12 `CFI_CLANG=y`, 6.18 `CFI=y`, `CFI_PERMISSIVE` off),
    UBSAN_TRAP + BOUNDS + ARRAY_BOUNDS + LOCAL_BOUNDS, FORTIFY, LIST_HARDENED and
    BUG_ON_DATA_CORRUPTION.
  - No port patch casts a function pointer; the one cast in 0030 (`sde_connector` mode_valid)
    is a data cast.
  - No cast-initialised callbacks in the vendor sources.
  - New `__counted_by` annotations in 6.18 include/ (23) touch nothing the vendor modules fill
    (cxl, nfs, sunrpc, netfilter, cfg80211/mac80211 NAN, ...).
- **UFS (0013): safe.**
  - 6.18 `ufshcd_config_pwr_mode` calls `negotiate_pwr_mode` first and copies desired on error
    (`ack/drivers/ufs/core/ufshcd.c:5032`). PRE_CHANGE's return is now ignored (:5002), and
    POST_CHANGE is called even on failure, with NULL (:5011); 6.12 only called it on success
    (`bsp612/kernel/drivers/ufs/core/ufshcd.c:4826`).
  - The fork's `pwr_change_notify` handles NULL first thing
    (`bsp612/soc-repo/drivers/ufs/host/ufs-qcom.c:2291`).
  - TX equalization is a no-op below HS-G4 / without UFSHCI support (`ufs-txeq.c`).
  - `hba->res` population is the same as 6.12 (MCQ only).
- **Vendor hooks outside WALT (109 hook names over all vendor sources).**
  - All are declared and called in 6.18 except `snd_pcm_check_no_buffer` (handled by 0021)
    and two hibernation hooks (qcom_secure_hibernation, not built or loaded).
  - The call sites of the boot-relevant ones are in the same functions: iommu iova/dma-ops,
    shmem_get_folio (kgsl), cma bitmap, try_fixup_sea, ufs send/compl/update_sdev/int_errors,
    gic_v3_set_affinity, timer_calc_index, jiffies_update, scheduler_tick, cpu_idle, ipi_stop,
    mpam_set, rproc_recovery_set.
  - **New behaviour:** `android_vh_allow_domain_state` is called in 6.18
    (`ack/drivers/pmdomain/governor.c:189`) but did not exist in ACK 6.12. qcom-cluster-lpm
    registers it, guarded by `#if defined(_TRACE_HOOK_PM_DOMAIN_H)`
    (`qcom-cluster-lpm.c:24, 538-563`), so on 6.18 it may become live and gate cluster genpd
    states. Dormant: qcom_lpm / cluster-lpm are in no 6.12 or 6.18 load list.
- **FBE: unchanged.**
  - `ufshcd-crypto-qti` advertises HW_WRAPPED only (`ufshcd-crypto-qti.c:205`) on both kernels.
  - `BLK_INLINE_ENCRYPTION_FALLBACK=y` on both, so raw-key /data uses the same path as on 6.12.
- **Config deltas that touch Android userspace: none boot-blocking.**
  - `MEMCG_V1` is gone: AOSP cgroups.json uses memory only via cgroup2, and the v1
    attributes in the vendor task_profiles.json simply fail, as before.
  - `DMABUF_SYSFS_STATS` is gone: meminfo only.
  - New `HARDLOCKUP_DETECTOR_BUDDY` without panic (helper2.sh does not arm
    `hardlockup_panic`).
  - `DPM_WATCHDOG` (25 s, suspend only).
  - `PROC_MEM_FORCE_PTRACE`, `MSEAL_SYSTEM_MAPPINGS` (Android 17 GKI defaults).
  - ASHMEM=y (Rust) and C binder (`ANDROID_BINDER_IPC=y`) on both.
  - `STACKPROTECTOR_PER_TASK` is off with clang r596125: modules use the global
    `__stack_chk_guard`, consistently.

## First-boot checks added by this audit

- `dmesg | grep -E "WALT-BUG|sched-walt:|sched_proxy_exec"` (with 0160: WALT-BUG lines are
  reported, not fatal).
- `dmesg | grep -E "no backend DAIs enabled|ASoC.*(no playback|no capture)"`; then
  `/proc/asound/pcm` = 53.
- With 0170/0171: `/dev/video32,33` (vidc) open without a WARN. Without them, expect
  `vb2_core_queue_init` and `v4l2-dev` WARN splats on the first media-codec probe.
- msm_smmu / context-fault lines at the first SurfaceFlinger buffer import.
- Wi-Fi: first association with ramoops capture (UBSAN/CFI traps on never-run paths).
