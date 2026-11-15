# ioncompat: the 5.4 msm ION ABI on DMA-BUF heaps (ACK android17-6.18)

The A52s vendor blobs allocate memory through `/dev/ion` only, with hard-coded msm heap id
bits and content protection (CP) flags, and the downstream drivers we forward-port call
`ion_alloc()` in the kernel. Kernel 6.18 has DMA-BUF heaps and no ION. This module gives both
callers the 5.4 interface and takes the memory from the DMA-BUF heap that stands for the 5.4
heap.

State: compiles cleanly against `out-ack` (6.18.33, `-Werror`, `W=1`). **Never loaded, never
run**: there is no test device yet. No change to `ack/` core code was needed.

Origin: started from `donors/redwood-6.12/modules/ioncompat/ioncompat.c` (POCO X5 Pro, same
SoC; `GPL-2.0-only`, no copyright line in that file). Kept from it: the misc device that turns
the allocation ioctl into `dma_heap_find()` + `dma_heap_buffer_alloc()`, and its finding that
the CP flag, not the mask, selects the secure memory. The heap selection was rewritten to
follow the 5.4 ION core. `include/uapi/linux/*.h` are byte-identical copies of the 5.4 headers.

## Build

    # once, and after a kernel config change (needs out-ack/Module.symvers, so build modules too):
    ./build-ack.sh config && ./build-ack.sh Image qcom/sm7325-samsung-a52sxq.dtb modules
    # the module:
    CLANG=$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r596125/bin
    KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
      make -C ack ARCH=arm64 LLVM=$CLANG/ O=../out-ack M=../modules/ioncompat W=1 modules
    # the userspace test (compile only):
    make -C modules/ioncompat/test

`ack/arch/arm64/configs/a52sxq_gki.fragment` gained `CONFIG_DMABUF_HEAPS_SYSTEM=y` and
`CONFIG_DMABUF_HEAPS_CMA=y` (the heaps `system`, `system-uncached`, `default_cma_region`).
The module needs only symbols the ACK core exports to everyone (`dma_heap_find`,
`dma_heap_buffer_alloc`, `dma_heap_put`; `dma_buf_put` in namespace `DMA_BUF`, imported).

## What /dev/ion answers (same as `ion_ioctl()` of the 5.4 kernel)

| ioctl | number | behaviour |
|---|---|---|
| `ION_IOC_ALLOC` | `0xc0184900` | dma-buf fd (`O_CLOEXEC`), heap chosen as below |
| `ION_IOC_HEAP_QUERY` | `0xc0184908` | the A52s heap list, highest id first; `-EINVAL` if a reserved field is set or a buffer is given with `cnt` 0 |
| `ION_IOC_ABI_VERSION` | `0x80044909` | 2 (`ION_CURRENT_ABI_VERSION` of 5.4; the donor answered 3) |
| `ION_IOC_PREFETCH`, `ION_IOC_DRAIN` | `0xc0184d03`, `0xc0184d04` | `-ENOTTY`. They are in the 5.4 UAPI header, but the 5.4 kernel has no handler for them either |
| anything else, e.g. the legacy `ION_IOC_FREE` probe of libion | | `-ENOTTY` (`-EINVAL` if the encoded size is over 24 bytes, `-EFAULT` on a bad pointer, checked first as in 5.4) |

32-bit callers: the structures have no pointers or longs and `__u64` is 8-byte aligned in the
arm EABI, so sizes and numbers are identical; 5.4 used one handler for both, and here
`.compat_ioctl = compat_ptr_ioctl` calls the same function. Checked at build time
(`BUILD_BUG_ON` in the module, `test/abi_check.c` for both targets).

Node: misc device `ion`, dynamic minor (5.4 had minor 127; nothing should depend on it), mode
0664; owner `system:system` comes from the vendor `ueventd.rc` as before.

## Heap table

A mask can name several heaps. As in 5.4 they are tried from the highest id down until one
succeeds; the last error is returned, `-ENODEV` if the mask names no existing heap. Only the
heaps the A52s 5.4 kernel registers are on by default (`enabled_heaps=0x02000ce2`); the other
ids of `msm_ion_ids.h` are in the table for completeness and are skipped like on the phone.

