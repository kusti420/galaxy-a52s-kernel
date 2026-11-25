# a52sxq_usb_moisture.ko: the moisture nodes One UI's USB HAL reads (SPEC/03 G16, S14, U18)

Status: **built, QEMU PASS (../sdfat-alias/qemu-test/run.sh, 18 checks for this module, with a fake
chip + fake "usb" supply), not on a phone.**

## What the HAL reads

`/vendor/bin/hw/android.hardware.usb@1.3-service.coral` (K4_UN1CA 9.3.173, strings):

    /sys/class/power_supply/usb/moisture_detection_enabled     "1" = detection on
    /sys/class/power_supply/usb/moisture_detected              "1" = contaminant present
    uevent lines starting with "POWER_SUPPLY_MOISTURE_DETECTED" (or "DEVTYPE=typec_") -> re-query
    property vendor.usb.contaminantdisable; log "ContaminantDetectionStatus:%d ContaminantProtectionStatus:%d"

The stock 5.4 kernel has neither node (grep over drivers/usb, drivers/battery, drivers/power: only the
unrelated qti_battery_charger / smb5 ones), so on 5.4 the HAL logs `Failed to open
moisture_detection_enabled` and One UI's moisture popup comes from Samsung's own path
(`/sys/class/sec/ccic/water`, the `CCIC=WATER` uevent of the ccic device, the battery misc event).
This module therefore adds something 5.4 does not have; the Samsung path is unchanged.

## What it does

Adds two files to the "usb" power supply device of sec-battery (`power_supply_get_by_name("usb")`):

- `moisture_detected` (0444): `1`/`0`, read at that moment from the PDIC chip driver's own sysfs getter
  (`PDIC_SYSFS_PROP_FW_WATER` = `is_water_detect` of pdic_sm5714 = `/sys/class/sec/ccic/water`).
- `moisture_detection_enabled` (0664, default `1`): stored flag; `0` makes `moisture_detected` read 0
  and stops the uevent. It does NOT switch off the chip's detection or the charger's hiccup protection.
- On `PDIC_NOTIFY_ID_WATER` (pdic notifier) and when loaded with a wet port: `KOBJ_CHANGE` on the supply
  with `POWER_SUPPLY_MOISTURE_DETECTED=0|1`.

The supply and the chip may appear later: it retries every second for 5 minutes; init never fails.

Imports 22, 0 CRC mismatches: GKI vmlinux (`bsp612/out/lahaina/Module.symvers`) + 3 from
pdic_notifier_module (`get_pdic_device` 0x1432c732, `pdic_notifier_register` 0x52528515,
`pdic_notifier_unregister` 0x0a227d4d = `pdic.symvers` = drivers612/power/Module.symvers = the CRCs
inside today's pdic_notifier_module.ko). Exports none. depends: pdic_notifier_module.
No source file of drivers612/power is changed (its headers are only included).

## ROM side (One UI), needed before the HAL can use it

- SELinux: `hal_usb_default` may read `vendor_sysfs_usb_supply` and only search `sysfs_battery`
  (vendor_sepolicy.cil 9.3.173). The supply's real path on 6.12 (`readlink -f
  /sys/class/power_supply/usb`) needs a genfscon to a type the HAL may read (and write, for
  `moisture_detection_enabled`). Without it the HAL logs the same `Failed to open` as on 5.4:
  no regression, no feature.
- `moisture_detection_enabled` is root 0664: the HAL can write it only after an init chown.

## Build

    drivers612/samsung-oneui/usb_moisture/mk.sh     -> out-p1/a52sxq_usb_moisture.ko + SHA256SUMS

## On-phone test

`$S` = the test phone's serial, always `adb -s $S`.

No hands (any ROM on 6.12; nothing is written to hardware):

    adb -s $S push drivers612/samsung-oneui/usb_moisture/out-p1/a52sxq_usb_moisture.ko /data/local/tmp/
    adb -s $S shell su -c 'insmod /data/local/tmp/a52sxq_usb_moisture.ko; sleep 2; dmesg | grep usb_moisture | tail -2;
      P=/sys/class/power_supply/usb; ls -lZ $P/moisture_detected $P/moisture_detection_enabled; readlink -f $P;
      cat $P/moisture_detected $P/moisture_detection_enabled /sys/class/sec/ccic/water'

  expected: `a52sxq_usb_moisture: bound: power_supply/usb nodes + PDIC notifier, water now 0`;
  `-r--r--r-- root root` and `-rw-rw-r-- root root`; values `0`, `1`, `0` (dry port).
  One UI: replug the cable (or wait for the next Type-C uevent), then
  `adb -s $S logcat -d | grep -iE 'moisture|Contaminant' | tail`: with the ROM-side label in place
  `ContaminantDetectionStatus` lines and no `Failed to open moisture_`; without it an avc denial for
  hal_usb_default (`dmesg | grep "avc.*moisture"`).
  LineageOS/IchthysOS: the AIDL USB HAL there reads `sec/ccic/water` (SPEC/03 U10); the nodes are
  simply extra. Unload: `rmmod a52sxq_usb_moisture` -> both files gone.

Hands (optional, broken-screen phone only, as SPEC/03 S14): one drop of tap water in the port:
`moisture_detected` 1, `sec/ccic/water` 1, dmesg `water 1 -> uevent on power_supply/usb`, charging
stops (hiccup), One UI popup; dry -> 0 and `water 0 -> uevent`.
