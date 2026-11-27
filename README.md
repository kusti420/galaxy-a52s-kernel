# a52sxq-kernel: Galaxy A52s 5G on current Android kernels

Kernel-side work to run the **Samsung Galaxy A52s 5G (SM-A528B, codename a52sxq, Snapdragon
778G / SM7325 "yupik")** on current Android kernels instead of Qualcomm's end-of-life 5.4
vendor kernel, while keeping the phone's closed vendor userspace (camera, audio, sensors, modem
blobs) working unchanged.

Two kernel targets, one source tree:

- **6.12**: Qualcomm's official 6.12 BSP for this chip family (KERNEL.PLATFORM.5.0, target
  `lahaina` with `CONFIG_ARCH_YUPIK`) on ACK `android16-6.12`, plus the Samsung board support
  and the downstream drivers ported here (`bsp612/`, `drivers612/`).
- **6.18**: Android Common Kernel `android17-6.18`, with the same drivers forward-ported
  (`bsp618/`, generated from `drivers612/` + `bsp618/port/patches/`).

This repository holds **sources only**: patch series, out-of-tree modules, device trees, build
and test scripts, and the notes needed to understand them. There are no kernel images, modules,
ramdisks or firmware in the tree; prebuilt test images are published separately (see
[Download](#download)).

## Download

Prebuilt **alpha** images are published as GitHub Releases of this repository (the Releases
page). Each release has its own README with the install and roll-back steps and a SHA256SUMS
file. Read the [safety notes](#safety-read-before-touching-a-phone) first.

**Linux 6.12 for the SM-A528B, any ROM.** Qualcomm's 6.12 BSP kernel (GKI 6.12.81 + the
forward-ported Qualcomm/Samsung drivers from this tree) in place of the phone's 5.4 kernel, as a
kernel-only recovery zip: it is not tied to a ROM. It is meant for Android 17 ROMs for the
SM-A528B that use the stock-derived a52sxq vendor (tested: LineageOS 24, IchthysOS, K4_UN1CA
One UI 9 port). The ROM and its vendor blobs run unchanged. For enthusiasts only.

Requirements:

- SM-A528B with an unlocked bootloader and a custom ROM installed (AVB verification disabled in
  vbmeta, as custom ROMs are installed).
- Android 17 with the a52sxq vendor. The installer accepts any Android ROM of this phone; on a
  ROM it was not tested with, or an Android version older than 17, it prints a warning and
  installs anyway (untested: it may not boot; the restore zip brings your ROM's kernel back).
- The mobile network (modem) needs the bootloader-bit-5 firmware (A528BXXU5...). On older
  firmware the phone boots, but TrustZone refuses the modem (no cellular).
- TWRP, or a recovery that can sideload zips.

What works (tested on two phones): display 120 Hz, touch, GPU, CPU/GPU/bus frequency scaling,
Wi-Fi, Bluetooth, NFC, LTE voice + mobile data, calls (CS/CSFB) + SMS, speaker/mic/call audio,
cameras (photo/video, flash, torch), hardware video decode, fingerprint (enroll + unlock), 32
sensors, battery + charging, USB, microSD, vibrator, SELinux enforcing, the real encrypted
`/data`.

Known issues: each release lists its own in the release notes.

Install in short (the release notes have the exact steps): flash the release's
`a52s-k612-<name>.zip` in the recovery. The zip keeps your ROM's own ramdisks, Android version
and security patch level; it replaces only the kernel, the first-stage modules, the device tree
and the dtbo, backs the current images up first and never writes `/vendor`. To roll back, flash
the release's `a52s-k612-restore.zip`: your ROM's own kernel is back. After a ROM update flash
the kernel zip again. If it bootloops: hold Vol-down + Power about 7 s to restart, then at once
Vol-up + Power with USB plugged in for the recovery, and flash the restore zip (or Vol-down +
Vol-up with USB plugged in for Download mode, and flash your ROM's own
`boot.img`/`vendor_boot.img`/`dtbo.img`). The first alphas (before alpha 6) were packages with
a `/vendor` add-on for LineageOS 24 only; their own READMEs describe them.

Two rules from the release notes that protect the phone:

- Never flash official firmware with a higher bootloader bit than the phone has (there is no
  way back).
- Never load firmware images from another phone or another firmware version: TrustZone raises
  its anti-rollback counter and the phone's own older images stop working.

## Status

Tested on SM-A528B units with their own stock firmware, booting Android 17 (LineageOS 24,
IchthysOS and the K4_UN1CA One UI 9 port) through the kexec test harness and as a real boot.

| Feature | 6.12 (Qualcomm BSP) | 6.18 (ACK android17-6.18) |
|---|---|---|
| Boot to Android UI | yes | yes |
| Display, colours, 120 Hz panel cmds | yes | yes |
| Screen off/on, brightness | yes | yes |
| Touch | yes | yes |
| GPU (kgsl) | yes | yes |
| CPU frequency + WALT | yes | yes |
| Thermal zones (tsens) | yes | yes |
| Board thermistors ap/bat | yes | yes |
| Board thermistors pa/wf | yes | not tested |
| Battery, charging, USB-PD | yes | yes |
| Speaker playback | yes | yes |
| Microphone / recording | yes | yes |
| Low-latency audio QoS vote | yes | yes |
| Sensors (SSC on ADSP) | yes | yes |
| ADSP / CDSP / FastRPC | yes | yes |
| Wi-Fi | yes: internet 122 Mbit/s | yes: internet 124 Mbit/s |
| Bluetooth | yes: scan | yes: on |
| NFC | yes | yes |
| Camera preview + photo (rear, front) | yes | yes |
| Video recording (1080p H.264+AAC) | yes | yes |
| HW video decode | yes | yes |
| Torch / flash LED | yes: torch | yes: torch |
| Vibrator | yes | yes |
| Fingerprint | yes | HAL up; FOD port pending |
| Suspend (s2idle shallow, RTC wake) | yes | yes |
| Suspend deep (cluster collapse) | not tested | not tested |
| Android autosuspend | not tested | not tested |
| Modem / cellular | yes | yes |
| Long soak | 45 min clean | 30 min clean + endurance w/ suspend |
| Real boot (flash boot/vendor_boot/dtbo) | yes | yes |

"not tested" means not tested yet, not known broken.

## Supported hardware

**SM-A528B only** (Galaxy A52s 5G, international, Snapdragon 778G). Other A52/A52s variants
(SM-A525F/M Helio, SM-A528N, US models) and other SM7325 phones are **not** supported: device
trees, regulators, panel and firmware layout differ.

## Safety: read before touching a phone

- **Bootloader binary (the "bit" / rollback index).** Never flash a Samsung firmware or
  bootloader with a higher binary revision than the phone has: the rollback fuse is burnt and
  there is no way back. Nothing in this project needs a newer bootloader.
- **Never flash another phone's firmware** (modem, EFS, persist, sec_efs, calibration
  partitions) or partition images taken from a different unit. Device-unique data (IMEI, Wi-Fi
  and BT MAC, calibration) lives there; crossing it over breaks the phone and may be illegal.
  The scripts only ever read firmware from the phone they run on.
- **Use the kexec harness first** (`kexec/`): a test kernel is booted from the running system
  into RAM, and a reboot brings back the installed kernel. Only flash `boot`/`vendor_boot`/`dtbo`
  after a kernel passed the kexec tests on your unit.
- **Have the way back ready before any flash**: dump your current `boot`, `vendor_boot`, `dtbo`,
  `recovery` and `vbmeta` images first, write down the exact restore command
  (`drivers612/realboot/README.md`, `drivers612/realboot/tools/mk-odin-rollback.sh`), and know
  how to reach Download mode with the keys (power off, hold both volume keys, plug in USB).
- The bootloader must be unlocked; a modified kernel trips Knox permanently.
- No warranty. You can lose data or brick the phone.

## Layout

| Directory | What |
|---|---|
| `bsp612/` | assembles and builds the Qualcomm 6.12 BSP with plain `make` (no bazel): `assemble.sh`, `build.sh`, the soc-repo patch series, board DT overlay |
| `drivers612/` | per-subsystem driver ports for 6.12 (audio, camera, display, GPU/video, Wi-Fi/BT/modem, NFC, touch, fingerprint, power/charging, suspend, secure/ION), each with its build script, patches, DT fragment and README |
| `drivers612/boarddt/` | the a52sxq board device tree for the 6.12 BSP |
| `drivers612/realboot/` | builds flashable boot/vendor_boot/dtbo images (`build-realboot.sh`) and the rollback tooling |
| `bsp618/` | the 6.18 port: `port/port618.py` + `port/patches/`, Android packaging under `android/` |
| `kexec/` | the kexec test harness (boot a test kernel from the running phone without flashing) |
| `modules/` | standalone modules (ION compatibility layer, hardware watchdog helper) |
| `patches/ack-6.18/` | patches and the board DTS for ACK 6.18 |
| `samsung612/` | Samsung driver porting notes and compile checks |
| `downstream-dt/` | the 5.4 device trees as built from Samsung's kernel source (decompiled), the reference the 6.12 board DT is checked against |
| `research/` | notes: blob UAPI inventory, driver gap inventory, bootloader acceptance, sources |
| `tools/` | small helpers (on-device test tools, module ordering, DT tools) |

## Getting the sources this builds against

Kernel trees and the Qualcomm driver repositories are not copied in; they are fetched at the
commits this tree was built with (`SOURCES.lock`). The vendored driver trees under
`drivers612/` (for example `drivers612/audio/audio-kernel`) ship only the files we wrote plus a
`<tree>.upstream/` directory: the pinned upstream repository, the list of its files the tree
uses, and our changes to them as one patch. `tools/prepare-vendored.sh` rebuilds the full tree.

    tools/fetch-sources.sh                 # the trees needed to build (--all: also reference donors)
    tools/prepare-vendored.sh              # rebuild the vendored driver trees from them

## Building (6.12)

Host: Linux, clang/lld (Android prebuilt clang r547379 is what was used), `make`, `python3`,
`dtc`, `mkbootimg`, `avbtool`. Several scripts read the Android tree for the prebuilt clang and the
vendor image (`ANDROID_TREE`, default `$HOME/android`).

    tools/fetch-sources.sh
    bsp612/assemble.sh && bsp612/build.sh          # GKI Image + soc-repo modules + dtbs
    drivers612/<subsystem>/build.sh                # out-of-tree driver modules
    drivers612/realboot/build-realboot.sh <tag>    # boot/vendor_boot/dtbo images

Firmware is taken from your own phone's vendor partition at runtime; none is included here.
The test ramdisks (`mkramdisk.sh`, `bsp612/mkramdisk-612.sh`, `kexec/`) take busybox, musl and
`unudhcpd` from the postmarketOS initramfs of the woa-a52s `pmos-kodiak` packaging (fetched to
`pmos-kodiak/` by `tools/fetch-sources.sh`); the small helpers they add (`tools/rb.c`,
`tools/kx.c`, `drivers612/androidboot/a52init/`) are built from the sources here. No prebuilt
binary is shipped.
See `bsp612/README.md`, `drivers612/realboot/README.md` and `kexec/README.md` for the details.

## Licences

- Kernel code (patches, modules, drivers, device trees) is **GPL-2.0** (`GPL-2.0-only` or
  `GPL-2.0-or-later` as marked in each file), like the kernels it is part of.
- Third-party code is kept under its own licence and copyright: the Qualcomm/CodeLinaro
  techpacks (audio-kernel, display, graphics, camera, securemsm, wlan qcacld/fw-api: GPL-2.0 and
  ISC/BSD-3-Clause-Clear files), Samsung kernel drivers (GPL-2.0), and the userspace pieces under
  `drivers612/modem/userspace/src` (BSD-3-Clause, from linux-msm).
- Scripts and tools written for this project: GPL-2.0 unless a file says otherwise.

SPDX identifiers found in the exported files, by directory:

| Directory | SPDX (file count) |
|---|---|
| `bsp612` | BSD-3-Clause (1) |
| `bsp618` | GPL-2.0-only (1) |
| `drivers612/androidboot` | GPL-2.0 (1) |
| `drivers612/audio` | GPL-2.0-only (17), GPL-2.0-or-later (2) |
| `drivers612/boarddt` | GPL-2.0 (35), BSD-3-Clause (4) |
| `drivers612/camera` | GPL-2.0-only (25), GPL-2.0 WITH Linux-syscall-note (6), GPL-2.0-only WITH Linux-syscall-note (3) |
| `drivers612/conn` | GPL-2.0-only (18), BSD-3-Clause (3), GPL-2.0 (3), GPL-2.0-only WITH Linux-syscall-note (3) |
| `drivers612/debug` | GPL-2.0 (4) |
| `drivers612/display` | GPL-2.0-only (9), GPL-2.0 (3) |
| `drivers612/fingerprint` | GPL-2.0-only (3) |
| `drivers612/gpu-video` | GPL-2.0-only (47), GPL-2.0 WITH Linux-syscall-note (3), BSD-3-Clause (1) |
| `drivers612/hwbringup` | GPL-2.0-only (2), GPL-2.0 (1) |
| `drivers612/modem` | BSD-3-Clause (13), GPL-2.0-only (8), GPL-2.0 (2) |
| `drivers612/nfc` | GPL-2.0-only (3), GPL-2.0 (1) |
| `drivers612/power` | GPL-2.0 (30) |
| `drivers612/qfprom-sys` | GPL-2.0-only (1) |
| `drivers612/realboot` | GPL-2.0 (19), GPL-2.0-only (8), BSD-3-Clause (1) |
| `drivers612/samsung-oneui` | GPL-2.0-only (34), GPL-2.0 (19), GPL-2.0-or-later (6), GPL-2.0+ (1) |
| `drivers612/secure` | GPL-2.0-only (17), BSD-3-Clause (4), GPL-2.0 WITH Linux-syscall-note (3), GPL-2.0-only WITH Linux-syscall-note (1) |
| `drivers612/sensors-factory` | GPL-2.0 (1) |
| `drivers612/suspend` | GPL-2.0-only (1) |
| `drivers612/touch` | GPL-2.0-only (5) |
| `drivers612/vibrator` | GPL-2.0 (1) |
| `drivers612/wifibt` | GPL-2.0 (2), BSD-3-Clause (1) |
| `dtbo` | BSD-3-Clause (1) |
| `modules` | GPL-2.0-only (10), GPL-2.0 WITH Linux-syscall-note (3), GPL-2.0-only WITH Linux-syscall-note (1), GPL-2.0 (1) |
| `patches` | BSD-3-Clause (6), GPL-2.0-only (4), GPL-2.0-only OR BSD-2-Clause (2) |
| `samsung612` | GPL-2.0-only (2) |
| `tools` | GPL-2.0 (2), GPL-2.0-only (1) |
