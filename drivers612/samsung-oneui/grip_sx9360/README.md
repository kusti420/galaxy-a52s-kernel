# grip_sx9360: Samsung SX9360 grip (SAR proximity) sensor for the a52sxq 6.12 line

OFFLINE port, never loaded on a phone. Closes the grip gap of the OneUI 9 port on 6.12
(`drivers612/ONEUI9-PARITY.md` lines 35-38, 57, 307; `PARITY-2026-11-18.md` item 10 / line 118, P1):
no `/sys/class/sensors/grip_sensor` (SEMTECH / SX9360), no input devices `grip_sensor` + `grip_notifier`,
`SensorsGrip` gets ENOENT on `/sys/class/sensor_event/symlink/grip_sensor`, the HAL list loses
`SX9360_Grip_sensor`. Mainline's IIO `sx9360` is not the ABI the HAL wants; this is Samsung's own
5.4 driver with its input-device + sensors-class ABI.

## Files

| file | what |
|---|---|
| `sx9360.c`, `sx9360_reg.h` | 5.4 `drivers/sensors/sx9360.c` / `_reg.h` (`$ANDROID_TREE/kernel/samsung/sm7325`), ported (list below) |
| `sensors_glue612.h` | the 5.4 sensors_core API (`sensors_register`, `sensors_create_symlink`, ...) on top of adsp_factory's classes |
| `Kbuild` | `sx9360.ko`; 5.4 config switches: PDIC + Type-C manager notifier, MUIC, flip-cover path (`GRIP_PDIC=0` drops the notifier) |
| `extra-usb_typec_manager.symvers` | CRCs of `usb_typec_manager.ko` (rbich45 first stage) via `ko2symvers.py` |
| `i2c-gpio/` | `i2c-gpio.c` + `i2c-algo-bit.c` copied verbatim from `bsp612/kernel` (6.12.81): `CONFIG_I2C_GPIO`/`ALGOBIT` are `=m` in `out/lahaina/.config` but were never built into `bsp612/out/dist` (GKI: not set) |
| `grip.dtsi` | DT fragment (5.4 values, 6.12 labels) |
| `qemu-test/` | QEMU smoke: `run.sh`, `init.sh`, `grip-test.dtsi`, `sxfake/` (test-only adapter + SX9360 register file, never shipped) |

## Build

    cd ./
    G=drivers612/samsung-oneui/grip_sx9360
    python3 drivers612/samsung-oneui/ko2symvers.py $G/extra-usb_typec_manager.symvers \
        drivers612/realboot/out/rbich45/work/plan/first/usb_typec_manager.ko
    EXTRA_SYMVERS="$PWD/$G/extra-usb_typec_manager.symvers" drivers612/samsung-oneui/build.sh $G
    drivers612/samsung-oneui/build.sh $G/i2c-gpio

Outputs (stripped debug + BTF, vermagic `6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64`):

| module | bytes | sha256 (16) | depends |
|---|---|---|---|
| `out/sx9360.ko` | 101968 | c617ba8530f83d4e (full: c617ba8530f83d4e563df31266569c47e809e7e0dd818df01e65b757ba323b56; 2026-11-24, + `grip_stats`; before: 96360 / 78e6732e84c48d92) | usb_typec_manager |
| `i2c-gpio/out/i2c-algo-bit.ko` | 21704 | 2b9cc77a6a047144 | - |
| `i2c-gpio/out/i2c-gpio.ko` | 18144 | 7395d3f0cc43c1b0 | i2c-algo-bit |

## Load position (first stage)

In `drivers612/realboot/out/rbich45/work/plan/first.load`, right after `adsp_factory_dlkm.ko` (line 179):

    adsp_factory_dlkm.ko
    i2c-algo-bit.ko
    i2c-gpio.ko
    sx9360.ko

`usb_typec_manager.ko` (its only hard dependency) is line 166. `drivers612/realboot/tools/loadsim.py` on the
rbich45 first stage + these three: 272 ok, 0 FAIL. First stage, not the vendor add-on: the OneUI init.rc
`on boot` chowns `/sys/class/sensors/grip_sensor/*`, so the node must exist before `boot`.
The order is not load-critical: if the device probes before `/sys/class/sensors` exists, probe returns
-EPROBE_DEFER and creates nothing; any later driver bind retries it (QEMU-tested). Module init always returns 0.

## ABI (identical to 5.4)

