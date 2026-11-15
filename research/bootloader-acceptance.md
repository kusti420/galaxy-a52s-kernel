# What the A52s bootloader requires of kernel, dtb and dtbo (static analysis, 2026-11-11)

Scope: Samsung ABL `A528BXXSAGYA2` (LinuxLoader built "Jan 9 2025 15:22:55"), XBL and Gunyah
("haven") hypervisor from the stock firmware zip. No hardware was touched.

## Result in one paragraph

The 2026-10-03 refusal of `test1` was a **bootloader-side rejection; the mainline kernel never
ran**. The ABL's device-tree overlay library (an old libufdt) aborts when the base dtb has no
`/__symbols__` node, and also when the overlay has no `/__fixups__` node. `test1` violated both:
the mainline dtb was built without `-@`, and our one-entry overlay uses only `target-path = "/"`,
so dtc emitted no `__fixups__`. `BootLinux()` returns an error, and the only thing
`LinuxLoaderEntry` does after `BootLinux()` returns is "Launching odin" (Download mode, with no
reason line, which matches the "black-screen variant" seen). The 16 s is not a watchdog: the
first, unsigned image failed in `LoadImageAndAuth` (pure bootloader, before any kernel) and
showed the same 16 s and the same screen, because both failures end at the same `Launching odin`
call. Nothing in the ABL inspects the kernel beyond the arm64 header.

Confidence: high for "bootloader-side, overlay step" (the code path is unconditional). Not
verified on hardware.

## Material and method

- The directory `$HOME/Downloads/a52s-bit-bypass/` named in the task **does not exist**
  on this PC (checked `~/Downloads`, `~`, `~/git`); nothing from it was used.
- `BL_A528BXXSAGYA2...tar.md5` extracted from the firmware zip into
  `research/bl-scout/fw/` (`NON-HLOS`, `dspso` and the tar itself deleted again).
  `research/bl-scout/bin/`: `abl.elf`, `xbl.elf`, `hypvm.mbn`, `xbl_config.elf` (decompressed).
- `abl.elf` = FV at 0x3000, LZMA section at 0x3078 → 2.48 MB volume with four PE32+ images
  (`scripts/carve.py`, `scripts/pe.py`): OdinApp (0xac), **LinuxLoader (0xee0e8,
  `carve/abl/pe/LinuxLoader.efi`)**, two Quest apps. It is a DEBUG build: all `DEBUG()` strings
  are present, which makes the logic readable.
- `carve/abl/LinuxLoader.dis`: capstone disassembly with ADRP+ADD string cross-references
  (`scripts/dis.py`; file offset == RVA). `scripts/view.py <dis> <start> <end>` prints a range
  with the debug-print boilerplate collapsed. Function addresses below are RVAs in that file.
- `carve/xbl/uefiplat.cfg`: XBL's memory map, plain text inside `xbl.elf` at 0xE005B.
- `img/`: all five boot images unpacked; `scripts/kh.py` (arm64 header), `scripts/dtbo.py`
  (dtbo table), `scripts/resmem.py` (reserved-memory coverage).
- Qualcomm's open `QcomModulePkg` was used from memory as the reference for function names;
  every statement below is from the Samsung binary itself.

## 1. Boot flow in this ABL (BootLinux = 0x13fb8)

Caller: `LinuxLoaderEntry`, `0x1c10: add x0, sp, #0x28; bl 0x13fb8; b 0x1d38`. At 0x1d38 the
code checks CC mode and then prints "Launching odin" and starts `Odin`. There is no error screen
on this path, only `DEBUG()` text to the UART log. `LoadImageAndAuth` failure (0x1bf0) joins the
same path.

Inside BootLinux, in order (every "fatal" returns an EFI error → Odin):

