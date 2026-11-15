# fingerprint — A52s optical fingerprint (Egis ET713, `etspi,et7xx`) on the Qualcomm 6.12 BSP

State: **compiles and links against `bsp612/out/lahaina` with no warnings, all symbols resolved;
DT fragment applies to `out-ack/kx/android-r02.dtb` and equals the phone's node. Never loaded on
hardware.** See `STATUS.md` for what is unverified.

## What the phone actually uses

- Sensor: **Egis ET713**, optical, under the AMOLED (`etspi-chipid = "ET713"`, model `A528`).
- 5.4 driver: `drivers/fingerprint/` = `fingerprint_sysfs.c` + `fingerprint_common.c` +
  `fingerprint_common_qcom.c` + `et7xx-spi.c` + `et7xx-spi_data_transfer.c`, built in, with
  `CONFIG_SENSORS_FINGERPRINT=y CONFIG_FINGERPRINT_SECURE=y CONFIG_SENSORS_FINGERPRINT_QCOM=y
  CONFIG_SENSORS_ET7XX=y` (`arch/arm64/configs/vendor/lineage-a52sxq_defconfig`), no
  `SEC_FACTORY`, so `ENABLE_SENSORS_FPRINT_SECURE` is defined.
- **TrustZone-based**: the SPI bus (QUP SE14, `spi@a98000`, TLMM 56..59, function `qup16`) belongs
  to TZ; Egis' trusted app `dualfp` talks to the sensor. The kernel driver is a *platform* driver
  that only does: the 3.3 V rail (PM8350C L3, `VDD_BTP_3P3`), the sleep/reset line (TLMM 35),
  a wakeup source while the HAL "enables the SPI clock", `/dev/esfp0` (ioctls) and
  `/sys/class/fingerprint/fingerprint/*`. All SPI ioctls (`FP_REGISTER_READ` ...) are compiled
  out in this configuration, `et7xx-spi_data_transfer.c` is all `return 0` stubs. There is no
  interrupt, no `poll()`, no panel notifier: the finger-down event comes from touch
  (`/sys/class/sec/tsp/input/fod_pressed`), the illumination from the panel driver.
- HLOS never enables the SE14 clock: `fingerprint_common_qcom.c` only holds a wakelock.
  `gcc_qupv3_wrap1_s6_clk` is a voted branch (APPS vote = `0x52000` bit 13 in both 5.4
  `gcc-yupik` and 6.12 `gcc-sc7280`); TZ votes for itself, so 6.12's clock cleanup cannot take it
  away from TZ. No clock hook is needed (corrects `research/driver-gap-inventory.md` line 840).
- Same node, pin state and rail on hardware revisions r00, r01, r02 (Samsung dts sources);
  bench phones rev 3 / rev 4 boot r02.

## What is here

| Path | What |
|---|---|
| `port.sh` | Regenerates `orig/` + `src/` from the phone's read-only 5.4 tree, applies `patches/*.patch`, builds, fills `stage/` and `pack-fingerprint.tgz` |
| `patches/0001-et7xx-fingerprint-6.12.patch` | The complete change record (4 files, +117 / -32 lines). `mkpatch.sh` regenerates it from `diff orig src` |
| `Kbuild` | Copied into `src/`; the 5.4 Makefile + the a52sxq config switches as `-D` |
| `build.sh` | Compile check only (`src/` must exist); fails on any warning/error; log `build.log` |
| `orig/` | Untouched 5.4 sources (+ Kconfig/Makefile for reference) |
| `src/` | Ported sources and the built `.ko` files |
| `a52sxq-fingerprint.dtsi` | DT fragment: `/soc/etspi,et7xx` + L3C values (header explains every value) |
| `dt-check.sh`, `dt-compare.py` | Builds the fragment as an overlay, `fdtoverlay` onto `out-ack/kx/android-r02.dtb` (`BASE=` for another), compares with the phone's tree, asserts SE14 disabled, TLMM 56..59 reserved and no enabled node using a pin state on them. Output `dt-work/merged.dtb` |
| `esfptest/` | Static arm64 test tool (kernel nolibc) issuing the HAL's kernel ioctls |
| `fp-test.sh` | First on-device test (busybox ramdisk) |
| `stage/` | Module stage for `drivers612/androidboot/pack-kexec-rd.sh` (`load.list` included) |
| `pack-fingerprint.tgz` | `KX_PACK` for the ramdisk test: stripped `.ko`, `esfptest`, `fp-test.sh` |

## Build

    ./port.sh            # regenerate src/ from $ANDROID_TREE/kernel/samsung/sm7325/drivers/fingerprint, build, stage, pack
    ./build.sh           # rebuild src/ only
    ./dt-check.sh        # DT overlay check (BASE=<dtb> to test another base)

