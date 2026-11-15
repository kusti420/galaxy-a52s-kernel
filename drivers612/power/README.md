# drivers612/power — charging, battery, USB-C detection for a52sxq on the 6.12 BSP

State 2026-11-11: **all 22 modules compile and link (modpost clean, no unresolved symbols)
against `bsp612/out/lahaina`. Nothing has ever been loaded on a phone.**

## What is here

| Path | What |
|---|---|
| `src/` | driver sources (donor copies + fixes), built out of tree |
| `include/` | Samsung headers the drivers need (donor copies, three stubs) |
| `Kbuild`, `build.sh` | the build (`./build.sh`, ~1 min; `./build.sh PDIC=0 DIRECT=0` is not supported, see below) |
| `a52sxq-power.dtsi` | device-tree fragment for the 6.12 base, GENERATED from the phone's tree |
| `DT-VALUES.md` | every safety-critical value in decimal with its source line, GENERATED |
| `dt-extract/` | `extract.py` (verbatim node extraction), `gen-dtsi.py`, `gen-values.py`, `verify-dtsi.py` (fragment vs r02.dts / live trees), `propcheck.py` (which phone DT properties the port reads) |
| `patches/` | every change made to donor code, as diffs against the donors |
| `STATUS.md` | progress log |

### Modules and where each comes from

| Module (.ko) | Source | Donor |
|---|---|---|
| `sb-core` | `src/battery/core` | physwizz 6.12 (PHYS), unchanged |
| `sec-battery` | `src/battery/common` | PHYS; 1 include fix |
| `sec_pd` | `src/battery/common/sec_pd.c` | PHYS, unchanged |
| `sec-direct-charger` | `src/battery/common/{sec_direct_charger,sb_pass_through}.c` | PHYS, unchanged |
| `mfd_sm5714` | `src/mfd/sm/sm5714` | PHYS, unchanged |
| `sm5714_fuelgauge` | `src/battery/fuelgauge/sm5714_fuelgauge` | PHYS, unchanged |
| `sm5714-charger` | `src/battery/charger/sm5714_charger` | PHYS, unchanged |
| `common_muic` | `src/muic/common` | PHYS; `__setup()` block disabled (module) |
| `muic_sm5714` | `src/muic/sm/sm5714` | PHYS, unchanged |
| `pdic_notifier_module`, `usb_typec_manager`, `if_cb_manager` | `src/usb/typec/{common,manager}` | PHYS, unchanged |
| `pdic_sm5714` | `src/usb/typec/sm/sm5714` | PHYS; one `defined()` -> `IS_ENABLED()` (BC1.2 off while sourcing, as on 5.4) |
| `usb_notify_layer` | `src/usb/notify` (core) | PHYS, unchanged |
| `usb_notifier` | `src/usb/notify/usb_notifier.c` | Galaxy S26 6.12 (Qualcomm flavour); reverse-bypass hooks dropped |
| `a52sxq_usb_glue` | `src/glue` | NEW: implements `dwc_msm_vbus_event/id_event` etc. on an extcon device |
| `vbus_notifier`, `switch_class` | `src/vbus_notifier`, `src/switch` | S26 6.12, unchanged |
| `pca9468_charger` | `src/battery/charger/pca9468_charger` | crDroid sm8550 5.15 (v3.4.24S); probe/remove signatures |
| `s2mpb03` | `src/regulator/s2mpb03` | PHYS, unchanged |
| `leds-sm5714-fled` | `src/leds54` | the phone's 5.4 driver; remove() signature + drvdata, settings from the MFD child node, `sm5714_fled_mode_ctrl` parameter named `brightness` (gendwarfksyms CRC = the camera stub's) |
| `sec_thermistor` | `src/sec_thermistor` | the phone's 5.4 driver (three thermistor nodes); strscpy, remove() |

Options follow the phone's 5.4 defconfig (`lineage-a52sxq_defconfig`): AFC, MUIC_HV,
BCD_RESCAN, HICCUP_CHARGER, water detection, SBU, factory mode, step charging, direct
charging, USB_HW_PARAM, PDIC_PD30 off. Tristate options are passed as `CONFIG_x_MODULE`
(what the donor ran with on its MediaTek GKI target). The MUIC needs the PDIC notifier
(`CONFIG_MUIC_SUPPORT_PDIC=y` on 5.4), so the "small first set without PDIC" from
`samsung612/PLAN.md` does not compile; everything is built together.

