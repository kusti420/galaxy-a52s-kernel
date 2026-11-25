# nfc — A52s NFC (Samsung S.LSI S3NRN4V, `sec-nfc` on I2C) on the Qualcomm 6.12 BSP

State: **compiles and links against `bsp612/out/lahaina` with no warnings, modpost clean, all
symbols resolved; DT fragment applies to `out-ack/kx/android-r02.dtb` (and the busybox-test
trees) and equals the phone's nodes. Never loaded on hardware.** See `STATUS.md`.

Why: on 6.12 Android `com.android.nfc` aborts ("JNI FatalError called: enableInternal")
because `android.hardware.nfc-service.sec` cannot open `/dev/sec-nfc`.

## What the phone actually uses

- Controller: **Samsung S.LSI S3NRN4V** ("RN4V"): DT `sec-nfc,bootloader_ver = <6>`, vendor
  files `sec_s3nrn4v_firmware.bin` / `_hwreg.bin` / `_swreg.bin`, `libnfc-sec-vendor.conf`.
  Not NXP, not ST: the Qualcomm reference `qcom,sn-nci` node `nq@28` is disabled in the phone's
  tree (and `NFC_QTI_I2C`, `NFC_PN547`, `NFC_FEATURE_SN100U` are off in the defconfig).
- 5.4 driver: `drivers/nfc/sec_nfc.c` + `nfc_logger/nfc_logger.c` (+ `nfc_wakelock.h`) as
  **one module `nfc_sec.ko`** (`CONFIG_SAMSUNG_NFC=m`, `CONFIG_SEC_NFC=y`,
  `CONFIG_SEC_NFC_LOGGER=y`, `CONFIG_SEC_NFC_DUPLICATED_IRQ_WQ_QC=y`,
  `CONFIG_SEC_NFC_WAKELOCK_METHOD=0`; `arch/arm64/configs/vendor/lineage-a52sxq_defconfig`;
  loaded by the ROM from `device/samsung/a52sxq/modules.load`).
- Bus: QUP SE9 as I2C, `i2c@a84000` (`qupv3_se9_i2c`), TLMM 36 SDA / 37 SCL (`qup11`),
  1 MHz, address **0x27**. GPIOs: VEN 38, CLK_REQ 39, FIRM 40, IRQ 41; PVDD = GPIO-switched
  `regulator-fixed` "fixed_regulator1" on TLMM 42. Same on Samsung's r00/r01/r02 overlays.
- **No eSE**: no secure-element/SPI node in the tree, `ESE_P3_LSI`/`ESE_SECURE`/
  `ESE_USE_TZ_API`/`NFC_P61`/`SEC_STAR` off. Nothing is TZ-owned, nothing to keep disabled for
  HLOS except the unused SPI personality of SE9 (`spi@a84000`, disabled as on the phone).
- **No clock from HLOS**: the node has no `clocks` property, so the 5.4 driver never got
  `oscclk_nfc` (`pdata->clk == NULL`); CLK_REQ (TLMM 39) is only a wake interrupt
  (`sec-nfc,clk_req_wake`: rising edge -> 2 s wakelock). No RPMh/LN_BB clock vote, no PMIC GPIO
  for NFC in the tree. Nothing to provide from the 6.12 base (see open questions).
- No pm_qos, no panel notifier, no regulator voltage: PVDD is a load switch enabled by a GPIO.

## What is here

