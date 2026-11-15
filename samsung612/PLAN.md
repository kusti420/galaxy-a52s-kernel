# Samsung board drivers for the A52s on the Qualcomm 6.12 BSP: port plan

Written 2026-11-11 from offline source analysis. Nothing here ran on a phone. "Compiled"
below always means a compile against 6.12 headers on the PC, never a boot.

Trees compared (abbreviations used throughout):

| Name | What | Path |
|---|---|---|
| 5.4 | the phone's kernel, 5.4.254 | `$ANDROID_TREE/kernel/samsung/sm7325` |
| S26 | Galaxy S26 (canoe), kernel 6.12.30 | `donors/samsung-s26-6.12/Kernel` |
| S24 | Galaxy S24 family (pineapple), 6.1 vendor modules | `samsung612/donors/sm8650-modules` (samsung-sm8650, `lineage-22.2`) |
| S23 | Galaxy S23 family (kalama), 5.15 vendor modules | `samsung612/donors/sm8550-modules` (LineageOS, `lineage-24.0`) |
| PHYS | MediaTek A-series, 6.12.23, has the SM5714 stack | `samsung612/donors/physwizz-a24` |
| CRD | crDroid sm8550, 5.15 (pca9468, sx9360, stm_spi) | `samsung612/donors/crdroid-sm8550` |
| QC r7 | Qualcomm display techpack for lahaina on 6.12 | `donors/display-drivers` (`display-kernel.lnx.1.11.r7-rel`) |
| DT | the phone's real device tree | `downstream-dt/a52sxq-r02.dts` |

The S24 and S23 trees were fetched tonight (display-drivers only). They were not in
`research/source-scout.md` and they change the display decision.

## 1. Decision per driver, in bring-up order

| # | Driver | Base to port from | A52s parts carried from 5.4 | Difficulty |
|---|---|---|---|---|
| 0 | `sec_class` + restart reasons | new small module, written (`modules/sec_core`) | addresses and values | done, compiled |
| 1 | Display framework `ss_dsi_panel_*` + hooks in Qualcomm code | **S23** framework and hooks, moved onto QC r7 | — | L |
| 2 | Panel `S6E3FC3_AMS646YD01_LO` | 5.4 panel directory + `self_display_FC3` | all of it, DT node unchanged | S once 1 exists |
| 3 | `sec_input` framework | 5.4 forward-port | — | S |
| 4 | STM touch (FTS5CU56A, I2C 0x49) | 5.4 `stm/` forward-port | all | S-M |
| 5 | SM5714 MFD core | PHYS | — | S |
| 6 | SM5714 fuel gauge | PHYS | `battery0,*` tables from DT | M |
| 7 | SM5714 charger | PHYS | DT limits | S-M |
| 8 | SM5714 MUIC + AFC | PHYS (+ PHYS `muic/common`) | — | S |
| 9 | `sec_battery` framework, `sec_pd`, `sec_direct_charger` | PHYS | battery DT node | M-L |
| 10 | SM5714 USB-PD/Type-C, pdic, typec manager | PHYS; `usb/notify` from S26 | — | L |
| 11 | PCA9468 direct charger | CRD (5.15) + 6.12 fix-ups | DT node | M |
| 12 | S2MPB03 regulator (camera rails) | PHYS | — | S |
| 13 | SM5714 flash LED | 5.4 forward-port | — | S |
| 14 | `sec_vibrator` + DC motor | 5.4 forward-port | — | S |
| 15 | Hall IC | S26 | — | S |
| 16 | SX9360 grip + `sensors_core` | CRD sx9360 + S26 `sensors_core` | `sx9360,vdd_en` block | S-M |
| 17 | et7xx fingerprint | 5.4 et7xx + S26 `fingerprint_sysfs.c` | all | S-M |
| 18 | sec-nfc | 5.4 forward-port (+ S26 `nfc_logger`) | all | S |
| 19 | `adsp_factory` | 5.4 forward-port | all | M |
| — | `sec_param`, rest of `sec_debug` | not ported (see 6) | — | — |