| id | 5.4 name | 5.4 type | on A52s | DMA-BUF heap used | available in 6.18 now |
|---|---|---|---|---|---|
| 25 | system | MSM_SYSTEM (21) | yes | `system` if `ION_FLAG_CACHED`, else `system-uncached`; any secure flag: `-EINVAL` | yes |
| 11 | secure_display | HYP_CMA (18) | yes, 140 MiB CMA | `qcom,cp-display-<vm>[-<vm>...]`; no CP flag: `-EINVAL` | **no**, `-ENODEV` |
| 10 | secure_heap | SYSTEM_SECURE (17) | yes | `qcom,secure-<vm>`; exactly one of TOUCH, BITSTREAM, PIXEL, NON_PIXEL, CAMERA, else `-EINVAL` | **no**, `-ENODEV` |
| 7 | qsecom | DMA (2) | yes, 28 MiB CMA | `qcom,qseecom`, else `default_cma_region`; secure flag: `-ENOMEM` | via fallback |
| 6 | user_contig | DMA | yes, 16 MiB CMA | `qcom,user-contig`, else `default_cma_region` | via fallback |
| 5 | audio_ml | DMA | yes, 28 MiB CMA | `qcom,audio-ml`, else `default_cma_region` | via fallback |
| 1 | qsecom_ta | DMA | yes, 16 MiB CMA | `qcom,qseecom-ta`, else `default_cma_region` | via fallback |
| 15 | secure_carveout | SECURE_CARVEOUT (20) | disabled in DT | `qcom,secure-<vm>` (`qcom,secure-cdsp`) | off |
| 17, 16 | audio_carveout, tui_carveout | MSM_CARVEOUT (19) | no | `qcom,audio-carveout`, `qcom,tui` | off |
| 8, 4, 3 | audio, adsp, display | DMA | no | `qcom,audio`, `qcom,adsp`, `qcom,display` | off |
| 30, 14, 9 | camera_heap, spss, mm | | no | no mapping defined | off |

`<vm>` is the word for the CP flag, several joined in ascending bit order: `touch` (bit 17),
`bitstream` (18), `pixel` (19), `non-pixel` (20), `camera` (21), `hlos` (22), `spss-sp` (23),
`spss-sp-shared` (24), `sec-display` (25), `app` (26), `camera-preview` (27), `cdsp` (29),
`spss-hlos-shared` (30). Examples: secure video output = `qcom,secure-pixel`; Codec2 secure
input (mask 0xc00, CP_BITSTREAM) = `qcom,cp-display-bitstream`, then `qcom,secure-bitstream`;
secure camera (`cam_mem_mgr`) = `qcom,cp-display-camera` and `qcom,cp-display-camera-cdsp`.
`ION_FLAG_CP_TRUSTED_VM` (bit 15) is refused: its VMID comes from Haven, which the phone
does not run.

`/sys/kernel/debug/ioncompat/heaps` prints this table with `ok`/`MISSING` per backing heap.

Parameters: `enabled_heaps` (mask, load time), `cma_fallback` (Y/N, writable at run time).

## Backing heaps that still have to be provided

The shim only chooses a name; `dma_heap_buffer_alloc()` has no flags to pass a VMID, so there
is one DMA-BUF heap per VMID set. Whoever registers a heap under one of these names must do
the following (reference: `donors/clo-kernel-6.12/drivers/dma-buf/heaps/`, and
`heaps/ion_system_secure_heap.c`, `ion_cma_heap.c`, `ion_secure_util.c` of the 5.4 kernel).

1. **`qcom,secure-pixel`, `-non-pixel`, `-bitstream`, `-camera`, `-touch`** (5.4 secure system
   heap; the first two exist in CLO 6.12 as `qcom_secure_system_heap.c`): pages from the page
   allocator; before the buffer is handed out, flush and hyp-assign every chunk from HLOS to
   the one VMID (CP_TOUCH 0x8, CP_BITSTREAM 0x9, CP_PIXEL 0xA, CP_NON_PIXEL 0xB, CP_CAMERA 0xD)
   with the permissions of 5.4 `msm_secure_get_vmid_perms()`, using `qcom_scm_assign_mem()`
   (6.18: `include/linux/firmware/qcom/qcom_scm.h`); on release assign back to HLOS (RWX) and
   only then free; if that fails, leak the pages, never free them. No CPU mapping: `mmap`,
   `vmap` and `begin_cpu_access` must fail. Attachments get an sg_table without CPU sync.
   Optional: per-VMID page pools and prefetch (`msm_ion_heap_prefetch()` is `-ENOTSUPP` here).
2. **`qcom,cp-display-<vm...>`** (5.4 HYP_CMA on `secure_display_region`, 140 MiB): contiguous
   memory from that CMA region, hyp-assigned to **all** VMIDs of the name, back to HLOS on
   release. Needed sets seen in 5.4 sources: `sec-display`, `camera`, `camera-cdsp`,
   `bitstream` (Codec2 mask 0xc00). Do not point this at CLO 6.12's `qcom,secure-display`:
   that one is a plain CMA heap and assigns nothing, which is why the name differs.