| Path | What |
|---|---|
| `port.sh` | Regenerates `orig/` + `src/` from the phone's read-only 5.4 `drivers/nfc`, applies `patches/*.patch`, builds, fills `stage/` and `pack-nfc.tgz` |
| `patches/0001-sec-nfc-6.12.patch` | The complete change record (5 files, +234 / -57). `mkpatch.sh` regenerates it from `diff orig src` |
| `Kbuild` | Copied into `src/`; the 5.4 Makefile + the a52sxq config switches as `-D` |
| `build.sh` | Compile check only; fails on any warning/error; log `build.log` |
| `orig/`, `src/` | Untouched 5.4 sources (+ Kconfig/Makefile for reference) / ported sources + `nfc_sec.ko` |
| `a52sxq-nfc.dtsi` | DT fragment (header explains every value) |
| `dt-check.sh`, `dt-compare.py` | Overlay build, `fdtoverlay` onto `out-ack/kx/android-r02.dtb` (`BASE=` for another), comparison with the phone, bus/pin conflict checks. Output `dt-work/` |
| `nfctest/` | Static arm64 test tool (kernel nolibc) using `/dev/sec-nfc` the way the HAL does |
| `nfc-test.sh` | First on-device test (busybox ramdisk) |
| `stage/` | Module stage for `drivers612/androidboot/pack-kexec-rd.sh` (`load.list` + `00-nfc_sec.ko`) |
| `out/nfc_sec.ko` | Copy of `src/nfc_sec.ko` with debug info and `.BTF` removed (made by hand like `drivers612/samsung-oneui/build.sh`: `llvm-strip --strip-debug`, `llvm-objcopy --remove-section=.BTF --remove-section=.BTF.base`); not written by `port.sh` |
| `pack-nfc.tgz` | `KX_PACK` for the ramdisk test: stripped `nfc_sec.ko`, the SE9 I2C controller modules (`msm_gpi`, `i2c-msm-geni` from `bsp612/out/dist`), `nfctest`, `nfc-test.sh` |

## Build

    ./port.sh            # regenerate src/ from the 5.4 tree, build, stage, pack
    ./build.sh           # rebuild src/ only
    ./dt-check.sh        # DT overlay check (BASE=<dtb> to test another base)

`nfc_sec.ko`: vermagic `6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64`,
no module dependencies (84 vmlinux symbols, every one in `bsp612/out/lahaina/Module.symvers`),
aliases `of:N*T*Csec-nfc`, `i2c:sec-nfc`, parameter `nfc_param_lpcharge`. kCFI: no
function-pointer casts, every callback (fops, class attrs, PM ops, IRQ threads, i2c probe/remove)
has its exact 6.12 prototype; `bsp612/tools/initrefs.py`: no data references into `.init`.

## Changes against 5.4 (all in the patch, each marked `a52sxq 6.12:` in the code)

API (required by 6.12):
1. `i2c_driver.probe(client)` without `i2c_device_id` (6.3); `.remove` returns `void` (6.1).
2. `class_create(name)` without owner (6.4); class attribute `show`/`store` take
   `const struct class *` / `const struct class_attribute *` (kCFI would trap the old ones).
3. `fops->poll` returns `__poll_t` (`EPOLLIN|EPOLLRDNORM`).
4. `<linux/pinctrl/consumer.h>` included explicitly (`devm_pinctrl_get_select`).
5. Non-static functions without prototypes made `static` (`-Wmissing-prototypes`).
   Legacy integer GPIO API kept on purpose: `of_get_named_gpio`, `gpio_request`, `gpio_*value*`
   are all exported by GKI 6.12; a descriptor conversion would change no behaviour.

Behaviour (bugs that bite on a module build or on 6.12):
6. PVDD lookup: 5.4 gave up after three deferrals (`static retry_count`) and failed with
   -ENODEV, losing a regulator/probe-order race for good; now it defers while the core returns
   -EPROBE_DEFER (`dev_err_probe`), other errors fail as before.
7. Probe/remove teardown: 5.4 freed a never-requested clk_req IRQ, called remove after a failed
   I2C half and then returned 0 (driver bound with freed drvdata), leaked the I2C buffer, the
   IRQ GPIO, the clk_req GPIO, the second wakeup source, both classes and the PVDD regulator
   (left enabled, never put), and left `/proc/nfclog` pointing into the unloaded module. All
   released now; rmmod + insmod works (5.4: second insmod failed on the existing classes).
   `IS_ERR(&nfc_class)` (always false) fixed to `IS_ERR(nfc_class)`.
8. `nfc_logger_print` has `__printf(1, 2)` now (found one `%d` for a `size_t`); `pref` cast in
   the hex dump; `g_entry` static.
9. `nfc_wake_lock_active()` no longer dereferences a NULL wakeup source.
10. LPM (power-off charging): 5.4 (`CONFIG_BATTERY_SAMSUNG=y`) skipped PVDD via sec-battery's
    built-in `lpcharge`. The 6.12 power stack is modules with private `lpcharge` params, so
    this module uses its own `nfc_sec.nfc_param_lpcharge=1` (default: PVDD on, = normal boot).