| Step | Address | Check | Fatal? |
|---|---|---|---|
| Kernel type | 0x1457c | `kernel[0x38] == "ARMd"`, else treated as a 32-bit kernel | wrong path |
| Optional prefix | 0x14558 | image starts with `UNCOMPRESSED_IMG` → "Patched kernel detected", skips 0x14 bytes | no |
| Load addresses | 0x145ac–0x14710 | UEFI vars `KernelBaseAddr`/`KernelSize`; fallback PCDs: offset 0x80000, size 0x5600000. Header offsets in the boot image are ignored. Ramdisk = end − ALIGN(ramdisk) − 0x1000; DT = ramdisk − 0x201000. "Not Enough space left to load kernel image" | yes |
| Physical KASLR | 0x14728–0x148d0 | random N (0..63), kernel load += N × 0x8000; writes magic `0xcdefcdef` + offset to **physical 0xA0001000** | hangs only if the RNG fails |
| gzip | 0x14a28 | gzip kernels are inflated (zlib 1.2.8); no lz4 | on error |
| Runtime size | 0x14b1c | arm64 header `image_size` ≤ DT − kernel ("DTB header can get corrupted due to runtime kernel size") | yes |
| Overlap | 0x14bb4 | `image_size + 2 MB` must end below the DT address ("Kernel is overlapped with DT") | yes |
| SoC dtb | 0x14f88 → 0x18880 | best `qcom,msm-id` match in the dtb area ("Appended Soc Device Tree blob not found") | yes |
| Board dtbo | 0x14fac → 0x19d20 | best match in the dtbo table ("Board Dtbo blob not found") | yes |
| Hyp overlays | 0x15058 | if VM-hyp is active, hypervisor-supplied dtbos are queued too; NULL list is fatal, a bad entry is skipped | partly |
| EDTBO | 0x1513c | Samsung `edtbo` partition, optional; version compare via `dtbo-version` | no |
| **ApplyOverlay** | 0x152ac–0x15328 | `ufdt_install_blob` + `ufdt_apply_overlay`; NULL → "ApplyOverlay: ufdt apply overlay failed" → "Error: Dtb overlay failed" | **yes** |
| Size | 0x15358 | merged dtb must fit in ramdisk − DT = 0x201000 (about 2 MB) | yes |
| `dtbo-version` in merged dtb | 0x15420 | missing → "Error finding dtbo-version property at Dtb", continues | no |
| HDM policy, cmdline | 0x158f4, 0x15920 | `UpdateCmdLine` error is fatal | yes |
| UpdateDeviceTree | 0x15a40 → 0x1b440 | see section 3 | partly |
| Jump | 0x15f14 | `x0 = dtb, x1 = base, x2 = kernel − base, x3 = 0; blr kernel` | – |

## 2. The cause: libufdt in this ABL (0x3de64–0x3e380)

```
3dea0: ... "/__symbols__"      ; looked up in the MAIN tree (x19)   -> x21
3debc: ... "/__fixups__"       ; looked up in the OVERLAY tree (x20) -> x0
3dec8: cbz x21, 0x3df38        ; "Bad main_symbols in ufdt_overlay_do_fixups"  -> 0x3e35c
3ded0: cbz x0,  0x3e124        ; "Bad overlay_fixups in ufdt_overlay_do_fixups" -> 0x3e35c
3e35c: ... "failed to perform fixups in overlay" ; mov w28, #-1 ; return
```

Both are hard errors in this version (current AOSP libufdt tolerates them; `fdtoverlay`, which
`mkimage.sh` uses as its check, also tolerates them, so the host-side check passed).
`/__local_fixups__` may be absent (0x3e774: NULL → returns 0).

What the inputs had (`strings` on the unpacked blobs):

| Blob | `__symbols__` | `__fixups__` |
|---|---|---|
| stock base dtb (`yupik`) | yes | – |
| stock dtbo entry 2 | yes | yes |
| mainline `sm7325-samsung-a52sxq.dtb` (test1, bisectB) | **no** | – |
| our overlay (test1) | no | **no** |

So: `test1` fails at 0x3dec8. `bisectB` (mainline dtb + stock dtbo) would fail at the same
place. `bisectA` (mainline kernel + stock dtb + stock dtbo) would pass the bootloader and enter
the 7.2 kernel with the downstream tree (no usable console; it would have needed a key reset).

## 3. Everything else the ABL does with the trees

### SoC dtb and dtbo selection (0x18880, 0x19d20, matcher 0x18b08)

