# Source scout: donor trees for the SM7325 (yupik/kodiak) 5.4 -> 6.18 port

Date: 2026-11-11. Method: `git ls-remote`, CodeLinaro GitLab API tree/raw fetches, `gh api`. No clones were made.
Legend: **V** = verified by fetching a listing or file content today; **U** = unverified / inferred; **R** = reported by a research subagent from repo docs (spot-checked where noted).

## 0. Headline

**Qualcomm ships an official yupik (SM7325 / QCM6490) Android BSP on kernel 6.12.** (V)

- CodeLinaro `clo/la/kernel/qcom`, branches `kernel.lnx.6.12.*` (newest seen: `kernel.lnx.6.12.r70-rel`), the "soc-repo" overlay on ACK android16-6.12 used by KERNEL.PLATFORM.5.0:
  - `build.config.msm.lahaina`, `configs/lahaina_{perf,consolidate}.bzl`, `modules-lists/modules.list.msm.lahaina`
  - `configs/lahaina_perf.bzl` sets `CONFIG_ARCH_LAHAINA=y`, **`CONFIG_ARCH_YUPIK=y`**, `CONFIG_PINCTRL_YUPIK=m`, `CONFIG_INTERCONNECT_QCOM_YUPIK=m`, `CONFIG_PHY_QCOM_UFS_V4_YUPIK=m`, `CONFIG_QSEECOM_PROXY=m`, `CONFIG_QCOM_DMABUF_HEAPS=m`
  - `drivers/pinctrl/qcom/pinctrl-yupik.c` (snapshot 2025-02-17, last change 2026-04-20), `drivers/interconnect/qcom/yupik.c`, `drivers/clk/qcom/{gcc,camcc,dispcc,gpucc,videocc,debugcc}-sc7280.c`
- Devicetree: `clo/la/platform/vendor/qcom-opensource/devicetree` @ `kernel.lnx.6.12.r70-rel`, `qcom/`: 53 `yupik*` + 44 `yupikp*` files (`yupik.dtsi`, `yupik-idp`, `yupik-qrd`, `yupik-iot-*`, `yupikp-iot-rb3-gen2*`, `yupik-dma-heaps.dtsi`, `msm-arm-smmu-yupik.dtsi`). `yupik.dtsi` has 61 commits, 2025-03-29 ("Add initial device tree for Yupik") to 2026-08-14; includes "Enable APR audio and ADSP SSR glink channels" and "Add qseecom memory region properties".
- Vendor release tags (`clo/la/la/vendor/manifest`): `LA.VENDOR.16.2.1.r1-*-LAHAINA.0`, `LA.VENDOR.16.2.8.r1-*-LAHAINA.0` (newest `-06100-`), `LA.VENDOR.16.2.7.r1-*-LAHAINA1.0` (newest `-08200-`). The manifests carry device tree `platform/vendor/qcom/lahaina612` whose `lahaina612.mk` has `TARGET_BOARD_PLATFORM := lahaina`, `DEVICE_MANIFEST_SKUS := yupik`, `manifest_yupik.xml`, and RB3 Gen2 comments.
- No kodiak/yupik target exists in msm-5.10, msm-5.15, 6.1 or 6.6 Android kernels (target lists of every `kernel.lnx.6.1.*` / `6.6.*` branch checked; no kodiak refs in msm-5.10/5.15). The jump is 5.4 -> 6.12 directly.
- No public `kernel.lnx.6.18.*` Android branch exists yet in `clo/la/kernel/qcom` (only 6.1, 6.6, 6.12). CLO does mirror ACK 6.18 prebuilts (`clo/la/kernel/prebuilts/6.18`).
- The old QCM6490 Android LTS line (`LA.UM.9.14.x`, up to `QISI15`) stays on msm-5.4.

This contradicts the project's the private project log "Known facts" line "Qualcomm never released a newer Android kernel for this chip"; that line should be corrected by the owner.

