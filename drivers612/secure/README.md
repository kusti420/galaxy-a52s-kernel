# secure: TrustZone- and memory-facing drivers for the A52s on the Qualcomm 6.12 BSP

State 2026-11-11: everything below **builds** against `bsp612/out/lahaina` (GKI 6.12.81 +
soc-repo r70) with no compile or modpost errors. **Nothing has been loaded on hardware.**

| Directory | What | Result |
|---|---|---|
| `securemsm/` | Qualcomm securemsm-kernel `sec-kernel.lnx.14.16.r27-rel` (donor commit b1c5edcf) + 8 patches | 9 modules in `out/`, plus a second smcinvoke variant in `out/smcinvoke-compat/` |
| `ioncompat/` | `/dev/ion` (5.4 msm ION ABI) over Qualcomm's `qcom_dma_heaps`, with secure heaps and the in-kernel `ion_alloc()` face | `ioncompat.ko`, `test/build/iontest{64,32}`; own `README.md` |
| `adsprpc/` | legacy FastRPC (`/dev/adsprpc-smd`, `-smd-secure`), 5.4 ioctl ABI incl. 32-bit | `frpc-adsprpc.ko`; own `NOTES.md` |
| `qseetest/` | static nolibc test client for `/dev/qseecom`, `/dev/smcinvoke`, `/dev/qce` | `build/qseetest{64,32}` |
| `uapi-compare/` | `compare.sh`: ioctl numbers of the 5.4 headers vs the 6.12 ones, arm64 and armv7 | `result.txt` + per-header tables |
| `a52sxq-secure.dtsi` | DT fragment + node-by-node comparison for qseecom, shm bridge, smcinvoke, qcedev, rng, tz-log | applies to `yupik.dtb` with fdtoverlay |

Other DT fragments: `ioncompat/a52sxq-dma-heaps.dtsi`, `adsprpc/a52sxq-fastrpc.dtsi`.

## Build

    securemsm/build.sh        # copies the donor to securemsm/src, applies patches/, builds, strips into out/
    ioncompat/build.sh        # ioncompat.ko; (cd ioncompat/test && make) for the tests
    adsprpc/build.sh          # frpc-adsprpc.ko
    (cd qseetest && make)     # build/qseetest64, build/qseetest32
    uapi-compare/compare.sh   # re-run the ABI comparison (needs securemsm/src)

All of them only read `bsp612/` and write below this directory. Clang r547379, the brief's `M=`
method, `KBUILD_EXTRA_SYMBOLS=bsp612/soc-repo-staging/build/Module.symvers`.

## securemsm: which modules a yupik phone needs

| Module | Node | Load on a52sxq | Depends on (modinfo) |
|---|---|---|---|
| `qseecom_dlkm.ko` | `/dev/qseecom` | yes, first stage | `qseecom_proxy`, `qcom-scm`, `mem_buf_dev` |
| `smcinvoke_dlkm.ko` | `/dev/smcinvoke` | yes (Widevine holds 3 fds on 5.4) | `qseecom_proxy`, `qcom-scm`, `si_core_module` (variant `out/smcinvoke-compat/`: `mem_buf_dev` instead of `si_core_module`) |
| `qce50_dlkm.ko` | - | yes (qcedev needs it) | `sps_drv` |
| `qcedev-mod_dlkm.ko` | `/dev/qce` | yes (node exists on 5.4, `libcpion.so`) | `qce50_dlkm`, `mem_buf_dev` |
| `hdcp_qseecom_dlkm.ko` | - | only if the display techpack links against it | `smcinvoke_dlkm`, `qcom-scm`, `qseecom_proxy` |
| `qcrypto-msm_dlkm.ko` | - | no (base DT node has no compatible; kernel crypto only) | `qce50_dlkm` |
| `qrng_dlkm.ko` | `/dev/msm-rng` | no (base uses upstream `qcom,trng`; no blob opens msm-rng) | - |
| `smmu_proxy_dlkm.ko` | - | no (trusted-VM camera; no such VM on this phone) | `smcinvoke_dlkm`, `mem_buf_dev`, `gh_msgq`, `qcom_dma_heaps` |
| `tz_log_dlkm.ko` | `/proc/tzdbg` | **NEVER** (redwood: probing it on yupik resets the phone) | `qcom-scm` |

