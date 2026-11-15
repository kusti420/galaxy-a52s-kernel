# FOD: LineageOS kernel fingerprint-on-display (dim layer + finger mask HBM) on 6.12

Status 2026-11-15: built only (msm_drm.ko compiles, 0 warnings, export CRCs/imports/vermagic
unchanged). NOT loaded on a phone yet.

## Why
Enrollment on phone 1 (LineageOS 24, Samsung stock vendor) fails on 6.12 with BAuth
BAD_QUALITY (39) and works on its stock 5.4 kernel. LineageOS's fingerprint HAL never writes
`/sys/class/lcd/panel/mask_brightness`; the KERNEL turns the mask HBM on from the UDFPS layer.
On 6.12 none of that code existed, and the `zpos` range (0..8) made the DRM core reject the
flagged z-order with -EINVAL, so the composer fell back to GPU composition and nothing reached
the panel.

## What 5.4 (LineageOS, `kernel/samsung/sm7325` 58af9aab0070^) does
1. SurfaceFlinger (Lineage UDFPS extension) gives the UDFPS layer z | `FOD_PRESSED_LAYER_ZORDER`
   (0x20000000, uapi `sde_drm.h:501`). The composer passes that into the plane `zpos` property
   (range INT_MAX on 5.4).
2. `sde_plane_atomic_set_property` (sde_plane.c:4280) moves the bit into the plane property
   `fod` and stores zpos without it; `sde_plane_is_fod_layer()` (3596) reads it.
3. `sde_crtc_fod_atomic_check()` (sde_crtc.c:5016, called before `_sde_crtc_check_zpos`):
   with a FOD plane, `sde_crtc_setup_fod_dim_layer()` (4961) builds a full-screen black
   INCLUSIVE dim layer at the FOD plane's stage, alpha = `dsi_panel_get_fod_dim_alpha()`
   (dsi_panel.c:1116, `fod_dim_lut` by `bl_config.real_bl_level`), and every plane at or above
   that stage moves up one. The dim layer is programmed in `_sde_crtc_blend_setup_mixer`
   (1567) under `SDE_CRTC_DIRTY_DIM_LAYERS`.
4. Same function, Samsung part: layer appears and `!finger_mask && finger_mask_bl_level == 0`
   -> `finger_mask_bl_level = 331, finger_mask = 1, finger_mask_updated = true`; layer gone and
   `finger_mask && bl_level != 0` -> `0, 0, true`.
5. `sde_connector_pre_kickoff` (sde_connector.c:906) logs `[FINGER_MASK]updated finger mask mode 1`
   (every kickoff while the mask is on, the property being 0), then `dsi_display_pre_kickoff`
   (dsi_display.c:8631) consumes `finger_mask_updated`: `ss_send_hbm_fingermask_image_tx(vdd,
   finger_mask)` -> `ss_brightness_dcs(.., BACKLIGHT_FINGERMASK_ON/OFF)`. In there (5.4
   ss_dsi_panel_common.c:6546-6731) `finger_mask_updated` selects: backup of the normal level at
   ON, 2-TE wait before TX_BRIGHT_CTRL, panel brightness packets without dimming (S6E3FC3 panel
   file 0x20 vs 0x60/0x28), then `sysfs_notify(actual_mask_brightness)` and the flag is cleared.
6. Also in 5.4 but NOT ported: `sde_plane_get_csc_cfg()` skips the plane-CSC PCC for the FOD
   layer. That belongs to Lineage's PCC-through-SSPP-CSC feature, which r7 does not have: on 6.12
   PCC (night light) is DSPP-wide and also tints the UDFPS circle.