Rule that came out of the comparison: where the newest Samsung copy talks to the same chip
with the same protocol (SM5714, S2MPB03, hall), take the newest copy. Where the newer copy
speaks to a different chip generation or a different userspace protocol (touch, vibrator,
`adsp_factory`, the S26 display framework), stay with the 5.4 code and fix the kernel API
changes, which are few.

## 2. Display

### 2.1 What Samsung changes in Qualcomm's display code

Samsung ships its own copy of the display techpack. Its changes sit inside
`CONFIG_DISPLAY_SAMSUNG` blocks:

| Tree | Hook lines (`CONFIG_DISPLAY_SAMSUNG`) | Lines inside the blocks | Files touched |
|---|---|---|---|
| 5.4 | 325 | 2,734 | 44 |
| S23 | 398 | not counted | — |
| S24 | 312 | not counted | — |
| S26 | 382 | 3,125 | 49 |
| QC r7 | 0 | 0 | 0 |

Most hooks are in `dsi/dsi_display.c`, `dsi/dsi_panel.c`, `sde/sde_connector.c`,
`sde/sde_encoder*.c`, `sde/sde_crtc.c`, `sde/sde_kms.c`, `msm_atomic.c`. QC r7 has none of
them, so they must be put in by hand whichever Samsung tree they come from.

How far each Samsung tree's Qualcomm code is from QC r7 (changed lines per file after
removing the Samsung blocks; smaller means the hooks move over with less rework):

| File (QC r7 lines) | 5.4 | S23 | S24 | S26 |
|---|---|---|---|---|
| `dsi/dsi_display.c` (9,263) | 2,724 | 421 | 174 | 1,765 |
| `dsi/dsi_panel.c` (5,029) | 1,014 | 152 | 52 | 2,112 |
| `dsi/dsi_ctrl.c` (4,311) | n/a | 200 | 136 | 930 |
| `sde/sde_connector.c` (3,627) | 972 | 189 | 42 | 1,335 |
| `sde/sde_encoder.c` (6,872) | 2,564 | 818 | 215 | 3,652 |
| `sde/sde_encoder_phys_cmd.c` (2,756) | 1,256 | 866 | 29 | 456 |
| `sde/sde_crtc.c` (8,814) | 2,772 | 432 | 192 | 1,990 |
| `sde/sde_kms.c` (5,494) | 1,416 | 209 | 117 | 1,600 |
| `msm_atomic.c` (987) | 268 | 141 | 62 | 86 |
| `dsi/dsi_drm.c` (1,571) | 724 | 129 | 49 | 244 |

QC r7 is the pineapple-era code line: the S24 copy is almost the same Qualcomm code, S23 is
close, and both 5.4 and S26 are far away.

Does the S26 copy still know yupik? Yes in the code (`SDE_HW_VER_720`,
`_sde_get_hw_caps_for_yupik`, `qcom,dsi-phy-v4.1`, `config/gki_lahainadisp.conf`), but Samsung
builds it only for canoe (`targets/`), it needs canoe-era companions (HFI, CESTA, synx), and
Qualcomm pairs lahaina on 6.12 with r7, not with that code line. Using the S26 techpack as a
whole on this phone is not a sensible route. S23 and S24 also keep `IS_YUPIK_TARGET`.

### 2.2 How the Samsung framework changed (5.4 -> S23 -> S24/S26)

