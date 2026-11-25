# Finger mask HBM stuck under OneUI 9 on 6.12 (2026-11-22)

Status: root cause found from source (offline), fix BUILT ONLY. Not loaded on any phone.
Module: `drivers612/display/out-fmask/msm_drm.ko` (stripped)
sha256 `783175739b570a277ec1c14b500648bf1374f1dac54c08bf15511a3046aef760`
(unstripped `out-fmask/msm_drm.unstripped.ko` deabab41...cb074a; `*.ko` is gitignored, the
files are local only; rebuild = `./build.sh display-drivers` + `llvm-strip --strip-debug`).
Patch record: `patches/0007-oneui-mask-brightness-stock-semantics-and-finger-mask-safety-net.diff`.

## Symptom (daily phone, OneUI 9 port on 6.12)
Evidence dir `/mnt/B1/OneUi9/scratch/k612_daily/brightness_stuck/`.
- every brightness write: `[FINGER_MASK]BACKLIGHT_NORMAL save backup_acl = 1, backup_level = <slider>, bl_level=331`
  (= `finger_mask_hbm_on` is set, normal brightness is only backed up), VRR switches re-send
  `BACKLIGHT_FINGERMASK_ON_SUSTAIN ... 0->331`, `cd (547)`; `actual_mask_brightness` = 331.
- NOT a fingerprint touch: `fingerprint.txt` has 0 enrolled prints, logcat has
  `isUdfpsEnrolled=false`, no BAuth / capture activity; `sf.txt` / `sf_hwc.txt` have no
  fingerprint / mask layer at all while stuck. What happened at ~984-987 s uptime
  (21:02:12-15) is the user opening the shade and auto brightness animating: that is only
  the first moment the frozen brightness became VISIBLE in the (rolled) dmesg, which starts
  at 990 s. The ON transition itself is not in the captures.
- `cat mask_brightness` -> EIO is normal: the attribute has no show() on 5.4 either
  (`DEVICE_ATTR(mask_brightness, ..., NULL, ss_finger_hbm_store)` in both trees).
- `fps_et7xx_work_func_debug` every 11 s is the driver's periodic debug work, not a session.

## 1. Stock flow (5.4, `~/git/kernel_a52sxq_bone/techpack/display`, OneUI userspace)
Who writes what:
- system_server, `SemUdfpsOpticalHelper` (services.jar, lambda `writeMaxBrightnessInfo`):
  writes `mMaxBrightness` (331 here, 319 fallback, never 0) to
  `/sys/class/lcd/panel/mask_brightness`. Posted to the helper's bg handler from
  FingerprintService `setBrightnessConfigs` (`FingerprintService$$ExternalSyntheticLambda1`,
  lambda case 3), i.e. ONCE AT BOOT: logcat `setBrightnessConfigs: node = 547` at
  20:46:11.000 = ~23 s uptime, no later call. These are the only two smali files in
  services.jar that name the node; no stock vendor blob does. It is CONFIGURATION ("the level to use for the mask"), not a request.
  5.4 `ss_finger_hbm_store` (ss_dsi_panel_sysfs.c:4548): only
  `vdd->br_info.common_br.finger_mask_bl_level = value`.
- SystemUI draws the mask view; SurfaceFlinger/HWC marks the frame; the stock composer
  (`vendor/lib64/libsdedrm.so`: "fingerprint_mask", "Setting Fingerprint mode %d";
  `libsdmcore.so`: "HWDeviceDRM: Setting Fingerprint Indisplay Layer property = %u") sets the
  CONNECTOR property `fingerprint_mask` = 1 on commits with the mask layer and 0 without.
  No plane property, no layer name, no zpos bit on stock.
- Kernel ON and OFF, both in the commit: `sde_connector_pre_kickoff` (sde_connector.c:904)
  compares the property with `vdd->finger_mask` on EVERY kickoff (level, not edge):
  different -> `finger_mask_updated = true; finger_mask = prop`; `dsi_display_pre_kickoff`
  (dsi_display.c:8632) -> `ss_send_hbm_fingermask_image_tx(vdd, finger_mask)` ->
  `ss_brightness_dcs(BACKLIGHT_FINGERMASK_ON / OFF)` (backup / restore of the normal level,
  2-TE wait, no-dimming packets) -> `sysfs_notify(actual_mask_brightness)` which the HAL polls.
  `sde_encoder.c:3524/3594` waits one more frame on OFF. Panel off clears the state.
So on stock: ON = first commit with property 1, OFF = first commit with property 0, and the
sysfs node never switches anything.

