# out-p1: SPEC/05 P1 power items (2026-11-24). Built, not on a phone

Rebuild + proof: `drivers612/power/out-p1/build.sh` (copy of drivers612/power in `tree/`, same make line as
`../build.sh`, nothing written into drivers612/power or bsp612/out). Result: `CRC-CHECK.txt`, `SHA256SUMS`.
The `.ko` files are not committed (`*.ko` is ignored here, as in `../out-flavor`).

Modules to swap in the vendor ramdisk (shipped = rb108 and rbou9, same three files):

| module | shipped sha256 | new sha256 | exports | imports |
|---|---|---|---|---|
| `sec-battery.ko` | 85cec1d2... | 1bb8e0d2b895d7b5f48f230116253be018bc0c08edb4b1f1defc2bb9c6c9e438 | 79 of 79 CRCs identical | 128 -> 127 (`sec_pd_get_apdo_prog_volt` no longer used), depends unchanged |
| `common_muic.ko` | 85e214c0... | 7b7ff75e0c82f6f3b56b9e4a2e5a3de9ea5a921f447eb49532f20ae27d4c3d31 | 26 of 26 | 17 -> 26, all 9 new ones vmlinux exports (of_chosen, strstr, kstrtoint ...), depends unchanged |
| `muic_sm5714.ko` | 13f01335... | 35d996737adad85ae59b01613dc3b5d57b2dae2f9a6fcab2e642cf1cab782f7c | 5 of 5 | 61 -> 75, all 14 new ones vmlinux exports (filp_open, kernel_read, kernel_write ...), depends unchanged, modinfo + `parm: a52_afc_param_write:bool` |

Module.symvers of the whole power stack: 313 exports, CRC + name + module identical to the shipped build.
Consumers in the rb108 first-stage set: 8 + 18 + 3 imported CRCs checked against the new modules, 0 mismatches.
No load-order change. `support_dex_mode` is DT only (`drivers612/touch/a52sxq-touch.dtsi`): needs a DT rebuild
by the kernel line, no module.

## What changed

- a. `sec_battery.c` usb_typec_handle_id_power_status(): APDO power = min(real APDO max voltage,
  `battery,apdo_max_volt` 11000) x max current, as bone 5.4 `sec_battery.c:6312-6320` (was: nominal 9 V for an
  11 V APDO). 11 V / 2.25 A: 24750 mW (was 20250) -> `hv_charger_status` 3.
