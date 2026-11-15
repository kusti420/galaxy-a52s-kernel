# drivers612/camera: A52s camera kernel driver on the Qualcomm 6.12 BSP

State 2026-11-11: `camera.ko` builds against `bsp612/out/lahaina` with 0 errors, 0 warnings,
modpost and depmod clean. Never loaded on hardware.

## Base decision: B, the phone's own 5.4 Samsung techpack, forward-ported

Compared: Samsung 5.4 `$ANDROID_TREE/kernel/samsung/sm7325/techpack/camera` (S) against
Qualcomm 6.12 `donors/camera-kernel` @ camera-kernel.lnx.4.4.r1-rel (Q).

- Q is the same code generation as S (both camera-kernel.lnx.4.x): 440 vs 481 `.c/.h` files,
  436 common paths, 209 common files differ, identical `yupikcamera.conf`. So Q is not a newer
  driver, it is the same driver with Qualcomm's own kernel-version branches.
- Samsung's delta is large and all in the sensor module: 45 Samsung-only files (about 30k lines:
  `cam_sysfs_init.c` 4,988 = all of `/sys/class/camera`, `cam_ois_mcu_stm32g.c` 4,157,
  `cam_sensor_retention.h`, OTP/eeprom tables, adaptive-MIPI tables) plus 9,282 changed/added
  lines in common `cam_sensor_module` files, behind 631 Samsung `#if` sites in 31 files.
- UAPI, `include/uapi/camera/media/*.h` byte for byte (17 headers): 5 identical; 11 differ only
  by Q's include path (`<media/..>` vs `<camera/media/..>`), a copyright line and additions
  (`cam_req_mgr.h`: `ALLOC_BUF_V2`/`MAP_BUF_V2` opcodes + structs, additive). ONE header is
  incompatible: `cam_sensor.h`. Samsung inserted fields inside existing structs
  (`gyro_raw_x/y/z` + `efs_cal`, 16 bytes; `version_id`; `__u16 shooting_mode`) and added
  `struct cam_sensor_release_dev`. Q does not have them, so with base A every later field of
  those structs sits at a different offset than the Samsung HAL/CamX blobs write.
- The headers the blobs were built with were not found in the vendor tree (searched
  `vendor/samsung/{a52sxq,sm7325-common}` and `device/samsung` for `cam_sensor.h`,
  `cam_req_mgr.h`); the phone's kernel techpack headers are the best available stand-in.

Conclusion: A would need Samsung's ~40k lines re-applied on top and still ends at the same
code; B keeps struct layouts, sysfs and Samsung sensor/OIS/eeprom/flash handling by
construction, and its 5.4 -> 6.12 API delta turned out small (64 files touched, 1,685 diff
lines, all generated). Q stays useful as the reference for how Qualcomm itself ported each
call (`donors/camera-kernel/drivers/cam_utils/cam_compat.c`).

## What is here
| Path | What |
|---|---|
| `port.sh` | regenerates `work/` from the read-only Samsung source and builds. `./port.sh build` rebuilds without regenerating |
| `port612.py` | every source edit (regex rules + anchored edits); aborts if a mandatory anchor is missing |
| `compat/cam_compat_612.h` | force-included API shims (strlcpy, timeval, of_gpio, icc, dma_buf vmap, WLED, no_log accessors) |
| `compat/a52sxq_camera_conf.h` | the phone's camera `CONFIG_*` set from `lineage-a52sxq_defconfig` |
| `compat/linux/qcom_scm.h`, `compat/linux/mfd/sm/sm5714/sm5714.h`, `compat/dt-bindings/msm/msm-camera.h` | headers that moved or are missing on 6.12 |
| `compat/ioncompat-include/` | copy of `modules/ioncompat/include` (in-kernel `ion_alloc` face) |
| `Kbuild.tail` | appended to the Samsung Makefile: include paths, `UBSAN_SANITIZE := n`, `-D__NO_FORTIFY`, warning switches (each with its reason) |
| `deps/ioncompat/` | copy of `modules/ioncompat` built for 6.12 (only change: `MODULE_IMPORT_NS(DMA_BUF)` unquoted, 6.12 syntax) |
| `deps/sm5714-fled-stub/` | stand-in exporting `sm5714_fled_mode_ctrl/sm5714_store/sm5714_show` for bring-up without the SM5714 stack |
| `patches/port612-generated.diff` | the complete diff Samsung source -> `work/drivers` (record of every donor change) |
| `a52sxq-camera.dtsi`, `DT-NOTES.md`, `dt-work/` | device tree fragment, its generator and notes |
| `work/` | generated tree and build output (`work/drivers/camera.ko`, 30 MB with debug info, 6 MB stripped) |

