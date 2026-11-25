# battery_attrs: `battery/pass_through` + `battery/sub_bat_temp_raw` on 6.12

Two `/sys/class/power_supply/battery` attributes the One UI 9 port's 5.4 kernel has and the 6.12 line lacks
(`drivers612/ONEUI9-PARITY.md`: `quirk.rom_kernel_check` FAIL `missing=pass_through`, `battery.attrs` missing
`pass_through sub_bat_temp_raw`, `battery.oneui_attrs`, EACCES on `battery/pass_through` from `[SS]BattUtils` /
`System.err`). Built and checked OFFLINE only: nothing was loaded on a phone, nothing committed, `drivers612/power`
not touched (it belongs to another agent; the change is a patch for it + a module built from a copy).

## Files

| Path | What |
|---|---|
| `0001-sec-battery-pass_through-sub_bat_temp_raw.patch` | the change, `patch -p1` in `drivers612/power` (applies clean, result = `tree/` sources) |
| `tree/` | copy of `drivers612/power` sources with the patch; only `Kbuild`'s two `$(src)/../..` include paths made absolute |
| `build.sh` | same make line as `drivers612/power/build.sh` (M= the copy), then strip like `samsung-oneui/build.sh` |
| `out/sec-battery.ko` | the rebuilt module (the only replaced module) |
| `crc-check.sh`, `crc/CRC-CHECK.txt` | CRC / modinfo / attribute-table proof |
| `attrtable.py` | prints the new `device_attribute` table from the .ko's relocations |
| `swap-vendor-boot.sh`, `ramdisk/<rb>/` | vendor ramdisk + vendor_boot.img with only `sec-battery.ko` replaced (rd-swap-ko.py) |
| `baseline-build.log`, `build.log` | builds of the copy without / with the patch |

## What `pass_through` does on 5.4 (port kernel, k4 patch 0008)

`~/git/kernel_a52sxq_bone/k4-patches/0008-battery-pass-through-node-for-One-UI-pause-USB-PD.patch`, in
`sb_full_soc.c`. One UI's Game Booster "Pause USB Power Delivery" (`BatteryService` / `[SS]BattUtils`) writes
`1`/`0`. While set:
* `sec_vote(chgen_vote, VOTER_PASS_THROUGH, true, SEC_BAT_CHG_MODE_CHARGING_OFF)`: the phone runs from the
  charger, the battery is not charged. This is the charger state the "Protect battery" limit already uses
  (`VOTER_FULL_CAPACITY`): sm5714 `sm5714_chg_charging(false)`, buck stays on; on PD/PPS the direct charger stops
  and the switching charger is set CHARGING_OFF. No bypass register, no new charger mode.
* status CHARGING -> NOT_CHARGING; `sec_bat_check_full_capacity()` is skipped (and keeps NOT_CHARGING).
* `0`: vote released; NOT_CHARGING -> CHARGING if health GOOD and no full-capacity event; monitor work queued.
* cleared on cable removal (`cw_nocharge_type`) and in slate mode (`cw_slate_mode`); off at boot.
* read: `%d\n` (0/1). Write: `%10d` parse, `-EINVAL` on garbage. Mode 0664 (init.rc makes it system:system 0660).

ROM side (MonsterROM): `post_mods.sh` sets `SEC_FLOATING_FEATURE_BATTERY_SUPPORT_PASS_THROUGH=TRUE` unless
`kernel_bone_machine/disable`; `kernel_feature_check/kernel_check` only tests
`exists /sys/class/power_supply/battery/pass_through` (result `pass_through`, level `feat` when the floating
feature is TRUE) -> `quirk.rom_kernel_check` ok=1 needs only the node to exist.

## Why 6.12 has no `battery/pass_through`

`drivers612/power` does contain Samsung's own `sb_pass_through.c` (linked into `sec-direct-charger.ko`, it would add
`pass_through` to the battery psy through `sb_sysfs`). It never appears because `sb_pt_init()` ->
`parse_dt()` needs a DT node named `pass-through` (`of_find_node_by_name(NULL, "pass-through")`): the a52sxq tree
(5.4 and `a52sxq-power.dtsi`) has none -> `-ENODEV`, `charger->pt = NULL`, no attribute. Not a psy/index/config
problem. Turning it on by adding the node would be WRONG and unsafe here: that driver is a different feature
(real bypass: `SEC_BAT_CHG_MODE_PASS_THROUGH`, `POWER_SUPPLY_EXT_PROP_PASS_THROUGH_MODE` writes to the main and
direct charger, `sec_pd_detach_with_cc`, DCFV/TA-voltage loop). The sm5714 charger has no PASS_THROUGH case at all
(its mode switch leaves `is_charging` unchanged for that value) and pca9468 bypass was never validated on this
board. So it stays off.