### Patches (`securemsm/patches/`, applied in order by `build.sh`)
1. `0001` (from redwood): use the soc-repo headers on every target, not only seraph.
2. `0002` smcinvoke `compat/` variant: accept the 5.4 UAPI layout next to the 6.12 one.
3. `0003` qseecom: keep the three 5.4 ioctls the 6.12 driver dropped.
4. `0004` smcinvoke `si_core_xts/` variant (the one the BSP config builds): same 5.4 layout.
5. `0005` (audit 2026-11-18) qseecom_dlkm provides the `qseecom_proxy` ops (`-DCONFIG_QSEECOM=1` for
   `qseecom/qseecom.o`); both smcinvoke variants no longer register their `-EOPNOTSUPP` listener stub.
   A TZ listener request raised inside an smcinvoke call now reaches qseecomd, as on 5.4. Kernel
   clients of `qseecom_start_app()`/`qseecom_send_command()` (hdcp) also go to the legacy qseecom driver.
6. `0006` qcedev: a queued request that times out or is signalled no longer clears another
   request's `active_command` and returns `-ETIMEDOUT`/`-EINTR` instead of 0.
7. `0007` qseecom: closing a keymaster client fd frees its handle (was leaked).
8. `0008` qseecom: restore the 5.4 `sigprocmask()` calls around the listener waits.
`gen-0002-*.py` / `gen-0004-*.py` are the scripts that made the edits (reference only).

### UAPI comparison, 5.4 phone headers vs 6.12 (`uapi-compare/result.txt`)
- **qseecom.h**: all 33 ioctls that exist on both sides have identical numbers (so identical
  argument sizes) for arm64 and armv7 callers; the structures moved to `qseecom_api.h` unchanged.
  Missing on 6.12: `PERF_ENABLE_REQ` (0x970b), `PERF_DISABLE_REQ` (0x970c),
  `SET_BUS_SCALING_REQ` (0xc0049717). libQSEEComAPI issues them (`QSEECom_set_bandwidth`).
  Patch 0003 puts them back with the behaviour the 5.4 driver had on this phone
  (`qcom,no-clock-support`, no bus scaling): handle check, then success. Also wired in the 32-bit
  path. The `case` lists of the 5.4 and 6.12 ioctl switches (64-bit and compat) are otherwise equal.
- **Samsung additions to qseecom on 5.4**: none. `drivers/misc/qseecom.c`, `compat_qseecom.c`,
  `smcinvoke.c` and `qcedev.c` of the phone's tree contain no SAMSUNG/SEC ifdef and no extra ioctl.
- **smcinvoke.h**: CHANGED. `smcinvoke_obj` grew from 16 to 24 bytes (so every argument slot),
  `smcinvoke_cmd_req` 0x18 -> 0x20, `smcinvoke_accept` 0x30 -> 0x38 with fields reordered,
  `smcinvoke_server` 4 -> 16, ACK_LOCAL_OBJ s32 -> s64. All four ioctl numbers differ
  (5.4: 0xc0189801, 0xc0309802, 0xc0049803, 0xc0049804). Layout is the same for 32- and 64-bit
  callers. Patches 0002/0004 accept the 5.4 numbers and convert requests, argument arrays
  (16-byte slots) and callback buffers in both directions; 6.12-layout callers are unaffected.
  Not covered: ACK_LOCAL_OBJ does not exist in the si_core variant at all (old and new number get
  -ENOTTY there); it works in the compat variant.
- **qcedev.h**: the 12 ioctls of 5.4 are unchanged for both ABIs; 6.12 only adds two.

