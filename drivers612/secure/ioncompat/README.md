# ioncompat for the Qualcomm 6.12 BSP: the 5.4 msm ION ABI on qcom_dma_heaps, with secure heaps

Port of `modules/ioncompat` (written for ACK 6.18, verified on hardware there for the system and
CMA heaps) to `bsp612` (GKI 6.12.81 + soc-repo r70). Same `/dev/ion` ABI and same heap-walking
logic; what changed is what stands behind the heap table: Qualcomm's `qcom_dma_heaps` and
`mem_buf`, so the secure cases that were `-ENODEV` on 6.18 have memory here.

State: **builds** (`-Werror`, `W=1`, no modpost errors, every undefined symbol resolved against
vmlinux, `mem_buf_dev` or `secure_buffer`). **Never loaded on 6.12.** The DT fragment applies to
`bsp612/out/dist/dtb/yupik.dtb` with `fdtoverlay` (checked offline), not booted.

## Files

| file | what |
|---|---|
| `ioncompat.c` | the module (`/dev/ion`, `ion_alloc()`, msm_ion helpers, VMID query) |
| `include/uapi/linux/{ion,msm_ion,msm_ion_ids}.h` | byte-identical 5.4 UAPI headers |
| `include/linux/{ion,msm_ion}.h` | in-kernel face for forward-ported 5.4 drivers |
| `Kbuild`, `build.sh` | build against `bsp612/out/lahaina` (reads bsp612 only) |
| `a52sxq-dma-heaps.dtsi` | overlay fragment: region sizes of the phone, heaps to disable |
| `test/` | `abi_check.c` (static asserts, 64/32-bit), `iontest.c` (static nolibc; `build/iontest64`, `build/iontest32`) |

## Build

    ./build.sh            # ioncompat.ko + list of undefined symbols and their providers
    make -C test          # ABI check + iontest64/iontest32

`build.sh` is the brief's `M=` method with `KBUILD_EXTRA_SYMBOLS=bsp612/soc-repo-staging/build/Module.symvers`
and `SOCINCLUDE=-I soc-repo-staging/include{,/uapi}`. `Kbuild` puts this directory's `include/`
**before** the soc-repo headers: soc-repo ships its own, different `linux/ion.h` / `linux/msm_ion.h`.

Changes against `modules/ioncompat` (all in `ioncompat.c`, `include/linux/msm_ion.h`, `Kbuild`,
`test/`):
- heap names `system`/`system-uncached` -> `qcom,system`/`qcom,system-uncached` (uncached falls
  back to cached if that heap is not built);
- secure heaps: new `lend_from` path (below), VMIDs from the BSP's `soc/qcom/secure_buffer.h`
  with a `BUILD_BUG_ON` that they equal the 5.4 values, permissions from
  `msm_secure_get_vmid_perms()`;
- new exports `ion_compat_dma_buf_get_flags()`, `ion_compat_dma_buf_vmids()`,
  `ion_compat_dma_buf_is_secure()`;
- `MODULE_IMPORT_NS(DMA_BUF)` without quotes (6.12 syntax), `MODULE_SOFTDEP("pre: qcom_dma_heaps mem_buf_dev")`;
- a one-time warning when a contiguous heap is served from the default CMA area;
- test: Makefile paths, stub headers for the 6.12 nolibc (`test/nolibc612/`), secure cases.

## Load order and dependencies

    secure_buffer.ko  ->  mem_buf_dev.ko  ->  qcom_dma_heaps.ko (probes "qcom,dma-heaps")  ->  ioncompat.ko

Hard symbol dependencies (modinfo `depends`): `secure_buffer`, `mem_buf_dev`. `qcom_dma_heaps` is
a soft dependency: heaps are looked up by name at allocation time, so ioncompat loads without it
and answers `-ENODEV` until the heaps exist. For Android first stage: ioncompat goes into
`modules.load` after `qcom_dma_heaps`; it must be up before `qseecomd`, the allocator HAL and
keymaster/gatekeeper start, i.e. first stage (vendor_boot/vendor_dlkm), not late.