## What the 6.12 change does

New `src/battery/common/sb_oneui_attrs.c` in `sec-battery.ko`: the k4 0008 logic line for line (same vote, same
status transitions, same hook at the top of `sec_bat_check_full_capacity()`, same clear in `cw_nocharge_type()` and
`cw_slate_mode()`, same read/write format), so writing `1` does exactly what it does on the 5.4 port kernel and `0`
restores normal charging. `VOTER_PASS_THROUGH` already exists in 6.12's voter list (unused, Samsung's sb_pt is not
active). Differences, both on purpose:
* the state is a static in the new file (+ its own mutex, also taken by the cable-removal clear) instead of a field
  in `struct sb_full_soc`: that struct is fully defined in the CU of exported functions
  (`get_full_capacity`, ...), so gendwarfksyms would have changed their CRCs. Nothing new is exported.
* the two files are created with `device_create_file` after `sb_full_soc_init()`, non-fatal (logged
  `sb_oneui_attrs_init: pass_through (0)`), instead of joining `sb_full_soc_attrs[]` (a name clash there would make
  `sb_full_soc_init` fail as a whole).

`sub_bat_temp_raw`: 5.4 `sec_battery_sysfs.c` returns the sub-battery thermistor ADC temperature without the LR
adjustment when `battery,sub_bat_thermal_source` is ADC, else `0`; mode 0664, store `-EINVAL`. Same here (ADC ->
`sec_bat_get_temperature(sub_bat_thm_info)`, else 0; the 6.12 helper honours a set test temperature, 5.4's raw path
did not: only matters with `batt_temp_test`-style test values).

## `sub_bat_temp_raw` verdict

Not applicable hardware-wise (single cell, no sub-battery thermistor): the a52sxq DT has no
`battery,sub_bat_thermal_source` (checked in `downstream-dt/a52sxq-r0{0,1,2}.dts`, the 5.4 bone tree and
`drivers612/power/a52sxq-power.dtsi`), so 5.4 reads `0` and the 6.12 node now reads `0` too. It is still added
because the Samsung thermal HAL (`vendor.samsung.hardware.thermal@1.0-service`,
`research/blob-uapi-evidence/byfile.txt`) reads it; with it missing the HAL gets ENOENT, with it present it gets
the 5.4 value. (`research/blob-uapi-evidence/battery.txt` is the stock kernel's list, which has neither node; the 5.4
port list with both is in `logs/oneui-sweep/diff.txt` / the selftest tables.)

## Modules replaced

Only `sec-battery.ko`. `sm5714-charger.ko` and `sec-direct-charger.ko` are unchanged (no charger-side change
needed: the CHARGING_OFF path exists).

* `out/sec-battery.ko`: 683136 bytes, sha256 `f1f2e4294cee0b08...`, vermagic `6.12.81-4k-g8a69376da734 SMP preempt
  mod_unload modversions aarch64`, `--strip-debug` + `.BTF/.BTF.base` removed.
* shipped: `realboot/out/{rbou3,rbich45,...}/work/vr/lib/modules/sec-battery.ko` sha256 `553ec48cae8d98ff` (= the
  current `drivers612/power/sec-battery.ko` stripped the same way, byte for byte; `rbich45/work/plan/first/` holds
  the same module with .BTF still in it, same CRCs).
* unmodified copy rebuilt first (`baseline-build.log`): identical export + import CRCs to the shipped one, so the
  copy builds like the original.

## CRC check (`crc/CRC-CHECK.txt`, `./crc-check.sh`)

* export CRCs (ko2symvers.py, both modules): 79 of 79 identical;
* import CRCs (`__versions`): 126 identical; modinfo (vermagic, depends, params, aliases) identical;
* every first-stage module of rbou3 that imports a sec-battery export: 8 imported CRCs checked against the new
  module, 0 mismatches;
* attribute table compiled in: `oneui_attrs[0]: name=pass_through mode=0664`, `oneui_attrs[1]:
  name=sub_bat_temp_raw mode=0664` with their show/store functions.

## Ramdisk delivery (`./swap-vendor-boot.sh <rb> out/sec-battery.ko`, nothing flashed)

