# video: the phone's 5.4 `msm_vidc` (v1 V4L2 dialect) on the Qualcomm 6.12 BSP

The closed Codec2/OMX blobs (`libqcodec2_v4l2codec.so` & co) speak the lahaina `msm_vidc`
dialect on `/dev/video32` (decoder) and `/dev/video33` (encoder). Qualcomm's 6.12 video driver
is the v2 driver and does not accept it; the 6.12 base for yupik has no video node at all.
This directory is the phone's own 5.4 driver (iris2 for yupik), forward-ported.

State: **builds to `msm-vidc.ko` against `bsp612/out/lahaina`, 0 errors, 0 warnings (-Werror),
modpost clean, all 212 undefined symbols are exported by vmlinux or soc-repo modules.
Never loaded, never run.**

## What is here
| path | what |
|---|---|
| `msm/vidc/` | `$ANDROID_TREE/kernel/samsung/sm7325/techpack/video/msm/vidc` + the port changes |
| `msm/vidc/vidc_612.[ch]` | from redwood-6.12: firmware load (MDT loader + SCM PAS id 9) instead of PIL, DDR type, SCM wrapper |
| `include/uapi/vidc/media/` | the 5.4 UAPI headers. `msm_media_info.h` byte-identical; `msm_vidc_utils.h` identical except one in-kernel enumerator name (below) |
| `config/konavidconf.h` | `CONFIG_MSM_VIDC_V4L2` + the `V4L2_*_MPEG_*` aliases 6.12 hides from kernel code |
| `Kbuild`, `build.sh` | out-of-tree build; `./build.sh` (log `build.log`); `K=1 EXTRA=-ferror-limit=0 ./build.sh` to see every error |
| `a52sxq-video.dtsi` | DT fragment for the 6.12 base |
| `PORTING-CHANGES.patch` | every change against the Samsung 5.4 source, as one diff (2450 lines) |
| `STATUS.md` | progress log |

## Method
redwood-6.12 (POCO X5 Pro, same SoC, video reported working) ported an *older* lahaina tag of
the same driver. Their per-file diffs were read hunk by hunk; the hunks that are 6.12 API work
were applied to the Samsung source, the hunks that are only "their tag is older" were not.
Kept from Samsung's newer source (redwood's tree lacks them): input-crop extradata
(`EXTRADATA_ENC_INPUT_CROP`, `MSM_VIDC_EXTRADATA_INPUT_CROP`), `V4L2_CID_MPEG_VIDC_VENC_COMPLEXITY`
(BASE+137), `CAP_VP9_LEVEL`, `CAP_ALLINTRA_MAX_FPS`, sys-ping on response timeout, cx-ipeak hooks
(inline no-ops in the 6.12 soc-repo header), ab/ib bus votes, `pm_suspended`, per-instance log
contexts, HEVC tier in level, the memory checks.

## Changes to the 5.4 source (reason for each; full text in PORTING-CHANGES.patch)
1. **Firmware**: `subsystem_get_with_fwname("venus")`/`subsystem_put` -> `vidc_fw_load()`/`vidc_fw_unload()`
   (request `vpu20_1v.mdt`, `qcom_mdt_load()` into the node's `memory-region`, `qcom_scm_pas_auth_and_reset(9)`,
   `qcom_scm_pas_shutdown(9)`). 6.12 has no PIL and no `/dev/subsys_venus`.
2. **SSR**: `subsystem_crashed("venus")` -> log line. The driver never used subsystem *notifiers*;
   recovery is its own path (sys error -> core deinit -> PAS shutdown -> reload on next session), unchanged.