The binding header `include/dt-bindings/battery/sec-battery.h` is the **phone's 5.4 copy**,
so the cable-type and enum numbers compiled into the drivers are the ones the phone's DT
values were written with. The donor compiled against it without needing newer constants.

## Build

    cd drivers612/power && ./build.sh        # PDIC=1 DIRECT=1 are the defaults

Uses clang r547379, `O=bsp612/out/lahaina` (read only), `KBUILD_EXTRA_SYMBOLS` =
`samsung612/modules/sec_core/Module.symvers` + `bsp612/soc-repo-staging/build/Module.symvers`.
Objects land next to the sources. Symbol check done: every undefined symbol of every `.ko`
resolves to vmlinux, a BSP module, `sec_core`, or one of these modules.

## Load order (dependencies computed from the symbol tables)

Needed first from the BSP: `i2c-msm-geni`, the SPMI/PMIC stack with `qcom-spmi-adc5` +
`qcom-vadc-common`, `pinctrl-spmi-gpio`, `debug-regulator` (for `s2mpb03`), and
`samsung612/modules/sec_core/sec_core.ko`. `dwc3-msm` may load before or after
`a52sxq_usb_glue` (it defers until the extcon in its `extcon` property exists).

    sec_core  a52sxq_usb_glue  if_cb_manager  switch_class  usb_notify_layer  vbus_notifier
    sb-core  sec_pd  sec_thermistor  s2mpb03
    common_muic  pdic_notifier_module  usb_typec_manager
    mfd_sm5714  muic_sm5714
    sec-battery &        <- IN THE BACKGROUND: its probe waits up to 20 s for the next four
    sm5714_fuelgauge  sm5714-charger  pca9468_charger  sec-direct-charger
    usb_notifier  pdic_sm5714  leds-sm5714-fled

`sec-battery` exports symbols the fuel gauge and chargers need, so it must be inserted before
them, and its probe then blocks in `sec_chg_check_modprobe()` until FG, main charger, PCA9468
and sec-direct-charger have announced themselves (20 s timeout, then it carries on).

## Device tree

`a52sxq-power.dtsi` carries: `samsung_mobile_device/{wireless-power-info, cable-info,
sec-direct-charger, sec_thermistor@0/1/2, sm5714-fuelgauge (+battery_params), battery,
sm5714-charger}`, `usb-notifier`, the five PMK8350 VADC channels, the PM7325 GPIO and TLMM
interrupt pin states, `s2mpb03_pmic@56` (SE0), `sm5714@49`, `pca9468@57`, `sm5714-fled`
(SE3), `usbpd-sm5714@33` + `pdic-manager` (SE8).

How it was made: nodes are cut verbatim out of `downstream-dt/a52sxq-r02.dts` by line range;
the only edits are dropped `phandle` lines and numeric phandles replaced by labels.
`dt-extract/verify-dtsi.py` confirms 456 property lines are identical to r02.dts **and to the
live trees of both bench phones** (hw rev 3 `testdev-PHONE1/live.dts`, hw rev 4
`testdev-PHONE2/live.dtb`); the 19 remaining lines are the label substitutions and the
additions below. Samsung's r02 overlay covers hw_rev 2..0x20, so rev 3 and rev 4 share it.
dtc accepts the fragment with stub labels (not yet compiled into the real 6.12 a52sxq tree).

