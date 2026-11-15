# sec_thermistor: why 6.12 reads different ADC values than 5.4

Code-only investigation, 2026-11-13. No phone was touched and nothing was built.

## Result in one paragraph

The software chain is the same on both kernels: the DT, the sec_thermistor read, the ADC7
register programming and the uV scaling. The 6.12 numbers are lower because the ADC really
measures a lower ratio at the pins. They are not mis-scaled. Decoded (ratiometric, 0x4000 = pull-up
voltage, 100 kOhm internal pull-up), the pins show:

| channel | 5.4 code | 5.4 R_ntc | 6.12 code | 6.12 R_ntc | 6.12 as a 100k/B4250 NTC |
|---|---|---|---|---|---|
| ap 0x146 (PM7325 AMUX_THM3_100K_PU, own pin) | 7892 | 92.9 k | 5337 | 48.3 k | 41.0 C |
| pa 0x148 (AMUX_THM5_100K_PU, pin shared with PM7325 gpio1) | 7936 | 93.9 k | 2075 | 14.5 k | 71.7 C |
| wf 0x14c (ADC7_GPIO3_100K_PU = PM7325 gpio4) | 7887 | 92.8 k | 2280 | 16.2 k | 68.7 C |

(code = temp_adc_uV x 0x70e4 / 1 875 000. All six values come out as exact integers, so both kernels
use the same HW_CALIB_DEFAULT formula with full_scale_code_volt 0x70e4.) Samsung's tables are a
plain 100k NTC (B about 4250) on the 100k pull-up. So sec_thermistor converts correctly on 6.12.
The pins really do see 48 k, 14.5 k and 16 k. **No file, function or constant in the ADC or
thermistor path differs. The cause is the analog state of the board under 6.12. Code review
alone cannot settle it.** Two candidates remain (next section). Only one of them is a software fix.

## Candidates (ranked) and how to tell them apart