Modules (vermagic `6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64`):

| Module | Needs | Provides |
|---|---|---|
| `fingerprint_sysfs.ko` | vmlinux only (7 symbols) | class `fingerprint`, `fingerprint_register/unregister`, `fingerprint_class` |
| `fingerprint.ko` | `fingerprint_sysfs` + vmlinux (66 symbols) | platform driver `egis_fingerprint` (`etspi,et7xx`), chrdev major 152 |

modpost clean; checked separately that every undefined symbol of both modules is in
`bsp612/out/lahaina/Module.symvers` or `src/Module.symvers`. kCFI: no function-pointer casts (all
fops/attr/pm/timer/work callbacks have their exact prototypes); `bsp612/tools/initrefs.py` finds
no data references into `.init`.

## Changes against 5.4 (all in the patch, each marked `a52sxq 6.12:` in the code)

API (required by 6.12):
1. `class_create(THIS_MODULE, name)` -> `class_create(name)` (6.4), version-guarded as in
   Samsung's S26 6.12 `fingerprint_sysfs.c`. Both classes (`fingerprint`, `egis_fingerprint`).
2. `#include "../pinctrl/core.h"` dropped. 5.4 reached into the private `struct pinctrl` to set
   `->state = NULL`, so that selecting the never-looked-up (NULL) secure-mode states returned 0
   without touching pins. Same effect now by NULL checks; the `idle`/`sleep` log lines are kept.
3. `of_get_named_gpio_flags()` (removed) -> `of_get_named_gpio()` (flags were unused).
4. `.llseek = no_llseek` removed (gone in 6.12); `nonseekable_open()` already makes llseek -ESPIPE.
5. platform `.remove` returns `void` (6.11).

Behaviour (bugs that bite on a module build, or a 6.12 trap):
6. Rail lookup: new optional DT property `etspi-btp-supply` -> `regulator_get(dev, "etspi-btp")`,
   which defers until rpmh-regulator has registered L3C. The 5.4 lookup by name with no device
   (`regulator_get(NULL, "VDD_BTP_3P3")`) is kept as fallback; on 6.12 it silently returns the
   dummy regulator if L3C is not registered yet (sensor never powered, no error).
   A non-deferral regulator error no longer skips the sleep-pin request and the wakeup source.
7. `fingerprint_register()` now returns the device it creates (`struct device **`), and
   `fingerprint_unregister()` unregisters it. On 5.4 the device was lost (by-value parameter):
   after rmmod the sysfs files pointed at freed memory and a second insmod failed.
8. Probe error path no longer destroys the module-wide `et7xx_class` (double destroy at rmmod)
   and now drops the minor/list entry; a failed `device_create(esfp0)` now fails the probe.
9. Remove: destroys the debug workqueue (leaked per bind), powers the sensor off first if the
   HAL left it on (6.12 WARNs on `regulator_put` of an enabled consumer).
10. `pinctrl_get_select_default` -> `devm_` variant (handle was never put).
11. `FP_MODEL_INFO` copies the same 10 bytes, zero-padded, instead of reading 5 bytes past the
    DT string `"A528"`.

Kept on purpose: the IchthysOS `FP_SET_SENSOR_TYPE` cap (ROM commit `58af9aab0070`: TEE value 8
-> `type_check` 1, else BAuth wipes the calibration), the 10 s debug log line, the fixed major 152,
compat ioctl (64-bit layout only, as on 5.4), the `CPU_FREQ_LIMIT` boost path off (on 5.4 it was
compiled in but inert: no `etspi-min_cpufreq_limit` in the a52sxq node).

## Userspace contract (what the vendor HAL expects)

Consumers: `android.hardware.biometrics.fingerprint-service.samsung` (open, `hardware/samsung/aidl/fingerprint`)
dlopens closed `libbauthserver.so` (+ `libbauthtzcommon.so`, `libegis_fp_normal_sensor_test.so`).

Kept unchanged:
- `/dev/esfp0`, char 152:0, class `egis_fingerprint`, parent the platform device
  (`/sys/devices/platform/soc/0.etspi,et7xx/egis_fingerprint/esfp0`). Permissions come from
  the ROM: `init.fingerprint.rc` / `init.samsung.rc` `on boot`: `chmod 0660`, `chown system system`;
  SELinux `/dev/esfp[0-9]` -> `fp_sensor_device`. ueventd has no rule for it, so the module must
  be loaded **before `on boot`** (an early androidboot stage is; a late `@` stage is not).
