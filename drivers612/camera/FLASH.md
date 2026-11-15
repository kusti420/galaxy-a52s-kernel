# Main flash does not fire: analysis and fix

Symptom (run ab-s74t, 6.12 kexec Android, phone 2 on USB): forced-flash photo in Aperture, the
pre-flash lights, the main flash is not seen. Torch (sysfs `rear_flash`, QS tile) works. No dmesg
was saved after the photo (`logs/ab-s74t-cycle.txt` ends at boot), so there is no runtime trace
of the failing shot. Everything below is offline (code, DT, CamX disassembly, older logs).

## 1. The path, and what is NOT the cause

The whole flash path is the 5.4 one, byte for byte where it matters:

| Piece | Evidence |
|---|---|
| `cam_flash_core.c`, `cam_flash_soc.c`, `cam_flash_dev.h`, `cam_sensor_cmn_header.h` | identical to `$ANDROID_TREE/kernel/samsung/sm7325/techpack/camera` (`diff` empty; only `cam_flash_dev.c` has the two mechanical probe/remove signature changes) |
| SM5714 hooks | `cam_flash_core.c:1971-1978` (SET_OPS parse: FIRELOW -> PREPARE + TORCH_FLASH(mA), FIREHIGH -> MAIN_FLASH(mA)); apply at the request's EOF: `:1219-1230` FIREHIGH -> `cam_flash_high` `:621-634` -> `MAIN_FLASH, FLED_MODE_FLASH<<12` -> `sm5714_fled_control(FLED_MODE_FLASH)` = EXTERNAL mode + FLASH_EN high. FIREDURATION is a no-op for SM5714 (`:1278`), as on 5.4 |
| Enums / CRC | `SM5714_FLED_MODE_*` and `FLED_MODE_*` equal in `camera/compat/linux/mfd/sm/sm5714/sm5714.h` and `power/include/...`; `sm5714_fled_mode_ctrl` CRC 0x0b363dd1 in both (the `flash_data`->`brightness` rename only renamed the parameter; `flash_data = brightness` keeps bits 15..12 = mode, 11..0 = mA, `leds-sm5714-fled.c:414+`) |
| DT | `sm5714@49/sm5714-fled`: flash-en TLMM 96 (0x60), torch-en TLMM 97 (0x61), flash 0xf / pre 0x7 / torch 0x7, timeout 0xff = r00/r01/r02 values; probe logs `gpio=608:609` (base 512). `qcom,camera-flash@0` -> flash 1400 mA / torch 300 mA as 5.4. GPIO 96 is not in `qcom,gpios-reserved`, no other consumer (only the unused `pri_mi2s_mclk` pinctrl group names it, also on 5.4) |
| Charger/MUIC side | `sm5714-private.h`/`sm5714.h` identical to 5.4; donor `sm5714_charger_oper.c` table = 5.4 table; `muic_check_fled_state` identical |
| CamX (`vendor/lib64/hw/camera.qcom.so`, symbols from `.gnu_debugdata`) | `Flash::FirePMIC` jump table @0x1bbea0: FlashOperation Main -> 0xa02e0c, writes opcode **3 = FIREHIGH** (0xa02e98). So the HAL asks for a real main flash, which this kernel turns into GPIO 96 |

**"Query current failed" is a red herring.** `CAMERA_SENSOR_FLASH_CMD_TYPE_QUERYCURR`
(`cam_flash_core.c:2069-2093`) calls `qti_flash_led_prepare(fctrl->switch_trigger)`; the flash
node has no `switch-source` (`cam_flash_soc.c:84`, same in `downstream-dt/a52sxq-r02.dts:1458`),
so the trigger is NULL and leds-qti-flash returns -EINVAL. 5.4 has the same DT, the same
`CONFIG_LEDS_QTI_FLASH=y` and the same NULL check (`drivers/leds/leds-qti-flash.c:1070`), so the
5.4 phone fails this query too. CamX ignores the result: `Flash::ExecuteProcessRequest`
0x9ff690-0x9ff6b0 = `if (!flashType) QueryCurrent(); Fire(Main)` with no check of the return
value (on success it would only publish the current as a property). In run ab618-a6d the HAL
went straight on to the pre-flash packet 70 us after the error (`logs/ab618-a6d-dmesg-end.txt:2642-2649`).

## 2. Causes, ranked

1. **(Most likely kernel-side; fixed) the flash boost is dropped before the main flash fires.**
   Samsung's driver arms the charger's FLASH boost event when the camera *parses* the FIREHIGH
   packet (`sm5714_fled_flash_on`, `leds-sm5714-fled.c:277-300`, called from
   `cam_flash_core.c:1977`) and drops it in OFF (`:226-235`), which runs when an *earlier* request
   is *applied* at EOF (`cam_flash_off` of the pre-flash). Whenever the FIREHIGH of the shot is
   parsed before the pre-flash OFF is applied, that OFF clears `en_fled` and the FLASH event the
   FIREHIGH had just armed; the flash then fires (FLASH_EN high) with the charger in
   CHG_ON_VBUS instead of FLASH_BOOST (5.1 V). The 225 mA pre-flash/torch runs fine without the
   boost on VBUS (table row VBUS+torch = CHG_ON_VBUS); a 1.4 A flash does not. The second leg is
   a hole in Samsung's op-mode table: VBUS + flash + torch (status 0x26) has no row
   (`sm5714_charger_oper.c`, both 5.4 and donor), so if FIREHIGH is parsed while the pre-flash
   torch event is still held and a cable is attached, `change_op_table()` returns -EINVAL
   ("can't find matched charger op_mode table (status = 0x26)") and the FLASH bit is lost
   (`:192`). Every test so far ran with the USB cable attached; normal 5.4 use is mostly on
   battery. The ordering depends on how far ahead CamX parses requests; the CRM "workq schedule
   delay ~40 ms" warnings on 6.x (`logs/ab618-a6d-dmesg-end.txt`, ab-s47) make late EOF applies,
   and so this ordering, more likely than on 5.4 (those numbers cluster at one frame period, so
   part of them may be a timestamp race in `cam_req_mgr_workq.c` rather than real latency).
   Not proven: needs the test in section 4.