Additions that are not on 5.4 (all marked in the file):
- `a52sxq-usb-extcon` node and `&usb0 { extcon = <&eud>, <&a52sxq_usb_extcon>; }`.
- `battery,health_condition_cycle/_asoc` (the donor's new names for `battery,health_condition`).
- aliases `i2c21` (SE3) and `i2c23` (SE8): the ROM's sepolicy names
  `/devices/platform/soc/98c000.i2c/i2c-21/21-0049/` etc.; 5.4 got 21/23 from probe order.
  This shifts other buses: coordinate with the other fragments.
- Node order on SE3 is `sm5714@49`, `pca9468@57`, `sm5714-fled` as in the live tree. The fled
  node has the same `reg = <0x49>` as the MFD; whichever comes first gets the i2c client
  (5.4 log: `i2c-21: Failed to register i2c client sm5714-fled at 0x49 (-16)`, harmless).
  On 6.12 the fled node came first anyway and took 0x49 (no fuel gauge/charger, Android shut
  down "battery"), so the I2C-level `sm5714-fled` is emitted `status = "disabled"`, and its
  settings are emitted again as a child `sm5714@49/sm5714-fled` WITHOUT reg/compatible/status
  (a data node; nothing binds to it). The device is the MFD cell `sm5714-fled` created by
  `mfd_sm5714`; `leds-sm5714-fled` reads `<parent of_node>/sm5714-fled` first and falls back
  to the 5.4 lookup by name (2026-11-14).

Prerequisites: the a52sxq board file must include `pmk8350.dtsi`/`pm7325.dtsi` (labels
`pmk8350_vadc`, `pm7325_gpios`; the plain `yupik.dtb` has no PMIC nodes) and must NOT carry
Qualcomm's `pm7325_sdm_skin_therm` channel (0x146 is the phone's `ap_therm`). Keep
`maximum-speed = "high-speed"` on dwc3 (the phone's port is USB 2.0; the base says super-speed).

### Qualcomm-side glue, resolved by reading the BSP

- **ADC**: PMK8350 VADC is `qcom,spmi-adc7` in `soc-repo/drivers/iio/adc/qcom-spmi-adc5.c`
  (`CONFIG_QCOM_SPMI_ADC5=m`; adc5-gen3 is off and not for this PMIC). It still parses
  `label`, `qcom,pre-scaling`, `qcom,hw-settle-time`, `qcom,ratiometric`, `qcom,scale-fn-type`.
  The phone's `qcom,scale-fn-type = <5>` is `SCALE_HW_CALIB_DEFAULT` in both kernels (enum
  entries 0..7 identical, later ones reordered), so channels return microvolts and the
  Samsung tables (microvolts -> 0.1 degC) apply unchanged. Consumers: `sec_adc.c`
  (`adc-temp`, `adc-chg-temp` by name, `iio_read_channel_processed`) and `sec_thermistor`
  (`use_iio_processed`).
- **dwc3-msm**: `soc-repo/drivers/usb/dwc3/dwc3-msm-core.c` exports none of Samsung's hooks.
  It accepts (a) extcon devices listed in `extcon` (EXTCON_USB = peripheral, EXTCON_USB_HOST
  = host; several allowed, a name containing "eud" is treated as the EUD) and (b) a USB role
  switch (`usb-role-switch`). `a52sxq_usb_glue` uses (a): it registers an extcon device and
  exports `dwc_msm_vbus_event()`, `dwc_msm_id_event()`, `is_dwc3_msm_probe_done()`,
  `dwc3_max_speed_setting()`, `gadget_speed()` (always 0) for the S26 `usb_notifier.c`.
  dwc3-msm stays unmodified. State: `cat /sys/devices/platform/soc/soc:a52sxq-usb-extcon/state`.
- **Regulators**: none of these chips has a supply property in the phone's DT (always-on
  rails). S2MPB03 registers 7 LDOs, min == max as on the phone (table in DT-VALUES.md).
- **I2C/pinctrl**: SE0 (TLMM 0/1), SE3 (12/13), SE8 (32/33); the bus pin states of the 6.12
  base equal the phone's. Interrupts: SM5714 TLMM 54, USB-PD TLMM 140.

## Userspace contract (checked against the 5.4 driver and the ROM tree)

Kept, by construction or by check:
- Supplies: `battery`, `usb`, `ac`, `wireless`, `pogo`, `otg`, `sm5714-charger`,
  `sm5714-fuelgauge`, `sm5714-otg`, `pca9468-charger`, `sec-direct-charger` (same names).
- `/sys/class/power_supply/battery/*`: all 5.4 attributes still exist (`diff` of the
  `SEC_BATTERY_ATTR` lists: nothing removed; `batt_full_capacity` moved to `sb_full_soc.c`;
  the port adds 15). Used by the ROM/blobs: `capacity status temp current_now voltage_now
  siop_level chg_temp usb_temp blkt_temp dchg_temp sub_bat_temp gps batt_slate_mode
  wc_tx_en wc_tx_stop_capacity lcd`.
- Device path `/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/...`
  (sepolicy + thermal HAL hold `siop_level` by this path): kept, the node stays under
  `/samsung_mobile_device`.
- `/sys/class/sec/switch/afc_disable` (init.qcom.rc), `/sys/class/sec/ccic`,
  `/sys/class/sec/sec-{ap,pa,wf}-thermistor`: created through `sec_core`.