3. **`qcom,qseecom`, `qcom,qseecom-ta`, `qcom,user-contig`, `qcom,audio-ml`** (5.4 DMA heaps):
   plain CMA heaps on `qseecom_region` (28 MiB), `qseecom_ta_region` (16 MiB),
   `user_contig_region` (16 MiB), `audio_cma_region` (28 MiB); zeroed, mappable. The upstream
   CMA heap registers the default area only, so a small per-region heap (CLO
   `qcom_cma_heap.c`, or a `dma_heap_add()` loop over the reserved-memory nodes) plus the
   four `shared-dma-pool` nodes in our dts is needed. Until then `cma_fallback` serves them
   from `default_cma_region`: same kind of memory, but shared and only 16 MiB with the current
   config, so large TA loads can fail and the regions are not reserved for their users.
4. **`qcom,secure-cdsp`** only if secure_carveout is ever enabled (it is disabled on the A52s).

Also outside this module, and needed by the forward-ported drivers:
- 5.4 drivers read the ION flags of a dma-buf (`dma_buf_get_flags`; seen in qseecom and
  smcinvoke) to learn its VMIDs. 6.18 has no such hook; the secure heaps above must export
  an equivalent (CLO 6.12: `mem_buf_dma_buf_copy_vmperm()` family), and those call sites must
  be changed.
- `/sys/kernel/ion/total_heaps_kb` and `total_pools_kb` (read by the open memtrack HAL) are
  not provided.

## In-kernel API (`include/linux/ion.h`, `include/linux/msm_ion.h`)

A forward-ported driver adds `-I<this dir>/include -I<this dir>/include/uapi`,
`KBUILD_EXTRA_SYMBOLS=<this dir>/Module.symvers`, and keeps its code:

| symbol | state |
|---|---|
| `ion_alloc(len, heap_id_mask, flags)` | implemented, same selection as the ioctl; returns `struct dma_buf *` |
| `ion_query_heaps_kernel()` | implemented |
| `msm_ion_heap_is_secure()`, `get_ion_flags()`, `ion_populate_vm_list()`, `ion_get_flags_num_vm_elems()` | implemented (5.4 VMID table) |
| `msm_ion_heap_prefetch()`, `msm_ion_heap_drain()` | stub, `-ENOTSUPP` (vidc secure pool warm-up; belongs in the secure heap) |
| `msm_ion_heap_device_by_id()` | stub, `ERR_PTR(-ENODEV)` (qseecom used the heap's platform device) |
| `msm_ion_heap_add_memory()`, `_remove_memory()`, `msm_ion_dma_buf_lock()` | inline `-ENODEV` (mem-buf only, no VM on this phone) |
| `ion_free()`, `struct ion_heap`, `ion_device_add_heap()` | not provided: heaps are DMA-BUF heaps now |

## Known differences from 5.4

- CMA heaps: the upstream CMA heap always maps cached; 5.4 mapped these write-combined when
  `ION_FLAG_CACHED` was absent. Callers must use `DMA_BUF_IOCTL_SYNC` / dma-buf map calls.
- `ION_FLAG_POOL_FORCE_ALLOC` and `ION_FLAG_ALLOW_NON_CONTIG` are accepted and ignored.
- A failed copy of the result to userspace does not leave an unknown fd behind (5.4 did).
- No "allocation from generic sys heap" warning for mask bit 0.

## Test (`test/`)

- `abi_check.c`: static asserts only. Sizes, field offsets, ioctl numbers, heap ids, heap
  types and flags of `ion_abi.h` (the copy a blob has compiled in) against the 5.4 headers of
  `$ANDROID_TREE/kernel/samsung/sm7325` and against the module's copies, for
  `aarch64-linux-gnu` and `armv7a-linux-gnueabi`. `make check` passes; a wrong number makes it
  fail (tried).
- `iontest.c`: raw ioctls as a blob issues them: ABI version, legacy probe, heap query
  (count, list, truncation, error cases), allocations with the masks the blobs and drivers
  use (map, zero check, write, sync, read back for non-secure memory), and the refusals of
  5.4 with their errno. `-ENODEV` from a missing secure heap is reported as SKIP. Built as
  static nolibc binaries `test/build/iontest64` and `test/build/iontest32` (the compat path).
  **Compiled only; they cannot run on this PC and have not run anywhere.**

## Not verifiable without hardware

Everything at run time: module load and `/dev/ion` creation with the vendor SELinux labels
and ueventd rules; that the blobs get through with this heap list; CMA fallback capacity for
real TA loads; the uncached system heap with CamX/kgsl importers; all secure paths (blocked on
the backing heaps anyway); 32-bit processes through `compat_ptr_ioctl`.