2. **(Real, fixed; 6.x-specific part) GPIO ownership in `sm5714_fled_control`.** 5.4 requested
   one pin per call and freed both in OFF. A multi-frame pre-flash calls TORCH every frame: from
   frame 2 `gpio_request(97)` fails -EBUSY (already ours), the driver falls back to I2C torch
   mode and clears `used_gpio_ctrl`, so the pre-flash OFF neither lowers nor frees TORCH_EN (left
   high and owned). OFF also frees the pin that was never requested; on 5.4 `gpiod_free()`
   ignored that (`gpiolib.c:2819-2827`), on 6.12 it still does `module_put()` +
   `gpio_device_put()` (`bsp612/kernel/drivers/gpio/gpiolib.c:2441-2448`): a TLMM refcount
   underflow on every torch-off. Neither blocks the main flash by itself (the FLASH path drives
   TORCH_EN low after FLASH_EN high), but it puts the chip through I2C/EXTERNAL mode flips in
   the middle of the flash sequence.
3. **Not a port bug at all.** Nothing in the kernel path differs from 5.4; whether a forced-flash
   Aperture shot fires the main flash on stock 5.4 LineageOS was never checked. CameraX
   (camera-pipe) has no flash quirk for SM-A528B (checked the quirk device lists), so the HAL
   gets a normal AE_MODE_ON_ALWAYS_FLASH capture.

## 3. Fix (applied; built; NOT run on a phone)

`drivers612/power/src/leds54/leds-sm5714-fled.c` (leds-sm5714-fled.ko):
- `fled_arm_event()` (`:394`): at the moment of firing (MAIN_FLASH/PRE_FLASH with the mode bits,
  i.e. `cam_flash_high`/`cam_flash_low`) re-arm the FLASH/TORCH boost event if an earlier OFF
  dropped it. No-op in the order the 5.4 code expected.
- `fled_gpio_claim()/fled_gpio_release()` (`:120-156`): both pins claimed together on first use,
  held while lit, levels only set on repeated calls, released together by OFF/remove. No -EBUSY
  fallback during a pre-flash, no free of an unrequested GPIO.
- `sm5714_fled_mode_ctrl()` now holds `fled_mutex` around every `sm5714_fled_control()` call
  (5.4 called it unlocked from the CRM apply thread while the ioctl thread changed the same
  counters under the mutex).
- One log line per fire, `sm5714-fled: fire: FLEDCNTL1=.. FLEDCNTL2=.. CHG_CNTL2=.. (op N)
  fen= men= ...` (`fled_log_fire`, `:158`): op 8 = FLASH_BOOST, 5 = CHG_ON_VBUS.

`drivers612/power/src/battery/charger/sm5714_charger/sm5714_charger_oper.c` (sm5714-charger.ko):
row VBUS + flash + torch -> FLASH_BOOST, 5.1 V (`:108`), same as VBUS + flash.

camera.ko unchanged (QUERYCURR left as on 5.4). Built with `drivers612/power/build.sh`
(bsp612/out/lahaina, clang r547379): 0 warnings, `Module.symvers` identical to before (all CRCs
unchanged, `sm5714_fled_mode_ctrl` 0x0b363dd1), vermagic 6.12.81-4k-g8a69376da734. New import of
the fled module: `sm5714_read_reg` (mfd_sm5714, stage powerpd, loaded before stage camera).

## 4. What has to be rebuilt / repacked (not done here)

- 6.12 test ramdisk: strip and swap the two modules into the current REF
  (`llvm-strip --strip-debug` copies of `drivers612/power/src/leds54/leds-sm5714-fled.ko` and
  `drivers612/power/sm5714-charger.ko`, then
  `python3 -I drivers612/realboot/tools/rd-swap-ko.py drivers612/androidboot/out/s76-rd.cpio.gz
  drivers612/androidboot/out/s78-rd.cpio.gz <both .ko>`; fled sits in stage camera, the charger
  in powerpd).
- Real boot: `REF=s78 ... drivers612/realboot/build-realboot.sh rbNN` (both modules are first
  stage = vendor_boot; no dtb, boot.img or vendor add-on change).
- 6.18: `bsp618/port/build618.sh port drivers` (regenerates bsp618/src/drivers612/power and
  builds), then the same swap into the 6.18 REF (a10) and `KERNEL=618 build-realboot.sh`.

Test (key-free, kexec or rehearsal; phone muted; in the dark, Aperture, flash forced ON, one shot):

    adb shell dmesg | grep -E 'sm5714-fled|change_op_table|can.t find matched|CAM-FLASH'

Read: `fire: ... (op 8)` = flash fired with the boost; `boost event armed at fire time` = cause 1
happened; a FIREHIGH without any `Flash mode` line = the apply never came (CRM/CamX side, then look
at `cam_flash_pmic_apply_setting`); then repeat once on battery (adb over Wi-Fi) and once on stock
5.4 for the baseline (cause 3).