- `/sys/class/usb_notify/usb_control/{usb_data_enabled,cards,...}`: identical attribute set.
- `/sys/class/typec/port0/{data_role,power_role,port_type}` (USB HAL): `CONFIG_TYPEC=y` in
  the BSP, the SM5714 typec driver registers the port.
- Module parameter names the bootloader passes: `sec-battery.*`, `sm5714_charger.factory_mode`,
  `sm5714_fuelgauge.factory_mode` match the module names here.

Changed / not verified:
- `sec_mparam.pmic_info/charging_mode/pd_disable` and plain `pmic_info=`, `ccic_info=`,
  `afc_disable=` are no longer parsed (built as modules, `sec_mparam`/`sec_param` not
  ported): AFC-disable set in the bootloader menu and `sec_set_param()` persistence of
  `afc_disable` are lost; defaults apply (AFC on, PD on).
- `/sys/class/power_supply/battery/system_temp_level` does not exist on 5.4 either.
- `/sys/class/switch/uart3/state`: the switch class is built; not checked who reads it.
- uevent contents (`POWER_SUPPLY_*`) not compared on a device.
- `battery_last_dcvs()` (reset-reason statistics) and `sec_debug` hooks are stubs.

## SAFETY

Lithium cell, 4,500 mAh, 4.38 V float. Read this before leaving a phone charging on this
kernel.

### If the drivers never load (or crash)

Observed in the test phone's bootloader log (`testdev-PHONE1/last_kmsg-rd5.txt`, XBL,
USB cable attached), the bootloader programs the SM5714 itself before the kernel starts:
float voltage **4380 mV** (`sm5714_CHG_set_BATREG ... 0x67`), input limit **500 mA**, charge
current **500 mA**, topoff code 0x0A, charging enabled, charger watchdog **off**. With no
driver the chip keeps those values: constant-current/constant-voltage to 4.38 V and its own
topoff termination are done in hardware. What is missing without the driver: all
temperature protection (JEITA zones, 50 degC stop: the NTCs are read by the SoC ADC, not by
the charger chip), the safety timer, recharge logic, input current raise for chargers, OTG,
and the fuel-gauge alerts. PCA9468 direct charging never starts by itself (it needs the
driver and a PPS contract). Only the USB case was observed; what the bootloader programs
with an AFC/PD charger is not known.
So: 500 mA into a room-temperature phone on the desk is hardware-safe; an unattended
charge in the cold (<0 degC) or heat is not.

### Checks with a USB power meter before any unattended charge

1. Driver not loaded: meter shows <= 0.5 A at 5 V, current falls to ~0 near full.
2. After loading, `cat /sys/class/power_supply/battery/{temp,chg_temp}`: plausible room
   values (200..350 = 20..35 degC) and they move when the phone is warmed by hand. A wrong
   ADC scale makes every temperature limit meaningless: do this first.
3. `voltage_now` against a multimeter on a known state, and `capacity` against the value
   Android showed before the test (fuel gauge tables: `battery0,*`).
4. USB SDP port: <= 0.5 A (table: 475 mA input). 5 V/2 A charger: <= 1.8 A. AFC 9 V
   charger: 9 V and <= 1.65 A. Then full charge once while watching: charging must stop
   (`status` Full) with the cell <= 4.38 V; float never above 4.40 V on the meter-derived or
   `voltage_now` reading.