Second headline: **a community SM7325 phone already runs its 5.4-era vendor on this 6.12 BSP**: `suvojeet-sengupta/redwood-6.12` (POCO X5 Pro 5G). It contains an `/dev/ion` compat module and a forward-port of the 5.4 camera driver. See section 3.

## 1. Qualcomm Android techpacks that support yupik on 6.12 (CodeLinaro)

All under `https://git.codelinaro.org/clo/la/platform/vendor/...`. Branches taken from the LAHAINA / LAHAINA1 manifests above.

| Driver | Repo | Branch / tag | Kernel | Evidence for yupik | UAPI vs 5.4 blobs |
|---|---|---|---|---|---|
| SoC core (clk, pinctrl, icc, PIL, dma heaps, smmu) | `clo/la/kernel/qcom` | `kernel.lnx.6.12.r70-rel` | 6.12 (overlay on ACK) | V: files listed in section 0 | n/a; 5.4 PIL sysfs paths are gone (redwood uses a `subsys_compat` module) |
| DT | `qcom-opensource/devicetree` | `kernel.lnx.6.12.r70-rel` | 6.12 | V: 97 yupik/yupikp files | DT bindings are the 6.12 downstream ones, not mainline |
| Camera (handset) | `opensource/camera-kernel` | `camera-kernel.lnx.4.4.r1-rel` | 6.12 | V: `config/yupikcamera.conf`, `lahaina_defconfig`, `cpastop_v570_200.h`, target list has `lahaina` | V: 16 UAPI headers diffed against `LA.UM.9.14.1.r1-18500-QCM6490.QSSI15.0`: `cam_sync.h`, `cam_defs.h`, `cam_isp_*` identical; others differ only by include path and additions (`CAM_REQ_MGR_ALLOC_BUF_V2`, `MAP_BUF_V2`). Additive. |
| Camera (IoT) | `opensource/camera-kernel` | `camera-iot-kernel.qclinux.1.1.r5-rel` | 6.12 | V: `config/qcm6490-camera.mk`, `lahaina_*_defconfig` | U: same header set; not diffed |
| Display (SDE) | `opensource/display-drivers` | `display-kernel.lnx.1.11.r7-rel` | 6.12 | V: `config/gki_lahainadisp.conf`, `targets/lahaina.bzl`, `IS_YUPIK_TARGET` / `SDE_HW_VER_720` in `sde_hw_catalog.[ch]` | U: `sde_drm.h`, `msm_drm_pp.h` present; not diffed |
| mm-drivers (sync fence, ext display) | `opensource/mm-drivers` | `display-kernel.lnx.1.11.r7-rel` | 6.12 | U: only `kalamammdrivers.conf` in `config/` | U |
| GPU (kgsl) | `qcom/opensource/graphics-kernel` | tag `GRAPHICS.LA.16.1.r2-04700-LAHAINA.0` (also `GRAPHICS.LA.16.0.r6-03600-LAHAINA1.0`; branch family `gfx-kernel.lnx.16.0`) | 6.12 | V: `adreno_gpu_core_a642l` (`qcom,adreno-gpu-a642l`), `config/lahaina_{perf,consolidate}_gpuconf` | R: old `libgsl` passes list size as entry size in `IOCTL_KGSL_GPU_COMMAND`; needs a small kernel patch (redwood `patches/graphics-kernel`) |
| Audio (Elite/APR, legacy) | `opensource/audio-kernel` and `qcom/opensource/audio-kernel-ar` | `audio-kernel-legacy.lnx.6.12.r1-rel` | 6.12 | V: `config/lahainaauto.conf` (`CONFIG_SND_SOC_LAHAINA`, WCD938x/937x, bolero), `asoc/lahaina.c` handles `yupik` card names, q6 v2 / APR sources present | Same APR/q6asm-v2 generation as 5.4. R: mixer control names change |
| Video | `opensource/video-driver` | tags `VIDEO.LA.5.1.r1-06100-LAHAINA1.0`, `VIDEO.LA.5.1.r1-06000-LAHAINA.0` | 6.12 | V: `driver/platform/yupik/`, `config/yupik_video.conf`, `driver/variant/iris2` | **Not compatible**: this is the msm_vidc v2 driver (`v4l2_vidc_extensions.h`); 5.4 codec2/OMX blobs speak the old `msm_vidc` v1 controls. Redwood ports the old `msm_vidc` forward instead. |
| TrustZone (qseecom, smcinvoke, qcedev, hdcp) | `qcom/opensource/securemsm-kernel` | `sec-kernel.lnx.14.16.r27-rel` | 6.12 | V: `qseecom/`, `smcinvoke/`, `include/uapi/linux/{qseecom.h,smcinvoke.h,qcedev.h}`, `sec-kernel_defconfig_qseecom.conf` | qseecom UAPI kept. R: smcinvoke UAPI changed in newer branches (cupid had to update `libminkdescriptor`); R: do not load `tz_log` on yupik (reset) |
| FastRPC | `qcom/opensource/dsp-kernel` | `dsp-kernel.lnx.2.2.r13-rel` | 6.12 | U: `config/` lists only niobe/pineapple/sun | R: 5.4 DSP firmware rejected `ADD_PAGES` remote-heap grow with this driver; redwood ships a legacy `adsprpc` (`/dev/adsprpc-smd`) module |
| IPA | `opensource/dataipa` | `data-kernel.lnx.5.0.r30-rel` | 6.12 | U: generic `dataipa_GKI*.conf`, no per-SoC file | U. R: modem needs IPA up before going online |
| rmnet | `qcom/opensource/datarmnet`, `datarmnet-ext` | `data-kernel.lnx.5.0.r30-rel` | 6.12 | U | R: prebuilt 5.4 netmgrd wants the old `rmnet_data` UAPI |
| Wi-Fi WCN6750 | `qcom-opensource/wlan/qcacld-3.0` + `qca-wifi-host-cmn` + `wlan/platform` (icnss2) | `wlan-cld3.driver.lnx.2.0.9.r33-rel`, `wlan-cmn.driver.lnx.2.0.9.r33-rel`, `wlan-platform.lnx.2.0.r39-rel` | 6.12 | V: `configs/lahaina_gki_qca6750_defconfig`, `lahaina_consolidate_qca6750_defconfig`; `icnss2/` present | R: DT must use `iommu-addresses` instead of `qcom,iommu-dma-addr-pool` |
| Bluetooth | `qcom-opensource/bt-kernel` | `bt-kernel-css.lnx.16.0.r6-rel` (LAHAINA) / `bt-kernel.lnx.16.0.r10-rel` (LAHAINA1) | 6.12 | V: repo layout (`pwr/`, `slimbus/`, `btfmcodec/`); U: yupik target | R: redwood needed its own `btpower` |
| Touch, NFC, synx, spu, cvp | see manifests | `touch-kernel.lnx.11.0.r54-rel`, `nfc-driver.lnx.16.0.r17-rel`, ... | 6.12 | U | not needed (Samsung parts) |