## 2. 6.12 port: what exists
| path | 6.12 state |
|---|---|
| `fingerprint_mask` connector property | registered (sde_connector.c), same name the stock composer looks up; ON/OFF on property EDGES (IchthysOS rule from 5.4 182cea7c) |
| LineageOS FOD (zpos bit 0x20000000 -> `fod` plane prop -> dim layer) | present (patch 0004); the stock composer never sets the bit, so inert under OneUI |
| `mask_brightness` store | patch 0005 (audit 11-18) gave it the IchthysOS meaning: ANY write > 0 = "switch the mask ON at the next kickoff", 0 = off (`vdd->ichthys_sysfs_mask_req`), with priority over property / FOD |
| `actual_mask_brightness` show + notify | identical to 5.4 |

## Root cause
The OneUI framework's one configuration write of 331 to `mask_brightness` is taken by the
6.12 store as an ON request. `sde_connector_pre_kickoff` applies it at the next kickoff
(`[FINGER_MASK] sysfs 331 -> mask 1`, then `BACKLIGHT_FINGERMASK_ON`). OFF never comes
because under OneUI nothing ever writes 0 to the node, and the property stays 0 (no edge;
the edge rule was put there precisely so a sysfs mask is not cancelled by a property that
sits at 0). The 5.4 kernel of the port has the stock store, hence no bug there.
LineageOS is unaffected (its HAL never writes the node), IchthysOS is the ROM the request
semantics were made for (its HAL writes level on press, 0 on release and at start).
Not proven by a log line (the ON lines rolled out of dmesg); to confirm on the stuck
kernel after a reboot: `dmesg | grep -E 'mask_bl_level value|FINGER_MASK\] sysfs'` soon
after boot should show `mask_bl_level value : 331` then `sysfs 331 -> mask 1`.
Timeline on the daily phone, consistent with this: the write is at ~23 s uptime and the
screen never went off between boot and the captures (logcat: a single `wakeUp` at 38 s, no
goToSleep), so the mask was on from the first kickoff after 23 s; "987 s" is when the
owner opened the shade and saw the slider do nothing (first lines of the rolled dmesg).
It released without a reboot between 1186 s and 1520 s (`dmesg_after_release.txt`:
`hbm:0`, `actual_mask_brightness value : 0` at 1527 s), most likely a screen off/on:
`ss_panel_off_post` clears `finger_mask` / `finger_mask_hbm_on`, and nothing re-writes the
node afterwards. So before the fix every OneUI boot on 6.12 runs at 547 nits until the
first screen off. Missing piece = an OFF while the screen stays on, which the stock flow
never needs because the stock store never turns the mask on.

## 3. Fix (in `techpack/display-drivers/msm`, all under CONFIG_DISPLAY_SAMSUNG)
Gated by what userspace does, not by ROM name.
1. `samsung/ss_dsi_panel_sysfs.c` `ss_finger_hbm_store`: a level write is an on/off REQUEST
   only after a 0 has been written to the node at least once since boot (static
   `ss_mask_sysfs_trigger_armed`). The IchthysOS HAL writes 0 at start
   (`hardware/samsung/aidl/fingerprint/LegacyHAL.cpp:138`) and on every release, so it arms
   the request path before its first press. The stock framework never writes 0, so its 331
   stays "level only" (stock 5.4 meaning; log:
   `[FINGER_MASK] mask_brightness 331 = level only (stock semantics, no 0 written yet)`).
   OneUI then turns the mask on and off through the property edges, as on 5.4.
2. Safety net, `sde/sde_connector.c` (`sde_connector_pre_kickoff` + helpers above it):
   - a mask lit by a sysfs request is bounded: `ICHTHYS_MASK_SYSFS_HOLD_MS` = 10 s after the
     last on-request, enforced by a delayed work (works on a static screen, no kickoff
     needed) -> `[FINGER_MASK] safety net: mask on with no holder (mask_brightness request
     timed out), forcing off`.
   - on every kickoff: mask on AND no FOD layer AND property 0 AND no live sysfs request for
     `ICHTHYS_MASK_ORPHAN_FRAMES` = 3 consecutive kickoffs -> forced off
     (`... (no fod layer, property 0, no live sysfs request)`). Catches every other way of
     ending up with an unheld mask.
   - forced off = the normal OFF path (`ss_send_hbm_fingermask_image_tx(vdd, 0)` under
     `vrr_lock`, `finger_mask_updated`): backup level restored, `actual_mask_brightness`
     notified, so a HAL polling it sees 0.
   - a FOD layer or non-zero property takes a sysfs-lit mask over (no time bound from then
     on, its own edge switches the mask off), so the timer never cuts a mask the composer
     holds.
   - panel off / unblank: unchanged, `ss_panel_off_post` already clears `finger_mask`,
     `finger_mask_hbm_on` and the pending request; after unblank the mask can only come back
     from a holder (FOD layer level-triggered, property edge, fresh sysfs request).
   - doze: no extra rule. A property / FOD-held mask in LP1 is legitimate (AOD unlock);
     an unheld one is dropped by the orphan rule on the next kickoff or by the timer.
   State is file-static (one optical-FP panel per device): no struct layout change.
