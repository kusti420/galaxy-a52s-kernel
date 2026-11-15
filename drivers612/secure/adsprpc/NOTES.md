# Legacy FastRPC (adsprpc) for the Qualcomm 6.12 BSP — a52sxq

State 2026-11-11: **builds** (`frpc-adsprpc.ko`, no warnings, no unresolved symbols,
vermagic `6.12.81-4k-g8a69376da734`). Never loaded on hardware.

## What is here
| File | What |
|---|---|
| `adsprpc.c`, `adsprpc_612.h`, `trace/` | the 5.4 driver on 6.12. Base: `donors/redwood-6.12/modules/adsprpc` (same SoC, same BSP), plus the a52sxq changes below |
| `adsprpc_compat.c` | 32-bit ioctl face, new for 6.12 (redwood has none). `#include`d by `adsprpc.c` |
| `adsprpc_shared.h` | byte-identical to the phone's `drivers/char/adsprpc_shared.h` (`cmp` clean) |
| `a52sxq-fastrpc.dtsi` | `qcom,msm_fastrpc` + 16 context banks from `downstream-dt/a52sxq-r02.dts`; compiles on top of `bsp612/devicetree/qcom/yupik.dts` with the BSP's dtc |
| `a52sxq-vs-redwood.patch` | every change made to the donor code |
| `port-vs-a52s-5.4.diff` | this `adsprpc.c` against the phone's 5.4 `adsprpc.c` (what the port changed in total) |
| `redwood-fastrpc.dtsi.ref` | redwood's DT, reference only |
| `build.sh` | `./build.sh` (reads `bsp612/`, writes only here); `./build.sh clean` |

## Build
`./build.sh` = `make -C bsp612/kernel O=bsp612/out/lahaina M=$PWD
KBUILD_EXTRA_SYMBOLS=bsp612/soc-repo-staging/build/Module.symvers
SOCINCLUDE="-I<soc-repo-staging>/include -I.../include/uapi"`, clang r547379.

## Load order / dependencies
`modinfo -F depends`: `rproc_qcom_common, pdr_interface, minidump, qcom-scm, mem_buf_dev`
(import namespace `DMA_BUF`). At run time it also needs, loaded before a client opens the node:
the glink stack for the ADSP/CDSP edges (`qcom_glink`, `qcom_glink_smem`, `rpmsg` core), the
ADSP and CDSP remoteprocs (PAS) started, the SMMU (`arm_smmu`) and a PD mapper for the two static
PDs (`qcom,fastrpc-adsp-audio-pdr`, `-sensors-pdr`): the in-kernel `qcom_pd_mapper` or the
vendor's `pd-mapper`. Do NOT also load dsp-kernel's `frpc-adsprpc.ko`/`cdsp-loader` FastRPC
driver: same module name, same rpmsg channel (`fastrpcglink-apps-dsp`), same device names.
Not needed: `ioncompat` (see "ION" below).

Module parameter: `signoff` (see Samsung differences).

## Userspace contract (kept from the phone's 5.4 kernel)
- Device nodes: `/dev/adsprpc-smd` (minor 0) and `/dev/adsprpc-smd-secure` (minor 1), class
  `fastrpc`, dynamic major: unchanged, so the vendor's existing ueventd lines and SELinux
  labels for these two names apply as they are (not re-read here: check `vendor/ueventd.rc`
  and `file_contexts` for `adsprpc-smd` when writing the first-stage list).