Which manifest is which (inferred, U): `LAHAINA` (16.2.1 / 16.2.8) uses the IoT camera branch and `data-eth`, and its device tree mentions RB3 Gen2, so it is the QCM6490 line; `LAHAINA1` (16.2.7) uses `camera-kernel.lnx.4.4`, legacy audio-kernel and cvp, so it is the handset lahaina/yupik line. Both build `lahaina612`.

KERNEL.PLATFORM manifests: `clo/la/kernelplatform/manifest` tags `KERNEL.PLATFORM.5.0.r1` ... `r48` (6.12). Redwood documents r35 and r48 as its bases (R; tags `KERNEL.PLATFORM.5.0.r35-02100-kernel.0` and `r48-00400-kernel.0` exist, V).

Older KERNEL.PLATFORM generations (1.0 = 5.10 waipio, 2.0 = 5.15 kalama, 3.0 = 6.1 pineapple, 4.0 = 6.6 sun): none has a yupik/lahaina target, so they are not useful donors. Not examined per techpack.

## 2. Qualcomm Linux (QCS6490 / RB3 Gen 2), GitHub `qualcomm-linux`

| Component | Repo | Branch | Kernel | Evidence | UAPI note |
|---|---|---|---|---|---|
| Kernel | `qualcomm-linux/kernel` | `qcom-6.18.y` (6.18.56, commit 2026-11-11); `qcom-next` (7.3.0) | 6.18 / next | V: `sc7280.dtsi`, `sm7325.dtsi`, `qcs6490-rb3gen2.dts`, `qcs6490-camera.dtsi`, `qcs6490-audioreach.dtsi`, `kodiak-el2.dtso`, `qcm6490-fairphone-fp5.dts`, `sm7325-nothing-spacewar.dts` | Mainline-style bindings and drivers (no SDE, no kgsl in-tree) |
| Topic branches | `qualcomm-linux/kernel-topics` | `tech/all/dt/qcs6490`, `tech/mem/dma-buf`, `tech/mem/secure-buffer`, `tech/bsp/remoteproc`, ... | next | V: branch list | |
| Camera (CamX kernel side) | `qualcomm-linux/camera-driver` | `camera-kernel.qclinux.0.0` (commit 2026-11-10) | builds as DKMS against qcom-6.18 (U) | V: `config/qcm6490-camera.mk`; `camera_kt/include/uapi/camera/media/` has the same 17 headers (`cam_req_mgr.h`, `cam_sync.h`, `cam_isp.h`, ...) | Same UAPI family as Android CamX; content not diffed (U) |
| GPU | `qualcomm-linux/kgsl` | `gfx-kernel.le.0.0` | 6.18 (U) | V: A642L / A643 entries in `adreno-gpulist.h` | kgsl UAPI |
| Display (SDE) | `qualcomm-linux/display-driver` | `main` (2026-10-13) | U | V: `IS_YUPIK_TARGET` in catalog, `gki_lahainadisp.conf`; `targets/` has no lahaina/kodiak bzl | U |
| Video | `qualcomm-linux/video-driver` | `video.qclinux.main` | U | V: `driver/platform/kodiak/` | msm_vidc v2 / iris; not the 5.4 UAPI |
| Audio | `pkg-audioreach-dkms` etc. | | | AudioReach only | **Not usable** with a 5.4 Elite/APR ADSP image |
| TrustZone | `pkg-quic-teec`, `pkg-minkipc`, mainline qcomtee | | | | No qseecom |