- ioctl `EGIS_IOC_MESSAGE(1)` = `_IOW('k', 0, char[32])`, `struct egis_ioc_transfer` (32 bytes,
  arm64), opcode in `.opcode`, argument in `.len`: `FP_SENSOR_RESET 0x04`, `FP_POWER_CONTROL
  0x05`, `FP_SET_SPI_CLOCK 0x06`, `FP_RESET_CONTROL 0x07`, `FP_DISABLE_SPI_CLOCK 0x10`,
  `FP_CPU_SPEEDUP 0x11`, `FP_SET_SENSOR_TYPE 0x14`, `FP_SPI_VALUE 0x1a`, `FP_MODEL_INFO 0x1f`,
  reserved no-ops `0x16 0x17 0x19 0x1b 0x1c 0xa4 0xa5 0xa8`; anything else -EFAULT, wrong magic
  -ENOTTY. The HAL's boot sequence on 5.4 (research/blob-uapi-evidence/dmesg_boot.txt): open,
  MODEL_INFO, SET_SPI_CLOCK 20 MHz, POWER_CONTROL 1, TZ loads `dualfp`, POWER_CONTROL 0,
  DISABLE_SPI_CLOCK, SET_SENSOR_TYPE 8, then the same power/clock pair around every TZ session.
- `/sys/class/fingerprint/fingerprint/` = `/sys/devices/virtual/fingerprint/fingerprint/`
  (genfs label `sysfs_fingerprint` matches): `bfs_values`, `type_check`, `vendor` (EGISTEC),
  `name` (ET713), `adm` (1), `position`, `rb`, all 0444. The rc files also chown `hbm`,
  `intcnt`, `resetcnt`, `cbgecnt`, `wuhbtest`: those do not exist on 5.4 either (other sensors).
- wakeup source `et7xx_wake_lock` (held between SET_SPI_CLOCK and DISABLE_SPI_CLOCK).

Changed: two modules instead of built-in code (`fingerprint_sysfs`, `fingerprint`); DT property
`etspi-btp-supply` (optional, new). Not verifiable offline: SELinux labels on 6.12 sysfs paths,
the platform device name (`0.etspi,et7xx` expected on both kernels).

## Dependencies outside this directory

Secure world (fingerprint does nothing without them; all use **the phone's own firmware only** —
never load a TA or any signed image from another phone or firmware version: a firmware image from another phone once raised a test phone's anti-rollback counter):
- `/dev/qseecom` + listeners: `drivers612/secure` (`qseecom_dlkm.ko`, `si_core_module`, ...)
  and the ROM's `qseecomd`. TAs loaded by `libbauthtzcommon.so` via `QSEECom_start_app` from
  `/vendor/firmware_mnt/image` (that phone's apnhlos partition): `dualfp` (.mdt + .b00..b07,
  the Egis TA; 5.4 dmesg: "App with id 11 (dualfp) now loaded"), `authhat` (auth tokens),
  `skeymast` (keymaster64, HMAC key shared with the TAs). Also referenced, not seen loading:
  `securefp`, `/apex/com.samsung.android.biometrics.fingerprint/etc/ta/fpta`.
- ION/dma-heaps for QSEECOM shared buffers: `drivers612/secure/ioncompat`.
- `QSEECom_set_bandwidth()` (called around each session): the 6.12 qseecom has these perf
  ioctls as no-ops (`drivers612/secure` patch 0004). Whether the TA then runs fast enough /
  has its crypto clocks is unverified.
- Secure SPI: SE14 must stay disabled and TLMM 56..59 reserved (boarddt fixups own it;
  `dt-check.sh` asserts it).

Other subsystems the HAL needs for an optical UDFPS (not in this directory):
- touch (`drivers612/touch`): `/sys/class/sec/tsp/input/fod_pressed` (sysfs_notify) and the
  `fod_enable`, `set_fod_rect` commands from `init.fingerprint.rc`;
- display (`drivers612/display`): `/sys/class/lcd/panel/mask_brightness`,
  `actual_mask_brightness`, `fp_green_circle`, the HBM finger mask;
- power: `/sys/class/power_supply/battery/temp` (sec-battery);
- `/sys/power/cpufreq_max_limit` (Samsung `cpufreq_limit.c`, not ported; libbauthserver names it,
  whether it tolerates its absence is unverified).

## Device tree

`a52sxq-fingerprint.dtsi` (see its header): `&soc { etspi: etspi,et7xx {...} }` with every
property of the phone's node + `etspi-btp-supply = <&pm8350c_l3>`; `&pm8350c_l3` with the
phone's `VDD_BTP_3P3` 3.3 / 3.3 / 3.3 V, mode 4 (identical to boarddt's regulators file).
Labels used from the base: `soc`, `tlmm`, `et7xx_rst` (boarddt `a52sxq-pinctrl.dtsi`),
`pm8350c_l3`. `dt-check.sh` result: overlay 1.3 KB, all properties equal the phone's.
Integrating it: add it next to the camera/fastrpc fragments in `kexec/mkandroidtree.sh`
or apply `dt-work/a52sxq-fingerprint.dtbo` with `fdtoverlay`.

