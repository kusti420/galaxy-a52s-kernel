# touch — A52s touchscreen (ST FTS5CU56A) and keys on the Qualcomm 6.12 BSP

State: **compiles and links, never loaded on hardware.** Everything under "Not verified" needs
the phone.

## What is here

| Path | What |
|---|---|
| `src/` | The ported sources + `Kbuild`. Builds 8 modules (below). |
| `orig/` | Untouched copy of the same files from the phone's 5.4 kernel (`drivers/input/sec_input` and `stm/`). `diff -ru orig src` is the complete change record. |
| `port-5.4-to-6.12.patch` | That diff, sources only (8 files, 547 lines). Regenerate after any source change. |
| `build.sh` | Compile check against `bsp612/out/lahaina` (read-only). `VBUS=1 ./build.sh` also hooks the charger notifier of `drivers612/power`. |
| `a52sxq-touch.dtsi` | Touch node, pins, rail, `ss_touch`, hall alternative; keys check in a comment. Applies on `bsp612/out/dist/dtb/yupik.dtb` (tested with `fdtoverlay`; the merged node equals the phone's value for value). |
| `touch-test.sh` | First on-device test for the busybox ramdisk. |
| `STATUS.md` | Progress log. |

Modules (vermagic `6.12.81-4k-g8a69376da734`, all symbols resolved by modpost: 138 from vmlinux,
2 from `sec_core`, the rest among themselves):

| Module | Needs | Purpose |
|---|---|---|
| `sec_tsp_log.ko` | — | `/proc/tsp_msg`, `tsp_raw_data`, `tsp_cmd_hist`, `tsp_sponge_log` |
| `sec_input_notifier.ko` | — | notifier chain (built in on 5.4; a module here). Also used by the display techpack, see below |
| `sec_cmd.ko` | sec_tsp_log, sec_core | `/sys/class/sec/tsp/{cmd,cmd_status,cmd_result,cmd_list,...}` |
| `sec_secure_touch.ko` | sec_core | `/sys/class/sec/ss_touch` (binds to `/soc/ss_touch`) |
| `sec_common_fn.ko` | sec_tsp_log | DT parsing, power, input devices, `enabled` node. Parameter `lcd_id` |
| `sec_tclm_v2.ko` | sec_tsp_log | calibration bookkeeping |
| `sec_tsp_dumpkey.ko` | sec_common_fn | key-combination raw dump |
| `stm_ts.ko` | all of the above | the I2C driver, compatible `stm,stm_ts` |

Not ported: `stm_spi.c`, `stm_ioctl.c`, `stm_mmap.c`, `stm_vendor.c` (SPI build only),
`sec_virtual_tsp.c` (foldables), `synaptics/`.

## Build

    ./build.sh            # -> src/*.ko
    ./build.sh clean

`Kbuild` passes the 5.4 defconfig switches as `-D` (no Kconfig in an external tree):
`INPUT_SEC_INPUT, SEC_DEBUG_TSP_LOG, INPUT_TOUCHSCREEN_TCLMV2, TOUCHSCREEN_DUMP_MODE,
INPUT_SEC_NOTIFIER, INPUT_SEC_SECURE_TOUCH, DRV_SAMSUNG, TOUCHSCREEN_STM, SAMSUNG_PRODUCT_SHIP, QGKI`
— the same set the phone's kernel has. Off, although on in the phone's 5.4 config:

| 5.4 switch | Why off | Effect |
|---|---|---|
| `VBUS_NOTIFIER` | provider is `drivers612/power` (`vbus_notifier.ko`); `VBUS=1 ./build.sh` turns it on and compiles | IC is not told "charger connected" (charger noise mode) |
| `HALL_NOTIFIER` | hall driver not ported | no flip-cover mode |
| `DISPLAY_SAMSUNG` | `get_lcd_attached()` lives in the display driver | panel id comes only from the `lcd_id` parameter (see below) |
| `SEC_ABC`, `SPU_VERIFY`, `USB_TYPEC_MANAGER_NOTIFIER` | Samsung service / factory helpers | none for normal use |

## Changes against 5.4 (all in `diff -ru orig src`)

1. `asm/unaligned.h` -> `linux/unaligned.h` (moved in 6.12).
2. `stm_i2c.c`: i2c `probe` without the id argument, `remove` returns void, `.owner` dropped,
   functions made static. `MODULE_SOFTDEP("pre: acpm-mfd-bus")` (Exynos) dropped.
3. `sec_secure_touch.c`: platform `remove` returns void.
4. `sec_common_fn.c`: `GPIOF_DIR_IN` -> `GPIOF_IN`, `strtobool` -> `kstrtobool`;
   `sec_input.h` includes `linux/pinctrl/consumer.h` explicitly.
5. `stm_cmd.c`: six `snprintf` calls relied on truncation (`-Wformat-truncation` is an error
   now); the format strings were shortened to exactly what was printed before. Output unchanged.
6. `stm_fw.c`: `static const int` return type; `stm_core.c`: an unused variable.
7. Audit 2026-11-18. `stm_core.c` `stm_ts_stop_device()`: drops the LPM irq wake itself
   (a reset in LPM leaked wake depth; the 6.12 TLMM re-enables a wake-armed IRQ at suspend);
   the duplicate call in `stm_cmd.c` `fod_enable` is removed. `stm_fw.c` / `stm_core.c` /
   `stm_dev.h`: when the firmware bin is not readable at probe (first-stage load, `-ENOENT`),
   `work_fw_recheck` reads it once 60 s after probe (retries while the screen is off, 5 x
   60 s), fills the `*_of_bin` versions and updates only if the IC is older (same compare as
   at probe). A corrupted IC is not covered by this: the bin must be in the first-stage
   ramdisk (`/lib/firmware/tsp_stm/`), which is a realboot packaging change.
7. `CONFIG_GH_RM_DRV` guards renamed to `CONFIG_SEC_INPUT_GH_TRUSTED_TOUCH` (never defined).
   The 6.12 BSP sets `GH_RM_DRV=m`, which would have switched on Qualcomm trusted-touch code
   that the phone's 5.4 kernel never built (it has `HH_RM_DRV`, a different name).
8. `stm_core.c`: the 5.4 driver fails its first probe with `-EPROBE_DEFER` on purpose. On 6.12
   a deferred device is retried only when another driver binds, so after a late `insmod` it
   could stay unprobed forever. Now opt-in: `stm_ts.defer_first_probe=1`.

Nothing else was needed: the `proc_ops` wrapper was already version-aware,
`wakeup_source_register`, `of_get_named_gpio`, `input_mt_init_slots`, `request_firmware` are unchanged in 6.12,
`class_create` (only without `DRV_SAMSUNG`) and the `set_fs` file helpers (only for dual
foldables on kernels before 5.10) are in branches that are not compiled.

**No display notifier is needed.** The 5.4 stm driver never listened to fb/drm/panel events:
screen on/off reaches it from userspace through `/sys/class/sec/tsp/input/enabled`
(the ROM's power HAL writes it, `powerhint.json`) and through input open/close.
`drivers612/display/sec_panel_notifier_v2` is therefore not used here.
The link goes the other way: the display techpack (`ss_dsi_panel_common.c`,
`#if IS_ENABLED(CONFIG_INPUT_SEC_NOTIFIER)`) calls `sec_input_register_notify()` for the
touch-reported ESD event. Interface for that agent: header `src/sec_input.h`
(`enum sec_input_notify_t`, `struct sec_input_notify_data`), symbols in `src/Module.symvers`
(`sec_input_register_notify`, `sec_input_unregister_notify`, `sec_input_notify`), provider
`sec_input_notifier.ko`, which must then be loaded before `msm_drm.ko`.

## Device tree

`a52sxq-touch.dtsi` (read its header). Summary: I2C SE13 `i2c@a94000` enabled, client 0x49,
attention TLMM 81 (level low, no reset line), AVDD = PM8350C L7 pinned to 3.0 V + boot-on,
no IO regulator on hw rev >= 1, firmware name `tsp_stm/fts5cu56a_a52sxq.bin`.
Revisions: rev 3 and rev 4 both boot Samsung's r02 overlay; r01 and r02 touch nodes are
identical; r00 (hw rev 0) has an extra `tsp_io_ldo-supply`.

Firmware blob: `$ANDROID_TREE/vendor/samsung/a52sxq/proprietary/vendor/firmware/tsp_stm/fts5cu56a_a52sxq.bin`
(122292 bytes, sha256 b06475df...; `/vendor/firmware/tsp_stm/` on the phone). The copy in the
kernel tree's `firmware/tsp_stm/` is a different, 4 bytes shorter file and is not what the
phone loads (`CONFIG_EXTRA_FIRMWARE=""`).

`lcd_id`: the bootloader puts `sec_common_fn.lcd_id=80000A` on the kernel command line.
`modprobe` and Android's init apply it; busybox `insmod` does not (the test script passes it).
Without it the driver logs `lcdtype 0x00000000` and carries on.

## Keys and hall sensor

- Power (PMK8350 kpdpwr, KEY_POWER), volume down (resin, KEY_VOLUMEDOWN), volume up (PM7325
  GPIO 6, active low, 15 ms, wake-up): already in `bsp612/dts/a52sxq-bringup-overlay.dts`,
  checked here field by field against the phone's tree: correct. Drivers present in the 6.12
  build: `qcom-pon.ko`, `pm8941-pwrkey.ko` (has `qcom,pmk8350-pwrkey` / `-resin`),
  `pinctrl-spmi-gpio.ko` (all three in `first-stage.a52sxq.list`), `gpio-keys` built in
  (`CONFIG_KEYBOARD_GPIO=y`). Expected: `/proc/bus/input/devices` shows `gpio-keys`,
  `pmic_pwrkey`, `pmic_resin`.
- Hall IC (TLMM 101, active low): Samsung's `hall_ic` driver is a separate 800-line driver,
  not part of sec_input, **not ported**. `a52sxq-touch.dtsi` has a disabled `gpio-keys` switch
  on the same pin as the no-code replacement; the switch code is an open choice (comment there).

## Userspace contract

Kept (same code, same names):
- inputs `sec_touchscreen` and `sec_touchproximity` (ear detect), same event codes incl.
  Samsung's private ones (`BTN_PALM 0x118`, `KEY_BLACK_UI_GESTURE 0x1c7`, `KEY_INT_CANCEL 0x2be`,
  `ABS_MT_CUSTOM 0x3e`, `KEY_WAKEUP` for double tap) — none collides with a 6.12 code;
- `/sys/class/sec/tsp/` : `cmd`, `cmd_status`, `cmd_status_all`, `cmd_result`, `cmd_result_all`,
  `cmd_list`, `input` (link), `enabled`, `ear_detect_enable`, `prox_power_off`, `virtual_prox`,
  `sensitivity_mode`, `hw_param`, `fod_pos`, `fod_info`, `aod_active_area`, `support_feature`,
  `scrub_pos`, `get_lp_dump`, `read_ambient_info`, `dualscreen_policy`;
- `/sys/class/sec/tsp/input/enabled` (power HAL) and `/sys/class/sec/tsp/input/fod_pressed`
  (fingerprint HAL `Sensor.h`, with `sysfs_notify` on press/release). `fod_pressed` sits in the
  secure-touch attribute group, which is why secure touch is built as on 5.4; the group also
  gives `secure_touch_enable`, `secure_touch`, `secure_ownership`;
- every `cmd` the ROM sends: `aot_enable`, `glove_mode`, `singletap_enable`, `fod_enable`,
  `set_fod_rect`, `set_game_mode` (and `spay_enable`, `aod_enable`, `fod_lp_mode`,
  `fp_int_control`, `ear_detect_enable`, `pocket_mode_enable`);
- `/proc/tsp_msg`, `/proc/tsp_raw_data`, `/proc/tsp_cmd_hist`, `/proc/tsp_sponge_log`,
  `/proc/tsp_cmoffset_all`; firmware name and path.

Changed: module `sec_input_notifier` is new as a module (was built in); parameter
`stm_ts.defer_first_probe` is new.

Could not verify without hardware: the i2c bus number (5.4 sysfs paths like
`/sys/devices/.../a94000.i2c/i2c-N/N-0049` depend on adapter numbering; the ROM uses the
`/sys/class/sec/tsp` paths, which do not), SELinux labels of the new sysfs paths.

## Load order

Before the touch modules: the first-stage set (`pinctrl-msm`, `pinctrl-yupik`, `gcc-sc7280`,
`rpmh-regulator`, ...) and the I2C bus driver, which is NOT in `first-stage.a52sxq.list`:
`i2c-msm-geni.ko` with, per `modules.dep` (load in this order, skipping what is loaded):
`gh_arm_drv, gh_dbl, gh_msgq, qcom-scm, secure_buffer, gh_rm_drv, gh_mem_notifier,
mem_buf_dev, smem, debug_symbol, msm_dma_iommu_mapping, deferred-free-helper, qcom_dma_heaps,
minidump, qcom_ipc_logging, msm_gpi, i2c-msm-geni`.

Then:

    sec_core  sec_tsp_log  sec_input_notifier  sec_cmd  sec_secure_touch
    sec_common_fn (lcd_id=<from cmdline>)  sec_tclm_v2  sec_tsp_dumpkey  stm_ts

(`sec_core.ko` is `samsung612/modules/sec_core`. With `VBUS=1` builds, `vbus_notifier.ko`
before `stm_ts`.)

## First on-device test (busybox ramdisk)

Copy `sec_core.ko`, `src/*.ko`, `touch-test.sh` into the ramdisk's `/extra`, boot a dtb that
includes `a52sxq-touch.dtsi`, load the I2C bus modules, then `sh /extra/touch-test.sh`.
Do **not** put the firmware file in the ramdisk for the first test: with no file the driver
cannot start a firmware update and just uses the IC as it is.

By hand:

    ls /sys/bus/i2c/devices/                 # expect N-0049
    insmod sec_core.ko; insmod sec_tsp_log.ko; insmod sec_input_notifier.ko; insmod sec_cmd.ko
    insmod sec_secure_touch.ko; insmod sec_common_fn.ko lcd_id=80000A
    insmod sec_tclm_v2.ko; insmod sec_tsp_dumpkey.ko; insmod stm_ts.ko
    dmesg | grep -e sec_input -e stm_ts
    ls /sys/class/sec/tsp/
    echo get_chip_name > /sys/class/sec/tsp/cmd; cat /sys/class/sec/tsp/cmd_result
    echo get_fw_ver_ic > /sys/class/sec/tsp/cmd; cat /sys/class/sec/tsp/cmd_result
    grep -A4 sec_touchscreen /proc/bus/input/devices          # Handlers= eventX
    hexdump -v -e '6/4 "%08x " "\n"' /dev/input/eventX        # touch the screen
    grep stm_ts /proc/interrupts                              # count rises while touching

Expected log (order; prefix `stm_ts N-0049: [sec_input]`):

    stm_ts_i2c_probe
    stm_ts_probe
    sec_input_get_lcd_id: lcdtype 0x0080000A
    sec_input_parse_dt: i2c buffer limit: ..., lcd_id:80000A, bringup:0, ...
    supply tsp_io_ldo not found, using dummy regulator        (regulator core, expected)
    stm_ts_init: init resource
    sec_input_pinctrl_configure: ACTIVE
    sec_input_power: on: avdd:on, dvdd:on
    stm_ts_fw_update_on_probe: Load firmware : tsp_stm/fts5cu56a_a52sxq.bin
    ... Firmware image tsp_stm/fts5cu56a_a52sxq.bin not available   (first test, expected)
    ... [IC] Firmware Ver: 0x...., Config Ver: 0x...., Main Ver: 0x....
    stm_ts_probe: request_irq = <n>
    stm_ts_probe: done
    input: sec_touchscreen as /devices/platform/soc/.../a94000.i2c/i2c-N/N-0049/input/inputM

`cmd_result` for `get_chip_name` should read `get_chip_name:fts5cu56a` (taken from the firmware name), and each
touch gives lines with `00350003` (X), `00360003` (Y), `00390003` (tracking id).

Under Android: `getevent -lt` on `sec_touchscreen`; `echo aot_enable,1 > /sys/class/sec/tsp/cmd`;
fingerprint: `cat /sys/class/sec/tsp/input/fod_pressed` goes 1 while the sensor area is held
with `fod_enable,1,1,0` set.

## Likely failure modes

| Symptom | Likely cause | Look at |
|---|---|---|
| no `N-0049` device | SE13 not enabled in the dtb, or `i2c-msm-geni` / `msm_gpi` not loaded or not probed (GPI DMA, QUP wrapper) | `dmesg \| grep -i -e geni -e gpi`; `/sys/bus/platform/devices/a94000.i2c/driver` |
| `Failed to get tsp_avdd_ldo regulator`, probe -EINVAL | `rpmh-regulator` not up or `pm8350c_l7` label missing | `/sys/class/regulator/*/name` |
| I2C read errors (`-ENOTCONN`, `-110`) at chip-id read, probe fails | SE13 in the wrong mode (FIFO vs GSI), pins not muxed to qup15, or AVDD really off | `stm_ts_i2c_read failed` lines; pinctrl debugfs `gpio52/53/81` |
| `Unable to request threaded irq` | TLMM 81 not routable as a level-low interrupt (PDC wake map of the 6.12 pinctrl driver) | `/proc/interrupts`, pinctrl-yupik wakeirq map |
| probe OK, no events | IC in a low-power state, or interrupt never fires | `/proc/interrupts`; `echo 1 > /sys/class/sec/tsp/input/enabled` while a reader holds the event node open |
| nothing happens after `insmod stm_ts` with `defer_first_probe=1` | the stranded deferral described above | `echo N-0049 > /sys/bus/i2c/drivers/stm_ts/bind` |
| firmware update starts on a later boot | firmware file present and newer than the IC's | intended 5.4 behaviour; keep power and do not interrupt |
| `lcd is not attached` then -ENODEV | `lcd_id=FFFFFF` passed (no panel) | cmdline |

## Not verified (needs the phone)

- Everything at runtime: probe, I2C traffic through `i2c-msm-geni` on 6.12, the level-low
  interrupt on TLMM 81, suspend/resume (`stm_ts_i2c_pm_*`), low-power gestures (AOT, FOD in
  LPM use `enable_irq_wake`), firmware update, TCLM calibration.
- That the rev 4 phone's IC has the same firmware generation as rev 3 (same DT, so expected).
- Whether Android's first-stage `modprobe` passes `sec_common_fn.lcd_id` on this boot chain
  (bootconfig vs cmdline).