Not found in the org: securemsm-kernel, dataipa, datarmnet, qcacld, bt-kernel (Qualcomm Linux uses ath11k, upstream IPA, upstream BT).

Use for this project: the `qcom-6.18.y` kernel is the best source of sc7280 fixes already on 6.18, and `camera-driver` / `kgsl` / `display-driver` show how Qualcomm builds the downstream camera, GPU and SDE drivers against 6.18 APIs. That is exactly the 6.12 -> 6.18 delta needed for the CodeLinaro techpacks.

## 3. Prior-art ports

### 3.1 `suvojeet-sengupta/redwood-6.12` (POCO X5 Pro 5G, SM7325) - closest match

V: repo exists (pushed 2026-11-09), layout `modules/ patches/ bringup/ qcom/ Documentation/porting-notes.md STATUS.md`. Prebuilt kernel repo `suvojeet-sengupta/device_xiaomi_redwood-kernel-6.12` (description: "6.12.81 ... CLO KERNEL.PLATFORM.5.0.r48"). A separate full tree `genie1997/android_kernel_xiaomi_redwood-6.12` has Makefile 6.12.96 (V).

`modules/`: `adsprpc audio btfmslim btpower camera54 fingerprint focaltech haptics ioncompat subsys_compat video wlan ...` (V). `patches/`: `audio-kernel display-drivers graphics-kernel mm-drivers securemsm-kernel soc-repo wlan-platform wlan-qcacld` (V).