| Area | 5.4 | S23 (5.15) | S24 / S26 |
|---|---|---|---|
| Framework size (`*.c` / `*.h`) | 33,802 / 5,526 | 38,681 / 6,216 | 21,520 / 4,615 and 22,957 / 4,859 |
| Panel commands | DT tables `samsung,*_tx_cmds_revA`, parsed through `ss_cmd_set_prop_map` | both: the DT path is kept, plus the new text "panel data file" (`support_ss_cmd`) | panel data file only (`panel_data_file/*.dat`, a small language with `W`, `Delay`, `IF ... THEN`, `${SYMBOL}`), loaded as firmware or built into a header |
| Panel registration | name match in `ss_panel_init`, then `<PANEL>_init(vdd)` | same | same |
| Brightness / HBM / ACL / VRR | panel fills `panel_func.br_func[BR_FUNC_*]` and `make_brightness_packet` | same callbacks still exist | callbacks removed; logic lives in the data file, panel code only supplies `pre_brightness`, `post_vrr`, symbol callbacks |
| AOD (LPM) | `samsung_update_lpm_ctrl_cmd`, `samsung_set_lpm_brightness`, `lpm_bl_level`, `TX_LPM_*NIT_CMD` | same | removed, data-file driven (`pre_lpm_brightness`) |
| Fingerprint HBM ("finger mask") | `finger_mask*`, `panel_hbm_entry_delay`, `panel_hbm_entry_after_te`, `panel_hbm_exit_delay` | `..._after_te` replaced by `panel_hbm_entry_after_vsync(_pre)` | same as S23, plus `panel_hbm_exit_frame_wait` |
| Self display | one file per DDI (`self_display_FC3.c`, 611 lines) | one file per DDI, no FC3 | one generic `self_display.c` |
| Smart dimming, interpolation, flash tables, SPI DDI | present (12,500 lines) | present | removed |
| COPR | 900 lines | 900 lines | 51-line stub |
| mDNIe | tables as positional `struct dsi_cmd_desc` initialisers | — | tables through a `MDNIE_CMD_LW()` macro with named members |
| Kernel file I/O (`set_fs` / `filp_open`) | 28 / 7 | 28 / 7 | 4 / 1 |
| `/sys/class/lcd/panel` attributes | 108 | not counted | 101 in S26; 32 of the 5.4 ones gone, 24 new |

The attributes the HALs use (`mask_brightness`, `actual_mask_brightness`, `fp_green_circle`,
plus `lcd_type`, `window_type`, `cell_id`, `alpm`, `vrr`, the mDNIe set) exist in 5.4 and in
S26. `self_mask` and the full list of 95 live attributes were not checked one by one.

### 2.3 Can the 5.4 panel directory be compiled against a newer framework? (measured)

The unmodified 5.4 files (`ss_dsi_panel_S6E3FC3_AMS646YD01_LO.c/.h`, the mDNIe header,
`self_display_FC3.h`) were compiled with clang r547379 against the 6.12.81 kernel headers of
this project (`samsung612/k612-gki`, a `gki_defconfig` header tree made from `bsp612/kernel`)
and each framework's headers. Logs and the exact flags are in
`samsung612/compile-check/panel54-vs-{s26,sm8650,sm8550}/` (`Kbuild`, `build.log`,
`errors-summary.txt` for S26).

| Framework | Errors in the panel `.c` | Errors in the mDNIe header | Verdict |
|---|---|---|---|
| S26 | 128 (73 different symbols) | 208 | no: needs a rewrite |
| S24 | 128 (same list) | 208 | no: needs a rewrite |
| **S23** | **5 (3 symbols)** | 208 | **yes, with small edits** |

Against S26 and S24 the panel file loses, by name:
- `panel_func.br_func[]` and all 38 `BR_FUNC_*` indices it sets; `make_brightness_packet`,
  `ss_add_brightness_packet`, `samsung_brightness_tot_level`;
- `samsung_update_lpm_ctrl_cmd`, `samsung_set_lpm_brightness`, `lpm_info.lpm_bl_level`,
  `LPM_2NIT/10NIT/30NIT/60NIT`, `TX_LPM_BL_CMD`, `TX_LPM_*NIT_CMD`;
- command ids `TX_GAMMA_MODE2_NORMAL/HBM/HMT`, `TX_VRR`, `TX_ACL_ON/OFF`,
  `TX_DYNAMIC_FFC_SET`; `panel_func.set_ffc`;