## What was ported (drivers612/display/techpack/display-drivers, patch `patches/0004-*.diff`)
All under `IS_ENABLED(CONFIG_DISPLAY_SAMSUNG)` (the `SAMSUNG=0` r7 build is unchanged).
| 6.12 file:line | what |
|---|---|
| `include/uapi/display/drm/sde_drm.h:562` | `FOD_PRESSED_LAYER_ZORDER` |
| `msm/msm_drv.h:157` | `PLANE_PROP_FOD` (last range property) |
| `msm/sde/sde_plane.c:4180,4187` | zpos range INT_MAX (as 5.4; stage limit still enforced by `_sde_crtc_check_zpos`), `fod` property |
| `msm/sde/sde_plane.c:4510-4526` | zpos bit -> `fod`, zpos stored without it |
| `msm/sde/sde_plane.c:3650`, `.h:385` | `sde_plane_is_fod_layer()` |
| `msm/dsi/dsi_panel.c:56,1225,1235-1266,3285`, `.h:163,387` | `fod_dim_lut`, `real_bl_level` (set in `dsi_panel_set_backlight`), `dsi_panel_get_fod_dim_alpha()` |
| `msm/sde/sde_crtc.h:598` | `fod_dim_layer` (pointer) + `fod_dim_layer_cfg` (own storage) |
| `msm/sde/sde_crtc.c:6226-6337` | `_sde_crtc_fod_get_display`, `sde_crtc_setup_fod_dim_layer`, `sde_crtc_fod_atomic_check`; called at 6370 before `_sde_crtc_check_zpos` |
| `msm/sde/sde_crtc.c:2029` | dim layer staged in the mixer |
| `msm/sde/sde_crtc.c:5192` | duplicate_state clears the pointer |
| `msm/sde/sde_connector.c:1049,1138-1183`, `.h:661` | finger mask on/off from the committed state |

Deliberate differences from 5.4:
- The finger_mask transition is decided in `sde_connector_pre_kickoff` from the crtc state being
  kicked off (`fod_dim_layer != NULL`), not in atomic_check: the SDM composer validates with
  TEST_ONLY commits, which must not touch panel state. Timing is the same as 5.4 (HBM DCS in the
  kickoff of the first frame with / without the dim layer). On S23 the consumer is in the same
  place: `finger_mask_updated = true -> ss_send_hbm_fingermask_image_tx() -> false` under
  `vrr_lock` (the S23 framework has no `dsi_display_pre_kickoff` consumer; its
  `ss_brightness_dcs` uses `finger_mask_updated` exactly like 5.4: backup at ON, 2-vsync wait in
  `ss_send_cmd`, panel no-dimming packets, `sysfs_notify`; only the clear moved to the caller).
- `SDE_CRTC_DIRTY_DIM_LAYERS` is set while the FOD dim layer exists and on the commit that drops
  it (5.4 relied on the composer setting the dim-layer property every frame); a removed dim layer
  cannot stay on the mixer.
- dim layer stage follows `SDE_FEATURE_BASE_LAYER` like `_sde_crtc_check_zpos` (yupik has no
  base layer: identical to 5.4); `real_bl_level` read with READ_ONCE instead of under panel_lock.
- The 5.4 log line repeated every frame; 6.12 prints it once per transition.

### Interaction with the IchthysOS property path and sysfs
`vdd->finger_mask` has two sources: FOD layer (level-triggered ON, as 5.4 re-armed after
`ss_panel_off_post` cleared the mask; edge-triggered OFF) and the `fingerprint_mask` connector
property (edges only, as before). Wanted = FOD layer OR property != 0; a transition happens only
on an edge (or FOD shown with the mask off) and only if wanted != current. So:
- property 1->0 while the FOD layer is shown keeps the mask; the FOD layer leaving while the
  property is 1 keeps it; when both are gone the mask goes off (cannot stick at HBM).