STATUS.md (dated 2026-10-28, V) lists as working with the 5.4 ROM userspace on 6.12: display 120 Hz, kgsl A642L, ADSP/CDSP boot, WCN6750 Wi-Fi scan, modem + data, camera preview, `/dev/ion` compat, charging, sound card `lahaina-yupikidp-snd-card`. Open at that date: Bluetooth, camera provider crash in SNPE (FastRPC remote heap). The README reports a later daily-usable state including camera, BT, fingerprint and Widevine L1 (R, not re-read by me).

Lessons (R unless marked):
1. Base on Qualcomm's `lahaina` 6.12 target; build vendor modules against the lahaina config, not the bare GKI one.
2. Camera: the 5.4 camera driver was ported forward (`modules/camera54`, from the LineageOS sm8350 techpack via `port.py` + `cam_compat_612.h`) instead of using the 6.12 camera-kernel (V in STATUS.md). LRME must stay in the DT or CamX ZSL pipelines fail.
3. ION: `modules/ioncompat/ioncompat.c` (GPL-2.0, V) is a misc `/dev/ion` device that maps the modern ION alloc/heap-query ioctls and 5.4 msm heap ids/flags onto DMA-BUF heaps. Needed because vendor SELinux lets everything open `ion_device` but not the heap nodes.
4. kgsl: patch for old `libgsl` `IOCTL_KGSL_GPU_COMMAND` struct sizes.
5. TrustZone: `CONFIG_QSEECOM=m` in securemsm-kernel; HWKM v1 for wrapped keys; no `tz_log`.
6. Display: yupik display DT ported from 5.4; `cell-index` needed on DMA `dgm` blocks; boot with `clk_ignore_unused pd_ignore_unused` early on.
7. Audio: Elite/APR with the legacy audio-kernel; `qcom,rproc-handle`; in-kernel pd-mapper with yupik domains.
8. Wi-Fi: icnss2 `iommu-addresses` (V in STATUS.md). qcrild needs the signed GKI TIPC modules.
9. `subsys_compat` recreates 5.4 PIL sysfs paths (V); drop `qcom_edac` (IRQ storm, V).
10. Legacy `adsprpc` and old `msm_vidc` ported forward because the DSP firmware and codec blobs are 5.4-era.
11. Safety: test on slot b with `/data` on tmpfs.

### 3.2 cupid-development / Evolution-X (SM8450, 5.10 -> 6.6) (R)

- `cupid-development/android_kernel_xiaomi_sm8450-6.6`, `-modules-6.6`, `-devicetrees-6.6` (branch `lineage-24.0-6.6`, 6.6.144, pushed 2026-11-09); `Evolution-X-Devices/kernel_xiaomi_sm8450` `cnb-6.6` (pushed 2026-11-10) is downstream of it.
- `Documentation/waipio-port.rst` and `zeus-test-report.rst` were **not found**; per-subsystem status is undocumented.
- Technique differs from redwood: fork of `LineageOS/android_kernel_qcom_sm8750` (msm-6.6), waipio clocks/pinctrl/icc re-added by hand, true GKI + DDK modules. Userspace is **not stock**: HAL and DSP blobs swapped to a parrot-on-6.6 device's, AIDL audio / Codec2, `libminkdescriptor` updated for new smcinvoke, binary patches to `vulkan.adreno.so` and C2 store, old `rmnet_data` kept for netmgrd.
- Note Qualcomm now also has an official waipio 6.12 target (`build.config.msm.waipio`, `LA.VENDOR.16.2.9 WAIPIO`).