- `ss_panel_data_read()`, `MAX_CELL_ID`, `MAX_OCTA_ID`; `ss_ddi_id_read` and
  `ss_octa_id_read` are now framework functions (name clash);
- members `brightness_info.cd_idx`, `vrr_info.brr_lock`,
  `ss_brightness_info.smart_dimming_loaded_dsi` / `smart_dimming_hmt_loaded_dsi`,
  `panel_hbm_entry_after_te`.

Against S23 only three symbols are missing: `MAX_CELL_ID`, `MAX_OCTA_ID` and
`panel_hbm_entry_after_te` (now `panel_hbm_entry_after_vsync`, the fingerprint HBM timing:
check its unit before copying the value 60).

The 208 mDNIe errors have one cause in all three: Qualcomm added `ctrl`, `ctrl_flags` and
`ts` to `struct dsi_cmd_desc` (QC r7 has them too), which shifts Samsung's `ss_txbuf` in the
positional initialisers. One macro with named members, applied to 192 table rows, fixes it.

Limits of this check: it is the panel file against headers. The S23 framework itself was not
compiled on 6.12; its own header already shows two 6.12 breaks (`strlcpy`,
`struct drm_vblank_crtc`). `self_display_FC3.c` was not compiled. Four small shim headers
were needed for the S23 Qualcomm headers (`samsung612/compile-check/shim/`).

### 2.4 Panel device-tree properties

The panel node (DT lines 17546-17768, copy in `notes/panel-node-r02.dts`) has 66 different
`samsung,*` properties (revision suffix removed) and 83 `qcom,*`.

| Framework | `samsung,*` properties of the node it has no parser for |
|---|---|
| 5.4 | 0 |
| S23 | 2: `samsung,elvss_interpolation_temperature`, `samsung,mdss-dsi-sot-hs-mode` |
| S24 / S26 | 49: all 41 command tables (`*_tx_cmds`, `*_rx_cmds`, `self_grid_*`), the four candela map tables (`candela_map_table`, `hbm_`, `aod_`, `hmt_`), `dynamic_mipi_clk_sel_table`, `dynamic_mipi_clk_timing_table`, and the two above |

All 349 command-set names of the 5.4 map were compared with S23's 378: the ones the A52s
node uses are all still there. Lists: `notes/dt-*.txt`, `notes/cmdmap-*.txt`.
S24/S26 still read 17 of the node's properties from the DT (GPIOs, `panel-vendor`,
`support_*` flags, gpara settings); everything else would have to be rewritten as a data
file. The candela tables are read through built names in 5.4 and S23, so their absence from
the string lists is not a finding; whether S23 reads them identically was not traced.

### 2.5 Display decision

Port the **S23** framework and its hooks onto QC r7 and keep the 5.4 panel directory and the
panel DT node as they are.

- It is the last Samsung generation that still accepts this panel's code (3 symbols) and its
  DT command tables (2 minor properties). The panel logic that is known to work on this
  hardware stays byte-for-byte.
- Its Qualcomm code is close to QC r7, so the 398 hook lines move with moderate rework.
- Cost: the framework is 5.15 code. It needs the 6.12 API fixes (28 `set_fs`, 7
  `filp_open`, 33 `strlcpy`, `class_create`, the two header breaks). The files with most of
  the file I/O (smart dimming, flash table, POC, SPI DDI) serve other DDIs; check which the
  FC3 panel needs and leave the rest out.

Second choice, if the S23 hook transplant turns out worse than measured: S24 framework and
hooks (near drop-in on QC r7, already free of most file I/O) and rewrite the panel as a data
file: 41 command tables and about 1,200 lines of brightness, HBM, AOD and VRR logic into the
new format, with no way to check the result except on the panel.

Not recommended: 5.4 framework onto QC r7 (largest hook distance and the oldest kernel API),
or the S26 techpack as a whole.