Device node: misc `ion`, dynamic minor, mode 0664. The vendor `ueventd.rc` line
(`/dev/ion 0664 system system`) and the `ion_device` SELinux label match on the name, so nothing
changes there. `/dev/dma_heap/*` nodes also appear on 6.12; the 5.4 vendor policy has no rules
for them and no blob opens them.

## Heap table on 6.12 (5.4 id + flags -> Qualcomm heap)

Heap ids are the phone's (`msm_ion_ids.h`, DT `qcom,ion-heap@N reg`): the id is the bit number.

| 5.4 id (mask) | 5.4 name / type | flags | 6.12 heap | how |
|---|---|---|---|---|
| 25 (0x2000000) | system / MSM_SYSTEM | `ION_FLAG_CACHED` | `qcom,system` | direct |
| 25 | | none | `qcom,system-uncached`, else `qcom,system` | direct |
| 25 | | any secure/CP flag | - | `-EINVAL` as 5.4 |
| 10 (0x400) | secure_heap / SYSTEM_SECURE | `CP_PIXEL` | `qcom,secure-pixel` | direct (pre-assigned pool) |
| 10 | | `CP_NON_PIXEL` | `qcom,secure-non-pixel` | direct (pre-assigned pool) |
| 10 | | `CP_BITSTREAM` | `qcom,secure-bitstream` if a kernel registers it, else `qcom,system` + lend to VMID 0x9 | lend |
| 10 | | `CP_CAMERA` | `qcom,secure-camera`, else `qcom,system` + lend to 0xD | lend |
| 10 | | `CP_TOUCH` | `qcom,secure-touch`, else `qcom,system` + lend to 0x8 | lend |
| 10 | | no CP flag, two CP flags, other CP flag | - | `-EINVAL` as 5.4 |
| 11 (0x800) | secure_display / HYP_CMA | any set of CP flags (`CP_SEC_DISPLAY`, `CP_CAMERA`, `CP_CAMERA\|CP_CDSP`, `CP_BITSTREAM`, `CP_CAMERA_PREVIEW`, ...) | `qcom,secure-display` (CMA on `secure_display_region`, 140 MiB) + lend to all VMIDs of the flags | lend |
| 11 | | no CP flag | - | `-EINVAL` as 5.4 |
| 7 (0x80) | qsecom / DMA | no secure flag | `qcom,qseecom` (28 MiB with the fragment) | direct |
| 1 (0x2) | qsecom_ta / DMA | | `qcom,qseecom-ta` (16 MiB) | direct |
| 6 (0x40) | user_contig / DMA | | `qcom,user-contig` (16 MiB) | direct |
| 5 (0x20) | audio_ml / DMA | | `qcom,audio-ml` (28 MiB) | direct |
| 7, 1, 6, 5 | | secure flag | - | `-ENOMEM` as 5.4 |
| 15 (0x8000) | secure_carveout | one CP flag | `qcom,secure-cdsp` | off on the A52s (`enabled_heaps`), as in its DT |
| 17, 16, 8, 4, 3 | audio_carveout, tui_carveout, audio, adsp, display | | `qcom,audio-carveout`, `qcom,tui`, `qcom,audio`, `qcom,adsp`, `qcom,display` | off: not on the phone |
| 30, 14, 9 | camera_heap, spss, mm | | none | off: not on the phone |

A mask with several bits is tried from the highest id down, as in 5.4. So Codec2's secure input
(mask 0xc00, `CP_BITSTREAM`) gets secure_display CMA memory lent to the bitstream VM first, then
secure_heap, exactly the 5.4 order; "any heap" (~0) and "system | camera" get system memory.

"Lend" = `dma_heap_buffer_alloc()` from a normal Qualcomm heap, then `mem_buf_lend()` (or
`mem_buf_share()` if `CP_HLOS` is in the flags) to the VMIDs with the permissions of
`msm_secure_get_vmid_perms()` (sec-display and camera-preview read-only, cdsp RWX, others RW:
identical in 5.4 and 6.12). On HLOS without Gunyah VMs this ends in the same
`qcom_scm_assign_mem` hyp-assign the 5.4 secure heaps issued. mem-buf then refuses `mmap`, `vmap`
and CPU access on the buffer, hands the VMID list to importers, and assigns the memory back to
HLOS when the last reference is dropped (pages are leaked, not freed, if that fails).
`/sys/kernel/debug/ioncompat/heaps` shows each backing heap as `ok`/`MISSING`.