### 3.3 Others (R)

- `JiaqiLi404/android_kernel_618_for_sm8550`: SM8550 on ACK 6.18.32, untested on hardware per README. Only public 6.18 downstream attempt found.
- `i-am-wolfi/android_kernel_qcom_sm8450-6.12`: early.
- No public lahaina/kona/yupik ports to 5.10 / 5.15 / 6.1 found.
- All official SM7325 device kernels are 5.4 (LineageOS fairphone_qcm6490, nothing_sm7325, motorola_sm7325, samsung_sm7325, shift_qcm6490). Fairphone 5 Android 15 manifest still uses `kernel/msm-5.4`.
- Mainline: `sm7325-nothing-spacewar`, `sm7325-motorola-dubai`, `sm7325-xiaomi-lisa`, `qcm6490-fairphone-fp5`, `qcm6490-shift-otter` upstream; no Samsung SM7325 DTS upstream. `korryasdlerto-lgtm/sc7280-mainline-linux-m52xq` (Galaxy M52 5G, 7.1.13): SM5714 charger, NFC, WCN6750, SSC sensors reported working; useful Samsung DT reference.

## 4. ION on new kernels

| Option | Source | Status |
|---|---|---|
| Kernel `/dev/ion` shim over DMA-BUF heaps | `suvojeet-sengupta/redwood-6.12` `modules/ioncompat/ioncompat.c` (6.12, GPL-2.0) | V: exists; written for exactly this SoC and 5.4 msm heap ids. Best starting point. |
| Userspace | AOSP `libion` (vendor variant is built from source) falls back to DMA-BUF heaps when `/dev/ion` is absent | Works only for blobs that go through libion and whose SELinux domain can open heap nodes (U for Samsung blobs) |
| ACK staging ION | `clo/la/kernel/msm-5.10` `drivers/staging/android/ion/` (`ion.c`, cma + system heaps) | V: source present on 5.10, but waipio configs use `QCOM_DMABUF_HEAPS` only; msm_ion heaps were not carried. Porting it to 6.18 is more work than the shim. |
| UAPI headers | 6.12 soc-repo keeps `include/uapi/linux/{ion.h,msm_ion.h,msm_ion_ids.h}` | V: headers only, no driver |

GitHub searches for other maintained ION-over-dma-heap modules returned nothing relevant.

## 5. Samsung drivers on newer kernels

All rows R (subagent fetched directory listings and top-level Makefiles through the GitHub API; not re-checked by me). GitHub code search only indexes default branches, so newer copies may exist.

Best mirrors:
- **A** `polygraphene/SM-S942U_NA_16_Opensource` (`master`): Galaxy S26, Qualcomm canoe, **6.12.30**. Samsung drivers in `Kernel/kernel_platform/soc-repo/drivers/`, display in `Kernel/vendor/qcom/opensource/display-drivers/msm/samsung/`.
- **B** `physwizz/A24-A15-A16` (`main`): MediaTek A-series, **6.12.23**, `kernel/kernel_device_modules-6.12/drivers/`. Not Qualcomm, but has the whole SM5714 stack.
- **C** `crdroidandroid/android_kernel_samsung_sm8550` (`16.0`): kalama, **5.15.208**. Newest Qualcomm tree with `pca9468`, `sx9360`, full `stm_spi`.
- Also: `ata-kaner/android_kernel_samsung_sm6475` (`A366BXXU1AYB9`, A36, 6.6.46) + its `-modules` repo; `Flopster101/kernel_device_samsung_gts10fewifi` (Exynos, 6.6.111); `samsung-sm8650/android_kernel_samsung_sm8650` (`lineage-22.1`, 6.1.78).