Steps: (1) QC r7 builds and lights up the SDE without Samsung code (other agent's BSP);
(2) add S23 `msm/samsung/` minus unused DDI files, fix 6.12 API; (3) transplant hooks file
by file in the order of the table in 2.1; (4) add the 5.4 panel directory, the mDNIe macro
fix, `self_display_FC3`; (5) DT: panel node from the 5.4 tree unchanged.

## 3. Touch

Source: subagent report (file diffs, no compile).

- STM driver: S26's `stm_fst3ca60y_spi` is another protocol generation (device id 0x52/0x36
  instead of 0x48/0x36, event read 0xED burst instead of 0x60/0x61, different firmware
  header, 73 of 218 register defines differ, SPI only). It cannot drive the FTS5CU56A. CRD's
  5.15 `stm_spi` is the same driver as 5.4 (`stm_reg.h` and `stm_fw.c` identical) with no
  6.x fixes, and it lacks the ROM's `fod_pressed`. So: the 5.4 `stm/` (14,851 lines in the
  I2C build).
- Framework: S26 changed the API the 5.4 stm driver uses (`sec_cmd_init` arguments,
  `sec_input_enable_device` takes a `struct device`, 5 exports and 10 `sec_ts_plat_data`
  members gone, 17 DT properties no longer parsed, of which the A52s node uses
  `sec,tclm_level` and `sec,unuse_dvdd_power`). So: 5.4 `sec_common_fn.c` + `sec_cmd.c`
  (5,625 lines).
- 6.12 breaks in the 5.4 code: i2c `probe` signature 1, i2c `remove` 1, `class_create` 1.
  `set_fs`/`filp_open` hits are in dead `#else` branches.
- Blob-facing names stay because the code stays: inputs `sec_touchscreen`,
  `sec_touchproximity`, `/sys/class/sec/tsp/{cmd,cmd_status,cmd_result,ear_detect_enable,fod_pressed}`.
- Load order: `sec_core`, `sec_tsp_log`, `sec_cmd`, `sec_common_fn`, `sec_tclm_v2`, `stm_ts`.
  Stub or switch off: `vbus_notifier`, `hall_ic_notifier`, `usb_typec_manager_notifier`,
  `abc`, secure touch. DT: `stm,stm_ts` at 0x49, `sec,irq_gpio` TLMM 81,
  `tsp_avdd_ldo-supply`. Firmware `tsp_stm/fts5cu56a_a52sxq.bin`.

## 4. Charging and power

Source: subagent report (file diffs and symbol checks, no compile).

| Driver | 5.4 lines | Donor lines | What differs |
|---|---|---|---|
| `sm5714_core.c` / `-irq.c` | 537 / 364 | PHYS 547 / 364 | probe/remove signatures only; headers byte-identical |
| `sm5714_charger.c` (+oper) | 1,529 / 400 | PHYS 2,028 / 490 | registers identical; 7 optional DT properties added, none removed |
| `sm5714_fuelgauge.c` | 3,093 | PHYS 3,231 | registers identical; `battery0,*` table parsing unchanged |
| `sm5714-muic.c` / `-afc.c` | 2,604 / 1,375 | PHYS 2,639 / 1,402 | small API renames; DT identical |
| `sm5714_pd/_policy/_typec.c` | 10,704 | PHYS 12,182 | PHYS `usb_notifier.c` is MediaTek-only: take S26 `usb/notify` (needs `dwc_msm_id_event`/`dwc_msm_vbus_event` from the BSP dwc3-msm) |
| `battery/common` | 30,736 | PHYS 34,077; S26 42,947 | PHYS is much nearer to 5.4 (`sec_battery.c` 1,703 changed lines vs 4,410) and has run with SM5714 |
| `pca9468_charger.c` | 5,193 (v3.4.16S) | CRD 7,123 (v3.4.24S) | same 32 registers; CRD still has 5.15 signatures; drops `pca9468,ta-mode` (DT sets 1, effect unknown) |
| `s2mpb03.c` | 749 | PHYS 761 | probe wrapper only |
| `leds-sm5714-fled.c` | 700 | PHYS 856 | PHYS pulls in a MediaTek camera header: forward-port 5.4 |