5. `echo 1 > batt_slate_mode`: input current drops to ~0 (the ROM's charge-control node).
6. Warm/cool behaviour cannot be bench-tested safely; compare the limits the driver prints
   at probe (`sec_bat_parse_dt`, `wire_*_thresh`) with DT-VALUES.md instead.
7. Direct charging (25 W PPS, PCA9468): only after 1-6. Expected <= 2.55 A input at ~9-10 V
   (`pca9468,input-current-limit` 2,550,000 uA, `charging-current` 6,000,000 uA,
   `ta-max-vol` 10.5 V; steps 4900/3960/3650 mA at 4055/4220/4380 mV). The ported PCA9468
   driver is a newer version (3.4.24S vs 3.4.16S) from a 5.15 tree and does not read
   `pca9468,ta-mode`: watch the first run on the meter the whole time, stop on any input
   above 2.6 A or cell above 4.40 V. To keep it off: do not load `pca9468_charger.ko`
   (then `sec-battery` waits 20 s at probe and `sec-direct-charger` has no direct charger;
   that path has not been tried) — or use a non-PPS charger.

## First on-device test (busybox shell in the test ramdisk; modules in /extra)

    cd /extra
    for m in sec_core a52sxq_usb_glue if_cb_manager switch_class usb_notify_layer \
             vbus_notifier sb-core sec_pd sec_thermistor s2mpb03 common_muic \
             pdic_notifier_module usb_typec_manager mfd_sm5714 muic_sm5714; do
        insmod $m.ko || echo "FAILED $m"; done
    insmod sec-battery.ko &
    for m in sm5714_fuelgauge sm5714-charger pca9468_charger sec-direct-charger; do
        insmod $m.ko || echo "FAILED $m"; done
    wait
    for m in usb_notifier pdic_sm5714 leds-sm5714-fled; do insmod $m.ko || echo "FAILED $m"; done
    dmesg | grep -i -E "sm5714|sec_bat|sec-battery|pca9468|muic|pdic|thermistor|s2mpb03|usb_notify|a52sxq usb glue"
    cat /sys/class/power_supply/*/uevent
    cat /sys/class/power_supply/battery/temp /sys/class/power_supply/battery/chg_temp
    cat /sys/devices/platform/soc/soc:a52sxq-usb-extcon/state

For a first, lower-risk pass leave out `pca9468_charger` and `sec-direct-charger`
(and expect the 20 s wait). The test ramdisk's USB network runs over the same port: loading
`usb_notifier` + `pdic_sm5714` hands role control to the Samsung stack and may drop the
telnet session once; run the block from a script with output to a file.

Expected lines (from the same phone on 5.4, same functions in the port):

    sec-thermistor samsung_mobile_device:sec_thermistor@0: sec-ap-thermistor successfully probed.
    s2mpb03:s2mpb03_pmic_probe
    sm5714 21-0049: sm5714_i2c_probe start
    sm5714:sm5714_i2c_probe v_id=0x1, rev=0x1
    sm5714_fuelgauge_probe: SM5714 Fuelgauge Driver[...] Loaded
    sm5714-charger sm5714-charger: sm5714_charger_probe: read sm5714 option bits [0x93,0x10,0x9E,0x80]
    sm5714-charger sm5714-charger: sm5714_charger_probe: probe done[...]
    pca9468_hw_init: pca9468_revision=0
    pca9468_charger_probe: PCA9468 Charger Driver Loaded
    i2c i2c-21: Failed to register i2c client sm5714-fled at 0x49 (-16)        <- normal
    sec_direct_charger_probe: SEC Direct-Charger Driver Loaded(sm5714-charger, pca9468-charger)
    [muic-sm5714:sm5714_muic_probe] AFC mode enabled
    sec-battery samsung_mobile_device:battery: sec_battery_probe: SEC Battery Driver Loading
    usb_notify: registered otg_notify -
    a52sxq-usb-glue soc:a52sxq-usb-extcon: a52sxq usb glue: extcon registered

`cat /sys/class/power_supply/*/uevent` must list `battery` with `POWER_SUPPLY_CAPACITY`
close to the pre-test Android value, `POWER_SUPPLY_TEMP` 200..350,
`POWER_SUPPLY_VOLTAGE_NOW` 3.4..4.4 V (in uV), and with USB attached `usb` ONLINE=1.

Likely failure modes:
- `sm5714_i2c_probe` never prints: SE3 not enabled / wrong pinctrl / `i2c-msm-geni` not
  loaded; check `ls /sys/bus/i2c/devices/` for `21-0049`.
- `sec_bat_get_value_by_adc ... adc read fail` or temp = -200/900: VADC channel missing
  (PMIC dtsi not included, or `pm7325_sdm_skin_therm` clash) or `qcom-spmi-adc5` not loaded.
- `sec_chg_check_modprobe: dev_init timeout(0x..)`: one of FG/charger/PCA9468/direct charger
  did not probe; the mask says which.
- No USB after `usb_notifier`: dwc3-msm did not get the extcon (`extcon` property not
  updated, or the glue loaded after dwc3-msm gave up); check the `state` file and
  `/sys/class/extcon/`.
- `sec_device_create` failures: `sec_core` not loaded.
- Kernel CFI panic in a notifier callback: these Samsung notifier chains pass through
  function pointers with casts; kCFI is on in the GKI. Not compile-detectable.