11. `MODULE_DEVICE_TABLE(of, ...)` added (autoload alias); i2c id table `const`.

12. `/sys/class/nfc_sec/pvdd` added for the OneUI init script (see "Userspace contract").

Kept on purpose: the -ENODEV "mask" returned by `poll()` on a closed device (every bit set, so
the HAL's `select()` wakes and its `read()` gets -ENODEV, exactly as on 5.4); IRQF_NO_SUSPEND +
`enable_irq_wake` on the data IRQ (`DUPLICATED_IRQ_WQ_QC`); the unbalanced wake enable on
mode changes (5.4 behaviour); no `.compat_ioctl` (`SEC_NFC_COMPAT_IOCTL` off on 5.4; the HAL is
64-bit); `/sys/class/nfc_test/test` world-readable (it power-cycles the chip: SELinux limits it).

## Userspace contract (what the vendor HAL expects)

Consumers: `android.hardware.nfc-service.sec` (open source, `hardware/samsung_slsi/nfc`,
AIDL; config `/vendor/etc/libnfc-sec-vendor.conf`: `POWER_DRIVER = TRANS_DRIVER =
"/dev/sec-nfc"`), the NFC firmware is downloaded **by the HAL through `/dev/sec-nfc`** (not
`request_firmware`); closed `libsec-ril.so` reads `/sys/class/nfc_sec/nfc_support`.

Kept unchanged:
- `/dev/sec-nfc`: misc device, dynamic minor (5.4: 10:110 on the phone; may differ),
  parent the I2C client (6.12 base: `/sys/devices/platform/soc/ac0000.qcom,qupv3_1_geni_se/a84000.i2c/i2c-N/N-0027`; 5.4 had the SE directly under soc). Permissions:
  `on boot` in the HAL rc and `init.samsung.rc`: `chown nfc nfc`, `chmod 0660`; SELinux
  `/dev/sec-nfc u:object_r:nfc_device:s0` (`device/qcom/sepolicy_vndr/.../file_contexts`).
  ueventd has no rule, so **the module must be loaded before `on boot`** (an early androidboot
  stage after `i2c`, not an `@...` stage), or the HAL (user nfc) gets EACCES.
- ioctls, magic `'S'`, `_IOW(..., unsigned int)` with the value in `arg`:
  `SEC_NFC_SET_MODE` (1; 0 off, 1 firmware, 2 bootloader; >= 3 -EFAULT), `SEC_NFC_SLEEP` (2),
  `SEC_NFC_WAKEUP` (3) (both FIRM pin + wakelock, ignored in bootloader mode),
  `SEC_NFC_SET_NPT_MODE` (4, args 0x7E/0x7F), `SEC_NFC_DEBUG` (`_IO('S', 99)`). Not handled,
  as on 5.4: `SEC_NFC_GET_MODE` (0), and the newer HAL's `SEC_NFC_COLD_RESET` (5) /
  `SEC_NFC_SHUTDOWN` (6) -> ENOTTY (the HAL only uses them with `NFC_SEC_ESE_COLDRESET`).
- `read()`/`write()`: raw I2C frames, max 260 bytes per call (`SEC_NFC_MSG_MAX_SIZE`), -ENODEV
  while mode 0, -EAGAIN on O_NONBLOCK without data, -ERESTART on NACK; `poll()` readable when
  the IRQ (TLMM 41, rising) fired; IRQs during a mode change are skipped until the first write.
  The HAL reads a 3-byte NCI header (4 in bootloader mode), then the payload.
- sysfs: `/sys/class/nfc_sec/nfc_support` (0444, empty read, logs), `/sys/class/nfc_test/test`
  (0444, bootloader-version self-test).

Added (not on the phone's 5.4 kernel):
- `/sys/class/nfc_sec/pvdd` (0200, write-only, exists while the driver is bound). The OneUI
  `init.nfc.samsung.rc` writes "1" (late-init), "2" (post-fs-data), "3" (boot). The 5.4 A52s
  kernel had no such node (`# CONFIG_NFC_PVDD_LATE_ENABLE is not set`; the writes failed with
  ENOENT) and enabled PVDD in probe. Samsung's stores (5.4 `NFC_PVDD_LATE_ENABLE` code, S26
  `nxp_combined/common.c`) are write-only, enable PVDD on '1' only (late enable) and only log
  other values. Here "1", "2" and "3" all mean "ensure PVDD on": no-op when probe enabled it
  (normal), one `regulator_enable()` if probe could not; never disables, skipped in LPM
  (`nfc_param_lpcharge=1`), other values only logged, the write always returns its length.
  Probe and the store share `sec_nfc_pvdd_ensure_on()` (mutex + `pvdd_enabled`), so the
  regulator reference is taken once and dropped once in remove. `/proc/nfclog` lines:
  `pvdd val: 1, already on` / `enabled` / `regulator stays off at LPM`.
- `/proc/nfclog` (0444, 128 KiB ring), wakeup sources `nfc_wake_lock`, `nfc_clk_wake_lock`,
  IRQ names `sec-nfc` and `sec-nfc_clk`, module name `nfc_sec` (+ param `nfc_param_lpcharge`).

Not verifiable offline: the exact sysfs path / misc minor, SELinux on the 6.12 paths.

## Device tree

`a52sxq-nfc.dtsi` (see its header): `&qupv3_se9_i2c { sec-nfc@27 {...}; nq@28 disabled }`,
`&qupv3_se9_spi` disabled, the five TLMM pin states and `ldo_gpio1`, and the PVDD regulator at
the phone's path `/samsung_mobile_device/fixed_regulator@1` (created from `&{/}` because the
busybox-test trees have no `/samsung_mobile_device`). **Needed:** in the current 6.12 board
tree (boarddt) `nfc_pvdd-supply` points at `fixed_regulator1`, a todo placeholder without a
compatible (`/soc/a52sxq-todo-power-extra/fixed_regulator1`): without this fragment the driver
would wait for that supply forever (the 5.4 code: fail after 3 deferrals). Labels used from the
base: `tlmm`, `qupv3_se9_i2c`, `qupv3_se9_spi`, `nfc_{firm,ven,irq,clk_req}_gpio`, `ldo_gpio1`;
new label `a52sxq_nfc_pvdd`.