| Driver | Newest (repo, kernel, path) | Runner-up | Notes |
|---|---|---|---|
| `ss_dsi_panel` framework | A, 6.12.30, `.../display-drivers/msm/samsung/` | A36 modules, 6.6 | Restructured (`ss_panel_parse.c`, `ss_panel_power.c`, `panel_data_file/`, per-panel `*.conf` + `*_panel.c`). S26 tree has only `M1_S6E3FAE_AMS627LW01`. |
| S6E3FC3 AMS646YD01 panel | `LineageOS/android_kernel_samsung_sm7325` (`lineage-24.0`), **5.4.302**, `techpack/display/msm/samsung/S6E3FC3_AMS646YD01_LO/` | sm8250 trees, `S6E3FC3_AMS646YD01/` (kernel not checked) | **No S6E3FC3 directory in any 5.10+ tree listed.** Closest newer sibling: `A36_S6E3FC5_AMS663FS01` on 6.6. The panel files must be ported from 5.4 into the newer framework. |
| `sec_input` + STM touch | A, 6.12.30, `soc-repo/drivers/input/sec_input/` (`stm_fst3ca60y_spi/`, SPI-only) | sm8650 6.1.78 `drivers/input/sec_input/stm_spi/`; C 5.15 | C's `stm_spi/` has the same file set as the A52s `stm/` (incl. `stm_i2c.c`, `stm_ioctl.c`, `stm_vendor.c`). |
| SM5714 MFD / charger / fuel gauge / MUIC / USB-PD / flash LED | B, 6.12.23: `drivers/mfd/sm/sm5714/`, `battery/charger/sm5714_charger/`, `battery/fuelgauge/sm5714_fuelgauge/`, `muic/sm/sm5714/`, `usb/typec/sm/sm5714/`, `leds/leds-sm5714-fled.c` | gts10fewifi 6.6; `physwizz/A556e-U-u4` 6.1.43 | Newest Qualcomm instance: `fusiondrive/android_kernel_samsung_x910`, 5.15.178 (device identity unverified). |
| PCA9468 | C, 5.15.208, `drivers/battery/charger/pca9468_charger/` | `yoro1836/android_kernel_samsung_sm8450_s22` (5.10 family, Makefile not fetched) | Absent from 6.1 / 6.6 / 6.12 trees (they use pca9481, sm5461, sm5443a). |
| S2MPB03 | B, 6.12.23, `drivers/regulator/s2mpb03/s2mpb03.c` | gts10fewifi 6.6; sm8650 6.1.78 | |
| `sec_battery` | A, 6.12.30, `soc-repo/drivers/battery/common/` (+ `core/`) | B 6.12.23; A36 6.6.46 | Qualcomm 6.12 copy has split `sec_pd_*` and `sb_*` helpers. |
| `sec_debug`, `sec_param`, `sec_qc_*` | A, 6.12.30, `soc-repo/drivers/samsung/debug/qcom/`, `samsung/bsp/param/sec_param.c`, `samsung/bsp/qcom/param/sec_qc_param.c` | A36 6.6.46 | |
| `et7xx` fingerprint | sm7325 trees only, **5.4**, `drivers/fingerprint/et7xx-spi.c` | none | Same-family Egis drivers on newer kernels: `ec6xx/` in B (6.12.23), `el7xx-spi.c` in A556e (6.1.43). |
| `sec_nfc` | gts10fewifi, 6.6, `soc-series/s-android15/drivers/nfc/samsung/sec_nfc.c` | A556e 6.1.43 | Qualcomm copy: `galaxy-m55xq/android_kernel_samsung_sm7450`, 5.10.198. Not in either 6.12 tree. |
| `sx9360` grip | C, 5.15.208, `drivers/sensors_lego/sx9360.c` | sm7325 5.4 `drivers/sensors/` | Mainline `drivers/iio/proximity/sx9360.c` exists but has a different userspace interface. |
| `adsp_factory` | A, 6.12.30, `soc-repo/drivers/adsp_factory/` | A36 6.6.46; C 5.15 | |
| `sec_vibrator` + DC motor | B, 6.12.23, `drivers/vibrator/common/sec_vibrator.c`, `drivers/vibrator/dc/dc_vibrator.c` | x910 5.15.178 | A52s uses `drivers/vibrator/dc`. |

