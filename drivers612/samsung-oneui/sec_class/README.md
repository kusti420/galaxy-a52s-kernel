# a52sxq_sec_class: the missing /sys/class/sec devices (6.12)

`a52sxq_sec_class.ko` creates the twelve `/sys/class/sec` devices that the Galaxy A52s 5.4
kernel (A528BXXU5FWK4) has and the 6.12 stack does not (drivers612/ONEUI9-PARITY.md rows
`sec.class_dirs`, `sensors.hall`, `storage.sd_class`, `battery.switch_class`):

    hall_ic msm_dwc3 pcie-wifi sdcard sddata sdinfo sec_abc sec_abc_hub sec_misc sec_nad sec_sysup typec_manager

Attribute names, modes and print formats are copied from the 5.4 sources
(`$ANDROID_TREE/kernel/samsung/sm7325`, files listed in the source header, Samsung GPL-2.0
attribution kept). Where 6.12 has the data the value is REAL; otherwise the node is a STUB
that prints the 5.4 "nothing to report" answer. Every STUB is marked `STUB` in the source.

Status: built, QEMU smoke 89/89 PASS. **Never loaded on a phone.**

## Build / depends / load position

    EXTRA_SYMVERS=$PWD/drivers612/samsung-oneui/sec_class/sec_core.symvers \
        drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/sec_class
    -> drivers612/samsung-oneui/sec_class/out/a52sxq_sec_class.ko   (depends: sec_core)

`sec_core.symvers` = copy of `ufs_sec/sec_core.symvers` (CRCs of `___sec_device_create`,
`sec_device_destroy`, `sec_dev_get_by_name`). Everything else is GKI vmlinux.

Load it in the first stage after `sec_core.ko` (plan line 143) and after the powerpd stack
(`usb_typec_manager.ko` 166), i.e. with the other samsung-oneui modules right after
`input_booster.ko` (rbich45 plan line 186; "~191" in the task). `sdhci-msm.ko` loads later
(line 193): no problem, the SD nodes look the host up at every read. The hall is gpio-keys,
built into the GKI Image (HALL=1), so it exists before the module.