1. **pa/wf: PM7325 gpio1/gpio4 are not high-Z while the 6.12 kernel runs (medium confidence).**
   Stock wiring (`downstream-dt/a52sxq-r02.dts` 163-197, 651): sec_thermistor@2 (pa, 0x148) takes
   `gpio1_adc_default`, sec_thermistor@1 (wf, 0x14c) takes `gpio4_adc_default`, the battery takes
   `bat_thm_default` (gpio3, ADC 0x14b) + `chg_thm_default` (gpio2, ADC 0x14a). All four are
   `function = "normal"; bias-high-impedance;`, which sets the GPIO master enable to 0
   (`pinctrl-spmi-gpio.c` `pmic_gpio_config_set`: 5.4 line 459/501/623, soc-repo 6.12 line 482/525/657,
   identical apart from whitespace and the strength mapping). On 6.12 only the two pins whose pinctrl is
   applied by sec-battery (gpio2/3) read correctly. The two applied by sec_thermistor (gpio1/4) read
   about 70 C. A parallel load of 17-20 k to ground at 27 C would give exactly these values.
   The pinctrl states ARE in every 6.12 tree that was used (`boarddt/out/build/merged-r02.dtb`,
   `out-ack/kx/android-r02.dtb`, `full-r02-hw3.dtb`, `logs/kx-ab-s36-*/kexec.dtb`: pinctrl-0 present,
   nodes present, pm7325_gpios is `qcom,pm7325-gpio` and the shipped `pinctrl-spmi-gpio.ko` is
   soc-repo's). So this can only be true if sec_thermistor's "default" state was not applied
   in that run. Note: every 6.12 dmesg in `logs/`, including `kx-ab-s34-p2-213521` (the run
   that gave the numbers), shows
   `sec_thermistor: Unknown symbol devm_hwmon_device_register_with_groups` at boot, so
   sec_thermistor did not bind during boot. If it was insmodded later by hand after hwmon.ko and
   bound, the driver core applied the pinctrl at probe, before the first read. That weakens
   this candidate. It stays first because it is the only one with a software fix and it costs
   one debugfs read to rule out.
   Check (read-only, 6.12):
   `cat /sys/kernel/debug/pinctrl/*pm7325*8800*/pinconf-pins | grep -E 'gpio(1|2|3|4):'`
   gpio1 and gpio4 should show disabled/high-Z like gpio2/gpio3. Or read the registers: PM7325
   (SID 1) GPIO n block at 0x8800 + (n-1)*0x100, EN_CTL is offset 0x46. It should be 0x00 for n=1..4.
2. **The board really is hotter under 6.12 (medium confidence for ap; possible for pa/wf).**
   The 6.12 runs boot via kexec with `clk_ignore_unused pd_ignore_unused regulator_ignore_unused`,
   no cpufreq ("Failed cpufreq policy"), and tsens skipped (`a52.skip=qcom_tsens` is still on the
   s34 command line, so that run had no SoC temperature to cross-check). For reference: phone 1
   under 6.12 with tsens read CPU 34-35 C with only the ramdisk running. With full Android up,
   41 C at the AP is plausible. The AP thermistor
   (own pin, nothing to mis-configure) at 41 C is easy to believe under those conditions. pa/wf sit at
   the RF PA and the WCN6750, whose rails may be left on without their firmware running.
   Check: (a) feel the top of the phone. A 70 C spot cannot be missed. (b) read the adc_tm zones
   that use the same kind of channel (`/sys/class/thermal/*` types quiet-therm-usr,
   camera-therm-usr, rear-cam-therm-usr, xo-therm-usr = PM7325 THM1/2/4 and PMK8350 THM1, 100k PU,
   ratiometric). If xo/quiet are also about 40 C, the heat is real. (c) load qcom_tsens and compare
   the CPU sensors with ap.
   Extra A/B for both candidates: set `qcom,hw-settle-time = <1000>` (or 4000) on pa_therm only. A
   clear rise in temp_adc points to a slow or loaded node (candidate 1). No change points to a real
   resistance (candidate 2).

Also make sure the 5.4 and 6.12 numbers come from the same phone. The 6.12 runs in logs/ are
on PHONE2 (cmdline serialno). Its board revision is 4 (`androidboot.revision=4`) and it
has older bit-2 firmware.

## The fix

- **If check 1 finds gpio1/gpio4 enabled (DT change, high confidence that it fixes pa/wf in that
  case, and harmless otherwise):** apply the four thermistor pin states from the pin controller
  itself, so they no longer depend on sec_thermistor/sec-battery binding. In
  `drivers612/power/a52sxq-power.dtsi`, in the existing `&pm7325_gpios { }` block:
  ```dts
  	pinctrl-names = "default";
  	pinctrl-0 = <&gpio1_adc_default &chg_thm_default &bat_thm_default &gpio4_adc_default>;
  ```
  The consumer nodes keep their own pinctrl-0. Applying the same state twice does nothing.
  The pins end up exactly as on stock 5.4 once its drivers have probed. Also load `hwmon.ko`
  before `sec_thermistor.ko`, or sec_thermistor never binds.
- **If check 2 shows real heat:** sec_thermistor and the ADC are right. The fix belongs to power
  management (rails and clocks left on by `*_ignore_unused`, RF/WLAN power state, cpufreq), not
  to this driver.
- Neither the ADC driver nor sec_thermistor needs a patch. Changing scale-fn-type or the tables
  would hide the symptom.

## What was compared (all equal unless noted)

5.4 source: `$ANDROID_TREE/kernel/samsung/sm7325` (the phone's 5.4.254 tree). 6.12:
`bsp612/soc-repo` (the shipped `out/dist/.../qcom-spmi-adc5.ko`, `qcom-vadc-common.ko` and
`pinctrl-spmi-gpio.ko` are soc-repo builds: they contain `qcom,scale-fn-type`,
`qcom,spmi-adc7-sw-calib`, `Failed to restore pin`). GKI has `CONFIG_QCOM_SPMI_ADC5` off, so
upstream's driver (which ignores scale-fn-type) is not involved.

1. **sec_thermistor**: `drivers/hwmon/sec_thermistor/sec_thermistor.c` (5.4) vs
   `drivers612/power/src/sec_thermistor/sec_thermistor.c`: identical except strscpy and remove()
   returning void. `sec_therm_get_adc_data()` (line 113 in both) calls
   `iio_read_channel_processed()` because the DT has `use_iio_processed`. No Samsung scaling.
   Binary search plus linear interpolation over adc_array/temp_array is the same.
2. **ADC7 path**:
   - DT parsing: 5.4 `qcom-spmi-adc5.c` 1194-1199 vs 6.12 1108-1116. Both read
     `qcom,scale-fn-type`, `qcom,ratiometric` -> `ADC5_RATIOMETRIC_CAL`, `cal_val = ADC5_TIMER_CAL`
     (5.4 1209 / 6.12 1123), `hw-settle-time` 200 us -> index 2 of hw_settle_2, decimation default
     index 2 (1360), avg 1 sample. Virtual channel = sid<<8 | ch in both. The 100K_PU choice is the
     channel number (0x46/0x48/0x4c = THM3/THM5/GPIO3 _100K_PU, `dt-bindings/iio/qcom,spmi-vadc.h`
     268-277). The table defaults for those channels are the same in both (5.4 1027-1040, 6.12 937-950).
   - `adc7_data_pmic`: 5.4 line 1231, 6.12 line 1147: `full_scale_code_volt = 0x70e4`,
     decimation {85,340,1360}, the same hw_settle_2 table. 6.12 adds only `full_scale_code_raw` (unused here).
   - `adc7_configure` (5.4 401, 6.12 335) and `adc7_do_conversion`: the same register sequence
     (APP_SID, DIG_PARAM/FAST_AVG/CH_SEL/HW_SETTLE, CONV_REQ, wait for EOC, STATUS1 check, DATA0/1).
   - Processed read: 5.4 `adc7_read_raw` 705 vs 6.12 `adc_read_raw_common` 643 ->
     `qcom_adc5_hw_scale()` (5.4 `qcom-vadc-common.c` 1443, 6.12 1560) ->
     `qcom_vadc_scale_hw_calib_volt` -> `qcom_vadc_scale_code_voltage_factor` (5.4 892, 6.12 929):
     code x 1875 mV x 1000 / 0x70e4 x prescale. The prescale tables are the same, index 0 = 1/1.
   - Enum: `SCALE_HW_CALIB_DEFAULT` = 5 in both (5.4 `drivers/iio/adc/qcom-vadc-common.h` 225, 6.12
     `soc-repo/include/linux/iio/adc/qcom-vadc-common.h` 215). Values 8-19 ARE reordered in
     6.12 (e.g. 5.4 16 = THERM_100K_PU_PM7, 6.12 8 = THERM_100K_PU_PM7), but every scale-fn-type in
     the used trees is 5, so this does no harm. Do not copy a 5.4 scale-fn-type number > 7 without
     translating it.
   - `RATIO_MAX_ADC7` 0x4000, `R_PU_100K` 100000, `ADC_VDD_REF` 1875000: the same.
   - SW-calib (`qcom,spmi-adc7-sw-calib`) is not used: both trees say `qcom,spmi-adc7`.
3. **Other users of these channels or pins in the 6.12 base**:
   `bsp612/devicetree/qcom/yupik-pmic-overlay.dtsi` 114-119 adds `pm7325_sdm_skin_therm` at
   `PM7325_ADC7_AMUX_THM3_100K_PU` (= 0x146) with no scale-fn-type, and 148-153 an adc_tm monitor on
   the same channel. If that file were ever in the tree, `adc7_fwnode_xlate` (6.12 627, first match
   wins) would hand that node to ap_therm, and `SCALE_HW_CALIB_THERM_100K_PU_PM7` would return
   millidegrees. The readings show this is NOT happening: the yupik.dtb we use has no PMIC overlay.
   `boarddt/a52sxq-pmic.dtsi` provides the stock vadc node, and `a52sxq-bsp612-fixups.dtsi` 129
   deletes the adc_tm child. The vadc child list in the kexec dtb is the same as stock r02. The 6.12
   adc_tm (`qcom,spmi-adc-tm5-gen2`, monitors 0x144/0x145/0x147/0x44) only writes its own peripheral
   at 0x3400. Nothing else in the merged tree uses PM7325 gpio1-4 (only gpio6, volume key).
   The kexec harness DT (`logs/kx-ab-s36-*/harness-live.dtb`) does not configure them either.

## Not found / limits

- Samsung's 5.4 board DT exists only as decompiled dtbo entries (`downstream-dt/`, = ROM kernel
  `arch/arm64/boot/dts/samsung/a52/a52sxq/*.dts`). There is no Samsung source dtsi for the
  thermistor nodes. Values were checked against those files.
- No log in `logs/` contains the quoted readings. The s34 dmesg ends with sec_thermistor
  failing to load at boot, so the later manual load and its probe messages are not on disk.
- That PM7325 AMUX_THM5 shares a pin with gpio1 is an inference from Samsung pairing
  `gpio1_adc_default` with pa_therm. No PM7325 pinout was available to confirm it.

## Hardware result (main session, 2026-11-13 21:5x, run ab-s37)
Root cause found on the phone: binding sec_thermistor logs
`spmi spmi-0: disallowed SPMI write to sid=1, addr=0x8840` (PM7325 gpio1, pa) and `addr=0x8B40`
(gpio4, wf) -> "Error applying setting, reverse things back". The PMIC arbiter does not let the
apps EE configure those two GPIO peripherals (owned by another EE, presumably the modem/RF
side). In test runs the modem is off, so nothing puts the pins into analog/high-Z mode and
pa/wf read low resistance (71/69 C). ap (AMUX_THM3, no GPIO) 41 C may be real heat: tsens was
skipped (a52.skip=qcom_tsens, now removed from the Android cmdline) and cpufreq/unused
clocks were not managed. Driver and scaling are fine; re-check pa/wf once the modem runs.

## Test T1 (modem on/off), prepared 2026-11-14, NOT run yet

Question: does the modem (the EE that owns PM7325 gpio1/gpio4) put the pa/wf pins into their
analog/high-Z state when it boots? Phone 1 (PHONE1), kernel only, its own modem (the M1
flow of `drivers612/modem/README.md`), plus read-only sampling. No sec_thermistor, no
sec-battery, so nothing on the apps side tries to configure gpio1..4. Nothing writes a GPIO or
any other PMIC register; the only SPMI writes are the VADC driver's own conversion requests on
PMK8350 0x3100, the same as every sec_thermistor read.

Code: `drivers612/modem/kpack/therm.sh` (sourced by m1.sh when the argument `therm` is
given), `drivers612/modem/stages/therm/targets.txt` (qcom-spmi-adc5.ko + qcom-vadc-common.ko;
not in the bsp612 first stage; IIO is built in, hwmon not needed). Built into
`drivers612/modem/out/pack-modem.tgz` by `drivers612/modem/build.sh`.

Run (owner):

    M1_ARGS="100 therm" drivers612/modem/run-m1.sh m1t-p1

Samples (each one is an `ADC` line, four `GPIO` lines, four `PIN` lines):
`early#1` (ADC just loaded, before the dsp stage), `pre#1..3` (just before
`/dev/subsys_modem` is opened), `up#1..3` (after the 20 s QRTR listing, i.e. ~28-32 s after
"is now up"), `obs20..obs100` (every 20 s of the observe window; the DOG stall/recovery falls
at ~obs60), `ssr#1` (15 s after the deliberate SSR), `off#1` (3 s after the vote is released,
modem offline), `off10#1` (10 s later).

What to grep:

    L=$(ls -d logs/kx-m1t-p1-* | tail -1)
    grep -E "^T1 (ADC|iio|regmap|table|GPIO id)|T1 FAIL" $L/kexeced-extra.txt
    grep -E "^T1 GPIO" $L/kexeced-extra.txt | grep -E " g(1|4) "
    grep -E "is now up|crash #|a52sxq-init: modem: T1" $L/kexeced-dmesg-after.txt

Line format:

    T1 ADC  pre#1 t=<uptime> ap=<uV>/<R_ntc>k/<C> pa=<uV>/<R>k/<C> wf=<uV>/<R>k/<C> chg=<uV>/<R>k bat=<uV>/<R>k quiet=<mC> xo=<mC> die=<mC>
    T1 GPIO pre#1 g1 rt=<RT_STS 0x10> m40..4a=[MODE VIN PULL DIG_IN OUT_SRC DIG_OUT EN 47 48 49 ANA_PASS] en=<EN_CTL 0x46>
    T1 PIN  pre#1 0 (gpio1): ---            (pinconf-groups: "---" = master enable off)

Conversion (done on the phone, the same as sec_thermistor): `<uV>` is
`in_temp_<label>_input` of the VADC (= `iio_read_channel_processed`, the value sec_thermistor
calls temp_adc). The temperature is sec_thermistor's binary search + linear interpolation over the
node's own `adc_array` (uV, ascending) / `temp_array` (0.1 C, 90.0 .. -20.0 C) from
`/sys/firmware/devicetree/base/samsung_mobile_device/sec_thermistor@{0,2,1}` (ap, pa, wf),
with C integer division. By hand: find adc[i] < uV < adc[i+1], then
`T = temp[i] + (temp[i+1] - temp[i]) * (uV - adc[i]) / (adc[i+1] - adc[i])` (0.1 C). Examples
with the pa table: 512000 -> 27.6 C, 134623 -> 71.0 C. `R_ntc` = `100 k * code / (16384 - code)`,
`code = uV * 0x70e4 / 1875000` (ratiometric, 100 k pull-up; valid for every 100k_PU channel, so
chg/bat can be compared without their tables; ~90 k = room temperature). quiet/xo/die are the
driver's own millidegree scaling (independent reference for the real board temperature).
GPIO registers (PM7325 SID 1, gpio N at 0x8800 + (N-1)*0x100): EN_CTL bit 7 = master enable;
stock DT state for all four thermistor pins ("normal", bias-high-impedance) is EN_CTL = 0x00.
LV/MV subtypes (printed once as `GPIO id gN type/subtype`, type 0x10, subtype 0x10/0x11..):
MODE_CTL bits 1:0 = 0 input, 1 output, 2 in/out, 3 analog pass-through.

First run kx-m1t-p1-p1-182150 (2026-11-14 18:21): every value that went through awk was empty
(ap/pa/wf/chg/bat, tables "0 points", GPIO registers) because the bsp612 ramdisk links only a
subset of busybox applets into /bin and awk/od/paste are not among them ("awk: not found" in
kexeced-extra.txt). The sysfs paths were right (iio:device0 = vadc@3100, quiet/xo/die read,
regmap/0-01 with address/data found). PIN lines were empty because pinctrl-spmi-gpio only
implements the group dbg_show (pinconf-groups, not pinconf-pins). Fixed in therm.sh (busybox
wrappers, pinconf-groups, a one-time `T1 ls ...` inventory of the iio/regmap/pinctrl/DT
directories with the first sample, label-substring fallback for the ADC attributes); rerun with
the same command.

Reading the result:
- **Confirms:** `pre` (and `early`) show pa ~134 k uV / wf ~148 k uV (R ~15 k, ~70 C) and
  `up`/`obs` show pa/wf at 450-560 k uV (R ~75-105 k, 22-32 C, close to ap minus a few degrees and
  close to quiet/xo), together with a change of g1/g4's registers (EN_CTL 0x80 -> 0x00, or MODE_CTL
  -> analog) while g2/g3 do not change. Then the 6.12 fix is "the modem must run" (it does on a real
  boot); nothing to change in the ADC or sec_thermistor. Whether `off`/`off10` go back to the bad
  value tells whether the modem undoes it at shutdown (cosmetic for a real boot).