SM7325 Samsung sources: newest is `salvogiangri/android_kernel_samsung_sm7325` (`sep-17/stock`, A736BXXSCGZH1, 5.4.289, A73 only, no A52s panel dir). Newest A52s import found: A528BXXU5FWK4 in `Mesa-Labs-Archive/android_kernel_samsung_sm7325` (5.4.233). No Samsung SM7325 device on a kernel newer than 5.4 was found (XCover6 Pro and Tab Active4 Pro not checked).

Samsung donor choice: take frameworks (`ss_dsi_panel`, `sec_input`, `sec_battery`, `sec_debug`/`sec_qc_*`, `adsp_factory`) from tree A (Qualcomm 6.12, same generation as the CLO yupik BSP); SM5714 stack, S2MPB03 and `sec_vibrator`/DC motor from tree B (6.12); PCA9468, `sx9360` and the full `stm_spi` from tree C (5.15); `sec_nfc` from the 6.6 tree; the S6E3FC3_AMS646YD01 panel files and `et7xx` from the phone's own 5.4 tree.

## 6. Recommended donor tree per subsystem

| Subsystem | Donor | Why |
|---|---|---|
| SoC core, PIL, smmu, dma heaps, DT | `clo/la/kernel/qcom` `kernel.lnx.6.12.r70-rel` + `devicetree` same branch; cross-check `qualcomm-linux/kernel` `qcom-6.18.y` for 6.18 API changes | Official yupik on 6.12; only one kernel generation behind 6.18 |
| Camera | First choice: `camera-kernel.lnx.4.4.r1-rel` (UAPI verified additive vs 5.4). Fallback: redwood `camera54` approach (5.4 driver ported forward) if Samsung CamX depends on driver behaviour | Redwood chose the fallback; reason not established for Samsung |
| Display | `display-drivers` `display-kernel.lnx.1.11.r7-rel` + Samsung `ss_dsi_panel` from the newest Samsung tree (section 5) | Has yupik catalog on 6.12 |
| GPU | `graphics-kernel` `GRAPHICS.LA.16.1.r2-04700-LAHAINA.0` + redwood kgsl patch | A642L on 6.12 |
| Audio | `audio-kernel` `audio-kernel-legacy.lnx.6.12.r1-rel` | Elite/APR, matches 5.4 ADSP firmware |
| Video | Port the 5.4 `msm_vidc` v1 forward (see redwood `modules/video`) | New video-driver UAPI does not match old codec blobs |
| qseecom / smcinvoke | `securemsm-kernel` `sec-kernel.lnx.14.16.r27-rel` | qseecom kept; check smcinvoke struct compat |
| FastRPC | Legacy adsprpc forward-port (redwood `modules/adsprpc`); dsp-kernel as reference | 5.4 DSP firmware compatibility |
| ION | redwood `ioncompat` | Only maintained shim found |
| IPA / rmnet | `dataipa`, `datarmnet` `data-kernel.lnx.5.0.r30-rel`; keep old `rmnet_data` UAPI | per cupid/redwood |
| Wi-Fi / BT | qcacld `wlan-cld3.driver.lnx.2.0.9.r33-rel` + `wlan-platform.lnx.2.0.r39-rel`; `bt-kernel` 16.0 | lahaina qca6750 defconfigs |
| Whole-port template | `suvojeet-sengupta/redwood-6.12` | Same SoC, same blob generation, documented |

Open risk for the stated 6.18 target: every Qualcomm Android donor is 6.12. Either accept 6.12 (android16-6.12 ACK) as the base, or carry the 6.12 -> 6.18 delta yourself using Qualcomm Linux's 6.18 builds of camera-driver / kgsl / display-driver as API references.