Which combinations blobs and drivers really use (research/blob-uapi-inventory.md sections 9, 11,
12; 5.4 sources): system (everyone), qsecom + qsecom_ta (libQSEEComAPI users: qseecomd, KeyMint,
Gatekeeper, fingerprint, Widevine), secure_heap with PIXEL / NON_PIXEL / BITSTREAM (vidc, Codec2),
secure_display with SEC_DISPLAY (secure UI) and CAMERA (cam_mem_mgr), adsp|system (adsprpc: system
memory), audio_ml (audio), user_contig.

## In-kernel face for forward-ported 5.4 drivers

Add `-I<this dir>/include -I<this dir>/include/uapi` **before** the soc-repo includes and
`KBUILD_EXTRA_SYMBOLS=<this dir>/Module.symvers`; `#include <linux/ion.h>` / `<linux/msm_ion.h>`
then work as on 5.4.

| symbol | state on 6.12 |
|---|---|
| `ion_alloc(len, heap_id_mask, flags)` -> `struct dma_buf *` | implemented, same selection as the ioctl |
| `ion_query_heaps_kernel()` | implemented |
| `dma_buf_get_flags(dmabuf, &flags)` | **redirected** by `linux/msm_ion.h` to `ion_compat_dma_buf_get_flags()`: ION flags rebuilt from the buffer's mem-buf VMID list (`ION_FLAG_SECURE \| ION_FLAG_CP_*`, 0 for HLOS-only memory and for non-Qualcomm dma-bufs) |
| `ion_compat_dma_buf_vmids(dmabuf, &vmids, &perms, &nr)` | VMID + permission arrays (kfree both); wrapper over `mem_buf_dma_buf_copy_vmperm()`, HLOS RWX for foreign dma-bufs |
| `ion_compat_dma_buf_is_secure(dmabuf)` | true if not HLOS-only |
| `msm_ion_heap_is_secure()`, `get_ion_flags()`, `ion_populate_vm_list()`, `ion_get_flags_num_vm_elems()` | implemented (5.4 table) |
| `msm_ion_heap_prefetch()`, `_drain()` | stub `-ENOTSUPP` (vidc warm-up of secure pools; the Qualcomm secure pools refill themselves) |
| `msm_ion_heap_device_by_id()` | stub `ERR_PTR(-ENODEV)` |
| `ion_free()`, `struct ion_heap` | not provided |

**Trap found while porting:** GKI 6.12 still exports `dma_buf_get_flags()`, but no Qualcomm 6.12
heap implements the `get_flags` op, so the stock function always returns flags 0. A 5.4 driver
(5.4 `qseecom.c` lines 1226 and 1290, `smcinvoke.c` 787 and 822, `adsprpc.c` 1493 and 1552) that is ported
without our header compiles and then treats secure buffers as normal memory. Include
`linux/msm_ion.h` from this directory in every such driver, or call the `ion_compat_*` function.
The VMID query works for any Qualcomm heap buffer, also ones allocated through `/dev/dma_heap`.

## DT (`a52sxq-dma-heaps.dtsi`)

The 6.12 base already has `qcom,dma-heaps`, `qcom-secure-buffer`, `qcom-mem-buf` and all CMA
regions with the phone's sizes, with three differences the fragment corrects from
`downstream-dt/a52sxq-r02.dts`: `qseecom_region` 20 -> 28 MiB; `cdsp_secure_heap@81800000` and its
`qcom,secure-cdsp` heap disabled (disabled on the phone); `non_secure_display_region` (100 MiB)
and its `qcom,display` heap disabled (do not exist on the phone). The table is in the file's
header. Nothing in it depends on the hardware revision (r02..r04 share the memory map; checked
only for r02's merged tree, the Samsung dtsi do not touch these nodes [inference from the
overlay sources not overriding them]).