### Two smcinvoke variants
The BSP config has `CONFIG_QCOM_SI_CORE=m`, so the default `smcinvoke_dlkm.ko` is the new
si_core-based implementation. `out/smcinvoke-compat/smcinvoke_dlkm.ko` is the SCM transport that
descends directly from the 5.4 driver. Which one the phone's 5.4-era QTEE (bootloader stays at
bit 5 / bit 2) accepts is a hardware question; try the default first, the compat one if
`qseetest` passes but Widevine/mink clients fail.

## Device tree
`a52sxq-secure.dtsi` has the full comparison. The 6.12 base already carries every node with the
phone's values (qseecom, shm bridge, smcinvoke, qcedev with the same SIDs). The only override is
`qseecom_region` 20 -> 28 MiB (the phone's size). No GPIOs, regulators or voltages are involved.
Nothing differs between hardware revisions 3 and 4 here (SoC-level nodes).

## Load order for the Android first stage
Already in `bsp612/out/dist/first-stage.a52sxq.list` (keep their order): `qcom-scm`,
`qcom_ipc_logging`, `gh_rm_drv`, `gh_mem_notifier`, `gh_msgq`, `secure_buffer`,
`msm_dma_iommu_mapping`, `deferred-free-helper`, `mem_buf_dev`, `qcom_dma_heaps`, `qseecom_proxy`.

Add, in this order, after those:

    si_core_module.ko        # soc-repo, built, not in the first-stage list (default smcinvoke needs it)
    sps_drv.ko               # soc-repo, built, not in the first-stage list (qce50 needs it)
    ioncompat.ko             # /dev/ion before qseecomd, keymaster, gatekeeper, allocator HAL
    qseecom_dlkm.ko          # /dev/qseecom: gates the FBE unlock (KeyMint/Gatekeeper)
    smcinvoke_dlkm.ko        # /dev/smcinvoke
    qce50_dlkm.ko
    qcedev-mod_dlkm.ko       # /dev/qce
    # NOT tz_log_dlkm.ko, qrng_dlkm.ko, qcrypto-msm_dlkm.ko, smmu_proxy_dlkm.ko

Second stage (vendor_dlkm `modules.load`), after glink and the ADSP/CDSP remoteprocs:

    frpc-adsprpc.ko          # needs rproc_qcom_common, pdr_interface, minidump, qcom-scm, mem_buf_dev
                             # never together with dsp-kernel's FastRPC driver (same name, same channel)

qseecomd also needs the RPMB path (`/dev/block/sda4`, UFS bsg node `/dev/0:0:0:49476`) and the
firmware partition mounted for the TA images; neither is part of this directory.

## Device nodes: ueventd and SELinux (names must stay exactly these)
From `device/samsung/sm7325-common/init/ueventd.qcom.rc` and the Qualcomm vendor policy
`file_contexts`; all match by name, majors are dynamic and may differ from 5.4.

| Node | ueventd | SELinux label | Driver here |
|---|---|---|---|
| `/dev/ion` | 0664 system system | `ion_device` | ioncompat (misc) |
| `/dev/qseecom` | 0660 system drmrpc | `tee_device` | qseecom_dlkm |
| `/dev/smcinvoke` | 0660 system drmrpc | (vendor policy, by name) | smcinvoke_dlkm |
| `/dev/qce` | 0660 system drmrpc | `vendor_qce_device` | qcedev-mod_dlkm |
| `/dev/adsprpc-smd` | 0664 system system | `vendor_qdsp_device` | frpc-adsprpc |
| `/dev/adsprpc-smd-secure` | 0644 system system | `vendor_xdsp_device` | frpc-adsprpc |

New on 6.12 and unknown to the 5.4 vendor policy: `/dev/dma_heap/*` (blobs do not open them;
leave them unlabelled or root-only).

## First on-device test (busybox test shell of the test ramdisk)
Pack into the ramdisk's `/extra`: the modules above (plus `si_core_module.ko`, `sps_drv.ko` from
`bsp612/out/dist/lib/modules/...` if the ramdisk does not load them), `qseetest64`, `qseetest32`,
`iontest64`, `iontest32`. Trigger from userspace (never built in), so a reset is recoverable.

    insmod /extra/si_core_module.ko
    insmod /extra/ioncompat.ko
    cat /sys/kernel/debug/ioncompat/heaps            # every backing heap [ok]
    /extra/iontest64 -v -s ; /extra/iontest32 -s
    insmod /extra/qseecom_dlkm.ko
    dmesg | grep -i qseecom                          # expect: "qseecom.qsee_version = 0x..."
    ls -l /dev/qseecom
    insmod /extra/smcinvoke_dlkm.ko ; ls -l /dev/smcinvoke
    insmod /extra/sps_drv.ko ; insmod /extra/qce50_dlkm.ko ; insmod /extra/qcedev-mod_dlkm.ko
    /extra/qseetest64 ; /extra/qseetest32
    /extra/qseetest64 -a keymaster64 -a skeymast     # read-only "is this TA loaded" query