- sysfs `remote_cdsp_status` on the `qcom,msm-fastrpc-compute` platform device: kept.
- debugfs `adsprpc/`: kept (Samsung's extra "SS_FASTRPC : ioctl" history block is dropped).
- ioctls, computed with the BSP clang from `adsprpc_shared.h` for arm64 and armv7 callers; the
  compat column is what `adsprpc_compat.c` accepts and equals the armv7 column in every row:

| ioctl | nr | 64-bit | 32-bit |
|---|---|---|---|
| INVOKE | 1 | 0xc0105201 | 0xc00c5201 |
| MMAP | 2 | 0xc0205202 | 0xc0145202 |
| MUNMAP | 3 | 0xc0105203 | 0xc0085203 |
| INVOKE_FD | 4 | 0xc0185204 | 0xc0105204 |
| SETMODE | 5 | 0xc0045205 | same |
| INIT | 6 | 0xc0285206 | 0xc01c5206 |
| INVOKE_ATTRS | 7 | 0xc0205207 | 0xc0145207 |
| GETINFO | 8 | 0xc0045208 | same |
| INIT_ATTRS | 10 | 0xc030520a | 0xc024520a |
| INVOKE_CRC | 11 | 0xc028520b | 0xc018520b |
| CONTROL | 12 | 0xc00c520c | same |
| MUNMAP_FD | 13 | 0xc018520d | 0xc010520d (new: 5.4 returned -ENOTTY to 32-bit callers) |
| MMAP_64 | 14 | 0xc020520e | same number, different layout (handled per ABI) |
| MUNMAP_64 | 15 | 0xc010520f | same number, different layout |
| GET_DSP_INFO | 17 | 0xc00c5211 | same |
| INVOKE2 | 18 | 0xc0185212 | 0xc0105212 |
| MEM_MAP | 19 | 0xc0405213 | same number, different layout |
| MEM_UNMAP | 20 | 0xc0305214 | same number, different layout |
| INVOKE_PERF | 21 | 0xc0385215 | 0xc0205215 |

  That is 19 defined numbers (9 = GETPERF is commented out in the phone's header, 16 unused);
  the "20 ioctls" count includes the removed GETPERF.

## Changes against the redwood donor (`a52sxq-vs-redwood.patch`)
1. **32-bit ioctls** (`adsprpc_compat.c`, `.compat_ioctl`). The phone's compat struct layouts and
   ioctl numbers are copied verbatim from its 5.4 `adsprpc_compat.c`. 5.4 built 64-bit copies in
   user memory with `compat_alloc_user_space()` (removed in 5.11) and re-entered the native
   ioctl; here each request is converted into the kernel struct and the internal handler is
   called. For invokes only the `remote_arg` array changes layout, so it is rebuilt in kernel
   memory and sent with a new message type `COMPAT_MSG`: `context_alloc()` memmoves `pra`
   instead of `copy_from_user`, everything else treats it as a user request (fd/attr/crc/perf/
   job arrays stay user pointers, as on 5.4). `fastrpc_ioctl_gate()` factors out the two checks
   every ioctl starts with so both entries share them.
   Kept 5.4 quirk: `INVOKE2`/`ASYNC_RESPONSE` from a 32-bit caller is passed to the native
   handler unchanged, which writes the 40-byte native `fastrpc_ioctl_async_response` into the
   caller's 24-byte struct. That is what 5.4 does; a 32-bit libcdsprpc using async on this
   phone would already be broken, so it was not "fixed" blind.
2. **Secure buffers.** 5.4 read `ION_FLAG_SECURE` from the ION buffer to route a map to the
   secure context bank (cb9, VMID_CP_PIXEL). The 6.12 qcom heaps have no `get_flags`, so
   redwood's port sees flags 0 for every buffer and never uses the secure bank.
   `fastrpc_dma_buf_get_flags()` (in `adsprpc_612.h`) adds: a mem-buf dma-buf that HLOS does not
   own exclusively (`is_mem_buf_dma_buf() && !mem_buf_dma_buf_exclusive_owner()`) is secure.
   New dependency `mem_buf_dev`.
3. **Samsung's `signoff` gate** on `qcom,secure-domains` restored (see below).
4. **`qcom,qos-cores` latency votes** (`FASTRPC_CONTROL_LATENCY` → `dev_pm_qos` resume-latency
   requests on CPUs 0-3) restored from the phone's driver; redwood removed them. Kept exactly as
   on the phone, including that the ioctl returns the positive value of
   `dev_pm_qos_add/update_request` (1 when the effective constraint changed).
5. `Kbuild`: soc-repo headers in front (`SOCINCLUDE`), `build.sh`.

Inherited from redwood unchanged (their 5.4 → 6.12 work, all in `port-vs-a52s-5.4.diff`):
SSR via `qcom_register_ssr_notifier` (subsystem names mapped adsp→lpass etc.), PDR via
`pdr_handle_alloc/pdr_add_lookup`, `hyp_assign_phys` via `qcom_scm_assign_mem`, rpmsg channel →
domain by `qcom,glink-label` of the glink edge (6.12 yupik has "lpass" and "cdsp": matches),
`mmap_read_lock`, `class_create`, no ramdump collection (`subsystem_restart` is a stub: a DSP
that needs a restart is only logged), cache maintenance done for all buffers, and three
upstream security fixes that the phone's 5.4 driver lacks (overlap handling split by ION/non-ION,
page-range overflow check, `FASTRPC_ATTR_KEEP_MAP` check, DMA-handle refcount).

## Samsung differences in the phone's 5.4 driver
Found by `grep SAMSUNG|SEC|SS_` and the full diff:
- `is_signoff_block()`: `qcom,secure-domains = <0xf>` (in the phone's DT) is applied only when
  the command line has `signoff=0x2377`. On a normal boot nothing is "secure-only", every
  domain works through `/dev/adsprpc-smd`. Ported as module parameter
  `frpc-adsprpc.signoff=0x2377` (a module cannot register an `early_param`; if the bootloader
  really passes `signoff=` it must be forwarded as `frpc-adsprpc.signoff=`). Redwood's code
  would have applied secure-domains always, which would lock unsigned/3rd-party PDs out of the
  non-secure node on this phone.
- `SS_FASTRPC_DEBUG` (ioctl history in debugfs, `ss_fastrpc_debug_*`, a panic on release with
  mapped memory in non-ship builds via `sec_debug`): debug only, not ported.
- No Samsung ioctl, no Samsung UAPI change: `adsprpc_shared.h` equals redwood's byte for byte.

## ION
The driver never allocates ION memory itself: user buffers arrive as dma-buf fds
(`dma_buf_get`), kernel-side memory comes from `dma_alloc_attrs` on the context-bank devices
and on the `qcom,msm-adsprpc-mem-region` CMA device (`adsp_mem`, 12 MiB, already in 6.12
`yupik.dtsi`). So fds from `/dev/ion` (ioncompat) and from qcom dma-heaps both work and no
in-kernel `ion_alloc()` face is needed here. The only ION-era dependency was the secure flag
(change 2). If ioncompat later exports a "5.4 ION flags of this dma-buf" query, it plugs into
`fastrpc_dma_buf_get_flags()` in `adsprpc_612.h` (one function; it would also give back
`ION_FLAG_CACHED`, today every buffer is treated as cached and gets cache maintenance).

## Device tree
`a52sxq-fastrpc.dtsi`: see its header. SIDs checked by script against the phone's tree
(identical set to redwood's, same SoC). Uses `iommu-addresses` instead of the deprecated
`qcom,iommu-dma-addr-pool`; keeps `qcom,iommu-faults` (6.12 arm-smmu parses it). The 6.12
yupik.dtsi has no FastRPC node of either generation, so no conflict; it already has
`qcom,msm-adsprpc-mem` and `qcom,msm-cdsp-loader`.

## Cannot be verified without hardware / known risks
1. **Remote heap / `ADD_PAGES`.** The assumption in the task ("the legacy driver fixes the
   ADD_PAGES rejection") is NOT supported by the donor: redwood's STATUS.md lists, *with this
   legacy driver*, "the DSPs refuse `ADD_PAGES`/remote heap maps (camera SNPE, audioadsprpcd)"
   as still open, "no kernel error, so the refusal is DSP side". Expect the same here until
   proven otherwise. Things this port has that redwood's did not, any of which may matter:
   `qcom,iommu-faults` on the banks, secure-buffer routing, phone-specific `signoff` handling.
   Suspects to test on hardware, in order: (a) `hyp_assign_phys` shim: source VM mask and
   `qcom,adsp-remoteheap-vmid = <22 37>` with perms from `init_secure_vmid_list` for the
   ADSP remote heap; (b) the IOVA the DSP is handed (5.4 `qcom,iommu-dma-addr-pool` allocated
   top-down from 0xf8000000; 6.12 iommu-dma with reservations may hand out different ranges or
   >32-bit addresses if the bank's DMA mask is 64-bit); (c) `me->compat` method-4 message
   (kept = 1 as on 5.4); (d) SMMU S1 attributes of the bank (5.4 set fast-map/atomic domain
   attrs that have no 6.12 equivalent).
2. PDR/SSR paths (audio PD, sensors PD up/down, ADSP restart): compile-checked only. A DSP
   crash is not recovered by this driver (`subsystem_restart` stub).
3. 32-bit path: converted by reading, never executed. First test should be a 32-bit
   `adsprpcd`/`sscrpcd`-style client doing INIT + INVOKE.
4. `FASTRPC_CONTROL_LATENCY` return value (see change 4) and pm_qos on GKI: untested.
5. `cdsprm` (`qcom,msm-cdsp-rm`) is a separate driver; soc-repo 6.12 builds `cdsprm.ko`
   (not compared with the phone's 5.4 one). The 5.4 `cdsp-loader` sysfs boot trigger was not
   looked at: check what the vendor's `cdsprpcd` start expects.

## First on-device test (test ramdisk, after ADSP/CDSP remoteprocs are up)
    insmod mem_buf_dev.ko ; insmod pdr_interface.ko ; insmod minidump.ko   # if not built in/loaded
    insmod frpc-adsprpc.ko
    ls -l /dev/adsprpc-smd /dev/adsprpc-smd-secure
    cat /sys/kernel/debug/adsprpc/global
    dmesg | grep -i adsprpc
Expected: both nodes; for each started DSP `adsprpc: fastrpc_rpmsg_probe: opened rpmsg channel
for lpass` / `cdsp`; 16 `qcom,msm-fastrpc-compute-cb` probes without "failed"; `PDR lookup added
for ...` twice. Failure modes: no rpmsg line = DSP not booted or glink label mismatch; cb probe
`-EPROBE_DEFER` forever = SMMU/`iommu-addresses` not accepted; `signoff 0x00000000` line is
normal.