Init never fails and never blocks: all devices and attributes are created synchronously in
init (so OneUI's `on boot` chown/chmod lines find them); a device name that already exists in
`/sys/class/sec` is skipped (and not removed at rmmod); missing data sources only change what
a read returns. The module prints nothing.

QEMU: `drivers612/samsung-oneui/sec_class/qemu-smoke/run.sh [sec_core.ko]` (default: the s99o
ramdisk's sec_core.ko). `fakehall.ko` (input "hall", SW_LID, param `lid`) stands in for the
gpio-keys hall; QEMU has no 8804000.sdhci and no qcom,qfprom node. Checks: 12 devices under
`/sys/devices/virtual/sec/`, attribute set + modes = 5.4, every read format, hall OPEN/CLOSE,
FCNT count + clear, the `hall=close|open` KOBJ_CHANGE uevent (tracefs kprobe on
kobject_uevent_env), all store paths, init-style chown, rmmod, reload, 0 WARN/BUG, silent.

## Per device

Consumers: strings of `~/git/MonsterROM/out/target/a52sxq/work_dir/{vendor,system,product,odm}`
(binaries, rc, xml/json, and every dex/so/xml inside apk/jar, decompressed with `unzip -p`;
compressed .capex payloads not scanned). Modes = 5.4 kernel modes (evidence:
research/blob-uapi-evidence/sec_detail.txt, a LineageOS 5.4 dump, so without OneUI's init.rc
chowns). Labels = longest-prefix genfscon in the OneUI vendor/plat/system_ext/product/odm cil;
`sysfs` = no rule (same on 5.4). Owners/modes after boot come from the OneUI rc lines listed.

| device / attr | mode | format (5.4) | REAL / STUB | 6.12 source | label | consumer |
|---|---|---|---|---|---|---|
| hall_ic/hall_detect | 0444 | `CLOSE\n` / `OPEN\n` | REAL | SW_LID state of the input device named "hall" (gpio-keys, input handler, `dev->sw`); none -> `OPEN` | sysfs_sec | vendor sensors.grip.so (`/sys/devices/virtual/sec/hall_ic/hall_detect`), services.jar |
| hall_ic/hall_count | 0444 | `"FCNT":"%d"` (no newline), cleared by the read | REAL | SW_LID changes seen by the handler (initial report not counted) | sysfs | DeviceKeystring (factory UI string `hall_count`) |
| hall_ic/hall_number | 0444 | `%u\n` | REAL | 1 if a hall input is connected, else 0 (5.4: DT count = 1) | sysfs | none |
| hall_ic/debounce | 0444 | `%d\n` | REAL | gpio-keys `debounce-interval` of the SW_LID key (6.12 DT: 15); no hall: 50 = 5.4's default (5.4 printed 50) | sysfs | none |
| hall_ic uevent | - | KOBJ_CHANGE `hall=close` / `hall=open` | REAL | sent on every SW_LID change, as 5.4 hall_ic_work() | - | none found |
| msm_dwc3 | - | no attributes (5.4: drvdata holder only) | - | - | sysfs | none |
| typec_manager | - | no attributes (5.4 non-factory) | - | see "typec_manager" below | sysfs | none |
| pcie-wifi/pcie_l1ss_ctrl | 0664 | read: L1ss register dump; write: `0`/`1` (always returns count) | STUB | A52s Wi-Fi is WCN6750/icnss2, no PCIe EP: prints `RC0 link is not enabled.\n` (5.4's no-link branch); writes accepted, ignored | sysfs_ss_writable | hyper (`vendor/etc/hyper/config_chipset.json` BoostPath, writes), `init.samsung.bsp.rc` on boot `chown radio system` |
| sdcard/status | 0444 | `Notray\n` / `Insert\n` / `Remove\n` | REAL | mmc host of 8804000.sdhci (`mmc_gpio_get_cd`) + card child; no host -> `Remove` | sysfs_ss_writable | services.jar |
| sdcard/cd_cnt | 0444 | `%u\n` | STUB 0 | 5.4 card_detect_cnt is a Samsung slot-gpio counter, not in 6.12 | sysfs_ss_writable | dumpstate (vendor + system), hqm_device.xml `CDCNT` |
| sdcard/max_mode | 0444 | `SDR104\n`..`HS\n` | REAL | host->caps | sysfs_ss_writable | init.rc chown only |
| sdcard/current_mode | 0444 | `SDR104\n`.. / `HS\n` / `No Card\n` | REAL | card->sd_bus_speed, mmc_card_uhs() | sysfs_ss_writable | init.rc chown only |
| sdcard/current_phase | 0444 | `%d\n` (SDR104 tuning phase, else -1) | STUB -1 | the phase is in soc-repo sdhci-msm's private struct; -1 also for SDR104 | sysfs_ss_writable | init.rc chown only |
| sdcard/sdcard_summary | 0444 | `"MANID":"0x%02X","SERIAL":"%04X","SIZE":"..","SPEEDMODE":"..","NOTI":"%d"\n` / NoCard JSON | REAL except NOTI | card CID/CSD (5.4 size code verbatim); NOTI = Samsung err_log -> 0 | sysfs_ss_writable | hqm_device.xml (bigdata) |
| sdcard uevent | - | KOBJ_CHANGE on SD I/O error (Samsung mmc core hook) | STUB: never sent | - | - | SystemUI (`DEVPATH=/devices/virtual/sec/sdcard`, SD error notification) |
| sdinfo/sd_count | 0444 | `%lld\n` / `no card\n` | STUB 0 with a card | Samsung err_log | sysfs | init.rc chown only |
| sdinfo/data | 0444 | raw CID `%08x%08x%08x%08x\n` / `no card\n` | REAL | card->raw_cid | sysfs_sdinfo | services.jar, vold/framework.jar (`/sys/class/sec/sdinfo`) |
| sdinfo/fc | 0444 | `GOOD\n` / `BAD\n` / `NOCARD\n` | STUB GOOD with a card | Samsung err_log (BAD thresholds) | sysfs_sdinfo | services.jar |
| sddata/sd_data | 0444 | `"GE":"0","CC":"0","ECC":"0","WP":"0","OOR":"0","CRC":"0","TMO":"0"\n` | STUB zeros | Samsung err_log | sysfs_ss_writable | hqm_device.xml (bigdata) |
| sec_abc/enabled | 0644 | `1\n` / `0\n`; write `1`/`0` or `ERROR_REPORT=1,ALL_REPORT=0,PRE_EVENT=1,...` | STUB (mode bits tracked exactly as 5.4) | - | sysfs_sec | system init binary (writes it), init.rc on boot `chown system radio` + 0664 |
| sec_abc/spec | 0644 | `spec type1\n` + spec lines | STUB (header only), writes ignored | - | sysfs_sec | init.rc chown/chmod |
| sec_abc/features | 0644 | `spec_control\nhost\n` | REAL (constant in 5.4) | - | sysfs_sec | init.rc chown/chmod |
| sec_abc uevent | - | KOBJ_CHANGE MODULE=/WARN=/INFO=/TIMESTAMP=/HOST=/EXT_LOG= | STUB: never sent; no `sec_abc_send_event()` export | - | sysfs_sec | SamsungDeviceHealthManagerService (`DEVPATH=/devices/virtual/sec/sec_abc`) |
| sec_abc_hub/enable | 0644 | `%d\n` (0/1) | STUB stored | - | sysfs | init.rc chown/chmod |
| sec_abc_hub/bootc_offset | 0644 | `fsck,%d\n`; write `<module>,<offset>` (only `fsck`) | STUB stored | - | sysfs_ski_testinfra_writable | vold + libfs_mgr (`bootc_offset_sec_sysfs`, writes fsck time) |
| sec_abc_hub/bootc_time | 0644 | `%d\n` (init -1; bad write -> -1) | STUB stored | - | sysfs_ski_testinfra_writable | bootchecker `--writebootc` (writes) |
| sec_misc/msm_feature_id | 0444 | `%02u\n` / `Feature ID is not supported!!\n` / `could not map FEATURE_ID address\n` | REAL | QFPROM JTAG id word bits 20..27 at `samsung,sec_misc` `qfprom_jtag,reg` (A52s 0x784180; fallback 0x784180), read once with ioremap ONLY if inside a `qcom,qfprom` node's reg (6.12: qfprom@780000 + 0x7000; 0x784180 = its tsens_chipinfo cell) | sysfs | none (DeviceKeystring/FacAtFunction use `msm_apc_avs_info`, which 5.4 only has in factory builds) |
| sec_nad/quest_fv_flashed | 0444 | `%d\n` | STUB 0 | 5.4 reads the param partition | sysfs_ski_debug_readable | none |
| sec_sysup/edtbo_version | 0440 | `%lu\n` | REAL | `androidboot.edtbo=` from /chosen/bootargs (5.4: early_param), else 0 | sysfs | init.samsung.bsp.rc on init `chown system system` (DeviceKeystring reads the prop `ro.boot.edtbo_ver`) |
| sec_sysup/edtbo_update | 0220 | write `1` | STUB: `1` -> -EOPNOTSUPP, else -EINVAL | 5.4 writes the edtbo.img fiemap into sec_param | sysfs_ski_system_writable | init.samsung.bsp.rc `chown system system`; writer DeviceKeystring (factory) |

Not ported because 5.4 on the A52s does not have them either (ROM references them anyway):
`hall_ic/{certify_hall_detect,flip_status,hall_wacom_detect,hall_logical_detect}`,
`sdcard/err_count`, `sdinfo/reason`, `sec_abc/{list,log,testinfo}`, `sec_misc/msm_apc_avs_info`.

`waiting_for_supplier` (listed in every 5.4 dir) is a 5.4 fw_devlink core attribute, not a
driver one; 6.12 does not add it to class devices without a fwnode.

### rc lines that touch these nodes (applied by OneUI's init, nothing to change)

    vendor/etc/init/hw/init.samsung.bsp.rc  on init: chown system system /sys/class/sec/sec_sysup/edtbo_{update,version}
                                            on boot: chown radio system /sys/class/sec/pcie-wifi/pcie_l1ss_ctrl
    system/etc/init/hw/init.rc  on boot: chown system system /sys/class/sec/sdcard/{status,cd_cnt,max_mode,current_mode,
                                           current_phase,sdcard_summary,err_count} sddata/sd_data sdinfo/{sd_count,data,fc,reason}
                                         chown system radio + chmod 0664 sec_abc/{enabled,spec,log,testinfo},
                                           0644 sec_abc/{features,list}, 0664 sec_abc_hub/{enable,bootc_offset,bootc_time}

The SELinux labels need no ROM change: the vendor policy labels by the real path
`/devices/virtual/sec/<name>/...`, which is where sec_core puts these devices (parent NULL),
exactly as on 5.4. (Rules written for `/class/sec/...` paths never match on either kernel.)

## typec_manager on 6.12 (why drivers612/power does not create it)

`drivers612/power/src/usb/typec/manager/usb_typec_manager_notifier.c` (donor 6.12 source)
creates the device only with `IS_ENABLED(CONFIG_DRV_SAMSUNG) && defined(CONFIG_SEC_FACTORY)`
(lines 71, 1344, 1667, 1732); 5.4 created it with `CONFIG_DRV_SAMSUNG` alone and added
`fac_usb_control` only for SEC_FACTORY. The power Kbuild defines DRV_SAMSUNG but not
SEC_FACTORY. The 5.4 user build has no attributes on it and nothing in the ROM reads it, so
this module creates the empty device instead of touching that directory.

The equivalent in-driver patch (not applied; other agent's dir) would be: lines 71 and 1667
`#if IS_ENABLED(CONFIG_DRV_SAMSUNG)` (declaration + `sec_device_create(NULL, "typec_manager")`),
keep lines 1344 and 1732 (manager_device check in the register path, fac_control +
`sysfs_create_group`) under `... && defined(CONFIG_SEC_FACTORY)`. If that patch lands, the
existing-device check here skips `typec_manager` as long as usb_typec_manager loads first
(it does: line 166). Load order the other way round would make the donor's init fail
(`sec_device_create` error -> `-ENODEV` from module init): keep usb_typec_manager first.

There is no `/sys/class/switch/typec_manager` on 5.4 (switch class there: ccic_dock, dock,
uart3); the parity row `battery.switch_class ... typec_manager=y` tests
`/sys/class/sec/typec_manager` (tools/selftest/oneui/checks/50-usb-storage-power.sh:53).

## On-phone read-only check (do not write anything)

    adb shell su -c 'cat /proc/modules | grep -E "^(sec_core|a52sxq_sec_class) "'
    adb shell su -c 'for d in hall_ic msm_dwc3 pcie-wifi sdcard sddata sdinfo sec_abc sec_abc_hub sec_misc sec_nad sec_sysup typec_manager; do
        echo "== $d $(readlink -f /sys/class/sec/$d)"; ls -lZ /sys/class/sec/$d/ | grep -v -e power -e subsystem -e uevent; done'
    adb shell su -c 'cd /sys/class/sec; for f in hall_ic/hall_detect hall_ic/hall_number hall_ic/debounce sdcard/status \
        sdcard/max_mode sdcard/current_mode sdcard/current_phase sdcard/sdcard_summary sddata/sd_data sdinfo/fc \
        sec_abc/enabled sec_abc/features sec_abc_hub/enable sec_abc_hub/bootc_offset sec_abc_hub/bootc_time \
        sec_misc/msm_feature_id sec_nad/quest_fv_flashed sec_sysup/edtbo_version pcie-wifi/pcie_l1ss_ctrl; do echo "$f=[$(cat $f)]"; done'
    # hall: cover the hall with a magnet / flip cover, read hall_detect again (CLOSE); hall_count clears on read
    # (read it only when you want the count). sdinfo/data prints the SD card's CID (a card identifier).

Expected on the phone: labels per the table (`ls -Z`: hall_detect `sysfs_sec`, sdinfo/data+fc
`sysfs_sdinfo`, the sdcard dir `sysfs_ss_writable`, ...), owners after boot per the rc lines,
same strings as 5.4 except: debounce 15 (5.4 50), cd_cnt 0, current_phase -1, NOTI 0,
sd_data zeros, sdinfo/sd_count 0, fc GOOD, quest_fv_flashed 0. Compare with 5.4 on the same
phone with the same command.

## Risks

- msm_feature_id is the only hardware access: one 32-bit MMIO read of QFPROM, guarded by the
  DT check above, done on the first read only. Same register 5.4 read on the same phone/TZ,
  and inside the region the 6.12 qfprom nvmem driver maps (tsens reads that very word), but
  never executed on the 6.12 phone yet.
- The SD reads hold device references (platform dev, mmc host class dev, card dev) instead of
  5.4's unlocked `host->card`; `mmc_gpio_get_cd()` would race only with an sdhci-msm unbind.
- The hall handler opens the "hall" input device (as evdev does); with HALL=0 there is no
  SW_LID device and hall_detect reads `OPEN`, hall_number `0` (5.4 would have 1).
- STUB telemetry never raises an ABC uevent; SamsungDeviceHealthManagerService and SystemUI's
  SD-error notification simply get nothing (as on a phone with no errors). If 6.12 drivers are
  later built with CONFIG_SEC_ABC they need a `sec_abc_send_event()` provider (not here).
- Duplicate names: a future driver creating one of these names after this module loads would
  fail its own `sec_device_create()` (see typec_manager).