Our vendor ramdisk fragment (`work/vr-add.cpio.lz4`) is decompressed (recompressing it with build-realboot's lz4
recipe gives the same bytes), `rd-swap-ko.py` replaces only `lib/modules/sec-battery.ko` (1 entry), the fragment is
recompressed (+ lz4 end marker where build-realboot added one), the ROM part is put back in front. CONTROL: the same
mkbootimg + AVB-footer recipe on the ORIGINAL ramdisk rebuilds the shipped `vendor_boot.img` byte-identical (also the
testkey-signed OneUI one) before the new image is made. Read-back: dtb, cmdline, header = shipped; extracted ramdisks
differ only in `lib/modules/sec-battery.ko`; modules.load/dep unchanged (depends identical). ABL load budget still
OK (+1.8 KB).

| build | vendor_boot.img (sha256) | was |
|---|---|---|
| `ramdisk/rbou3/` (One UI port, footer SHA256_RSA4096 testkey) | `59608081c516c0a8` | `cc3e7ce4ffb74c7e` |
| `ramdisk/rbich45/` (IchthysOS, unsigned footer) | `789601dbe593e09c` | `da39847b332bcbfc` |

`vendor-ramdisk.new` in each dir is the full vendor ramdisk blob (for build-realboot style repacks). boot.img and
dtbo.img are unchanged. For a future build-realboot run the clean route is to rebuild `drivers612/power` with the
patch (its owner), then the normal pipeline picks the module up.

## SELinux and rc (One UI vendor, `~/git/MonsterROM/out/target/a52sxq/work_dir`)

* path on 6.12 = 5.4: `/sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery`
  (`research/sepolicy/PATHS.md` row "samsung_mobile_device:battery ... same as 5.4"; 6.12 avc logs show that path).
* genfscon `vendor_sepolicy.cil:211` `.../power_supply/battery` -> `sysfs_battery`; no more specific entry for
  `pass_through` or `sub_bat_temp_raw` -> both are `u:object_r:sysfs_battery:s0` (as on 5.4).
* access: `system_server_30_0 sysfs_battery file rw` (l.7500), `hal_thermal_default sysfs_battery file read`
  (l.10796), `hal_health_default` read/write; `kernel_check`'s `sysfs_battery file getattr`
  (`kernel_feature_check/sepolicy_vendor_types.cil`).
* rc: `system/etc/init/hw/init.rc` `on boot` (l.2260-2261): `chown system system
  /sys/class/power_supply/battery/pass_through` + `chmod 0660 ...`; nothing for `sub_bat_temp_raw` (stays
  root:root 0664, world-readable; the thermal HAL only reads). The attributes exist from sec-battery's probe in the
  first stage, long before `on boot`.

## On-phone check (not done here; needs the 6.12 One UI boot with the new vendor_boot)

Read-only:

    B=/sys/class/power_supply/battery
    ls -lZ $B/pass_through $B/sub_bat_temp_raw     # system system 0660 sysfs_battery / root root 0664 sysfs_battery
    cat $B/pass_through $B/sub_bat_temp_raw        # 0 / 0
    dmesg | grep sb_oneui_attrs_init               # pass_through (0), sub_bat_temp_raw (0)
    kernel_check                                   # no "MISSING: pass_through"; getprop sys.kernel_check.missing

One reversible write (safe: the same CHARGING_OFF vote "Protect battery" uses; on USB, battery below 100 %, screen
on so the status is visible). Before, during, after read `status`, `current_now` (or `current_avg`), `capacity`,
`voter_status` (while on: `CHGEN: VOTER_PASS_THROUGH: en=1 v=2` and `CHGEN: voter=VOTER_PASS_THROUGH type=Min
v=2`, 2 = SEC_BAT_CHG_MODE_CHARGING_OFF, 4 = CHARGING), `charge_type`, `online`:

    echo 1 > $B/pass_through   # expect: status Not charging, battery current ~0/slightly discharging, USB still online,
                               # dmesg "set_pass_through: pass through on", sm5714 "charger_mode changed [4] -> [2]"
    echo 0 > $B/pass_through   # expect: status Charging again, current back, "pass through off", "[2] -> [4]"

Unplugging while on also clears it ("charger removed, pass through off"). Then the UI toggle (Game Booster "Pause
USB Power Delivery") should flip the same node without EACCES in logcat.

## Behaviour notes / risks

* Same as 5.4, kept on purpose: a `1` written while NO charger is attached stays set and holds charging off on the
  next plug-in until the next unplug (cable removal clears it; reboot clears it). One UI only offers the switch while
  charging.
* Not on a phone yet: the CHARGING_OFF path itself is old Samsung code, but whether the 6.12 sm5714/direct-charger
  pair behaves exactly like 5.4 under it (esp. during 25 W PPS direct charging) is unverified.
* Status: built, offline-checked. Not on a phone, not verified.