- GKI and `power_supply.h`: no core patch is needed. 5.4 already runs with
  `CONFIG_BATTERY_GKI=y`; the extra properties are a private enum starting at 1000 used
  through `psy_do_property()`.
- Blob-facing sysfs: a supply named exactly `battery` with `capacity`, `status`, `temp`,
  `current_now`, `voltage_now`, `siop_level`, `chg_temp`, `usb_temp`, `blkt_temp`,
  `dchg_temp`, `sub_bat_temp`, `gps` exists in 5.4, PHYS and S26. `system_temp_level` is in
  none of them, 5.4 included, so the inventory line that lists it is probably about a file
  that does not exist on the phone (not checked on a device).
  `/sys/class/usb_notify/usb_control/cards` exists in all. `/sys/class/switch/uart3/state`
  needs the switch class (S26 `drivers/staging/android/switch`) with the PHYS muic core.
- Board data: the 5.4 tree has no a52sxq battery dtsi source. Everything comes from the DT:
  `sm5714-fuelgauge` with `battery_params` (line 540 on), `sm5714-charger` (806),
  `sec-direct-charger` (153), `pca9468@57` (20237), `sm5714@49` (20250),
  `usbpd-sm5714@33` (20459). 4,500 mAh, float 4.38 V.
- First target "charges and shows %": `sb-core`, switch class + `common_muic`, `mfd_sm5714`,
  `sm5714_fuelgauge`, `sm5714-charger`, `sec_pd`, `muic_sm5714`, `sec-battery`. Build with
  `CONFIG_DIRECT_CHARGING=n` and point `battery,charger_name` at the SM5714 charger supply
  (name to confirm in the PHYS source). Needs the PMIC ADC channels `adc-temp`,
  `adc-chg-temp`. Then: pdic notifier, typec manager, `pdic_sm5714`, `usb_notify`, direct
  charger with PCA9468, S2MPB03, flash LED.

## 5. The rest

Source: subagent report.

- Vibrator: S26 has only input force-feedback drivers, nothing for
  `/sys/class/timed_output/vibrator`. Forward-port 5.4 `sec_vibrator.c` + `dc/` (1,752
  lines; `class_create` 1, platform `remove` 1). PHYS has a 6.12 copy that was not fetched.
- Hall: S26 `hall_ic.c` already carries 6.x guards and parses the A52s node (`gpios`,
  `event = <0x15>`); same `/sys/class/sec/hall_ic` files.
- SX9360: CRD's copy has no `set_fs` (5.4 has 5) and uses the hall notifier; it dropped
  `sx9360,vdd_en`, which the A52s uses (TLMM 104), so that block comes back from 5.4. The
  A52s config selects `CONFIG_SENSORS_SX9364`, which builds `sx9360.o`. One attribute
  (`mcc`) is missing in CRD.
- et7xx: only exists on 5.4. The kernel side does power, reset, IRQ and `/dev/esfp0`
  (44 ioctl cases); it enables no QUP clock itself. Whether the 6.12 kernel leaves that
  serial engine's clock and pins alone for TrustZone is not verified and is the real risk
  here. Keep the ROM's `FP_SET_SENSOR_TYPE` cap.
- sec-nfc: not in S26. 5.4 `sec_nfc.c` (1,758 lines): i2c signatures, `class_create` 2,
  class attribute signatures 3.
- `adsp_factory`: S26 is not wire-compatible with the 5.4 sensor HAL/SSC: the sensor enum
  lost `MSG_HH_HOLE` (every later id moves by one), a command id was removed, and five
  payload sizes differ. Keep the 5.4 core and header; `lsm6dso_accel.c` has 15 `set_fs`
  uses to replace; it is built in on 5.4 and must become a module.

## 6. sec_core (step 0, done tonight)

