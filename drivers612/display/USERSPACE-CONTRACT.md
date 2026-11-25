# Display: what the AOSP ROM's userspace reads and writes, and whether the S23 framework keeps it

Sources read (nothing was run on a phone): `research/blob-uapi-inventory.md` (display rows),
`$ANDROID_TREE/device/samsung/sm7325-common/init/*.rc`, `.../sepolicy`, `.../abyss`,
`$ANDROID_TREE/hardware/samsung/aidl/{fingerprint,livedisplay,light}`,
`hardware/samsung/fingerprint/UdfpsExtension.cpp`, the 5.4 framework
(`$ANDROID_TREE/kernel/samsung/sm7325/techpack/display/msm/samsung/`) and the S23 one
(`samsung612/donors/sm8550-modules/.../msm/samsung/`).
Machine comparison: `tools/sysfs-compare.py` over `tools/userspace-attrs.txt` (93 attributes),
full output in `sysfs-compare-54-vs-s23.txt`. It compares presence, mode and the
`sscanf`/`kstrto*`/`*printf` format strings of each show/store function; it does not prove that
the code behind an attribute behaves the same.

## 1. Paths with a real user (must work)

| Path | User | R/W | Values | 5.4 -> S23 |
|---|---|---|---|---|
| `/dev/dri/card0` + `DRM_IOCTL_MSM_*`, `sde_drm.h` | closed composer (`libsdmextension`, `libdpps`) | ioctl | — | Qualcomm side (r7), not Samsung's; UAPI struct check is the parent's/BSP's item |
| `/sys/class/backlight/panel0-backlight/{brightness,max_brightness}` = `/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/` | composer (live fd), `libdpps.so`, init (`init.qcom.rc`, recovery rc writes 200), Abyss (`abyss.rc` copies/writes raw level, max 486) | RW | 0..486 (`qcom,mdss-brightness-max-level = 0x1e6`) | Qualcomm `sde_connector.c` backlight, name `panel0-backlight` in r7 too. The device path needs the node to stay `qcom,mdss_mdp@ae00000` under `/soc` (kept in `dts/yupik-sde.dtsi`; sepolicy `vendor_file_contexts` and `ueventd.qcom.rc:427` name `ae00000.qcom,mdss_mdp`) |
| `/sys/class/backlight/panel/{brightness,max_brightness}` | open lights HAL default (`hardware/samsung/aidl/light/samsung_lights.h`) | RW | 0..max | Samsung backlight device `panel` (`ss_dsi_panel_sysfs.c`, `backlight_device_register("panel")`), same in S23. Which of the two nodes the ROM's lights path really uses on this device was not traced (composer holds `panel0-backlight`) |
| `/sys/class/lcd/panel/mask_brightness` | open fingerprint HAL (`LegacyHAL.cpp:138` writes 0 at start; `Session.cpp` writes level / 0), `libbauthserver.so` | W | decimal level, 0 = off | present, mode same, same input format. Since audit 2026-11-18 (patch 0005) the store has the ROM's 5.4 meaning again: a write is a one-shot request (`vdd->ichthys_sysfs_mask_req`) that `sde_connector_pre_kickoff` applies at the next kickoff, with priority over the property/FOD state (>0 = mask on at that level, 0 = mask off). Before that the S23 body only stored a level. Since 2026-11-22 (patch 0007, FINGERMASK-ONEUI.md) a write is a request only after a 0 has been written once (IchthysOS HAL does that at start); before that it is level-only as on stock (OneUI's framework writes 331 once at boot as configuration), and a sysfs-lit mask is bounded to 10 s. Compiled only, needs a phone test |
| `/sys/class/lcd/panel/actual_mask_brightness` | fingerprint HAL: `poll()` for `sysfs_notify`, then read | R + notify | mask level while `finger_mask` set, else 0 | present, identical show. The `sysfs_notify(..., "actual_mask_brightness")` is in `ss_dsi_panel_common.c` in both (5.4:6745, S23:7957): it only fires if the brightness path with `finger_mask_updated` is hooked up (needs the `sde_connector`/`sde_encoder` hooks) |
| `/sys/class/lcd/panel/fp_green_circle` | fingerprint HAL (opt-in experiment), `libbauthserver.so` | W | 0/1 | present, same mode/format; needs `TX_SELF_MASK_GREEN_CIRCLE_*` tables, which this panel's DT does not define (as on 5.4) |
| `/sys/class/lcd/panel/self_mask` | chown'd by init; HAL no longer writes it | W | 0/1 | present |
| DRM connector property `fingerprint_mask` (range) | SurfaceFlinger via `libudfps_extension.samsung` (UDFPS dim/pressed layer z-order bits) and the composer, `persist.ichthys.udfps_sync=1` | atomic property | 0 = off, 1 = HAL level, >1 = level | Property exists in stock 5.4 and S23 (`CONNECTOR_PROP_FINGERPRINT_MASK`), NOT in r7: comes with the hook transplant. **IchthysOS changed its meaning in the 5.4 kernel** (see section 3); stock S23 behaviour is not what the ROM expects |
| `/sys/class/mdnie/mdnie/mode` | livedisplay HAL `DisplayModes.cpp` | RW | mode index | present, same formats |
| `/sys/class/mdnie/mdnie/mode_max` | livedisplay HAL `DisplayModes.cpp` | R | `"%u\n"` = `MAX_MODE` | **MISSING in S23.** Re-add: `static ssize_t mode_max_show(...) { return snprintf(buf, PAGE_SIZE, "%u\n", MAX_MODE); }`, `DEVICE_ATTR(mode_max, 0444, mode_max_show, NULL)`, `device_create_file(tune_mdnie_dev, &dev_attr_mode_max)` (5.4 `ss_dsi_mdnie_lite_common.c:386,1292,1459`). Whether 5.4 stock had it or the ROM added it was not checked |
| `/sys/class/mdnie/mdnie/{outdoor,sensorRGB,accessibility,night_mode,scenario,bypass,whiteRGB,hdr,light_notification,color_lens,mdnie_ldu,cabc,afc,hmt_color_temperature}` | livedisplay HAL (`outdoor`, `sensorRGB`), init chown | RW | as 5.4 | all present, same formats (bodies differ only in logging/helpers by the format check) |
| `/sys/class/lcd/panel/power_reduce` | livedisplay `AdaptiveBacklight.cpp` | RW | 0/1 | present, same formats |
| `/sys/class/lcd/panel/alpm` | init chown; AOD path | RW | as 5.4 | present, same formats |
| `/sys/class/lcd/panel/{lcd_type,window_type,cell_id,octa_id}`, `SVC_OCTA*` | init chown, `libsec-ril.so`/factory strings | R | ids | present. `cell_id`, `octa_id`, `SVC_OCTA`, `SVC_OCTA_CHIPID`, `SVC_OCTA_DDI_CHIPID` are built differently in S23 (string prepared at read time into `vdd->cell_id_dsi` / `octa_id_dsi` with a length, then copied; 5.4 printed fixed `%02x...` formats). Output must be compared on the panel; the panel file's `MAX_CELL_ID`/`MAX_OCTA_ID` compile errors are this same change |
| `/sys/class/lcd/panel/vrr`, `vrr_lfd` | init chown | R / RW | — | present; `vrr_lfd` show text differs slightly |
| `/sys/class/lcd/panel/vrr_state` | only `init.samsung.display.rc:461` (chown/chmod 0440); no reader found in the open tree | R | mode list | **MISSING in S23** (5.4 `ss_dsi_panel_sysfs.c:4746`, attr at 5623/5713). No user found: init only logs a failed chown. Port the 20-line show function if a blob turns out to read it |
| `/sys/class/drm/card0/sde-crtc-0/measured_fps` | SystemUI FPS overlay (`config_fpsInfoSysNode`) | R | fps x10 | Qualcomm `sde_crtc.c`, in r7 |
| `/sys/class/drm/card0-DSI-1/{modes,status}` | `init.qcom.early_boot.sh:49`, `libperfconfig.so` | RW | — | DRM core; connector must stay `DSI-1` (one DSI display, as now) |
| `/sys/class/drm/card0/device/power/control`, `/sys/devices/platform/soc/ae00000.qcom,mdss_mdp power/control` | init chown, ueventd, `libops.so` | W | — | driver core; path kept by the node name |
| `/sys/class/lcd/panel/mipi_switch` | string in `libsec-ril.so` | ? | — | in neither framework's sysfs file (absent on 5.4 too) |