## Test (`test/`)

    # on the device (busybox test shell), after the modules above:
    insmod /extra/ioncompat.ko
    cat /sys/kernel/debug/ioncompat/heaps      # every backing heap must say [ok]
    /extra/iontest64 -v -s ; /extra/iontest32 -s

`-s` (strict) makes a missing secure backing heap a failure (right for the 6.12 BSP). New cases
against the 6.18 version: 8 MiB qsecom / qsecom_ta with map + write + read back; every secure
heap + CP flag combination of the table (fd must come back, read-write and read-only `mmap` must
be refused; the test never touches such a mapping); two-VMID lend (`CP_CAMERA|CP_CDSP`); 64 rounds
of alloc/close on secure_display (16 MiB of 140), secure_heap bitstream and pixel to show the
memory returns; a final 16 MiB system allocation that must be zeroed and writable.
Expected kernel log on success: nothing from `ioncompat:`. Failure signatures:
`ioncompat: lend of ... failed: -22` + `mem-buf driver not probed` (mem_buf_dev not bound: check
the `qcom-mem-buf` node), `No vm with vmid=0x..` (mem_buf VM table), `dmabuf ops ... are not a
mem_buf_dma_buf_ops` (lend_from heap is not a Qualcomm heap), `hyp_assign` errors from TZ.

## What only hardware can confirm

1. `mem_buf_lend()` to `VMID_CP_BITSTREAM` / `CP_CAMERA` / `CP_TOUCH` / `CP_SEC_DISPLAY` is accepted
   by this phone's TZ/hypervisor build (the 5.4 kernel issued the same assign calls, so it
   should), and reclaim on release works. A failed reclaim leaks the pages by design.
2. The mem-buf lend path itself at run time. Read from source: for CP VMIDs
   `mem_buf_assign_mem()` does `mem_buf_hyp_assign_table()` only (`mem_buf_assign_mem_gunyah()`
   returns early when no VM in the list uses Gunyah), after a `dma_map_sgtable()` on the mem-buf
   device for cache maintenance; it needs `qcom-mem-buf` probed with `qcom,vmid = <3>`.
3. Secure display CMA lent per buffer vs 5.4 HYP_CMA: same region and VMIDs; chunk granularity
   of the assign call differs (sg entries instead of one range).
4. Importers (kgsl, sde, vidc, camera smmu, qcedev) accept lent buffers. With the lend path the
   buffer's VMID list is exactly the CP VMIDs (no HLOS entry), the same shape Qualcomm's own
   secure heaps produce; how each 6.12 importer checks it was not read here.
5. `qcom,secure-pixel` / `-non-pixel` pools under the 5.4 Codec2 blob (pool refill timing replaces
   5.4's explicit prefetch).
6. 28 MiB qseecom CMA is enough for KeyMint + Gatekeeper + Widevine TA shared buffers at once
   (it is the 5.4 size).
7. 32-bit callers through `compat_ptr_ioctl` (verified on 6.18 hardware, same code).

## Known differences from 5.4 (unchanged from the 6.18 module unless noted)

- Qualcomm CMA heaps map cached; 5.4 mapped write-combined without `ION_FLAG_CACHED`.
- `ION_FLAG_POOL_FORCE_ALLOC`, `ION_FLAG_ALLOW_NON_CONTIG` accepted and ignored.
- `ION_FLAG_CP_TRUSTED_VM` refused (`-EINVAL`): no trusted VM on this phone.
- `ION_IOC_PREFETCH`/`DRAIN`: `-ENOTTY`, as the 5.4 kernel answers.
- `/sys/kernel/ion/total_heaps_kb`, `total_pools_kb` not provided (open memtrack HAL only).
- 6.12 only: `cma_fallback` (default Y) still lets qsecom/qsecom_ta/user_contig/audio_ml fall to
  `default_cma_region` if that heap exists; GKI 6.12 names the default CMA heap after the area,
  so on this BSP the fallback normally finds nothing and a missing Qualcomm heap is `-ENODEV`.