3. **ION -> DMA-BUF heaps** (`msm_smem.c`): `ion_alloc(mask, flags)` -> `dma_heap_find(name)` +
   `dma_heap_buffer_alloc()`. Names: `qcom,system` / `qcom,system-uncached` (fallback `system` /
   `system-uncached`), secure: `qcom,secure-pixel`, `qcom,secure-non-pixel`, `qcom,secure-bitstream`.
   Same naming as `modules/ioncompat` (its heap table), so buffers that userspace allocates through
   `/dev/ion` and buffers the driver allocates come from the same heaps. No link dependency on
   ioncompat (its `ion_alloc()` was not used: it is built for 6.18 only so far; switching is a
   10-line change in `msm_smem_alloc`).
   Imported buffers: 6.12 heaps have no `get_flags`, so cached/secure is derived from the
   exporter name (`qcom,system`/`system` = cached; `qcom,secure-*` and ioncompat's
   `qcom,cp-display-*` = secure). Secure pool prefetch/drain: no-ops.
4. **V4L2/vb2**: `VFL_TYPE_GRABBER` -> `VFL_TYPE_VIDEO`; `get_userptr` mem-op signature;
   `vb2_get_num_buffers()`; `platform_driver.remove` returns void; `MODULE_IMPORT_NS(DMA_BUF)`;
   `dma_buf_vmap` with `iosys_map`.
5. **32-bit callers**: 6.12's compat layer drops `v4l2_plane.reserved[]` (where this dialect
   carries extradata fd/offset etc.); redwood's shim keeps the words per queue/buffer/plane
   around QBUF/DQBUF (`msm_v4l2_vidc.c`). 64-bit callers are untouched.
6. **Bitrate-mode menu (found here, not in redwood)**: `V4L2_CID_MPEG_VIDEO_BITRATE_MODE` is a
   standard control registered with the core's menu, but the msm values go to 5
   (VBR 0, CBR 1, CBR_VFR 2, MBR 3, MBR_VFR 4, CQ 5). 6.12's core menu is {VBR, CBR, CQ, NULL} and
   the core indexes it with the value on every set: value 3 dereferences NULL, 4 and 5 read past
   the array. Now registered through `v4l2_ctrl_new_custom()` with the driver's own menu; id,
   values and range are unchanged for userspace.
   6.12 also has its own `V4L2_MPEG_VIDEO_BITRATE_MODE_CQ` (= 2); the msm enumerator is renamed
   `..._MSM_CQ` in the kernel copy of the header and **keeps the value 5**.
7. One-element arrays at the end of HFI packets get a flexible-array alias (`*_flex`) and
   `UBSAN_SANITIZE := n`, `-D__NO_FORTIFY` for the packet builder: GKI's bounds traps would panic.
8. Small API: `strlcpy`->`strscpy`, `of_property_present`, `devm_ioremap`, `iommu_map(..., GFP_KERNEL)`,
   `platform_get_irq`, `linux/firmware/qcom/qcom_scm.h`, `fallthrough`, `__kernel_old_timeval`,
   debugfs creators return void, `iommu_dma_enable_best_fit_algo` dropped (gone), trace include path.