Behaviour kept: LineageOS (FOD layer) unchanged. IchthysOS unchanged while its HAL behaves
(0 at start, level on press, 0 on release); new for it: a press held by sysfs alone for
> 10 s without a re-write is dropped (HAL died / lost the release), and a 331 written before
any 0 would be ignored (not its HAL's order).
Known limits: a composer that leaves the PROPERTY at 1 forever still holds the mask (that is
the stock contract; no timer on it, enrollment holds can be long). If some OneUI code path
does write 0 to the node, the request path arms and the old behaviour returns, but then the
10 s timer + orphan rule drop it (a 547 nit flash of at most 10 s instead of forever).

## Build / offline checks (done)
`./build.sh display-drivers`: 0 errors, 0 warnings, 0 modpost errors. `Module.symvers`
byte-identical (all export CRCs kept). Imports: one new, `mod_delayed_work_on` 0x92339a9b
= the GKI vmlinux CRC in `bsp612/out/lahaina/Module.symvers`; all others identical.
vermagic `6.12.81-4k-g8a69376da734`, depends unchanged.

## Test plan (broken screen = PHONE1; NO adb writes to /sys/class/lcd/panel/*)
Swap only msm_drm.ko into the OneUI ramdisk in use:
`python3 -I drivers612/realboot/tools/rd-swap-ko.py <ref-rd.cpio.gz> <new-rd.cpio.gz> drivers612/display/out-fmask/msm_drm.ko`
(refuses a vermagic mismatch), boot OneUI on it. Muted, no vibration tests.
A. No finger needed (this is the bug itself):
   1. after boot_completed: `dmesg | grep -E 'mask_bl_level value|FINGER_MASK'`
      expect `mask_bl_level value : 331` followed by `mask_brightness 331 = level only`,
      and NO `sysfs 331 -> mask 1`, NO `BACKLIGHT_FINGERMASK_ON`.
   2. `cat /sys/class/lcd/panel/actual_mask_brightness` (read only) = 0.
   3. move brightness (`cmd display set-brightness 0.2` / `0.8`, or the slider): dmesg shows
      normal `ss_brightness_dcs` lines with changing `bl_level`, no `[FINGER_MASK]BACKLIGHT_NORMAL save`.
   4. screen off/on, AOD on/off, 60/120 switch: still no `[FINGER_MASK]` lines.
   5. same boot on the UNFIXED module first (optional, proves the cause): step 1 shows
      `sysfs 331 -> mask 1` and step 3 shows the `save backup` lines.
B. Mask without a finger, through the HAL-visible path only: Settings > Security >
   Fingerprints > add (needs a screen lock: explicit OK). The enrol screen shows the sensor
   icon; SystemUI adds the mask view only on touch-down in the sensor rect, so a touch is
   needed: any object / knuckle on the sensor area lights the mask (no enrolled finger
   needed). Watch `dmesg -w | grep -E 'FINGER_MASK|fingermask_image_tx'` and
   `logcat | grep -E 'Fingerprint (mode|Indisplay)|SemUdfps|MaskView'`:
   down -> `[FINGER_MASK] property 1 -> mask 1`, `BACKLIGHT_FINGERMASK_ON`, notify 1;
   up -> `[FINGER_MASK] property 0 -> mask 0`, `BACKLIGHT_FINGERMASK_OFF ... restore`, notify 0;
   `actual_mask_brightness` 331 while down, 0 after. No `safety net` line in normal use.
   `dumpsys SurfaceFlinger --hwc` while held shows the mask layer (reference for sf_hwc.txt).
C. 5.4 reference on the same phone (planned for tomorrow): same steps, compare the ON/OFF
   line order and that 5.4 never logs a transition from the boot write.
D. Regression, LineageOS (white cable) and IchthysOS: FOD.md test plan unchanged; IchthysOS
   additionally `dmesg | grep 'mask_bl_level value'` must show the HAL's `0` before the
   first level write (arms the request path), then press / release as before.
Needs the user's finger: real enrollment + unlock under OneUI on 6.12 (capture quality at
547 nits, BAuth result), and a long press > 10 s on IchthysOS to see whether the 10 s
sysfs bound ever bites during enrollment (raise ICHTHYS_MASK_SYSFS_HOLD_MS if it does).

## Not done
- no phone test of any kind; root cause not confirmed by a kernel log line.
- 6.18 port (`bsp618/port/build618.sh port drivers`) not regenerated.
- USERSPACE-CONTRACT.md row for mask_brightness: one sentence added pointing here.