`samsung612/modules/sec_core/`: `sec_core.c` (about 300 lines), `include/linux/sec_class.h`,
`Kbuild`. Built as `sec_core.ko` against the 6.12.81 lahaina build of the other agent
(`bsp612/out/lahaina`, `W=1`, no warnings, no unresolved symbols at modpost). Never loaded.

    CLANG=$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r547379/bin
    KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost \
      make -C bsp612/kernel ARCH=arm64 LLVM=$CLANG/ O=$PWD/bsp612/out/lahaina \
      KCONFIG_EXT_PREFIX=$PWD/bsp612/soc-repo/ M=$PWD/samsung612/modules/sec_core W=1 modules

What it does:
- `/sys/class/sec` with `sec_device_create()`, `sec_device_destroy()`,
  `sec_dev_get_by_name()`: same names and macro as 5.4.
- A reboot notifier that leaves the two cells the Samsung bootloader reads in the state the
  three 5.4 writers (`sec_debug.c`, `qcom-reboot-reason.c`, `msm-poweroff.c`) leave them:

| Command | PON byte (PMK8350 SDAM 0x7100, offset 0x48, bits 1-7) | IMEM word (0x146aa65c) |
|---|---|---|
| none, `adb*` | 0x14 | 0 |
| `recovery*` | 0x01 | 0x77665502 |
| `recovery-update` | 0x60 | 0x77665502 |
| `bootloader*` | 0x02 | 0x77665500 |
| `download*` | 0x15 | 0x77665501 |
| `rtc`, `dm-verity device corrupted`, `dm-verity enforcing`, `keys clear` | 0x03, 0x04, 0x05, 0x06 | 0x77665503, ...08, ...09, ...0a |
| `nvbackup`, `nvrestore`, `nverase`, `nvrecovery` | 0x16-0x19 | 0x77665501 |
| anything else | 0x14 (5.4 leaves the byte unwritten here: the one deliberate difference) | 0x77665501 |
| power-off, halt | untouched | 0 |

- It finds both cells the way 5.4 does: the node `qcom,msm-imem-restart_reason` and the
  nvmem cell `restart_reason` of the node `qcom,reboot-reason`. Both exist in Qualcomm's
  6.12 yupik tree. It must be loaded after the SDAM nvmem driver (insmod fails with
  `-EPROBE_DEFER` otherwise).
- On load it sets the IMEM word to 0 (`clear_on_load=0` turns that off). 5.4 arms upload
  mode there instead; this module has no upload-mode support.

Left out on purpose:
- Panic and watchdog paths (`upload_cause` at IMEM 0x66c, upload magic 0x776655ee, download
  mode SCM bit). The BSP's `qcom-dload-mode` owns the SCM bit. What the bootloader does
  after a panic with this module loaded is not known.
- `sec_param`: 5.4 reads and writes the `param` partition from the kernel by path. Nothing
  needs that to boot; the RIL opens `/dev/block/param` itself. If a driver later needs
  `sec_get_param()` (the PHYS battery code references `sec_param.h` on Qualcomm), port the
  S26 `drivers/samsung/bsp/param/sec_param.c`, which already uses the block layer.
- Debug level, CP debug, force-upload, `swsel` and `multicmd` reboot commands.

## 7. Open points and things not verified

- No Samsung code other than `sec_core` and the panel file has been compiled on 6.12.
- The hook transplant (S23 -> QC r7) is estimated from line distances, not attempted.
- `panel_hbm_entry_after_te` -> `panel_hbm_entry_after_vsync`: unit and meaning must be
  read before the optical fingerprint works.
- PHYS typec manager against S26 `usb_notify.h`: not checked. `linux/sec_ext.h` guard in the
  PHYS muic: not checked.
- et7xx: QUP clock ownership on 6.12.
- Hall: that `SW_MAX` in the 6.12 GKI covers event codes 0x15 and 0x1b.
- While setting up the compile check, a `make O=bsp612/out/lahaina` of mine ran at a moment
  when the other agent had just wiped `bsp612/out`, and created that directory empty. I
  removed the empty directory seconds later; the other agent's build then completed
  normally. Nothing else was written under `bsp612/`.