## Load order

1. first stage: `pinctrl-msm`, `pinctrl-yupik` (TLMM), `cmd-db`, `qcom_rpmh`, `rpmh-regulator`
   (all in `bsp612/out/dist/first-stage.a52sxq.list`);
2. `fingerprint_sysfs.ko`, then `fingerprint.ko` (`stage/load.list`). Without
   `etspi-btp-supply` load them only after rpmh-regulator has probed (dummy-regulator trap).
3. For the HAL (Android): the `secure` stage (qseecom + ioncompat), qseecomd, touch, display.
   As an androidboot stage: `STAGES="... fingerprint:drivers612/fingerprint/stage"` and
   `a52.mods=...,secure,...,touch,fingerprint` (early, not `@...`, so it is there before `on boot`).

## First on-device test (busybox test ramdisk, kernel side only)

No TZ, no HAL, no SPI traffic. Board tree: `drivers612/fingerprint/dt-work/merged.dtb`
(= android-r02.dtb + this fragment). With the hwbringup runner:

    ./drivers612/fingerprint/dt-check.sh
    drivers612/hwbringup/run.sh fp1 drivers612/fingerprint/pack-fingerprint.tgz \
        drivers612/fingerprint/dt-work/merged.dtb 'sh /p/fp-test.sh'
    # later, with an explicit OK for enabling L3C through the driver:  'sh /p/fp-test.sh power'
    # unbind/rebind paths:                                                     'sh /p/fp-test.sh reload'

Expected (`fps_<function>:` prefix; compare the 5.4 lines in `research/blob-uapi-evidence/dmesg_boot.txt`
and `logs/ab-s44-logcat-live.txt`):

    fps_et7xx_init: Entry
    fps_et7xx_probe: Platform_device Entry
    fps_et7xx_parse_dt: sleepPin=<global number of TLMM 35; 371 on 5.4, different on 6.12>
    fps_et7xx_parse_dt: not use ldo_pin
    fps_et7xx_parse_dt: regulator: VDD_BTP_3P3
    fps_et7xx_parse_dt: chipid: ET713 / modelinfo: A528 / position: 11.81,... / rb: 547,-1,-1,FFFFFF
    fps_et7xx_pin_control: sleep
    fps_et7xx_platformInit: btp_regulator ok
    fps_et7xx_platformInit: sleep value =0
    fps_et7xx_probe: is successful
    fps_et7xx_work_func_debug: ldo: 0, sleep: 0, tz: 1, spi_value: 0x0, type: unknown   (every 10 s)

then `/dev/esfp0` c 152,0; sysfs `EGISTEC`, `ET713`, `1`, position, rb, `-1`,
`"FP_SPICLK":"20000000"`; regulator `VDD_BTP_3P3 3300000 disabled`; `esfptest info` ->
`"A528"`; `bad` -> errno 25 then 14; `type 8` -> `type_check` 1; with `power`: rail `enabled`,
debug line `ldo: 1, sleep: 1`, then back to `disabled` / `ldo: 0, sleep: 0`.

Likely failure modes:
- `fps_et7xx_platformInit: is failed. -517` repeating, no probe: L3C not registered
  (rpmh-regulator not loaded, or the label resolves elsewhere) -> `devices_deferred`.
- No `fps_` line at all after `fps_et7xx_init`: node missing (tree without the fragment) ->
  check `/proc/device-tree/soc/etspi,et7xx`.
- `gpio_requset et7xx_sleep failed`: TLMM 35 claimed by someone else, or TLMM not probed.
- `supply etspi-btp not found, using dummy` / `VDD_BTP_3P3 not found`: tree without the
  `etspi-btp-supply` line and L3C named differently.
- A reset when anything touches TLMM 56..59 or SE14 registers (TZ-protected): only possible if
  the base lost `qcom,gpios-reserved` or enabled `spi@a98000`; `dt-check.sh` guards both.

Android-level test (after the above passes; needs secure + touch + display stages): boot the
test Android with the fingerprint stage, then read-only `logcat | grep -iE 'bauth|egis|fingerprint'`
and dmesg: expect the 5.4 sequence above and `QSEECOM: ... App with id N (dualfp) now loaded`.
Do not enrol (writes `/data/vendor/biometrics`, `/efs/biometrics`; the test Android has
userdata/efs read-only by testguard, which is the point).
