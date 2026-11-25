# display — Qualcomm r7 techpack + Samsung ss_dsi_panel (S23) + S6E3FC3_AMS646YD01 panel (5.4)

Everything here is compiled only. Nothing was loaded on a phone.

## What builds (2026-11-11, against `bsp612/out/lahaina`, clang r547379)

| Module | Source | Notes |
|---|---|---|
| `techpack/display-drivers/msm/msm_drm.ko` (31 MB with BTF/debug) | Qualcomm `display-kernel.lnx.1.11.r7-rel` + Samsung hooks + framework + panel | 0 compile errors, 0 modpost errors |
| `lcd_class/lcd.ko` | `drivers/video/backlight/lcd.c` of the BSP kernel, unmodified | GKI has `CONFIG_LCD_CLASS_DEVICE` unset; needed for `/sys/class/lcd/panel` |
| `sec_panel_notifier_v2/sec_panel_notifier_v2.ko` | Galaxy S26 6.12 kernel, unmodified | `panel_notifier_register/unregister/call_chain`; header in `techpack/display-drivers/include/linux/` |
| `techpack/mm-drivers/msm_ext_display/msm_ext_display.ko` | Qualcomm mm-drivers, unmodified | only built for its headers/symvers |
| `techpack/display-drivers/bridge-drivers/lt9611uxc.ko` | Qualcomm | not needed on the phone |

Build: `./build.sh` (7 s on 20 cores). `SAMSUNG=0 ./build.sh display-drivers` builds plain r7.
Logs in `logs/`. It only reads `bsp612/`.

`modinfo msm_drm.ko` depends: `llcc-qcom, panel_event_notifier, qcom-scm, qcom_va_minidump,
pinctrl-msm, spmi-pmic-arb, lcd, sec_panel_notifier_v2, mem_buf_dev, qcom_iommu_util,
msm_dma_iommu_mapping`. Load order: those soc-repo modules, then `lcd.ko`,
`sec_panel_notifier_v2.ko`, then `msm_drm.ko`.

## How the tree was made

1. `techpack/display-drivers` = r7 copy (+ one `LINUXINCLUDE := $(SOCINCLUDE) ...` line in `Kbuild`,
   as in `bsp612/techpacks-probe.sh`).
2. Hooks: `tools/transplant.py` does a 3-way merge per file. Base = S23 file with every
   `CONFIG_DISPLAY_SAMSUNG` block evaluated as off; theirs = S23 file; ours = r7 file.
   `tools/resolve.py` then places conflicting blocks (a Samsung block is always "base plus
   inserted lines") on the unchanged lines around them. Result: 396 of S23's 406 hook lines are in
   53 files. `HOOK-PLACEMENT.txt` logs every automatic placement; the 5 blocks at its end were
   dropped (r7 rewrote the code they sat in). `tools/hook-context-check.py` output is
   `HOOK-CONTEXT-REVIEW.txt`: 359 blocks have the same code line before and after as in S23,
   24 differ on one side (all listed there; scanned, not each traced), 2 on both (fine: `msm_drv.h`,
   `dsi_ctrl.c` probe log). `tools/hook-function-check.py` compares the enclosing function of
   each block: 352 of 356 identical, the other 4 are r7 renames or file-scope blocks. It found
   one real misplacement (a debug line in `dsi_conn_get_avr_step_fps`, r7's twin of
   `dsi_conn_get_qsync_min_fps`), fixed by hand.
3. `msm/samsung/` = S23 framework files + `PBA_BOOTING`, `SELF_DISPLAY`, `MAFPC` (only the
   common files, PBA panel and `self_display_FC3` are compiled) + `S6E3FC3_AMS646YD01_LO/` and
   `SELF_DISPLAY/self_display_FC3.[ch]` from the phone's 5.4 tree. Wired in at the end of
   `msm/Kbuild` under `CONFIG_DISPLAY_SAMSUNG=y` (make variable set by `build.sh`);
   `msm/samsung/a52sxq_conf.h` selects the panel and the notifier and defines `MDNIE_CMD_LW`.
4. Every change to donor code is in `patches/`:
   - `0001-qc-r7-samsung-hooks-from-s23.diff` (r7 -> our Qualcomm files),
   - `0002-s23-framework-6.12-and-a52sxq-fixes.diff` (S23 framework -> ours),
   - `0003-5.4-panel-S6E3FC3-on-s23-framework.diff` (5.4 panel + self display -> ours).

## Changes made by hand (all also in the patches)

Qualcomm side (beyond the transplanted hooks):
- `sde_encoder_phys_cmd.c`: `_get_tearcheck_threshold()` adapter on r7's `_get_tearcheck_cfg()`.
- `sde_dbg.h`: `SDE_EVT32_PICK*` map to the normal event log (r7 has no "pick" log).
- `sde_dbg.c`: `ss_sde_dbg_debugfs_open()` uses `atomic_set` (r7 made `evtlog->last` atomic).
- `sde_kms.c`: one debug `SS_XLOG_VSYNC` line removed (variable gone in r7).
- `dsi_ctrl.c`: Samsung's `DSI_CTRL_TX_TO_MS` 400 raised to 1200 (r7's own default; S23's
  value would have shortened it).