`dt-check.sh` result (2026-11-14): overlay 3.3 KB applies to `android-r02.dtb`,
`full-r02-usb.dtb`, `hwbringup/hw-audio-full-r02.dtb`, `wifibt/wifibt-r02.dtb`; every property
of sec-nfc@27, the regulator and the 7 pin states equals the phone's; SE9 I2C okay with the
phone's sleep pins and 1 MHz, SPI personality disabled, sec-nfc the only live child; TLMM 36..42
not in `qcom,gpios-reserved`; the only other users of those pins (SE10 i2c/spi/uart a88000,
nq@28, spi@a84000) are disabled.

Integration: in `kexec/mkandroidtree.sh` add
`(cd drivers612/nfc && ./dt-check.sh >/dev/null 2>&1) || { echo "nfc overlay build failed"; exit 1; }`
and append `drivers612/nfc/dt-work/a52sxq-nfc.dtbo` to the `fdtoverlay` list. Long term
boarddt should carry the real regulator node instead of the placeholder.

## Load order

1. first stage: `pinctrl-msm`, `pinctrl-yupik` (TLMM; `regulator-fixed` is built in);
2. stage `i2c`: `msm_gpi.ko`, `i2c-msm-geni.ko` (SE9 controller);
3. `nfc_sec.ko` (`stage/load.list`), before `on boot`. As an androidboot stage:
   `STAGES="... nfc:drivers612/nfc/stage"` and `a52.mods=...,i2c,...,nfc,...` (early, no `@`).

## First on-device test (busybox test ramdisk, kernel side only)