9. Not taken from redwood on purpose: their removal of the debug-bridge LPI ack wait in
   `hfi_iris2.c` power-off (Samsung's 5.4 code kept; it only logs on timeout), and their
   early SELinux relabel of `sku_version` (Xiaomi init-script problem). Revisit both if seen.

msm_bus: nothing to do, this driver generation already uses the interconnect framework
(`of_icc_get`, `icc_set_bw`). Clocks/GDSC: plain clk + regulator consumers, unchanged.
CVP/eva: no code dependency in this tree (the yupik platform data has no CVP path); `/dev/cvp` not needed.

## Userspace contract
Kept (checked by compiling the same probe against 5.4 and 6.12 headers: all 281 `V4L2_*`/`VIDIOC_*`
values and ioctl numbers the driver uses are identical for 64-bit): `/dev/video32`, `/dev/video33`,
all private controls `V4L2_CID_MPEG_VIDC_*`, private events, pixel formats, extradata, `msm_media_info.h`
buffer math, sysfs `sku_version`, `thermal_level`, `pwr_collapse_delay`, `link_name`, debugfs `msm_vidc`.
Changed: `/dev/subsys_venus` is gone (kernel-internal on 5.4; check no init script touches it).
Not verified: 32-bit ioctl path on this phone's blobs (which processes are 32-bit), secure playback.

## Device tree
`a52sxq-video.dtsi`, values from `downstream-dt/a52sxq-r02.dts` (`/soc/qcom,vidc`, identical on hardware
revisions 3 and 4: Samsung's dts sources do not touch it). Compiled as an overlay and applied to
`bsp612/out/dist/dtb/yupik.dtb` with `fdtoverlay`: all labels resolve (videocc, both GDSCs, apps_smmu,
gem_noc/cnoc2/mmss_noc/mc_virt). Clock and interconnect ids are numerically the same as on 5.4.
**Nodes of the 6.12 base to disable: none** (the base has no msm-vidc/iris/venus node for yupik).
Adds `pil_video_mem` (0x8b200000, 5 MiB, no-map; where 5.4 loaded venus, free in the base map).

## Load order
`qcom-scm`, `smem`, `llcc-qcom`, `mdt_loader` (modinfo `depends`), plus at run time: `videocc-sc7280`,
the gdsc regulator driver, `arm_smmu`, the yupik interconnect provider, the qcom DMA-BUF heaps
(`qcom_dma_heaps`), then `msm-vidc.ko`. Firmware: `vpu20_1v.mdt` + `.b00..b10,.b19` in
`/vendor/firmware_mnt/image` (present in the vendor firmware list); the kernel needs
`firmware_class.path=/vendor/firmware_mnt/image` (as on 5.4) or the files in the test ramdisk's
`/lib/firmware`.

## First on-device test (test ramdisk, as shell commands)
    insmod /extra/msm-vidc.ko
    dmesg | grep -i -E 'vidc|venus'
    ls -l /dev/video32 /dev/video33
    cat /sys/devices/platform/soc/aa00000.qcom,vidc/sku_version
    cat /sys/kernel/debug/msm_vidc/core0/info        # ddr_type etc.
    # firmware boot is lazy (first open): put vpu20_1v.* into /lib/firmware, then
    exec 3<>/dev/video32; sleep 1; exec 3>&-
    dmesg | grep -E 'venus up from|loading|SFR|Failed'
Expected: probe without error, four context banks listed (`venus_ns`, `venus_sec_non_pixel`,
`venus_sec_bitstream`, `venus_sec_pixel`), on first open `venus up from vpu20_1v.mdt` and the
firmware version string. Under Android: `dumpsys media.player`/a local H.264 file in the gallery,
then camera recording (encoder), then Widevine L1 (secure).

## Likely failure modes
- Probe defers forever: a supplier missing (videocc, GDSC, smmu, interconnect).
- `no memory-region for the venus firmware` / PAS auth fails (-22): region not at 0x8b200000,
  overlaps another reservation, or the firmware files are not the phone's signed ones.
- Context bank gets no IOMMU domain or the wrong IOVA window (`iommu-addresses` regions): first
  decode faults or the firmware rejects buffer addresses. The driver needs addresses inside
  `virtual-addr-pool` (firmware uses 32-bit device addresses).
- `DMA_ATTR_DELAYED_UNMAP` not honoured (needs `msm_dma_iommu_mapping` semantics in the BSP): each
  QBUF maps at a new IOVA, reference frames are never released, playback starves.
- Garbage frames: cache flags of imported buffers wrong (exporter name not one of the expected).
- Secure decode: the 6.12 BSP registers only `qcom,secure-pixel` and `qcom,secure-non-pixel`;
  `qcom,secure-bitstream` (VMID 9) does not exist yet (ioncompat README, "backing heaps" item 1).
  Until it does, secure sessions fail at the first internal buffer with `No qcom,secure-bitstream heap`.
- Encoder PERSIST buffers use `qcom,secure-non-pixel` even in non-secure sessions (as on 5.4).
- Suspend with a session open, SSR after a firmware crash: untested paths (PAS shutdown + reload).
- Debug-bridge LPI wait logs `DBLP Set: status` on every power collapse (see change 9).