- level: property > 1 = that level, otherwise 331 (5.4's FOD level = ICHTHYS default). A mask
  already on keeps its level when the other source joins.
- `ss_finger_hbm_store` on 6.12 is S23's: it only stores `finger_mask_bl_level`, it never moves
  `finger_mask`, so there is no "mask already enabled" guard to block (that 5.4 guard was why
  IchthysOS 58af9aab removed the crtc pre-set). A HAL write of 0 during a FOD mask would lower
  ON_SUSTAIN to the normal level (the 8b3de7b3 max rule); LineageOS's HAL never writes it.
- IchthysOS ROM: its composer strips the bit (README), so the FOD path stays inert there.
- Panel off (`ss_panel_off_post`) clears `finger_mask`/`finger_mask_hbm_on`; the next kickoff
  without the layer is an OFF edge with the mask already off (no DCS).

## Expected dmesg on 6.12 (finger down, then up)
    [FINGER_MASK]updated finger mask mode 1 (fod layer 1, property 0)
    ss_send_hbm_fingermask_image_tx : ++ on
    ss_brightness_dcs : [FINGER_MASK]BACKLIGHT_FINGERMASK_ON turn on finger hbm & back up acl = .., level = <normal level>
    [sde error]finger_mask_updated/ sysfs_notify finger_mask_state = 1
    ss_send_hbm_fingermask_image_tx : --
    ... (finger up, UDFPS layer removed)
    [FINGER_MASK]updated finger mask mode 0 (fod layer 0, property 0)
    ss_send_hbm_fingermask_image_tx : ++ off
    ss_brightness_dcs : [FINGER_MASK]BACKLIGHT_FINGERMASK_OFF turn off finger hbm & restore acl = .., level = <normal level>
    [sde error]finger_mask_updated/ sysfs_notify finger_mask_state = 0
    ss_send_hbm_fingermask_image_tx : --
(5.4 shows the same ON/OFF lines; its `updated finger mask mode 1` repeats per frame.)
`cat /sys/class/lcd/panel/actual_mask_brightness` = 331 while the finger is down, 0 after.

## Build (done)
`cd drivers612/display && ./build.sh display-drivers` (bsp612/out/lahaina, clang r547379):
0 errors, 0 warnings (log identical to the pre-FOD build), Module.symvers identical (all export
CRCs), `--dump-modversions` imports identical, vermagic `6.12.81-4k-g8a69376da734`, depends
unchanged. Stripped (`llvm-strip --strip-debug`, as pack-kexec-rd.sh does):
`out-fod/msm_drm.ko` sha256 417d2232...a1cd4 (unstripped: `out-fod/msm_drm.unstripped.ko` =
`techpack/display-drivers/msm/msm_drm.ko`, 197c7c25...c8247). Previous (rb16/s76):
e7efa5bc... stripped.

## Test plan (key-free, phone 1 = LineageOS, muted)
msm_drm is a first-stage module: kexec ramdisks carry it as `a52/mods/display/18-msm_drm.ko`
(stage `display`, from `drivers612/androidboot/out/stage-display` + load.list with
`dsi_display0=... lcd_id=80000A`); real boots carry it in vendor_boot `/lib/modules` (first
stage, from REF ramdisk s76).
1. Swap only this module:
   `python3 -I drivers612/realboot/tools/rd-swap-ko.py drivers612/androidboot/out/s76-rd.cpio.gz drivers612/androidboot/out/s79-rd.cpio.gz drivers612/display/out-fod/msm_drm.ko`
   (pick the next free sNN; it refuses a vermagic mismatch).
2. Real-boot package: `REF=s79 DIAG=1 MODEM=1 SDCARD=1 drivers612/realboot/build-realboot.sh rb17`
   (= rb16 + new msm_drm in vendor_boot; no dtb/boot.img/add-on change), then rehearse key-free:
   `RB=drivers612/realboot/out/rb17 PHONE=1 drivers612/realboot/rehearse.sh 612 rh612p1fod`
   (kx line in out/rh-rh612p1fod/HOWTO.txt). Checks in the rehearsal: display up, boot_completed,
   `dmesg | grep -c 'failed to set fod prop'` = 0, no `plane stages assigned` / `Stage too large`
   errors, no `[FINGER_MASK]` line without a finger on the sensor.
3. Enrollment needs a screen lock: in the rehearsal (RAM /data) only with an explicit OK; the
   real test is rb17 flashed on phone 1 (hands-on session; rollback = /cache/a52rb-rollback rb16
   images), enroll a finger, then
   `adb shell dmesg | grep -E 'FINGER_MASK|fingermask_image_tx|Stage too large|fod'`
   and `cat /sys/class/lcd/panel/actual_mask_brightness` during/after a touch. Pass: the
   sequence above on every finger-down AND a `mode 0` / FINGERMASK_OFF on every lift (screen
   back to normal brightness), enrollment progresses. Fail signs: no `mode 1` (bit not reaching
   zpos: check the composer's zpos value), `mode 1` without `mode 0` (stuck HBM: report it).
4. 6.18: regenerate the port (`bsp618/port/build618.sh port drivers`) and repeat with REF a10.