- **Refutes (as far as M1 can):** pa/wf and the g1/g4 registers identical in all phases. Caveat:
  without rmt_storage the M1 modem stalls in initialisation (DOG at ~65 s after up) and may never
  reach the point where it sets up RF/thermal GPIOs, so "unchanged" is strong evidence only if the
  modem got as far as on 5.4; the decisive repeat is M2 (modem with RMTFS, Android). An unchanged
  result with g1/g4 already EN_CTL 0x00 points away from the pins (candidate 2: real heat, or a
  board load on that net).
- **Phone check:** the 6.12 readings above came from phone 2 (PHONE2). If phone 1 already
  reads ~27 C for pa/wf in `pre`, the bad value is phone-2-specific (its pins or its firmware
  set, see the 2026-11-13 incident) and the modem hypothesis does not apply to phone 1.
- chg/bat (gpio2/gpio3, apps-writable, NOT configured in this run because sec-battery is not
  loaded): if they also read low (~15-20 k) in `pre`, the pin's reset state alone loads the node,
  which supports the mechanism; if they read ~90 k with the same register values as g1/g4, the
  register state is not the difference.

## Result of T1 (2026-11-14 18:35, run kx-m1t2-p1-p1-182948) and conclusion
- 6.12 kernel-only on phone 1: pa 142k uV (15.5 kOhm, 69.5 C) / wf 146k (69.0 C) in EVERY phase (pre, modem up,
  DOG stall, SSR, off); PM7325 GPIO1/GPIO4 registers identical throughout: MODE 0x00 (digital in), PULL_CTL 0x04
  (10 uA pull-down), EN_CTL 0x80. ap 75.6k (32 C) and bat 85k are right; chg 16k is wrong in the same way.
- Same phones on 5.4: phone 2 LineageOS (modem refused by TZ since 2026-11-13): pa 132871 -> 71.4 C, wf 144679
  -> 69.3 C, i.e. the SAME wrong values as 6.12. Phone 1 One UI (modem fully running): pa 458044 -> 32.4 C,
  wf 454476 -> 32.9 C, correct.
- Conclusion: not a 6.12 bug. The pins belong to the modem's EE; they read correctly only once the modem is
  fully up (the M1 modem never gets past init without rmt_storage). Fix = a real boot with a working modem
  (M2 / A1). Until then keep sec_thermistor pa/wf out of thermal decisions in test runs.