## Build
    ./port.sh            # regenerate + build; prints error count, log in build.log
Uses clang r547379, `O=bsp612/out/lahaina`, symvers: soc-repo-staging/build, deps/ioncompat,
deps/sm5714-fled-stub (override with `FLED_SYMVERS=<power agent's Module.symvers>`).
Build the two deps first if their `Module.symvers` is missing (same `make ... M=deps/<x>`).

## What the port changes, and why
Mechanical (port612.py): `.remove` returns void; i2c `.probe` single argument;
`class_create()` one argument; debugfs_create_* return void; `struct timespec` -> `timespec64`;
`dma_buf_(un)map_attachment` -> `_unlocked`; `dma_buf_vmap` via iosys_map; `iommu_map(_sg)` gfp
argument; list_sort const comparator; `#undef pr_fmt`; trace header path + one-argument
`__assign_str`; `MODULE_IMPORT_NS(DMA_BUF)`.
Behavioural (each anchored, listed in the script with its reason):
1. interconnect: `icc_get(dev, src, dst)` -> path from the DT node the ids came from.
2. cam_smmu: `iommu_dma_enable_best_fit_algo`, `iommu_dma_reserve_iova` and
   `DOMAIN_ATTR_FAULT_MODEL_*` removed -> moved to the DT (`iommu-addresses`,
   `qcom,iommu-faults`; see DT-NOTES.md).
3. cam_smmu: `iommu_map_sg()` gets `orig_nents` (redwood: with the merged count only the first
   64 KB of the 1 MB secheap was mapped).
4. IRQ: `platform_get_irq_byname()` wrapped in a resource (DT devices have no IRQ resources).
5. CAM_REQ_MGR_CACHE_OPS: always syncs. 5.4 asked ION for `ION_FLAG_CACHED` through the
   dma_buf `get_flags` op; no 6.12 heap implements it, so every cache sync would have become a
   silent no-op (stale frames). Same as Qualcomm's 6.12 driver.
6. ION: `ion_alloc()` kept, served by ioncompat (heap policy in one place with `/dev/ion`).
Not ported, off: `CONFIG_MSM_GLOBAL_SYNX` (no synx driver in the 6.12 BSP), `CONFIG_SEC_ABC`,
`CONFIG_SEC_PM`, `CONFIG_ADSP_FACTORY` (OIS gyro self-test through the ADSP factory driver),
`CONFIG_QCOM_CX_IPEAK`.

Donor bugs the 6.12 compiler reports (left as on 5.4, warnings switched off for them):
`cam_ife_csid_core.c:378` condition always true; `cam_sensor_util.c:371` and
`cam_res_mgr.c:256` log lines with more `%` than arguments; several hundred `%d`-for-`size_t`
log formats.

## Userspace contract
Kept by construction (same source, same UAPI headers, no UAPI file touched):
`/dev/video0` `cam-req-mgr`, `/dev/video1` `cam_sync`, 24 `/dev/v4l-subdev*`, `/dev/media0/1`,
the multiplexed `VIDIOC_CAM_CONTROL` ioctl with all opcodes and struct layouts incl. Samsung's
`cam_sensor.h` fields, V4L2 private events, `/sys/class/camera/{rear,front,flash,ois,af,ssm,dual}`,
`/sys/devices/svc/Camera`.
Changed: nothing on purpose. `CACHE_OPS` now also syncs uncached buffers (harmless).
Could not verify: (a) `/dev/synx_device` is absent on 6.12 (5.4 had synx built in and cam_sync
registered with it; the blob inventory saw the node unopened at idle); (b) video node NUMBERS
depend on load order: on 5.4 camera took video0/1 before vidc's video32/33; (c) 32-bit compat
ioctl path untested; (d) Samsung `ABC` error uevents are not sent (`SEC_ABC` off).