- Standard Qualcomm matching on root `qcom,msm-id` (first pair only: platform id, SoC revision
  ≤ chip revision) and `qcom,board-id`. Our dtb has the same values as stock
  (`<0x1db 0x10000 0x203 0x10000>`, `<0 0>`), so it is selected.
- The dtbo is **not** chosen by `dtbo-hw_rev`/`dtbo-hw_rev_end` (those strings do not occur in
  the ABL). It is chosen by `qcom,board-id = <0x22 N>`: variant 0x22 must equal the board type,
  and N is compared with Samsung's hardware revision (0x2b730, "FindBestMatch GetBoardRev"):
  equal = exact, lower = best match, higher = rejected ("subtype-id doesnot match", 0x195cc).
  The stock table has N = 0, 1, 2; this phone (revision 3) takes N = 2. Our overlay's
  `<0x22 0x02>` matches the same way; `<0x22 0x00>` would match every revision.
- Table entry fields `id`/`rev`/`custom` are all 0 in the stock table and are not used.

### UpdateDeviceTree (0x1b440) and Samsung additions

| Path / property | What the ABL does | If missing |
|---|---|---|
| `/memory` (libfdt also matches `memory@80000000`) | fills `reg` from the RAM partition table; needs root `#address-cells`/`#size-cells` (1 or 2, equal) | **fatal** |
| `/memory`: `ddr_device_type`, `ddr_device_rank_ch*`, `ddr_device_hbb_ch*_rank*` | adds properties | not fatal |
| `/mem-offline` `granule` | updates | "INFO", not fatal |
| `/reserved-memory/splash_region` `reg` | rewrites address/size | not fatal |
| `/reserved-memory/demura_region_0/1`, `/soc/qcom,dsi-display-primary/secondary` `qcom,demura-panel-id` | only when demura info exists | not fatal |
| `/chosen` | `bootargs`, `rng-seed`, `kaslr-seed`, `linux,initrd-start/end` | node missing or `bootargs`/`initrd` write failing is **fatal**; seeds are not |
| `/reserved-memory` (0x1ace8, Samsung) | SMC 0xC300C000 (uh), then adds `uh_heap_region` (0xB0200000 + 0x200000) and `uh_guest_region` (from 0xB0400000) with `reg` only | logged, not fatal |
| `/firmware/android/fstab`, `/soc/` | boot-device fix-up of fstab entries | not fatal |
| `/cpus` and the `qcom,*` multimedia nodes | "partial goods" pruning; only on chips with fused-off blocks | error is fatal, but not reached on a normal chip |
| `dtbo-version` (root) | read for logging and EDTBO comparison | not fatal |

No `sec_debug`, `sec-bootstat`, `samsung,*` or panel path is required in the tree. Samsung data
(`sec_debug.*`, `androidboot.*`, panel id, `androidboot.dtbo_idx`) is passed on the command
line only.

### Kernel image

- Only checks: "ARMd" magic and `image_size` (section 1). No "Linux version" search, no
  `SEANDROIDENFORCE` requirement, no RKP/KDP signature check in LinuxLoader.
- `text_offset` in the header is ignored: load address is always base + 0x80000 + N × 0x8000.
  So the kernel is never 2 MB aligned. Mainline and ACK handle this only with
  `CONFIG_RELOCATABLE=y` (`early_map_kernel`: `pa_base % MIN_KIMG_ALIGN`); both `out/.config`
  and GKI have it.
- Headers (`scripts/kh.py`): stock 5.4 `text_offset 0x80000, image_size 0x334d000`;
  mainline 7.2 `text_offset 0, image_size 0x1860000`; ACK 6.18 (`out-ack`) `text_offset 0,
  image_size 0x2bb0000`. The stock kernel is already larger than `ramdisk_offset 0x01000000`
  and ends past `dtb_offset 0x01f00000`, which confirms those header fields are not used.
- Size budget: `image_size + ALIGN(ramdisk + vendor ramdisk, 4K) ≤ K − 0x482000`. `K` is the
  XBL "Kernel" region, `0xA0000000 + 0x10000000` in `uefiplat.cfg` (256 MB), or 0x5600000
  (86 MB) if the UEFI variables are absent. Which of the two applies was not proven; stock
  (0x334d000 + 0x1246000) fits both, ACK 6.18 with a 19 MB ramdisk (0x3df6000) fits both.
  The recovery partition (81,788,928 bytes) is the tighter limit; a gzip kernel is accepted.