## 2. Paths init only chowns (`init.samsung.display.rc`), no reader found in the open tree

Present in S23 with the same name, mode and formats (or differing only inside the function
body): `adaptive_control, brightdot, brt_avg, ccd_state, conn_det, copr, copr_roi, dia, dpci,
dpci_dbg, dpui, dpui_dbg, dynamic_freq, dynamic_hlpm, gamma_check, gamma_flash, gct, grayspot,
hmt_bright, hmt_on, hw_cursor, ioctl_power_ctrl, irc_mode, isc_defect, ldu_correction, lux,
mafpc_check, mcd_mode, mst, partial_disp, poc, poc_info, poc_mca, read_copr, self_mask_check,
self_move, siop_enable, spi_if_sel, temperature, tuning, xtalk_mode`, and
`/sys/class/backlight/panel/weakness_ccb`.
In neither 5.4's nor S23's sysfs file (init's chown already fails today): `cover_control,
demux_stress, dynamic_fps_use_te, force_flip, irc_onoff, mcd_resistance, motto, poc_onoff`,
`backlight/panel/weakness_hbm_comp`, mdnie `lcd_power, lcdtype, mdnie_temp, negative, playspeed,
tuning, lux`.

## 3. IchthysOS changes in the ROM's 5.4 display code that userspace depends on

These are commits in `$ANDROID_TREE/kernel/samsung/sm7325` on top of the Samsung snapshot. The
S23 framework is stock, so each must be re-applied after the transplant:

| Commit | File | What |
|---|---|---|
| `182cea7c38e0` | `sde/sde_connector.c`, `.h` | `fingerprint_mask` connector property drives the mask HBM on a value change, in the same atomic commit as the frame (range widened to 0..1023; 1 = HAL level, >1 = explicit level; `ichthys_finger_mask_prop`). This is the `udfps_sync` path the ROM ships enabled |
| `58af9aab0070` | `sde/sde_crtc.c` (+ `drivers/fingerprint`) | `finger_mask` is left to the HAL (Samsung's own layer detection in `sde_crtc.c` removed) |
| `9d97d2093379` | `samsung/ss_dsi_panel_common.c` | ACL kept on under the fingerprint mask HBM |
| `8b3de7b345e5` | `samsung/ss_dsi_panel_common.c` | finger mask never dims below the current level |
| `daf15e1e2698` / `d3c1fea4af28` | — | added and reverted (net nothing) |

## 4. Not verified

- Nothing ran. `sysfs_notify`, the backlight nodes and every show/store were compared as text.
- The closed composer's use of `msm_drm.h`/`sde_drm.h` structs against r7 (blob inventory
  row 115 and its note at line 542) is outside this file.
- Bodies marked "differs" in `sysfs-compare-54-vs-s23.txt` were not read one by one, except
  the ones in section 1.
- `mode_max`: origin (stock 5.4 or ROM patch) not checked.