## Load order (first on-device test)
Prerequisites from the BSP (modprobe resolves them; `modules.dep` line was checked with depmod):
clk-qcom, clk-rpmh, gdsc-regulator, **camcc-sc7280** (the camera GDSCs defer without it),
pinctrl-yupik, qnoc-yupik, arm_smmu, qcom_iommu_util, qcom-scm, secure_buffer, mem_buf*,
qcom_dma_heaps, msm_dma_iommu_mapping, leds-qti-flash (+ its qti-battery-charger/pmic_glink
chain; inert on this phone). Plus the S2MPB03 regulator driver (drivers612/power) and the DT
with `a52sxq-camera.dtsi` applied.

    insmod ioncompat.ko
    insmod leds-sm5714-fled.ko        # real driver (drivers612/power, after pdic_sm5714); the stub only without the power stack, never both
    insmod camera.ko
    # ICP firmware: Android's ueventd serves /vendor/firmware/CAMERA_ICP_170.elf; in the test
    # ramdisk set  echo -n /vendor/firmware > /sys/module/firmware_class/parameters/path  first

Must be true BEFORE the camera provider (`vendor.qti.camera.provider` / Samsung unihal) starts:

    cat /sys/class/video4linux/video*/name      # cam-req-mgr and cam_sync (video0, video1)
    cat /sys/class/video4linux/v4l-subdev*/name | sort | uniq -c
    #  1 cam-cpas, 1 cam-isp, 5 cam-csiphy-driver, 1 cam-actuator-driver, 6 cam-sensor-driver,
    #  5 cam-eeprom, 1 cam-flash-dev, 1 cam-icp, 1 cam-jpeg, 1 cam-lrme, 1 cam-ois  = 24
    ls /dev/media0 /dev/media1
    ls /sys/class/camera                        # rear front flash ois af ssm dual
    ls /sys/class/camera/*/ | wc -l             # 154 attributes on 5.4
    ls /sys/devices/svc/Camera
    dmesg | grep -E 'CAM_(ERR|WARN)|camera|cam_smmu|cpas'

Expected log lines: `CAM_INFO: CAM-CRM: ... All probes done, binding slave components`, then
`component_bind_all` success for each sub-driver, `CAM_INFO: CAM-SMMU: ... force_cache_allocs=`,
`[SVC] Success to create sys/devices/svc`. Sensors are probed later by CamX (`CAM_SENSOR_PROBE_CMD`),
so no sensor I2C traffic is expected before the provider starts.

Likely failure modes, in the order they would show:
1. camera.ko probe deferral forever: one component missing (a GDSC/clock/regulator supply name
   not resolvable, most likely an S2MPB03 rail or camcc not loaded). The component master only
   binds when ALL nodes probed: `cat /sys/kernel/debug/devices_deferred`.
2. `Get shared gpio`/pinctrl errors: pin state labels (20 added under &tlmm).
3. cam_smmu: `iommu-addresses` not honoured -> IOVA collisions when ICP maps firmware/shared
   regions (`IOMMU mapping failed`), or context-bank faults.
4. CPAS: interconnect path lookup (`cam_icc_get_np`) returns an error -> `cam_cpas` probe fails.
5. ICP: `CAMERA_ICP_170.elf` not found / `pil_camera_mem` not reserved -> preview never starts.
6. A UBSAN/CFI trap in an untested path (kCFI is on; no function-pointer casts were found with
   `-Wcast-function-type-strict`, UBSAN is off for the module).
7. Flash/torch do nothing with the stub.