- Entry: under Gunyah at EL1; `x1`/`x2` are non-zero (mainline only warns). The ROM's own
  working kernel has `CONFIG_UH`, `CONFIG_RKP`, `CONFIG_KDP` off
  (`vendor/lineage-a52sxq_defconfig`), so the hypervisor does not need kernel cooperation.

## 4. Download mode, watchdog, the 16 s

- Bootloader hypothesis: supported by the code (sections 1, 2) and by the first test, where an
  AVB failure, which cannot involve a kernel, produced the identical symptom and timing.
- Kernel-hang hypothesis: ruled out for `test1`, since the jump at 0x15f28 is never reached.
- For future tests (not proven statically): the application watchdog at 0x17c10000 is owned by
  the hypervisor (`hypvm.mbn`: "WDT Control: VM, enable", "WDT Set times", "WDT: Triggering NS
  Watchdog Bite"; XBL uses `SMC_ID_WDOG_CTL`). The ABL contains no application-watchdog code
  and disables the PMIC watchdog ("Error Disable pmic watchdog in LaunchDefaultBDSApps").
  Whether a watchdog is still armed at kernel entry could not be established. The downstream
  node is `qcom,msm-watchdog` at 0x17c10000 with no timing properties; the driver default is
  bark 11 s, bite bark + 3 s. Mainline `kodiak.dtsi` has the node as `status = "reserved"` and
  our dts does not enable it, so a hung test kernel is expected to stay hung until volume down
  + power.
- A refused boot image leaves Odin in the state the 2026-10-03 log describes (official binaries
  only). That follows from entering Odin through the failure path instead of a requested one.

## 5. Mainline dts vs stock tree, for a silent early hang

Checked on the `test1` dtb:
- Reserved memory: every fixed downstream region is covered (`scripts/resmem.py`, 33 of 33),
  including `kaslr@a0001000`, which the ABL writes before the jump.
- Root `interrupt-parent`, `/memory@80000000`, `/chosen`, `/reserved-memory`, `/firmware`,
  `/soc@0` (matches the ABL's `/soc` lookups) are present. PSCI is `smc` in both trees.
- `gcc` `protected-clocks` is present (status log). Not re-verified against TZ here.
- Command line: the downstream kernel has `COMMAND_LINE_SIZE 4096`, ACK 6.18 has 2048. The ABL
  appends a long `androidboot.*`/`sec_debug.*` tail after the image's own arguments; anything
  past 2047 characters is cut silently. Harmless for an initramfs test, relevant for Android.
- Display proof-of-life depends on `simple-framebuffer` + `CONFIG_DRM_SIMPLEDRM` + fbcon and on
  the listed clocks staying on (`clk_ignore_unused pd_ignore_unused` are in the cmdline).

Open risk: hypervisor-supplied overlays. The resource manager in `hypvm.mbn` generates an
overlay for the primary VM (`/hypervisor`, `qcom,haven-*`, `__fixups__`, `target-path`
strings), and the ROM kernel has the Haven drivers on. If such an overlay is queued, it is
applied to our base dtb by the same libufdt, and a fixup naming a label our tree lacks is fatal
("Couldn't find '%s' symbol in main dtb"). The label names could not be recovered statically
(no `intc`/`interrupt-parent` string in the image, which suggests it relies on the root
`interrupt-parent`). A missing target path is logged, and appears to be skipped rather than
fatal; that last point was not traced to the end.

## Ranked causes of the 2026-10-03 refusal

1. **Base dtb has no `/__symbols__`** (built without `-@`). Fatal at 0x3dec8. Confidence ~95 %.
2. **Our overlay has no `/__fixups__`** (no phandle reference to a base label). Fatal at
   0x3ded0 on its own, once 1 is fixed. Confidence ~95 % that it would be the next failure.
3. Hypervisor overlay needing a label absent from the mainline tree. Possible third failure
   after 1 and 2. Confidence ~15 %.
4. Kernel image rejected (header, size, overlap). Ruled out: all checks pass for 7.2 and 6.18.
5. Kernel started and a watchdog or sec_debug reset it into Download mode. Ruled out for
   `test1`; the kernel was never entered.

## Checklist for the 6.18 image on this bootloader

Kernel
- Raw arm64 `Image` (or gzip; no lz4), "ARMd" at 0x38, `image_size` set.
- `CONFIG_RELOCATABLE=y` (load address is 0xA0080000 + N × 0x8000, never 2 MB aligned).
- `image_size + ramdisk ≤ 81 MiB` to be safe under the fallback region size; whole image
  ≤ 81,788,928 bytes for `recovery`.
- Do not depend on `x1`–`x3` being zero. No RKP/uh hooks needed.
- Raise `COMMAND_LINE_SIZE` to 4096 before running Android.

Base dtb
- Build with symbols: `DTC_FLAGS_sm7325-samsung-a52sxq := -@` (or `DTC_FLAGS=-@`).
- Root: `qcom,msm-id = <475 0x10000>, <515 0x10000>`, `qcom,board-id = <0 0>`,
  `#address-cells`/`#size-cells` = 2, `interrupt-parent`; add `dtbo-version = <0>` (optional,
  silences a log line).
- Must exist: `/memory` (unit address allowed), `/chosen`, `/reserved-memory` with 2/2 cells.
- Keep `kaslr@a0001000`, `tima@b0100000` and the rest of the Samsung reservations; the ABL adds
  `uh_heap_region`/`uh_guest_region` itself.
- Keep the label `intc` on the GIC and `soc` on the SoC node (downstream names; cheap insurance
  for the hypervisor overlay).
- Merged dtb < 2 MB.

dtbo (recovery_dtbo, or the dtbo partition for a normal boot)
- Root `qcom,msm-id` as above, `qcom,board-id = <0x22 0x00>` (or one entry per revision like
  stock), `dtbo-version = <0>`.
- At least one fragment must use `target = <&label>` so that dtc emits `/__fixups__`, for
  example `target = <&soc>` with a marker property. `target-path` alone is not enough.
- Verify before any flash: `strings base.dtb | grep -x __symbols__` and
  `strings overlay.dtbo | grep -x __fixups__`. `fdtoverlay` succeeding proves nothing here.

## Lowest-risk first boot on the separate test device

1. Never use the sticky recovery request. Enter the test image with the keys, with `boot`
   untouched, and have the official `recovery.img.lz4` for that device's bootloader at hand
   (Download mode accepts only that after a refusal).
2. Two flashes. First the control repack (stock kernel, ramdisk, dtb, dtbo through
   `mkimage.sh`), to prove the packaging and AVB key on that device. Then the full 6.18 image
   (`-@` base dtb, overlay with a `target = <&soc>` fragment). The mainline dtb cannot be
   tested with the 5.4 kernel, so bootloader acceptance is read from the outcome: back in
   Download mode within seconds = bootloader refusal; a screen that stays black or shows
   kernel text = the kernel was entered.
3. Proof of life without a display, in order of earliness: (a) ramoops at 0xf0b00000 with the
   downstream layout, read after the next normal boot (`SYSTEM_LAST_KMSG`); requires the
   Android on that device to be the ROM whose 5.4 kernel has the same ramoops node. (b) the
   vibrator GPIO or the flash LED toggled from an early initcall. (c) USB gadget with a
   distinctive product ID (not `18d1:d001`). (d) simple-framebuffer console.
4. Watchdog: leave `&watchdog` disabled for the first boot so a slow boot is not cut short;
   add `panic=10` and `CONFIG_PSTORE_CONSOLE` so a panic reboots into the normal system with
   the log saved. Enable the watchdog node only after confirming on the stock kernel of that
   device that 0x17c10000 behaves as `qcom,kpss-wdt` expects.
5. On that device's stock/ROM system, before any flash, read `/proc/device-tree/hypervisor`
   and `/proc/device-tree/__symbols__` once: that shows whether a hypervisor overlay is applied
   and which labels it used, closing risk 3.