`qseetest` prints the QSEE version from `QSEECOM_IOCTL_GET_QSEOS_VERSION_REQ` and must end with
`qseetest: 0 failed`. It checks: version non-zero; the restored PERF ioctls (enable = 0, disable
= -EINVAL on a fresh handle, as on 5.4); the 5.4 smcinvoke INVOKE number is recognised (a
deliberately invalid request must give -EINVAL, not -ENOTTY; nothing is sent to TrustZone);
`/dev/qce` opens. It loads and unloads no trusted app. Then `adsprpc/NOTES.md` "First on-device
test" once the DSPs are up.

Likely failure modes:
- `open /dev/qseecom: errno 6` (ENXIO): the driver is not READY: probe failed. Look for
  `unable to parse memory-region of heap ...` (DT phandles `qseecom_ta_mem`/`user_contig_mem`)
  or shm-bridge registration errors (`qtee_shmbridge` not enabled by the hypervisor).
- insmod of `qseecom_dlkm` resets the phone: an SCM call the 5.4-era TZ rejects fatally. The
  crash guard of the test ramdisk recovers; compare the SCM IDs with the 5.4 driver.
- qseecom probes but the version is 0: `qcom_scm_qseecom_call` failed, see dmesg.
- smcinvoke INVOKE gives -ENOTTY (25): patch 0002/0004 is not in the loaded module.
- `iontest -s` fails on secure heaps: see `ioncompat/README.md` (mem-buf lend path).

## Userspace contract: kept / changed / not verifiable here
- Kept (compile-level proof): all qseecom ioctl numbers for 64- and 32-bit callers incl. the three
  restored ones; the four 5.4 smcinvoke numbers; all 12 qcedev numbers; `/dev/ion` ABI (ioncompat
  test, ABI asserts); adsprpc header byte-identical to the phone's, 32-bit numbers equal to what an
  armv7 caller computes; device node names.
- Changed: `/proc/tzdbg` is gone (tz_log not loaded); `/dev/msm-rng` is gone (unused);
  `/sys/kernel/ion` does not exist; ION prefetch/drain are stubs; device majors are dynamic.
- adsprpc: the task brief says 20 ioctls; the phone's `adsprpc_shared.h` defines 19 (GETPERF is
  commented out there). A 32-bit MUNMAP_FD was added (5.4 answered -ENOTTY).
- Not verifiable without hardware: everything at run time. In particular whether this phone's
  TZ accepts the 6.12 qseecom's SCM calls and shm bridge use, which smcinvoke variant works,
  the smcinvoke layout conversion with a real mink client (Widevine), listener traffic of
  qseecomd (RPMB, SFS), the mem-buf lend/reclaim of secure ION buffers, and FastRPC with the
  5.4 DSP firmware: **redwood's own STATUS.md still lists remote-heap ADD_PAGES as refused with
  this same legacy driver**, so the legacy driver is not a proven fix for that.
- Trap for anyone porting 5.4 drivers that take ION fds: `dma_buf_get_flags()` exists on GKI
  6.12 but no Qualcomm heap implements it (always 0), so secure buffers would look non-secure.
  Use `ioncompat/include` (its `linux/msm_ion.h` redirects the call to the mem-buf VMID query).
