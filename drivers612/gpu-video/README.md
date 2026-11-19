# gpu-video: KGSL (Adreno 642L) and msm_vidc v1 for the A52s on the 6.12 BSP

Two independent parts. Nothing here was ever loaded on a phone; everything is compile-checked
against `bsp612/out/lahaina` (GKI 6.12.81 + soc-repo r70) only.

| part | dir | result |
|---|---|---|
| A. GPU | `gpu/` | `gpu/src/msm_kgsl.ko` builds, 0 warnings, 0 unresolved symbols |
| B. Video codec | `video/` | see `video/README.md` and `video/STATUS.md` |
| shared | `tools/dtcmp.py` | compares nodes of two dtbs with phandles resolved |

---------------------------------------------------------------------------------------------

## A. GPU (`gpu/`)

### What is there
- `prepare.sh`: recreates `src/` from `donors/graphics-kernel` (tag
  GRAPHICS.LA.16.1.r2-04700-LAHAINA.0, commit 1418e58) and applies `patches/`.
- `build.sh`: `M=` build against the shared BSP output (reads `bsp612/` only), then lists
  undefined symbols that nobody exports (must be empty) and the modules it depends on.
  `KGSL_RECLAIM=y ./build.sh` builds Qualcomm's 6.12 lahaina allocator choice instead (below).
- `patches/` (every change to donor code):
  1. `0001` Kbuild: soc-repo headers first (`SOCINCLUDE`), `config/gki_a52sxq.conf` for
     lahaina/yupik. The donor tag has no `gki_*.conf` for this target. Values are the phone's
     5.4 defconfig (idle timeout 80, context debug, IO-coherency default, `msm-adreno-tz`).
     Allocator: page pools as on 5.4 (the phone's DT has `qcom,gpu-mempools`; 5.4 has no shmem
     or process reclaim). Qualcomm's own 6.12 lahaina fragment uses shmem + process reclaim
     without pools; that is the `KGSL_RECLAIM=y` variant (also builds clean).
  2. `0002` `governor_msm_adreno_tz.c`: `#include <linux/of.h>` (build fix).
  3. `0003` 5.4 copy semantics for old libgsl (below).
  4. `0004` `/sys/kernel/gpu/gpu_governor` and `gpu_available_governor` (below).
  5. `0005` `kgsl_pool.c`: parse `qcom,gpu-mempool` children in ascending
     `qcom,mempool-page-size` order. The 6.x board tree lists them @3..@0, and the pool
     fallback needs ascending order (reversed: -ENOMEM on a fragmented phone, black UI).
  6. `0006` `kgsl.c`: the `A52_KGSL_ERRNO_DEBUG` errno hunks (off by default).
  7. `0007` `kgsl_pwrctrl.c`: the PM QoS max-frequency notifier picks the fastest level at or
     below the limit (5 MHz slack) instead of needing a match within 5 MHz. Before, a devfreq
     `max_freq` write of 450 MHz followed by 560 MHz or the default left the GPU capped.
  `src/` must always equal donor + `patches/`: a change made only in `src/` is lost by the
  next `./prepare.sh`.
- `a52sxq-gpu.dtsi` + `dt-verify.sh` (below). `uapi-compare/` (below). `test/` on-device test.

### Build
    cd drivers612/gpu-video/gpu && ./prepare.sh && ./build.sh        # ~20 s
    (cd test && make)                                                # kgsltest64, kgsltest32
    ./dt-verify.sh                                                   # DT fragment vs phone
    ./uapi-compare/compare.sh                                        # UAPI header vs phone

### UAPI: donor header vs the phone's 5.4 header (`uapi-compare/report.txt`)
Compiled both `msm_kgsl.h` for aarch64 and for armv7 and compared every `IOCTL_KGSL_*` value
and every struct size: **all 62 ioctls and all 93 structs of the 5.4 header are identical in
the donor, 64-bit and 32-bit.** The donor only adds (4 ioctls: GET_FAULT_REPORT,
GPUMEM_BIND_RANGES, READ_CALIBRATED_TIMESTAMPS, RECURRING_COMMAND; 10 structs; props
0x2B-0x33; context flags LPAC/FAULT_INFO; `KGSL_MEMFLAGS_VBO` bits 34/35; perfcounter groups
0x2b-0x38). The 16 `*_COMPAT` ioctl definitions of `kgsl_compat.h` are textually identical, and
the ioctl dispatch tables (native, compat, adreno) contain every 5.4 entry, the sparse ioctls
included (the 5.4 kernel on this phone is already the "new" kgsl with timelines and VBO-less
sparse stubs, so nothing the blobs call was removed). `KGSL_VERSION` is 3.14 in both.