- `sde_connector.c/.h`, `ss_dsi_panel_common.c`: the ROM's 5.4 fingerprint commits ported
  (`182cea7c38e0` property edge + level 0..1023, `9d97d2093379` ACL kept under the mask,
  `8b3de7b345e5` never dim below the current level).
- `msm/Kbuild`: `-Wno-missing-prototypes` (Samsung code), `-Werror=implicit-function-declaration`
  (Qualcomm's Kbuild silences it; it had hidden `vmalloc`/`strlcpy` without declarations).

Framework (5.15 -> 6.12): `strlcpy` -> `strscpy` (33), `class_create()` one argument (3), SPI
`master`/`chip_select`/`remove` API, `<drm/drm_vblank.h>` and `<linux/vmalloc.h>` includes.
The `set_fs`/`filp_open` code of S23 is all inside disabled blocks in this configuration (no
undefined symbols), so it was not rewritten. Added: panel name
`ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD` in `ss_panel_init`, `mode_max` mDNIe attribute (the
livedisplay HAL reads it), the `samsung,elvss_interpolation_temperature` parser.

Panel (5.4 -> S23 framework): mDNIe rows through `MDNIE_CMD_LW()` (192 rows);
`cell_id_dsi` / `octa_id_dsi` / `ddi_id_dsi` are heap strings in S23 (were arrays of raw bytes):
the panel now builds the same text the 5.4 sysfs printed; `panel_hbm_entry_after_te = 60` became
`panel_hbm_entry_after_vsync_pre = 60`.

## Device tree

`a52sxq-display.dtsi` (+ `dts/`), generated from `downstream-dt/a52sxq-r02.dts` by
`tools/gen-dts.py`, checked by `tools/check-dts.sh` (compiles on the 6.12 `yupik.dts`, 540
properties byte-identical to the phone's tree). The 6.12 yupik base has NO display nodes, so
nothing has to be disabled; `dts/yupik-sde.dtsi` supplies mdss_mdp / dsi ctrl / phy / rscc / smmu.
Panel rails: L13C `panel_vci` 3.0 V, L8C `panel_vddi` 1.8 V (phone values). GPIOs: reset 44,
TE 80, UB con-det 47, ESD irq 3. Same for hardware revisions 3 and 4. Details and the list of
intended differences are in the header of `a52sxq-display.dtsi`.

## Userspace contract

`USERSPACE-CONTRACT.md` has the table (who reads what). Kept: `/sys/class/lcd/panel/*` (lcd class
module), `/sys/class/backlight/panel/*`, `/sys/class/backlight/panel0-backlight` (Qualcomm, max
486), `/sys/class/mdnie/mdnie/*` incl. `mode_max`, connector property `fingerprint_mask` with the
ROM's meaning, `mask_brightness`, `actual_mask_brightness`, `fp_green_circle`, `alpm`.
Changed or missing:
- `/sys/class/lcd/panel/vrr_state` does not exist in S23 (init only chowns it; no reader found).
- `vrr_lfd` show text differs slightly from 5.4.
- `cell_id`, `octa_id`, `SVC_OCTA*`: same text by construction, to be compared on the panel.
- DRM mode names follow S23: `1080x2400x120x<caps>HS` (5.4 format not compared).
- The LineageOS kernel FOD of the 5.4 tree (zpos bit -> plane property `fod`, dim layer with
  `fod_dim_lut`, finger mask HBM on/off from the layer) is ported since 2026-11-15: `FOD.md`
  (built, not yet run). The IchthysOS ROM's composer strips the bit, so there it stays inert.
- Kernel-side users of the panel notifier (touch, fingerprint, sensors) must use the v2 API
  (`linux/sec_panel_notifier_v2.h`); the 5.4 v1 API (`ss_panel_notify.h`) is not provided.

## First on-device test (test ramdisk, after the SoC display nodes are in the dtb)

    insmod lcd.ko; insmod sec_panel_notifier_v2.ko
    insmod msm_drm.ko dsi_display0=ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD: lcd_id=80000A
    dmesg | grep -E 'SDE|ss_dsi|\[drm|msm_drm|LCD_ID|panel_init|S6E3FC3' | head -80
    ls /sys/class/lcd/panel /sys/class/backlight /sys/class/mdnie/mdnie
    cat /sys/class/lcd/panel/lcd_type /sys/class/lcd/panel/window_type /sys/class/lcd/panel/cell_id
    echo 100 > /sys/class/backlight/panel/brightness; echo 400 > /sys/class/backlight/panel/brightness
    cat /sys/class/drm/card0-DSI-1/modes

(The bootloader puts `msm_drm.dsi_display0=...` and `msm_drm.lcd_id=80000A` on the kernel command
line; modprobe/Android init apply them, bare `insmod` does not, hence the explicit parameters.)
Expected: `[SDE] LCD_ID = 0x80000A`, the framework's `ss_panel_init`/`S6E3FC3_AMS646YD01_LO_FHD_init`
lines, `sde_kms` hw revision 0x70020000 (yupik), a `card0-DSI-1` connector with 60 and 120 Hz
modes, the splash kept (continuous splash), brightness visibly changing.

Likely failures: probe deferral on clocks/regulators/smmu (DT), the lahaina `sde_rscc`/RPMh
display votes, a NULL dereference in a hook whose surrounding r7 code changed meaning, panel-off
on the first commit if the S23 framework expects a callback the 5.4 panel file never set, wrong
tearcheck/VRR timing at 120 Hz, fingerprint HBM timing (vsync-based in S23, TE-GPIO-based in 5.4).

## Audit 2026-11-18 fixes (patch `patches/0005-*.diff`; compiled only, not yet on a phone)

- `a52sxq-display.dtsi` section 3: r7-format QoS overrides on `&mdss_mdp` (16-cell VBIF remap
  tables, 18-cell danger/safe LUTs, `qcom,sde-creq-lut`, `qcom,sde-num-ddr-channels = <2>`,
  `qcom,sde-ib-bw-vote`). `dts/yupik-sde.dtsi` stays as generated, so `tools/check-dts.sh` now
  reports these as CHANGED/ADDED against the phone's 5.4 tree: that is intended. The board tree
  takes its copy from `drivers612/boarddt/out/build/agents/display.dtsi`, which has to be
  regenerated before the fix reaches `android-r02.dtb`.
- mDNIe: `MDNIE_SCR_CMD_SIZE` back to 24 and `mdnie_scr_cmd_offset = 2` (5.4 values of the FC3
  tables); the S23 HBM-CE tables the FC3 panel does not have are NULL-checked (night mode wrote
  through NULL pointers).
- `mask_brightness` store drives the finger mask again (see USERSPACE-CONTRACT.md).
- `sde_color_processing.c`: a 5.4-size `drm_msm_sixzone` blob is zero-extended instead of
  rejected (the 5.4 struct is a prefix of r7's).
- Dynamic MIPI clock (`CONFIG_DEV_RIL_BRIDGE`), patch 0009, 2026-11-24, built, not on a phone: the
  RF band listener is registered with `symbol_get()` from a delayed work (2 s x 90 tries), so msm_drm
  does not depend on dev_ril_bridge.ko and the module lists stay as they are (dev_ril_bridge loads
  after msm_drm). `msm_drm a52_dyn_mipi=` 0 off / 1 (default) nothing changes on the panel until the
  first band report found in the DT table / 2 as 5.4; writing 0 at run time stops further switching.
  Only One UI's `libsec-ril.so` writes /dev/drb; on LineageOS / IchthysOS the listener never fires.
  Same patch: `temperature` reads the 5.4 table. Module: `out-p1/`, test steps: SPEC/01 section 13.