| node | content |
|---|---|
| `/sys/devices/virtual/sensors/grip_sensor` (= `/sys/class/sensors/grip_sensor`) | device in adsp_factory's `sensors` class, 31 attributes: `name` SX9360, `vendor` SEMTECH, `onoff`, `mode`, `raw_data`, `diff_avg`, `useful_avg`, `normal_threshold`, `avg_negfilt`, `avg_posfilt`, `avg_thresh`, `rawfilt`, `sampling_freq`, `scan_period`, `gain`, `range`, `analog_gain`, `phase`, `hysteresis`, `irq_count`, `resolution`, `adc_filt`, `useful_filt`, `motion`, `unknown_state`, `noti_enable`, `menual_calibrate`, `register_write`, `register_read`, `readback`, `reset` |
| input `grip_sensor` (`BUS_I2C`) | `EV_REL`: `REL_MISC` 1 = grip (ACTIVE) / 2 = release, `REL_X` unknown mode (1 on / 2 off); sysfs group `enable` (`/sys/class/input/inputN/enable`) |
| input `grip_notifier` | `EV_REL REL_X` = event type (1 USB, 2 hall, 3 boot, 4 force, 5 cover) when entering unknown mode with `noti_enable` = 1 |
| `/sys/class/sensor_event/symlink/grip_sensor` | link to the `grip_sensor` input device (HAL path) |
| wakeup source | `grip_wake_lock` (3 s per interrupt) |
| IRQ | `sx9360_irq`, TLMM gpio7 falling edge, threaded (`request_threaded_irq(NULL, thread, ONESHOT)`), wake-enabled while enabled |

HAL (`vendor/lib64/sensors.grip.so`, strings): `/sys/class/input/` + `%s%s%d/name` scan for `grip_sensor` /
`grip_notifier`, `/dev/input/`, `/sys/class/sensor_event/symlink/`, `/sys/class/sensors/grip_sensor/` +
`motion`, `noti_enable`, `enable`, `grip_register_recover`, `/country_code`, `/sys/class/sensors/sensor_dev/flush`,
hall paths. `grip_register_recover` and `country_code` do not exist in the 5.4 driver either (HAL logs
"Register Recover Fail" / "Country Code Write Fail" and goes on, same as 5.4). OneUI init.rc line 665 writes
`grip_request_firmware` (absent on 5.4 too).

### How the class is reached (`sensors_glue612.h`)

On 6.12 `/sys/class/sensors` and `/sys/class/sensor_event` are created by `adsp_factory_dlkm.ko`
(`drivers612/sensors-factory/sensors_core.c`), which exports none of the sensors_core functions (its
Module.symvers: only ois_reset_* and sensordump_*). A second `class_create("sensors")` fails with -EEXIST (or,
loaded first, breaks adsp_factory). So the driver looks the existing objects up through kernfs with public
structures only: `kernel_kobj->sd->parent` (= /sys) -> `class/sensors/sensor_dev` (created by sensors_core init,
always present) -> symlink target -> `struct device` -> `dev->class`; and `class/sensor_event/symlink` -> the
symlink device. Both are `get_device()`-pinned while the driver is bound; the class name is checked. The grip
device is `device_create()`d into that class, so it lands at the same path as on 5.4. No change to
sensors-factory is needed. Cleaner alternative for the sensors-factory owner: export `sensors_register`,
`sensors_unregister`, `sensors_create_symlink`, `sensors_remove_symlink` from adsp_factory_dlkm and drop the glue.

## Port changes vs 5.4

- `#include <linux/sensor/sensors_core.h>` -> `sensors_glue612.h` (above); `sensors_unregister` also removes
  the device (5.4 leaked it).
- probe(client) / void remove (6.3 / 6.1 i2c API); `of_get_named_gpio_flags` -> `of_get_named_gpio`.
- Hall IC poll: 5.4 called `filep->f_op->read` under `set_fs(KERNEL_DS)`; sysfs on 6.12 has no `->read`
  (NULL call) and no set_fs -> `kernel_read()`. A missing hall node is logged once, not every 2 s.
- WHOAMI: 5.4 built this file as `CONFIG_SENSORS_SX9364=y` (WHO_AM_I 100) while DT/HAL say SX9360 (96);
  both are accepted (same register map, logged which).
- Singleton guard (the ABI names and class refs are global): a second instance gets -EBUSY before touching
  anything. Probe defers (-EPROBE_DEFER, nothing created) until adsp_factory's classes exist.
