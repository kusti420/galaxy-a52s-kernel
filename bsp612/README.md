# bsp612: Qualcomm's 6.12 BSP for yupik (SM7325), built with plain make

First hop of the two-hop plan (5.4 -> Qualcomm 6.12 BSP -> ACK 6.18). This directory builds the
**unmodified** Qualcomm KERNEL.PLATFORM.5.0 kernel for target `lahaina` / `CONFIG_ARCH_YUPIK`
without bazel/kleaf: the GKI `Image`, the yupik device trees and all in-tree (soc-repo) vendor
modules. No Samsung board support yet. Nothing here has been booted; nothing is flashed by any
script in this directory.

State 2026-11-11 20:00: `./assemble.sh && ./build.sh` runs clean from scratch in 3.5 minutes
(24 cores), 0 errors, 0 compiler warnings (dtc prints Qualcomm's usual unit-address warnings),
depmod reports no unresolved symbol. Logs of the clean run and of a second, incremental run:
`out/full-run-clean.log`, `out/full-run-incremental.log`.
sha256: Image `70310a1805709be4...`, yupik.dtb `43cd7aea010d2057...`.

## Result

| What | Where | Size / count |
|---|---|---|
| Kernel `Image` (pure GKI, 6.12.81) | `out/dist/Image` | 41,052,672 bytes |
| Base dtb the A52s bootloader would select | `out/dist/dtb/yupik.dtb` | 345,882 bytes, has `/__symbols__` |
| All lahaina/yupik dtb + dtbo | `out/lahaina/arch/arm64/boot/dts/vendor/qcom/` | 355 files |
| GKI modules | `out/dist/modules-gki.list` | 110 |
| soc-repo (vendor) modules | `out/dist/modules-soc.list` | 272 |
| Stripped modules + `modules.dep` | `out/dist/lib/modules/6.12.81-4k-g8a69376da734/` | 44 MB |
| Proposed first-stage list (UFS + USB + PMIC keys), load order | `out/dist/first-stage.a52sxq.list` | 94 modules, 9.9 MB |
| Module config (GKI + lahaina_perf) | `out/dist/lahaina_perf.config` | |
| DT comparison (step 4) | `out/dt-compare.txt` | |

Version string: `Linux version 6.12.81-4k-g8a69376da734 (android-build@localhost) (... clang
version 20.0.0 ... r547379)`. Module vermagic: `6.12.81-4k-g8a69376da734 SMP preempt mod_unload
modversions aarch64`.

`yupik.dtb` carries exactly the ids of the base the phone boots today
(`downstream-dt/yupik-base.dts`): `qcom,msm-id = <475 0x10000>, <515 0x10000>`,
`qcom,board-id = <0 0>`. (`yupik-hsp.dtb` is board-id `<0 1>`, `yupik-iot.dtb` is msm-id 497.)

## How KERNEL.PLATFORM.5.0 is put together (what `assemble.sh` reproduces)

Found in soc-repo's `BUILD.bazel`, `kleaf-scripts/{android_build,dtbs,modules_register}.bzl`,
`build/Makefile` + `build/common_sources.mk`, and the manifest
`KERNEL.PLATFORM.5.0.r48-00400-kernel.0.xml`:

- `kernel_platform/common` = ACK `android16-6.12`, **unmodified**, built with `gki_defconfig`.
  For the `perf` variant the base kernel is `//common:kernel_aarch64`: the Image and the GKI
  modules are plain GKI. (`consolidate` = GKI + `consolidate.fragment`, a debug kernel; not built
  here.)
- `kernel_platform/soc-repo` = `clo/la/kernel/qcom` (`kernel.lnx.6.12.*`). `donors/clo-kernel-6.12`
  is this repo. It is **not a kernel tree** and is never merged into `common` (its top-level
  `Makefile` is a stale copy that says 6.11). It is an overlay of Qualcomm's drivers built as
  one external module tree against the GKI kernel:
  - Kconfig: ACK's top `Kconfig` ends with the Android hook
    `source "$(KCONFIG_EXT_PREFIX)Kconfig.ext"`. Kleaf generates `Kconfig.ext` by flattening
    soc-repo's `Kconfig.msm`; we write a one-line `Kconfig.ext` that sources it.
  - Config: `configs/lahaina_perf.bzl` is a Starlark dict of 399 symbols. Kleaf turns it into a
    defconfig fragment (`"n"` -> `# ... is not set`) and applies it on top of `gki_defconfig`
    **for the module build and the dtb build only**. `assemble.sh` does the same conversion into
    `lahaina_perf.fragment`.
  - Sources: soc-repo Makefiles also build unchanged ACK drivers that GKI leaves out
    (`clk-qcom`, `ufs-qcom`, `cfg80211`, ...). For that the ACK `drivers/` and `net/` `.c/.h`
    files are copied to `soc-repo-staging/` and soc-repo is laid over them; three files are an
    ACK source plus a soc-repo `.diff` (`qti_fixed_regulator.c`, `gpi_fixed.c`, `virtio_net.c`).
    `build/Makefile` in that staging tree is Qualcomm's own plain-make entry point
    (`make -C <ACK> M=<staging>/build modules`, soc-repo headers ahead of ACK's).
- Device tree = `clo/la/platform/vendor/qcom-opensource/devicetree`. The manifest checks it out
  at `kernel_platform/qcom/opensource/devicetree` and links it to
  `soc-repo/arch/arm64/boot/dts/vendor`; kleaf passes it as `dtstree` to a `make dtbs` of the ACK
  tree with `DTC_FLAGS=-@` and `DTC_INCLUDE=soc-repo/include`. Here it is linked as
  `kernel/arch/arm64/boot/dts/vendor` (an untracked symlink, the only thing added to `kernel/`).
- Techpacks (display, GPU, camera, audio, securemsm, IPA, rmnet, WLAN, ...) are separate repos
  built as further external modules against the same config with soc-repo's `Module.symvers`.
  Not built here yet.

### Exact sources

| Part | Source | Commit |
|---|---|---|
| `kernel/` | `https://android.googlesource.com/kernel/common`, tag `android16-6.12-2026-06_r3` (6.12.81) | `8a69376da734aa00bb02cd1155489c74454e4487` |
| `soc-repo/` | copy of `donors/clo-kernel-6.12` (`kernel.lnx.6.12.r70-rel`) + `patches/soc-repo/` | `46f13428ae2d6e32ddfe2f3e5cb5046428ae73b4` |
| `devicetree/` | copy of `donors/clo-devicetree-6.12` (`kernel.lnx.6.12.r70-rel`) | `d6e4067ef0794f213ddbb39682048171111d8b89` |

Why this ACK commit: soc-repo names it itself. `soc-repo/android/ACK_SHA` contains
`8a69376da734...` / `android16-6.12-2026-06_r3`, and that AOSP tag peels to exactly this commit.
The only public KP 5.0 r48 manifest tag (`r48-00400`) is one step older than our donor: it pins
soc-repo and devicetree at `kernel.lnx.6.12.r69-rel` (`d08fc445...`, `0e8fa33b...`) and
`kernel/common` at CodeLinaro's own mirror, commit `8fc057fab756...` ("Snap ... to
android16-6.12-keystone-qcom-release", also 6.12.81). I fetched that commit and diffed it
against our tag: 13 files, +177/-8 lines, kept as
`patches/reference/clo-common-8fc057fab756-vs-ack-8a69376da734.diff` (not applied). All of it
is bazel plumbing or code behind config symbols that `gki_defconfig` leaves off
(`QCOM_VM_MEMORY_FEATURES_NONGKI`, `SWIOTLB_NONLINEAR`, `QTVM_IOMMU_TRACE_HOOKS`,
`GKI_HACKS_FOR_DEBUG_CONFIG`: Qualcomm trusted-VM and debug builds). For the lahaina perf build
the two trees produce the same kernel, so the plain AOSP tag is used.

Toolchain: ACK pins clang `r536225` (`build.config.constants`). The AOSP prebuilts on this PC
start at `r547379` (clang 20.0.0), the nearest newer one; that is what `build.sh` uses. It
needed no source change. Identity is forced to `android-build@localhost`.

## Layout

    assemble.sh            builds soc-repo/, soc-repo-staging/, devicetree/, lahaina_perf.fragment
    build.sh               gki | config | soc | dtbs | collect | dtcompare | all
    kernel/                ACK android16-6.12 (git clone, untouched)
    soc-repo/              donor copy + patches (reset on every assemble.sh)
    soc-repo-staging/      ACK drivers/net sources + soc-repo; also holds the module objects
    devicetree/            donor copy (+ patches/devicetree/, none yet)
    lahaina_perf.fragment  generated from soc-repo/configs/lahaina_perf.bzl
    patches/{kernel,soc-repo,devicetree}/
    tools/dtcompare.{sh,py}   step 4 check
    tools/first-stage.py      first-stage module list with dependencies, in load order
    tools/mkpatch.sh          turns an edit in soc-repo/ or devicetree/ into a patch file
    techpacks-probe.sh     optional: compile mm-drivers, securemsm, kgsl, display (see below)
    techpacks/             donor copies made by the probe
    patches/reference/     CodeLinaro common vs AOSP tag diff (not applied)
    out/gki/               O= dir of the GKI build (Image, GKI modules, Module.symvers, vmlinux)
    out/lahaina/           O= dir with the lahaina_perf config: modules_prepare output + dtbs.
                           This is the tree every vendor module and techpack builds against.
    out/dist/              the deliverables

## Building

    ./assemble.sh          # idempotent; clones kernel/ if missing
    ./build.sh             # all steps, about 3.5 minutes; logs in out/*.log

Steps of `build.sh` (each can be run alone):

1. `gki`: `make O=out/gki gki_defconfig; make Image modules`.
2. `config`: `make O=out/lahaina KCONFIG_EXT_PREFIX=soc-repo/ gki_defconfig`, merge
   `lahaina_perf.fragment`, `olddefconfig`, `modules_prepare`; then copy `Module.symvers` and link
   `vmlinux` from `out/gki` (kleaf's `base_kernel`; vmlinux is needed for module BTF).
3. `soc`: `make O=out/lahaina M=soc-repo-staging/build KERNEL_SRC=kernel modules`.
4. `dtbs`: `DTC_INCLUDE=soc-repo/include make O=out/lahaina DTC_FLAGS=-@
   dtstree=arch/arm64/boot/dts/vendor dtbs`. `DTC_INCLUDE` must be in the environment, not on
   the make command line (Makefile.dtbs appends to it).
5. `collect`: `out/dist` with stripped modules, one `modules.dep` over both module sets
   (`depmod -e -F System.map`: empty output = every symbol resolves), lists.
6. `dtcompare`: `out/dt-compare.txt`.

To work on a fix inside `soc-repo/`: edit there, `KEEP_EDITS=1 ./assemble.sh` (re-stages without
resetting), `./build.sh soc`, then `tools/mkpatch.sh soc-repo <name> <files> < description` and a
plain `./assemble.sh` to prove the patch reproduces it. Do not edit `build.sh` while it runs
(bash re-reads the file).

## Config result

`gki_defconfig` + `lahaina_perf.fragment` configures cleanly. Of 399 fragment symbols one did
not take (`out/config-not-taken.txt`):

- `CONFIG_UAPI_HEADER_TEST=y`: depends on `CC_CAN_LINK`, which needs a target sysroot that a
  plain clang build does not have. Build-time header test only; no effect on the kernel.

The fragment changes 30 symbols that GKI sets (list: compare `out/dist/gki.config` with
`out/dist/lahaina_perf.config`), e.g. `ARM64_AMU_EXTN`, `SOFTLOCKUP_DETECTOR`, `SERIAL_DEV_BUS`,
`BT_HCIUART`, `ZRAM_*` off and `GUNYAH*` y -> m. That is Qualcomm's file as shipped; as in kleaf
it only affects how the vendor modules see the config, the Image is still GKI. Because of the
stale `GUNYAH=m`, Qualcomm's first-stage list names modules that do not exist on this ACK
(`gunyah.ko`, `gunyah_rsc_mgr.ko`, `gunyah_hypercall.ko`, `gunyah_platform_hooks.ko` are built
into the GKI Image; `regmap-spmi` too; `qcom_tzmem` is part of `qcom-scm.ko`; `crypto-qti` and
`sched-walt-debug` are not enabled in perf). `out/dist/first-stage-not-built.list` has them.

## What was patched, and why

Nothing was disabled. All fixes are for Qualcomm's plain-make path, which is clearly less
tested than the bazel one; no source file and no ACK file was changed.

| Patch | Problem |
|---|---|
| `patches/soc-repo/0001-build-Makefile-search-the-ACK-source-root-last.patch` | `build/Makefile` put `-I$(srctree)/` before the kernel's include paths, so `<crypto/hash.h>` resolved to ACK's private `crypto/hash.h` and all of mac80211's crypto users failed to compile. Moved to the end. |
| `patches/soc-repo/0002-net-phy-qcom-build-qcom-phy-lib-as-its-own-module.patch` | `qca808x-objs += qca808x.o ...` makes a module a member of itself. Built as `qcom-phy-lib.ko` + `qca808x.ko`, like ACK. (Ethernet PHY; irrelevant for the phone, kept so the set is complete. One module more than the bazel build.) |
| `patches/soc-repo/0003-soc-qcom-adsp_sleepmon-find-qcom_common.h.patch` | include path to `drivers/remoteproc` missing in the Makefile (kleaf lists the header as a module source). |
| in `assemble.sh` (not a patch) | Qualcomm's staging rsync takes only `drivers/` and `net/`; the aquantia PHY Makefile links `lib/crc-itu-t.c`. The `lib/` and `sound/` entries of `common_sources.bzl` `COPY_FILES` are staged too, as kleaf does. |
| in `build.sh` (not a patch) | `DTC_INCLUDE` from the environment; `Module.symvers` + `vmlinux` of the GKI build placed in `out/lahaina`. |

Three module names exist in both sets (`zram.ko`, `zsmalloc.ko`, `virtio_console.ko`). Qualcomm
blocks the GKI `zram` and `zsmalloc` (`modules-lists/modules.systemdlkm_blocklist.msm.lahaina`)
and loads its own copies, which are built with other options (no zstd backend, no writeback).
Load only one of each on the phone.

## Techpack probe (beyond the task, to check that `out/lahaina` works as the module base)

`./techpacks-probe.sh` copies four donors to `techpacks/`, applies redwood's patches where they
apply, and builds them with plain make against `out/lahaina` + soc-repo's `Module.symvers`.
Compile and modpost only; none of it is wired to a device tree or tested.

| Techpack (donor tag) | Result | Modules |
|---|---|---|
| `mm-drivers` | builds, 0 errors | `msm_ext_display.ko` (the fence modules are not built for this target) |
| `securemsm-kernel` + redwood 0001, `CONFIG_QSEECOM=m` | builds, 0 errors | `qseecom_dlkm`, `smcinvoke_dlkm`, `qce50_dlkm`, `qcedev-mod_dlkm`, `qcrypto-msm_dlkm`, `qrng_dlkm`, `hdcp_qseecom_dlkm`, `smmu_proxy_dlkm`, `tz_log_dlkm` (**never load `tz_log_dlkm` on yupik**) |
| `graphics-kernel` + redwood 0001, 0002 | builds, 0 errors | `msm_kgsl.ko` (has `qcom,adreno-gpu-a642l`) |
| `display-drivers` | builds, 0 errors, after one probe-only line in its `Kbuild` (`LINUXINCLUDE := $(SOCINCLUDE) $(LINUXINCLUDE)`: this branch has no hook to put the soc-repo headers first) | `msm_drm.ko` (yupik catalog present), `lt9611uxc.ko` |

Redwood's `display-drivers` and `mm-drivers` patches do not apply to our donor tags (they were
written for other branches) and were not needed to compile. Tried and failed in one shot each,
left for the next stage: `dataipa` (its lahaina Kbuild branch still expects the 5.4 in-tree
path `$(srctree)/techpack/dataipa` and QGKI config; errors in `ipa.c`/`ipa_net.c` from missing
soc-repo scm/ncm declarations) and `datarmnet` (needs the dataipa and `datarmnet-ext/mem`
headers on its include path). Redwood builds both with bazel. Not tried: `audio-kernel`
(its Makefile wants `LEGACY_PATH=../vendor/qcom/opensource/audio-kernel[/legacy]`),
`camera-kernel`, `datarmnet-ext`.

## DT comparison (step 4): the stock Samsung overlay cannot apply on the 6.12 base

`tools/dtcompare.sh` -> `out/dt-compare.txt`. Inputs: `downstream-dt/yupik-base.dts` (5.4 base),
`out/dist/dtb/yupik.dtb` (6.12 base), the three entries of `testdev-PHONE1/dtbo.img`
(entry 0 = hw rev 2..0x20, the one a rev 3 phone uses; entries 1 and 2 = rev 1 and rev 0; all
three need the same labels).

- 5.4 base: 3156 nodes, 1454 labels. 6.12 base: 2606 nodes, 1163 labels. 496 labels of the 5.4
  base do not exist in the 6.12 base; 234 exist at a different path (harmless for an overlay,
  which resolves labels through `/__symbols__`).
- The stock overlay needs 149 base labels (56 as fragment targets, 129 fragments, plus two
  `target-path = "/"` fragments). **53 of them are missing in the 6.12 base, 16 of those are
  fragment targets.** libufdt (ABL) and libfdt both abort on the first missing label.
  Confirmed with host `fdtoverlay`: stock dtbo entry 0 on the 5.4 base applies (exit 0), on
  the 6.12 base fails with `FDT_ERR_NOTFOUND`.
- What is missing is everything that Qualcomm moved out of the base tree into techpack device
  trees that do not exist for yupik on 6.12:
  - audio (the bulk): `audio_apr`, `q6core`, `bolero`, `lpi_tlmm` + its pin states, `yupik_snd`,
    `adsp_loader`, `afe`, `routing`, `pcm0/1/2`, `compress`, `voice`, `lsm`, `stub_codec`,
    `dai_mi2s*`, `va_cdc_dma_0_tx`, `*_swr_gpios`, `cdc_dmic*_gpios`, `lpass_*_hw_vote`;
  - display: `mdss_mdp`, `mdss_dsi0`, `mdss_dsi_phy0`, `sde_dp`, `sde_rscc`, `smmu_sde_sec`,
    `smmu_sde_unsec`, `ext_disp_audio_codec`;
  - camera: `cam_cci0`, `cam_cci1`;
  - `secure_carveout_heap` (ION heap node; 6.12 has `yupik-dma-heaps.dtsi` instead),
    `msm_imem` (`/soc/qcom,msm-imem@146aa000`), `cpu4..7_isolate` (cpu-isolation cooling).
- Present but moved (30 of the needed labels): all RPMh regulators are one level deeper
  (`/soc/rsc@18200000/drv@2/rpmh-regulator-*`), the QUP I2C/SPI/UART nodes sit under
  `/soc/qcom,qupv3_{0,1}_geni_se@...`, PCIe is `/soc/pcie@...`. Labels are unchanged
  (`L7B`, `pm8350c_l3`, `qupv3_se13_i2c`, ...), so a new overlay can keep using them.
- Hypervisor overlay targets: **both exist in the 6.12 base as they are**:
  `/soc/qcom,wdt@17c10000` (label `wdog`) and `/soc/timer` (label `arch_timer`); the root labels
  `reserved_memory`, `aliases`, `firmware` and `qcom_tzlog` are there too, and the bus is `/soc`
  (not `/soc@0`). The placeholder nodes the 6.18 mainline-style dts needs are not needed here.
  `/hypervisor` is absent in both bases (the hypervisor overlay adds it).
- Reserved memory: 22 of the fixed regions are identical. The phone's merged 5.4 tree
  (`a52sxq-r02.dts`) differs from the 6.12 base in: ADSP at `0x84700000 +0x4800000` (6.12 base:
  `0x86700000 +0x2800000`, plus `video_region@85b00000` and `camera@86200000` in the space
  Samsung gives to the ADSP), `cvp@8b200000`, `removed_region@c0000000` size `0x6a00000` (base:
  `0x5100000`), and Samsung's own regions (`ramoops@f0b00000`, `sec_debug`, `ss_plog`, `kaslr`,
  `hdm`, `tima`, `dummy_mem`, `modem_shared_mem`). The new overlay must restore this map: the
  phone's firmware images are linked for it (redwood hit the same thing).

Verdict: the stock dtbo is unusable on the 6.12 base and cannot be made to apply by adding a few
labels; a new a52sxq overlay has to be written on the 6.12 bindings, and the audio, display,
GPU and camera trees for yupik have to be brought in first (ported from the 5.4 tree, as redwood
did: `donors/redwood-6.12/qcom/{display,gpu,redwood-audio,redwood-camera}`). The bootloader side
looks easier than on 6.18: ids match, `/__symbols__` is there, the hypervisor's paths exist.

## Next stage: ordered TODO

1. **a52sxq overlay on the 6.12 bindings** (`devicetree/qcom/a52sxq-overlay.dtso`, added to
   `NOAPQ_YUPIK_BOARDS` with base `yupik.dtb`, carried as `patches/devicetree/`). Start from the
   6.18 bring-up dts and `downstream-dt/a52sxq-r02.dts`:
   - root: `qcom,msm-id = <475 0x10000>, <515 0x10000>`, `qcom,board-id = <0x22 2>`,
     `dtbo-hw_rev = <2>`, `dtbo-hw_rev_end = <0x20>` (values of stock entry 0);
   - the Samsung memory map (list above), ramoops at `0xf0b00000` with the 5.4 layout;
   - `&tlmm gpio-reserved-ranges` for the secure pins 56..59;
   - regulators: override every `rpmh-regulator-*` child the board uses with the voltages of
     `downstream-dt/regulators-r02.txt`, min == max (the base carries Qualcomm IDP values; the
     6.12 driver still uses `qcom,init-voltage`);
   - UFS (`&ufshc_mem`, `&ufsphy_mem`: VCC L7B, VCCQ L9B, PHY L10C/L6B, reset TLMM 175), USB 2.0
     device mode (`&usb0`, `&usb2_phy0`), volume/power keys;
   - disable what the board does not have (PMR735A/PM8008 users, SD card, IDP-only nodes).
   Check with `fdtoverlay` on `yupik.dtb`, then with the acceptance checks of
   `mkimage-ack.sh` (`__symbols__`, `__fixups__`, merged size).
2. **Bring-up image** in the proven recovery format: GKI `Image` + our ramdisk with
   `out/dist/first-stage.a52sxq.list` loaded in file order + `yupik.dtb` + the new dtbo.
   GKI has no `DEVTMPFS` and no fbcon/simple-framebuffer (same as on 6.18): either the ramdisk
   creates its device nodes itself, or build a second, non-GKI bring-up Image with a small
   fragment (then vendor modules must be built against that kernel's `Module.symvers`).
   Pass `clk_ignore_unused pd_ignore_unused` until display is up. Boot test only on the test
   phone and only when the user says so.
3. **First-stage modules** for UFS + USB: `out/dist/first-stage.a52sxq.list` = Qualcomm's lahaina
   first-stage list minus stale and SM8350-only entries, plus `dwc3-msm`, `phy-msm-snps-hs`,
   `phy-msm-ssusb-qmp`, `pinctrl-spmi-gpio`, `qcom-pon`, `pm8941-pwrkey` and their dependencies.
   Leave out `qcom_edac` (IRQ storm on redwood) and never load `tz_log` (resets the phone on
   yupik). Display adds, once built: `msm_drm.ko` and its mm-drivers dependencies
   (`sync_fence`, `msm_hw_fence`, `msm_ext_display`), plus the Samsung panel code inside
   `msm_drm`.
4. **Techpacks, in this order** (each: copy the donor to `bsp612/techpacks/<name>`, build with
   `make -C kernel O=out/lahaina M=<techpack> KBUILD_EXTRA_SYMBOLS=soc-repo-staging/build/Module.symvers
   SOCINCLUDE="-Isoc-repo/include -Isoc-repo/include/uapi" CONFIG_ARCH_LAHAINA=y CONFIG_ARCH_YUPIK=y`;
   redwood's `scripts/stage2.sh` has the exact variables per techpack and `patches/` the fixes):
   (`techpacks-probe.sh` already compiles steps 1-4 below; what is left there is device tree,
   Samsung panel code and runtime work.)
   1. `securemsm-kernel` with `CONFIG_QSEECOM=m` (lahaina leaves it off; keymaster/gatekeeper
      need `/dev/qseecom`; without it vold never mounts /data). Redwood patch
      `securemsm-kernel/0001`. The A52s has no wrapped keys, so redwood's HWKM v1 patch is not
      needed.
   2. `mm-drivers` (headers and fence modules display and GPU need; redwood patch 0001).
   3. `display-drivers` (redwood patch 0001 "Build for lahaina and yupik again"; check that our
      donor tag still has SDE 7.2 / `IS_YUPIK_TARGET`) + yupik display dtsi ported from 5.4 +
      Samsung `ss_dsi_panel` with the S6E3FC3 AMS646YD01 panel files. Largest single item.
      Every `dgm` block in `qcom,sde-sspp-dma-blocks` needs a `cell-index`.
   4. `graphics-kernel` (kgsl A642L; redwood patches 0001 and 0002: old `libgsl` passes the list
      size as entry size) + `yupik-gpu.dtsi` from graphics-devicetree.
   5. Compatibility shims for the 5.4 vendor: `/dev/ion` (`modules/ioncompat` already written for
      6.18; redwood's is the reference), `subsys_compat` (5.4 PIL sysfs paths), pd-mapper
      patches (redwood `soc-repo/0003`, `0004`: yupik domains, `rproc_qcom_common.pd-mapper`).
   6. `audio-kernel` (legacy Elite/APR) + the yupik audio dtsi ported from 5.4 + TAS256x amp.
   7. `dataipa`, then `datarmnet` + `datarmnet-ext` (the modem crashes when it goes online
      without IPA; netmgrd wants the old `rmnet_data` UAPI).
   8. Wi-Fi (`qcacld-3.0` + `wlan/platform` icnss2; not cloned yet; `iommu-addresses` instead of
      `qcom,iommu-dma-addr-pool`) and Bluetooth (`bt-kernel`).
   9. Camera (decide: `camera-kernel` 6.12 with its additive UAPI, or the 5.4 driver ported
      forward like redwood's `camera54`), then video (5.4 `msm_vidc` v1 forward-port), legacy
      `adsprpc`.
5. Samsung board drivers on 6.12 (donor trees in `research/source-scout.md` section 5): SM5714
   MFD/charger/fuel gauge/MUIC, S2MPB03, `sec_input` + STM FTS5CU56A touch, `sec_battery`,
   PCA9468, et7xx, sec_nfc, vibrator.
6. Then the second hop: carry the working set to ACK 6.18.

### Lessons from redwood's STATUS.md that apply to a Samsung board

- Build vendor modules against the lahaina config (`out/lahaina`), never the bare GKI one:
  against GKI the soc-repo headers hand out stubs that fail silently (cmd-db, RPMh tables).
- Firmware memory map comes from the 5.4 tree, not from Qualcomm's 6.12 base.
- `clk_ignore_unused pd_ignore_unused` while the display takes over the bootloader splash.
- No `qcom_edac`, no `tz_log`.
- IPA must be up before the modem goes online; set remoteproc `recovery` to enabled first.
- `qcom,iommu-dma-addr-pool` is refused by the 6.12 IOMMU code for new users: use
  `iommu-addresses` (WLAN); display and audio-ion still work with the old property.
- Audio: `qcom,rproc-handle` instead of the subsystem name; in-kernel pd-mapper needs the yupik
  compatible; APR children on first ADSP up. The Samsung audio HAL's mixer names are frozen
  ABI, and redwood found 5.4 mixer path names missing on the 6.12 audio-kernel: expect work.
- LRME must stay in the camera DT or CamX ZSL pipelines fail.
- 5.4 DSP firmware refuses FastRPC `ADD_PAGES` remote-heap grows with the new driver: legacy
  `adsprpc` forward-port.
- Strip modules before packing a ramdisk; an unstripped vendor ramdisk was refused by their
  bootloader (ours has an 81 MiB image limit anyway).
- Never let a 6.12 test boot write the real /data (redwood: /data on tmpfs, userdata held
  read-only by a guard module). On the A52s test phone the same rule applies.
- Xiaomi-specific items (battery property layout, HWKM v1 wrapped keys, slot b testing) do not
  apply: the A52s has no A/B slots (recovery partition is the test slot) and no wrapped keys.

## Open points

- Not boot-tested. The build proves the sources, config and toolchain; whether GKI 6.12.81 +
  these modules boot on yupik hardware is unverified here (redwood reports it on r35/r48).
- Donor soc-repo/devicetree are `r70-rel`; the newest public manifest tag (r48-00400) pins
  `r69-rel`. No manifest for r70 was found; the r70 soc-repo names its ACK commit itself.
- clang `r547379` instead of the pinned `r536225`: no build difference seen, but GKI module
  ABI checks (KMI) were not run; irrelevant as long as we ship our own Image.
- `consolidate` (debug) variant not built.

## First bring-up image (2026-11-11, TODO items 1-3 done offline, not booted)

`./mkimage-612.sh <name>` -> `../images/a52sxq-bsp612-<name>-recovery.img` (packs only).
Details, expected log markers, assumptions and failure modes: `BRINGUP.md`.

    dts/a52sxq-bringup-overlay.dts   overlay on yupik.dtb (plain dtc, literal numbers)
    ramdisk/init, ramdisk/leave      bring-up init (module stage, mkdevs, crash guard)
    mkramdisk-612.sh                 -> out/bringup/ramdisk-612.cpio.gz (+ hhwdt for 6.12)
    mkimage-612.sh                   -> image + bootloader-acceptance checks
    out/bringup/                     dtbo, merged.dtb, load.list, hhwdt build, ramdisk

The overlay is not wired into the Qualcomm devicetree build (`NOAPQ_YUPIK_BOARDS`), as TODO
item 1 proposed: it is built by `mkimage-612.sh` directly, which keeps `devicetree/` unpatched.

Findings that change the TODO list above:
- The base `yupik.dtb` has NO PMIC children on the SPMI bus and UFS disabled; Qualcomm adds
  them in the board overlays. The a52sxq overlay must carry every PMIC node it needs.
- The base's regulator table is already the phone's for 44 of 50 rails (table below); "override
  every rpmh-regulator child" is not needed, and for the six that differ it is better done
  together with their consumers.
- `gcc-sc7280` (6.12) registers 14 firmware-owned clocks that the phone's 5.4 `gcc-yupik` does
  not know; the overlay extends `protected-clocks`.
- `qcom,gpios-reserved` is the only source of reserved TLMM pins in the 6.12 driver.
- "download" is not a reboot reason Qualcomm's 6.12 code knows: `sec_core.ko` is required.
- dwc3-msm needs `eud.ko` (extcon phandle) and a write of `peripheral` to its `mode` attribute.
- Do not load `qcom-dload-mode.ko` on this phone until upload mode is wanted.

### Regulator table (rule: every voltage is the phone's 5.4 value, never the reference board's)

Method: all 50 RPMh regulator nodes of the 6.12 `yupik.dtb` were compared with the phone's merged
5.4 tree (`downstream-dt/a52sxq-r02.dts`): min, max, `qcom,init-voltage`, always-on/boot-on.
44 are identical. The 6.12 `rpmh-regulator` driver works like the 5.4 one: it sends nothing for
a regulator until a consumer enables it or the core has to move the voltage into the min..max
window, and `is_enabled` is the driver's own cached state (so the late "disable unused" pass
never touches a rail Linux did not enable itself).

Rails this image USES (consumers probe and enable them). No value had to be changed:

| Rail | Consumer in this image | Phone 5.4 (min / max / init) | 6.12 base | Overlay |
|---|---|---|---|---|
| L7B `pm7325_l7` | UFS VCC (`vcc-voltage-level` 2.504/2.952 V, 800 mA) | 2.400 / 3.544 / 2.952 V | same | supply reference only |
| L9B `pm7325_l9` | UFS VCCQ + ref-clk rail (900 mA) | 1.200 / 1.304 / 1.200 V | same | supply reference only |
| L6B `pm7325_l6` | UFS PHY PLL (18.4 mA) | 1.140 / 1.260 / 1.200 V | same | supply reference only |
| L10C `pm8350c_l10` | UFS PHY core (97.5 mA), USB HS PHY vdd (`qcom,vdd-voltage-level` 0 / 0.88 / 0.88 V) | 0.720 / 1.050 / 0.880 V | same | supply reference only |
| L1C `pm8350c_l1` | USB HS PHY vdda18 | 1.800 / 1.980 / 1.800 V | same | untouched (base reference) |
| L2B `pm7325_l2` | USB HS PHY vdda33 | 2.700 / 3.544 / 3.072 V | same | untouched (base reference) |
| `gcc_ufs_phy_gdsc`, `gcc_usb30_prim_gdsc` | UFS host, USB controller | GDSC | same | reference only |
| VDD_CX / VDD_MX levels | clock controllers, proxy votes | ARC levels 16..65535 | same | untouched |

Rails where the Qualcomm 6.12 base DIFFERS from the phone. None is used by this image, no
consumer exists, so Linux sends no request for them and they stay as the bootloader left them.
They are deliberately NOT overridden in the first overlay: giving L8C/L13C the phone's
`min = max` with the lower init voltage makes the regulator core issue a set-voltage at
registration, and the phone's `regulator-boot-on` without a display driver would end with the
panel rails switched off at the late cleanup. Put the phone's values in when the consumer
(display, touch, fingerprint) is ported:

| Rail | Phone 5.4 (name; min / max / init; flags) | 6.12 base (min / max / init) | Used on the phone by |
|---|---|---|---|
| L3C `pm8350c_l3` | `VDD_BTP_3P3`; 3.300 / 3.300 / 3.300 V | 2.800 / 3.540 / 2.800 V | named for the fingerprint sensor (no DT consumer found) |
| L7C `pm8350c_l7` | 3.000 / 3.000 / 3.000 V; boot-on | 3.000 / 3.544 / 3.000 V | touch AVDD (`tsp_avdd_ldo-supply`) |
| L8C `pm8350c_l8` | `panel_vddi`; 1.800 / 1.800 / 1.620 V; boot-on | 1.620 / 2.000 / 1.620 V | panel VDDI |
| L12C `pm8350c_l12` | 1.800 / 1.800 / 1.800 V; always-on | 1.650 / 2.000 / 1.650 V | always-on 1.8 V rail (no DT consumer found) |
| L13C `pm8350c_l13` | `panel_vci`; 3.000 / 3.000 / 2.700 V; boot-on | 2.700 / 3.544 / 2.700 V | panel VCI |
| S1B `pm7325_s1` | 1.856 / 2.040 / 1.872 V | 1.840 / 2.040 / 1.872 V | buck feeding LDOs (init equal) |

`regulator_ignore_unused` is on the command line as a second belt: GDSC "regulators" report
the real hardware state, and without it the display GDSC and friends would be switched off
30 s after boot.

### Enabled nodes of the 6.12 base that own a GPIO, a regulator or an I2C/SPI device

The base `yupik.dtb` is SoC-only (Qualcomm puts the IDP/QRD board parts — panels, cameras,
charger, fuel gauge, haptics, NFC, touch, codecs, SD card, PMIC children — into its board
overlays, which are not in the image). So the list is short. A node can only drive hardware if
its driver is loaded; the "module in ramdisk" column is the second safety net.

| Node (label) | Owns | Module in ramdisk | Decision |
|---|---|---|---|
| `gcc` clock-controller@100000 | vdd_cx | gcc-sc7280 | keep; FIX: `protected-clocks` + 15 firmware-owned clocks (below) |
| `dispcc` @af00000 | vdd_cx | dispcc-sc7280 | keep (same as the 6.18 boot; `clk_ignore_unused`) |
| `camcc`, `gpucc`, `videocc` | vdd_cx/mx | not loaded | keep, inert |
| `qcom,limits-dcvs` (cpufreq-hw) | isens vref supplies | not loaded | keep, inert |
| `bluetooth` bt_wcn6750 | TLMM 84/85/86 enables, 9 rails | not loaded | DISABLED (reference-board enable pins) |
| `wpss_pas`, `modem_pas`, `adsp_pas`, `cdsp_pas` | cx/mx | not loaded | keep, inert (no remoteproc starts) |
| 6 camera GDSCs, 2 video GDSCs, `gpu_cx_gdsc`, `gpu_gx_gdsc` | parent-supply VDD_CX | gdsc-regulator (defer: their clock controllers are not loaded) | keep |
| `disp_cc_mdss_core_gdsc` | proxy vote | gdsc-regulator | keep (holds the splash's power domain) |
| `refgen` regulator@88e7000 | proxy vote | not loaded | keep, inert |
| `usb0` ssusb@a600000 | `gcc_usb30_prim_gdsc` | dwc3-msm | keep; FIX: USB 2.0 only, device mode from userspace |
| `usb2_phy0` hsphy@88e3000 | L10C, L1C, L2B | phy-msm-snps-hs | keep (supplies already the phone's) |
| `usb_qmp_dp_phy` ssphy@88e8000 | L1B, L6B, pinctrl | dropped | DISABLED (phone uses `usb_nop_phy` as second PHY) |
| `qcom,dma-heaps` | depends-on-supply | qcom_dma_heaps (symbol dependency) | keep |
| `kgsl_smmu`, 5 `*_tbu` of apps-smmu | GDSC vdd | arm_smmu | keep (same as 5.4) |
| `qupv3_se1_i2c` i2c@984000 + `rtc6226` (FM radio, fmint-gpio, 2 rails) + `fsa4480@42` | I2C devices | not loaded (no geni drivers at all) | DISABLED (bus and both devices) |
| `ufshc_mem`, `ufsphy_mem` (disabled in the base) | L7B, L9B, L10C, L6B, TLMM 175 | ufs-qcom, phy-qcom-ufs-qmp-v4-yupik | ENABLED with the phone's values |
| `tlmm` | all TLMM pins | pinctrl-yupik | keep; FIX: `qcom,gpios-reserved` + 56..59 |
| RPMh regulators (50) | PMIC rails | rpmh-regulator | keep; see regulator table |
| `spmi_bus` (empty in the base) | PMICs | spmi-pmic-arb | ADDED: PMK8350 pon + SDAM 0x7100, PM7325 GPIO block (vol-up) only |
| `wdog` qcom,wdt@17c10000 | hypervisor-owned watchdog | dropped (`qcom_wdt_core`, `gh_virt_wdt`) | keep the node (the hypervisor's overlay patches it to disabled); `hhwdt` is used instead |
| `eud` qcom,msm-eud@88e0000 | extcon of `usb0` | eud (added) | keep (enabled on the phone's 5.4 too) |

Everything else in the base (QUP serial engines other than SE1, PCIe, SD host `sdhc_2`, sound,
display, cameras) is `disabled` in `yupik.dtb` already or has no driver in the ramdisk.