### Behaviour differences 5.4 -> 16.1 that old libgsl can trip over
1. **List sizes (redwood's claim: verified against the 5.4 source, fixed more widely).**
   5.4 copies variable-size user structs with `kgsl_copy_from_user()` = copy
   `min(kernel size, user size)`, ignore the rest (`kgsl.h:601`), and steps through
   cmdlist/memlist/synclist by `sizeof(kernel struct)`. The donor uses
   `copy_struct_from_user()`, which fails when user size > kernel size and the extra bytes are
   not zero. A libgsl that passes the size of the whole list as `cmdsize`/`objsize`/`syncsize`
   (redwood saw 64 for two 32-byte objects) therefore gets `-EFAULT` on every multi-entry
   `IOCTL_KGSL_GPU_COMMAND`. Whether the A52s libgsl does this was NOT checked in the blob
   (no disassembly); 5.4 semantics are strictly more permissive, so restoring them is safe.
   Patch 0003 adds `kgsl_copy_from_user_compat54()` and uses it at **all seven** places where
   5.4 used `kgsl_copy_from_user()` and the donor uses `copy_struct_from_user()`: cmdlist,
   memlist, synclist (the three redwood patched) plus `GPUOBJ_FREE` on-event (timestamp event
   and fence event), `GPUOBJ_IMPORT` dma-buf descriptor, and `GPUOBJ_SYNC` object list.
   Places where 5.4 itself already used `copy_struct_from_user()` (timeline ioctls,
   aux commands, sync-point timelines) are unchanged.
2. **Imported dma-bufs, cache mode.** 5.4 asked ION (`dma_buf_get_flags`, `ION_FLAG_CACHED`)
   and treated uncached ION buffers as uncached. The donor treats every imported dma-buf as
   cached (write-back) + IO-coherent. Not changed. Only matters for `system-uncached` buffers.
3. **Imported secure dma-bufs.** 5.4 trusted the ION secure flag. The donor checks the VMID
   list of the buffer through `mem_buf_dma_buf_copy_vmperm()`: a buffer imported with
   `KGSL_MEMFLAGS_SECURE` must be assigned to `VMID_CP_PIXEL` and vice versa, else `-EPERM`.
   This only knows buffers from Qualcomm's mem-buf based heaps. For buffers of any other heap
   it logs "Skipped access check" and accepts. Consequence for `modules/ioncompat`: secure
   video/display output must come from the soc-repo heap `qcom,secure-pixel` (as its heap
   table already says); a home-made secure heap without mem-buf VMID bookkeeping would be
   mapped without the check. KGSL's own secure allocations use `hyp_assign_table()`
   (`secure_buffer.ko`), no ION involved.
4. **Zap shader.** 5.4: PIL (`subsys_a660_zap`, node `qcom,kgsl-hyp`). Donor: loads
   `a660_zap.mdt` itself (`request_firmware` + `qcom_mdt_load` + `qcom_scm_pas_auth_and_reset`,
   PAS id 13) into the `zap-shader` child's memory region. `/dev/subsys_a660_zap` and
   `/sys/class/subsys/subsys_a660_zap` are gone (blob inventory: only ramdump/SSR daemons list
   them; libgsl does not).
5. **sysfs.** `/sys/class/kgsl/kgsl-3d0`: every 5.4 attribute exists in the donor except
   `ft_long_ib_detect` (tuning). 22 new ones. `/sys/kernel/gpu`: the phone has 9 entries; the
   donor has 7, missing the `gpu_governor` and `gpu_available_governor` links (5.4 creates
   them only when kgsl is built in). Patch 0004 adds both names as attributes that forward
   to the devfreq device's `governor` / `available_governors` files.
6. Same in both: a642l core entry (features, `gmu_major/minor`, prim fifo, protected regs),
   `KGSL_PROP_*` handlers, `gpumem` flag masks, PWRCTRL property, perfcounter ioctls, sync and
   timeline fences. `KGSL_PROP_PWRCTRL`-style size checks are unchanged.
7. Not compared line by line (too large for this session): dispatcher/fault-recovery timing,
   preemption, IFPC, snapshot format, GMU HFI message set (see risks).

### Firmware (checked against the vendor firmware lists)
| file | driver asks for | where it is on the phone |
|---|---|---|
| `a660_sqe.fw` | same name as 5.4 | `/vendor/firmware` (40496 bytes) |
| `a660_gmu.bin` | same name as 5.4 | `/vendor/firmware` (55256 bytes) |
| `a660_zap.mdt` + `.b00-.b02` | **`a660_zap.mdt`** (5.4 PIL asked for `a660_zap`) | firmware partition, `/vendor/firmware_mnt/image` |

The zap is now a plain `request_firmware()`: the directory `/vendor/firmware_mnt/image` must
be in the firmware search path (Android: `firmware_directories` in the vendor `ueventd.rc`;
test ramdisk: copy all six files into `/lib/firmware`).

### Device tree: `gpu/a52sxq-gpu.dtsi`
The 6.12 yupik base has **only an empty stub** for the GPU
(`msm_gpu: qcom,kgsl-3d0@3d00000 { #cooling-cells = <2>; }`): no reg, clocks, power levels,
no GMU node, no `qcom,kgsl-iommu`. Qualcomm keeps those in a separate graphics-devicetree
project. Present in the base and reused: `kgsl_smmu`, `gpucc`, `gpu_cx_gdsc`, `gpu_gx_gdsc`,
qfprom cells `gpu_speed_bin`/`gpu_gaming_bin`/`gpu_model_bin` (same reg/bits as the phone),
`pil_gpu_micro_code_mem`, thermal zones `gpuss-0`/`gpuss-1` with `gpu_cdev` maps.

The fragment supplies the complete `&msm_gpu`, `qcom,kgsl-iommu@3da0000` (3 context banks:
SID 0 user, 1 LPAC, 2 secure, mask 0x400) and `qcom,gmu@3d69000` (SID 5). `./dt-verify.sh`
applies it on `yupik.dtb` and compares with the tree the phone boots (`a52sxq-r02.dts`):
**335 properties identical** (all registers, IRQs 300/304/305, chip id 0x06030500, both DDR
bus tables, 5 speed bins 0/172/117/96/129 with every power level, bus index and ACD level,
4 mempools, iommu SIDs, GMU clocks/supplies, the zap region). Differences, all deliberate
and listed in the file header: zap-shader child instead of the PIL node; `apb_pclk` from
`&aoss_qmp`; thermal zone names without `-usr`; `qcom,no-nap`, `l3_path`, `kgsl-ddr-qos`
dropped (not parsed by the 6.12 driver, no L3 provider in the base); GMU reg window
0x3d69000/0x35000 (6.12) vs 0x3d6a000/0x34000; one extra Qualcomm speed bin (148) that the
phone's 5.4 table does not have (inert unless the fuse reads 148). gcc clock numbers differ
only because `qcom,gcc-sc7280.h` numbers them differently from 5.4's `qcom,gcc-yupik.h`.

Samsung overrides nothing inside the GPU node in any revision (r00-r02 sources; hardware
revisions 3 and 4 boot the r02 overlay). The Samsung overlay only adds three cooling maps that
point at `&msm_gpu` (`pm8350c-bcl-lvl1/vph_gpu`, `pm7325_tz/pm7325_gpu`,
`pm8350c_tz/pm8350c_gpu`); they belong to the thermal fragment. No regulator voltage appears
in the GPU nodes (GDSCs and RPMh corners only).

### Load order
`msm_kgsl.ko` depends on (modinfo): `msm_sysstats, mem_buf_dev, qcom_iommu_util, clk-qcom,
qcom-dcvs, qcom-scm, secure_buffer, mdt_loader, minidump, qcom_va_minidump, socinfo, llcc-qcom,
cmd-db, msm_performance, qcom_aoss`. Also needed before the GPU can power up (probe defers
otherwise): `gcc`, `gpucc-sc7280`, `gdsc-regulator`, `arm_smmu` (for `kgsl_smmu`), `icc-rpmh` +
`qnoc-yupik`, rpmh regulators. BRINGUP.md keeps `gpucc` out of the first-stage ramdisk; load
it right before `msm_kgsl`.

**Do NOT load soc-repo's `governor_msm_adreno_tz.ko` and `governor_gpubw_mon.ko`.** The
techpack has its own copies inside `msm_kgsl.ko` and registers governors with the same names;
if the soc-repo ones are loaded first, `devfreq_add_governor()` fails and kgsl runs without
power scaling ("Failed to add adreno tz governor" / "Failed to add busmon governor").

### First on-device test (test ramdisk, as root; never run by this agent)
    # firmware: a660_sqe.fw a660_gmu.bin a660_zap.mdt a660_zap.b00 .b01 .b02 in /lib/firmware
    modprobe gpucc-sc7280; modprobe msm_kgsl        # or insmod in the order above
    ls -l /dev/kgsl-3d0
    cat /sys/class/kgsl/kgsl-3d0/gpu_model          # want: Adreno642Lv1
    cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies   # want the fuse's bin, e.g. 812000000 ... 315000000
    ls /sys/kernel/gpu                              # want 9 entries incl. gpu_governor
    /extra/kgsltest64; /extra/kgsltest32            # want "kgsltest: 0 failed"
    dmesg | grep -iE 'kgsl|adreno|gmu|zap|a6xx'
`kgsltest` (static, nolibc, built from the phone's own 5.4 header) opens the node, reads
version (3.14) and chip id (0x060305xx), creates a GL-style context (this powers the GPU up:
GMU + SQE + zap), allocates and maps a buffer, submits NOP command buffers and waits for
retire, the last one with the old-libgsl "list size as entry size" convention.
Then, with Android: `dumpsys SurfaceFlinger | grep GLES` (want "Adreno (TM) 642L").

Failure modes to expect, by message:
- `zap-shader node not found` / `Couldn't load the firmware a660_zap.mdt`: DT fragment not
  applied / firmware path. Secure-mode exit then fails and the first context create hangs/faults.
- probe deferral forever: `gpucc`, GDSC or `kgsl_smmu` not up (`cat /sys/kernel/debug/devices_deferred`).
- GMU boot/HFI timeout on first power-up: GMU firmware vs driver mismatch (risk 1), or the GMU
  reg window (try the 5.4 window, see dtsi header).
- `GPU_COMMAND ... LIST size as cmdsize` failing with errno 14: patch 0003 not in the module.
- `Skipped access check` once per imported non-mem-buf dma-buf: informational.

### Userspace contract
Kept: `/dev/kgsl-3d0`; all 62 ioctls + 16 compat variants with identical numbers and struct
layouts; 5.4 copy semantics for sized structs; `/sys/class/kgsl/kgsl-3d0/*` (all but
`ft_long_ib_detect`); `/sys/kernel/gpu/*` all 9 names; devfreq nodes `3d00000.qcom,kgsl-3d0`
and `kgsl-busmon`; firmware names of SQE/GMU.
Changed: zap loaded without PIL (no `subsys_a660_zap` nodes); thermal zone names; imported
dma-bufs always cached; secure import checked by VMID.
Not verifiable offline: that the phone's libgsl/GLES/Vulkan blobs accept everything the newer
driver answers (property values such as `KGSL_PROP_UBWC_MODE`, `HIGHEST_BANK_BIT`, speed bin are
the same code paths and DT values); GMU firmware compatibility; `/sys/class/kgsl/kgsl/proc/*`
layout users (perf XML only).

### Risks (GPU)
1. The phone's 2021-2025 `a660_gmu.bin` with a 2025 driver: `gmu_major/minor` requirements are
   the same as 5.4, but the driver may send HFI messages the old firmware does not know.
   redwood reports the same combination working on another SM7325 (read, not verified).
2. Whole GPU device tree is new on this base; values are proven equal to the phone's, but
   `gpucc`/GDSC/`kgsl_smmu` bring-up on the 6.12 base has never run (GDSC parent supplies are
   BRINGUP.md's topic).
3. Secure playback path (CP_PIXEL) depends on which heap `ioncompat` hands out (difference 3).

---------------------------------------------------------------------------------------------

## B. Video codec (`video/`)
See `video/README.md` (what is there, build, load order, first test) and `video/STATUS.md`.