- `grip_en` (gpio104): freed on probe failure / remove (5.4 leaked it); not driven if the request fails.
- Remove also unregisters `grip_notifier`, the Type-C manager notifier and the reset work (5.4 leaked them).
- 5.4 error path dereferenced `data->input` (still NULL) when the input sysfs group failed: fixed.
- `normal_threshold` printed with %lu for u32 (clang -Werror): %u, same text.
- `MODULE_DEVICE_TABLE(of/i2c)` added (5.4 was built in); module init never fails.
- Unchanged: register setup, calibration, unknown-mode logic, debug/zero-detect work, suspend/resume,
  shutdown, Type-C attach -> recalibration (`manager_notifier_register(MANAGER_NOTIFY_PDIC_SENSORHUB)`).
- No regulators: VDD is GPIO 104 only; no voltage is touched anywhere.
- 2026-11-24 diagnostics, no behaviour change: read-only `/sys/bus/i2c/devices/19-0028/grip_stats` (driver
  `dev_groups`, on the i2c device, NOT in the sensors class, so the HAL ABI above is untouched; show() does no I2C
  traffic). Counters: interrupts by IRQSTAT cause (touch / release / compdone / status 0), `nirq_high` (edge with
  nIRQ already high), calibrations by trigger (mode, sysfs, reset node, USB attach, hall, hall cert), Type-C ATTACH
  notifications acted on / duplicate, suspend() calls and pending interrupts it cleared unprocessed, enable count
  and total enabled seconds, last 40 events (boottime s, kind, IRQSTAT, STAT, diff). Reason and the capture:
  `drivers612/SPEC/06-grip-irq-rate.md`, `capture-grip.sh`. QEMU: `qemu-test/run.sh` PASS, 36 checks.
- `grip-eur-tuning.dtsi`: OPTIONAL, not applied: Samsung's EUR threshold/hysteresis values (ours are KOR, as on
  both 5.4 kernels). A separate decision.

## DT (`grip.dtsi`)

5.4 `/soc/i2c@17` (i2c-gpio, cell-index 0x11, SDA gpio8, SCL gpio9, delay 2 us) + `sx9360-i2c@28` (nIRQ
gpio7, `vdd_en` gpio104, setup registers 0x32/0x38/0x36/0x1a/0x22/0x22/0x15/0x0c/0x0f/0x0f) + pinctrl
`grip_i2c_active` / `grip_int_active` (gpio, 2 mA, bias-disable), on `&soc` / `&tlmm`.
`drivers612/boarddt/a52sxq-sensors.dtsi` + `a52sxq-pinctrl.dtsi` already have the identical node, and
the rbich45 `vendor_boot.dtb` contains it (alias `i2c19 = /soc/i2c@17` -> bus `i2c-19`, client `19-0028`);
it never bound only because no driver existed. Check (scratch):

    printf '/dts-v1/;\n/plugin/;\n/include/ "grip.dtsi"\n' > ov.dts; dtc -@ -I dts -O dtb -o ov.dtbo ov.dts
    fdtoverlay -i drivers612/realboot/out/rbich45/vendor_boot.dtb -o m.dtb ov.dtbo
    diff <(dtc -I dtb -O dts rbich45 vendor_boot.dtb) <(dtc -I dtb -O dts m.dtb)