Board tree: `drivers612/nfc/dt-work/merged.dtb` built from `full-r02-usb.dtb` (the hwbringup
runner's tree family):

    BASE=$PWD/out-ack/kx/full-r02-usb.dtb drivers612/nfc/dt-check.sh && cp drivers612/nfc/dt-work/merged.dtb drivers612/nfc/dt-work/nfc-full-r02.dtb
    drivers612/hwbringup/run.sh nfc1 drivers612/nfc/pack-nfc.tgz drivers612/nfc/dt-work/nfc-full-r02.dtb 'sh /p/nfc-test.sh'
    # then, talking to the chip (bootloader info over I2C, no RF):  'sh /p/nfc-test.sh chip'
    # teardown paths:                                               'sh /p/nfc-test.sh reload'

Expected dmesg (5.4 wording, `sec_nfc:` prefix; GPIO numbers are global 6.12 numbers):

    sec_nfc: probe start
    sec_nfc: parse_dt() clk_req : <n>
    sec_nfc: sec_nfc_parse_dt : sec-nfc,clk_req_wake: true
    sec_nfc: bootloader_ver : 6
    sec_nfc: parse_dt() irq : <n>, ven : <n>, firm : <n>
    sec_nfc: probe() success
    sec_nfc: probe() start
    sec_nfc: regulator onoff = 1
    sec_nfc: success
    sec_nfc: probe() success

then `/dev/sec-nfc`, `/proc/nfclog` ("nfc logger init ok"), `fixed_regulator1` enabled,
`nfctest bad` -> 25 / 19 / 19 / poll 1 with revents 0x9 (POLLIN|POLLERR: the -ENODEV mask 0xffffffed filtered by poll). With `chip`: `cat /sys/class/nfc_test/test`
-> `BL ver: xx.xx.xx.xx, INT: OK`; `nfctest bl` -> poll 1, a 4-byte header + payload whose first
4 bytes are the same bootloader version; `nfctest modes` -> "NFC mode is : 2", ": 1", ": 0"
and the state lines `en(0) firm(1) pvdd(1) ... mode(2)` etc. as in the 5.4 boot log
(`research/blob-uapi-evidence/dmesg_boot.txt`, lines 2325-2339).

Likely failure modes:
- `sec_nfc: nfc_pvdd not ready` repeating / in `devices_deferred`: tree without the fragment
  (supply = placeholder) or `regulator-fixed` not probed (TLMM 42 / `ldo_gpio1` problem).
- No `sec_nfc:` line after insmod: no I2C client 0x27 -> `i2c@a84000` not probed (`i2c-msm-geni`
  or `msm_gpi` missing, SE9 clock/interconnect) -> `ls /sys/bus/i2c/devices`.
- `BL ver: ... INT: NOK` or `i2c write error -6/-121` / -ETIMEDOUT: chip not answering: PVDD
  not actually on, VEN polarity, 1 MHz timing on the 6.12 geni driver, or no reference clock.
- `INT: NOK` but data read back: IRQ (TLMM 41 rising) not delivered: PDC/wakeup-parent mapping
  of TLMM 41 on 6.12, or trigger type.
- `probe() failed to register CLK REQ IRQ handler`: TLMM 39 IRQ mapping; non-fatal.

Android-level test (after the above): boot the test Android with stages `...,i2c,...,nfc`, then
read-only `logcat | grep -iE 'nfc|SecNfc|NfcService'` and `dmesg | grep sec_nfc`: expect the
5.4 sequence open -> mode 2 -> mode 1, the HAL's "Bootloader: Version ..." line, NCI
CORE_RESET/INIT, and no `enableInternal` FatalError. Do not tap cards or enable payment
routing on a test phone without someone at the phone (and never on a daily-use phone).

## Open questions for hardware testing

1. Reference clock: the S3NRN4V's clock source is invisible in the tree (no `clocks`, CLK_REQ
   only to TLMM). Either it has its own crystal or the PMIC clock is driven by a hardware
   request line; 5.4 HLOS did nothing either way. If NCI init works but RF does not (no tag
   found), look at the PMK8350 LN_BB / RF clock state with and without `clk_ignore_unused`.
2. The HAL compares the chip firmware with `/vendor/firmware/nfc/sec_s3nrn4v_firmware.bin` and
   may rewrite the chip's flash (`FW_UPDATE_MODE=0`). Only ever run a phone's own vendor
   partition against its own chip (same rule as the 2026-11-13 TZ rollback incident).
3. 1 MHz I2C on the 6.12 `i2c-msm-geni` (FIFO vs GSI, clock divider table for 1 MHz).
4. Wake: TLMM 41 / 39 through the PDC on 6.12 (IRQF_NO_SUSPEND + irq wake); suspend not tested.
5. PVDD rail voltage (expected 1.8 V I/O) is not in any tree: only the GPIO is switched.
6. LPM: does the 6.12 boot in power-off charging need `nfc_sec.nfc_param_lpcharge=1`?
