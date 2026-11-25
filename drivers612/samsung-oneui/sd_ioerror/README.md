# a52sxq_sd_ioerror.ko: Samsung's "SD card IO error" uevent on 6.12 (SPEC/03 D13)

Status: **built, QEMU PASS (../sdfat-alias/qemu-test/run.sh, 9 checks for this module), not on a phone.**

## 5.4 reference (stock bone kernel, ~/git/kernel_a52sxq_bone)

- `drivers/mmc/core/block.c:499 mmc_card_error_logging()`: card status bits of failed block requests
  -> `card->err_log[0].{ge,cc,ecc,wp,oor}_cnt`; for `MMC_TYPE_SD` it calls `host->sdcard_uevent()`
  at every 1000th GE / ECC and every 100th WP / OOR error.
- `drivers/mmc/host/sdhci-msm.c:4449 sdcard_uevent()`: `kobject_uevent(KOBJ_CHANGE)` on the
  `/sys/class/sec/sdcard` device; `:4455 sdhci_sec_sdcard_uevent()` (device type) adds
  `DEVNAME=sdcard` and `IOERROR=YES|NO|NoCard`.
- Consumer (One UI 9.3.173): **SystemUI** (`SystemUI.apk` classes4.dex strings
  `DEVPATH=/devices/virtual/sec/sdcard` and `IOERROR`). vold, services.jar and framework.jar do not
  have the string (services.jar reads `/sys/class/sec/sdcard/status`, `sdinfo/data`, `sdinfo/fc`).

## 6.12

mmc core/block are built into the GKI Image and have no such hook. The module registers a probe on the
built-in `mmc_request_done` tracepoint (not exported: found with `for_each_kernel_tracepoint()`), looks
at the R1 status of CMD12/13/17/18/24/25 and the cmd/data/stop results of the SD slot's host
(`8804000.sdhci`, card type SD), counts like 5.4 and sends the same uevent
(`DEVNAME=sdcard`, `IOERROR=YES`) on the device `sec_dev_get_by_name("sdcard")`
(= `/sys/devices/virtual/sec/sdcard`, created by a52sxq_sec_class.ko; looked up when the uevent is
sent, so load order does not matter).

Differences from 5.4:
- every completed request is judged on its own (5.4: once per failed block request, status + stop +
  cmd response ORed), so a sticky bit seen in two responses of one transfer counts twice;
- `IOERROR=NO/NoCard` is not added to the device's other uevents (add/remove);
- the `/sys/class/sec/{sdinfo,sddata}` counters and `sdcard_summary` NOTI of a52sxq_sec_class.ko are
  still its stubs (that file was being changed by another work item on 2026-11-24); the real
  counters are readable here instead. Follow-up: let sec_class print these counters.

Nodes (`/sys/module/a52sxq_sd_ioerror/parameters/`): `sd_data` (0400, 5.4 sd_data format), `noti`
(0400, uevents sent for the current card), `hooked` (0444, Y = probe registered), `test` (0200:
`YES|NO|NoCard` sends the uevent once; touches no card).

Imports 22, 0 CRC mismatches (GKI vmlinux `bsp612/out/lahaina/Module.symvers` + `sec_dev_get_by_name`
0x52766e1a = sec_core.symvers = today's samsung612 sec_core.ko). Exports none. depends: sec_core.

## Build

    drivers612/samsung-oneui/sd_ioerror/mk.sh       -> out-p1/a52sxq_sd_ioerror.ko + SHA256SUMS

## On-phone test (no hands; the card is not touched: only a uevent is sent)

`$S` = the test phone's serial, always `adb -s $S`.

    adb -s $S push drivers612/samsung-oneui/sd_ioerror/out-p1/a52sxq_sd_ioerror.ko /data/local/tmp/
    adb -s $S shell su -c 'insmod /data/local/tmp/a52sxq_sd_ioerror.ko; cd /sys/module/a52sxq_sd_ioerror/parameters; cat hooked sd_data noti'

  expected: `Y`, `"GE":"0","CC":"0","ECC":"0","WP":"0","OOR":"0","CRC":"0","TMO":"0"`, `0`
  (after real card traffic CRC/TMO may be non-zero: that is real data).

    adb -s $S logcat -c
    adb -s $S shell su -c 'echo YES > /sys/module/a52sxq_sd_ioerror/parameters/test; sleep 2; cat /sys/module/a52sxq_sd_ioerror/parameters/noti; dmesg | grep sd_ioerror | tail -2'
    adb -s $S logcat -d | grep -iE 'IOERROR|sec/sdcard|sd ?card.*(error|damag)' | tail
    adb -s $S shell dumpsys notification --noredact | grep -iE 'sd card|sdcard' | head

  expected on every ROM: `1` and dmesg `a52sxq_sd_ioerror: Send Notification about SD Card IO Error
  (IOERROR=YES)`. One UI: SystemUI's observer on `DEVPATH=/devices/virtual/sec/sdcard` fires (its SD
  card error notification; the exact text and whether it needs a mounted card were not read
  offline: report what logcat / the notification dump show, with and without a card).
  LineageOS/IchthysOS: nothing listens (AOSP has no such notification); only `noti` counts.
  Unload: `adb -s $S shell su -c 'rmmod a52sxq_sd_ioerror'`.

Real-error path (hands, spare card only, optional): a worn card that returns ECC/GE status counts in
`sd_data`; not something to provoke on a good card, never on the broken-screen phone's own card.