Result: applies, phandles unchanged, only `#address-cells = <1>; #size-cells = <0>;` added to i2c@17
(Samsung's misspelt `address-cells`/`size-cells` kept; child `reg` is read as one u32 either way).
Pins 7/8/9/104 are not in `qcom,gpios-reserved`, used by no other node; gpio7 is not in
`wakeup-disabled-gpios` (wakes through the PDC). The other users of these pins' QUP functions
(`qupv3_se1_spi` spi@984000, `qupv3_se2_i2c` / `qupv3_se2_spi` @988000) are `status = "disabled"` in rbich45.

## SELinux / init (OneUI vendor + system, read from MonsterROM work_dir)

Same paths as 5.4, so the existing policy applies unchanged:
- `genfscon sysfs /devices/virtual/sensors/grip_sensor` -> `sysfs_sensor_writable` (vendor_sepolicy.cil:655;
  hal_sensors_default rw, radio r, system_server rw); `/class/sensors` -> `vendor_sysfs_sensors` (795);
  vendor_file_contexts:765 `/sys/class/sensors(/.*)?` -> sysfs_sensor_writable.
- input + sensor_event nodes: default `sysfs` (hal_sensors_default rw on sysfs, cil:5978); `/dev/input/event*`
  generic input labels. No grip lines in vendor ueventd.rc.
- wakeup dir `/sys/devices/platform/soc/soc:i2c@17/i2c-19/19-0028/wakeup` matches vendor_file_contexts:1208
  (sysfs_wakeup; the known 6.x wakeup genfscon denials in POLISH.md apply).
- chown: system `init.rc` 2708-2780 (`on boot`): `chown system radio /sys/class/sensors/grip_sensor/<attr>`;
  LineageOS: `init.vendor.sensors.rc:219-223` (PARITY-2026-11-18.md).

## Offline results

- Builds against bsp612 with modversions; loadsim 272/272 with the rbich45 first stage.
- `qemu-test/run.sh` (bsp612 dist Image, QEMU virt; real first-stage notifier modules + real
  `adsp_factory_dlkm.ko`): PASS, 35 checks: load/rmmod with no device; i2c-gpio binds an a52sxq-shaped node
  (legacy `gpios`, misspelt cells) and instantiates sx9360@28; probe defers before the class, creates nothing;
  after adsp_factory the no-chip probe fails cleanly (-ENXIO from the bus -> unwinds inputs, symlink,
  gpios); against sxfake: grip_sensor in adsp_factory's class (name SX9360, vendor SEMTECH, 34 entries),
  symlink, both input devices, threaded IRQ, WHOAMI, r02 setup registers written, enable 1/0 through the
  input `enable`, debug work (hall miss logged once), second instance refused, rmmod removes everything
  with `sensor_dev` intact, second probe round OK, adapter removal, 0 WARN/BUG/oops/duplicate-sysfs.

  Not covered offline: real I2C timing on gpio8/9, the chip's interrupt, Type-C notifier events, suspend.

## On-phone checks (READ-ONLY; hands-on session, nothing here is run yet)

Do NOT write any grip node (enable, onoff, motion, noti_enable, unknown_state, register_write, irq_count,
menual_calibrate) - they change SAR/RF behaviour. Do NOT read `reset` (its show() recalibrates the chip)
and never `cat grip_sensor/*`. No vibration involved.

    lsmod | grep -E '^(sx9360|i2c_gpio|i2c_algo_bit) '
    dmesg | grep -E '\[GRIP\]|i2c-gpio|sx9360'           # "whoami 0x.. (SX936x)", "Probe done!"
    readlink /sys/bus/i2c/devices/19-0028/driver          # .../SX9360
    ls -lZ /sys/class/sensors/grip_sensor/                # owners system:radio after boot, sysfs_sensor_writable
    for a in name vendor mode onoff normal_threshold motion noti_enable unknown_state; do
        echo "$a=$(cat /sys/class/sensors/grip_sensor/$a)"; done
    readlink /sys/class/sensor_event/symlink/grip_sensor; cat /sys/class/sensor_event/symlink/grip_sensor/name
    grep -B1 -A5 grip_ /proc/bus/input/devices
    grep sx9360 /proc/interrupts; ps -A | grep sx9360    # irq/NN-sx9360_irq thread
    dumpsys sensorservice | grep -i grip                  # expect SX9360_Grip_sensor in the list
    dmesg | grep avc | grep -iE 'grip|sensors'            # expect none
    getevent -lt /dev/input/eventN                        # optional, read-only: REL_MISC on hand approach

## Risks

- adsp_factory's classes are found through kernfs (public structs, exact kernel); if adsp_factory is ever
  rmmod'ed while sx9360 is bound, the class goes away under it (nobody rmmods it on the phone).
- Hard dependency on `usb_typec_manager.ko`: present in rbich45 first stage (line 166); a build without it
  must use `GRIP_PDIC=0` or the insmod (and first stage) fails.
- First real bit-bang traffic on gpio8/9 and power-cycling of the chip through gpio104 on 6.12 (5.4 does the
  same at every boot). No regulator involved.
- If the phone has no chip / it does not answer, probe ends -ENODEV/-ENXIO cleanly (QEMU-tested).
- The debug work polls `/sys/class/sec/hall_ic/hall_detect` every 2 s (as 5.4); if the 6.12 hall node is
  missing, hall-close recalibration does not happen (one log line).
- `grip_register_recover` / `country_code` absent (as 5.4).