- b. `usb` and `ac` supplies: `voltage_max` (uV, `input_voltage`) and `current_max` (uA, input current limit of
  the cable type), same expressions as both 5.4 trees. Consumer verified in source: AOSP
  `system/core/healthd/BatteryMonitor.cpp:561-602` reads `<online supply>/current_max` + `voltage_max`;
  SettingsLib `BatteryStatus.java:165-167`: power <= 0 unknown (plain "Charging"), < 5 W slowly, > 7.5 W rapidly.
  `usb` got its own property list (the shared `sec_power_props` also serves a supply whose getter knows only
  `online`; an -EINVAL there would break that supply's uevents).
- c. `support_dex_mode;` in the touch node (bone r00..r02 DT) -> `sec_touchpad` input device.
- d. "Fast charging" off switch across reboots, both halves of the 5.4 path:
  - read: `get_afc_mode()` (common_muic) takes bits 8..15 of `sec_mparam.charging_mode=` (what bootloader
    A528BXXU5FWK4 really writes: 0x00 never written, 0x3000 on, 0x3100 off; seen in logs) or a bare
    `afc_disable=` from `/chosen/bootargs`. sec-battery and muic_sm5714 already call it at probe.
  - write: `src/muic/sm/sm5714/a52_afc_param.h`: a write to `/sys/class/sec/switch/afc_disable` stores '0'/'1'
    as u32 in the param partition at `androidboot.cm.param.offset` + 4 (0x9001C4 = 5.4
    `struct sec_param_data.afc_disable`), from a kworker like 5.4. Guards: bootloader offset word present,
    struct starts with a debug level (0x4f4c/0x494d/0x4948), field holds 0/'0'/'1'; else nothing is written.
    OFF by default (coordinator decision: unproven raw write, the modules also go onto daily phones). Enable at
    run time: `echo 1 > /sys/module/muic_sm5714/parameters/a52_afc_param_write` (0644, root; lost at reboot), or at
    load: `muic_sm5714 a52_afc_param_write=1` in modules.options. The read half is always on.
  - NOT proven offline: that the kworker may open the param block device under each ROM's sepolicy, and that the
    bootloader reads this field (5.4 source says so). First run on broken screen, with the dd read-back below.

## On-phone tests (root shell; same steps on LineageOS / IchthysOS / One UI unless noted)

0. Modules in: `cat /sys/module/muic_sm5714/parameters/a52_afc_param_write` -> `N` (write half off by default).

a. PPS rated power. HANDS: plug a 25 W PPS charger (EP-TA800, 11 V / 2.25 A).
   - `dmesg | grep 'pd_max_charge_power('` -> `pd_max_charge_power(24750000,24750000,<fpdo>) = 24750000`
     (old module: `= 20250000`).
   - `cat /sys/class/power_supply/battery/hv_charger_status` -> `3` (old: 2).
   - One UI: lock screen says "Super fast charging". LineageOS/IchthysOS: no consumer of this value (see b).
   - Same charger on bone 5.4 must print `pd_max_charge_power = 24750mW` and 3.

b. usb / ac current_max, voltage_max.
   - No hands (phone on the PC's USB port): `cd /sys/class/power_supply; cat usb/online usb/voltage_max usb/current_max`
     -> `1`, `5000000`, the SDP limit in uA (not 0, no "Invalid argument"); `cat ac/voltage_max ac/current_max`
     readable; `dumpsys battery | grep -i 'max charging'` -> `Max charging current:` and `Max charging voltage:`
     non-zero (old module: 0 / 0). `dmesg | grep -i 'power_supply.*uevent\|usb: driver failed'` -> nothing.
   - HANDS: plug a wall charger (AFC 15 W or PD), adb over Wi-Fi or read after replug:
     `dumpsys battery | grep -i 'max charging'` -> current x voltage > 7500000 uW (AFC: 9000000 uV x 1650000 uA);
     LineageOS/IchthysOS lock screen: "Charging rapidly". One UI: unchanged (it uses hv_charger_status).

c. support_dex_mode (after a DT rebuild). No hands.
   - `ls /proc/device-tree/soc/i2c@*/touchscreen@49/support_dex_mode` exists.
   - `grep -A4 sec_touchpad /proc/bus/input/devices` -> one device `N: Name="sec_touchpad"`;
     `getevent -pl | grep -c sec_touchscreen` still 1; touch + fingerprint behave as before.

d. Fast charging off switch. No hands (two reboots). Do it on broken screen first.
   - Before: `tr ' ' '\n' < /proc/cmdline | grep -E 'charging_mode|cm.param.offset'` ->
     `sec_mparam.charging_mode=0x00` or `0x3000`, `androidboot.cm.param.offset=9437632`.
     Backup: `dd if=/dev/block/by-name/param of=/data/local/tmp/param.bak bs=1M`.
     `dd if=/dev/block/by-name/param bs=1 skip=$((0x9001c4)) count=4 2>/dev/null | xxd` -> `00000000` or `30000000`;
     `... skip=$((0x900000)) count=4 | xxd` -> `4c4f0000`.
   - Enable the write half (needed again after every reboot, before each write):
     `echo 1 > /sys/module/muic_sm5714/parameters/a52_afc_param_write; cat /sys/module/muic_sm5714/parameters/a52_afc_param_write` -> `Y`.
     Without it the echo below changes the node but logs no `a52_afc_param` line and the field stays as it was.
   - `echo 1 > /sys/class/sec/switch/afc_disable` (One UI: Settings > Battery > Charging settings > Fast charging off;
     LineageOS/IchthysOS: the fast-charge toggle). `dmesg | grep a52_afc_param` ->
     `a52_afc_param: afc_disable '1' -> param+0x9001c4 (4)`. The dd at 0x9001c4 -> `31000000`.
     If instead `open param failed (-13)`: sepolicy denies the kworker (`dmesg | grep 'avc.*param'`), report it.
   - Reboot. `grep -o 'sec_mparam.charging_mode=[^ ]*' /proc/cmdline` -> `0x3100`;
     `dmesg | grep -E 'afc_mode|AFC mode'` -> `afc_mode is 0x31`, `AFC mode disabled`;
     `cat /sys/class/sec/switch/afc_disable` -> `1`; `cat /sys/class/power_supply/battery/batt_current_event`
     has bit 0x10000 set. One UI: the toggle still shows off.
     (HANDS, optional: an AFC charger now stays at 5 V, `hv_charger_status` 0.)
   - Restore: enable the parameter again (`echo 1 > .../a52_afc_param_write`), `echo 0 > /sys/class/sec/switch/afc_disable`, dd shows `30000000`, reboot, cmdline `0x3000`, node `0`.
   - If the cmdline does NOT follow the write (stays 0x00 with 31 in the field): the bootloader reads another
     field; leave `a52_afc_param_write` off and report (the read half still gives 5.4 parity for a value stored on 5.4).
