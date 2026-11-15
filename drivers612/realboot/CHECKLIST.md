# realboot CHECKLIST: what hardware still has to prove

Nothing below has been done. Each flash needs the owner's explicit OK; phone 2 (PHONE2)
only, never DAILYPHONE or OTHERPHONE. Items marked (kexec) can be checked first through the
existing test path (harness + kexec, nothing flashed); the rest only on a real boot.

## Before the first flash
- [x] Blocker: bsp612 rebuilt with `patches/bsp612-kernel-0001-arm64-COMMAND_LINE_SIZE-4096.patch`
      (14:23), kexec runs ab-s70..s74 on it reach boot_completed; `REF=s74`; `rb2` reports no
      blocker. 6.18 (`rb618-1`): ack/ already 4096, no blocker.
- [ ] Choose the kernel for the first real boot: `rb3` (6.12, longest-tested) or `rb618-2` (6.18)
      (rb2/rb618-1 are superseded: broken add-on modules.dep, README).
      Install only that build's `vendor-addon/lib/modules/5.4-gki/qca_cld3_wlan.ko` (shared path).
- [ ] 6.18 at rb16 parity (`rb618-5`, README 2g): rehearsals `rh618p2` (phone 2) and `rh618p1`
      (phone 1, modem + data) pass, incl. the new `sd`, `dcvs`, `wlan-bind` checks; the 6.18 add-on
      goes to `/vendor/lib/modules/6.18` + `6.18-wlan` (never into 5.4-gki: the 6.12 wlan.ko stays).
- [ ] (kexec) ALL (kexec) items below in one run: `./rehearse.sh 612 <name>` / `./rehearse.sh 618 <name>`
      (README 2c), then `adb -s PHONE2 shell dmesg | grep a52rh:` (PASS/FAIL per item).
- [ ] (kexec, rh612a/rh618a: rc ran, modprobe loaded nothing = modules.dep trailing blank; fixed in
      rb3/rb618-2, re-run rh612b/rh618b) vendor add-on path: `a52sxq-k61x.rc` (gated on `ro.boot.a52sxq.k61x`) waits for
      `adsp_running` and modprobes the audio set from `/vendor/lib/modules/6.1x`; macloader loads
      wlan from `5.4-gki/qca_cld3_wlan.ko` (rehearsal: RAM overlay over /vendor, no helper load).
- [ ] (kexec) Run the realboot module set itself: s74 / a8 stages + `a52sxq_dsp_boot.ko` after `dsp`,
      without the helper's `@adsp` job: ADSP and CDSP come up by the module alone
      (`dmesg | grep a52sxq-dsp-boot`, `/sys/kernel/a52sxq_dsp/{adsp,cdsp}_running`), then the
      audio stage loads and the sound card registers.
- [ ] (kexec) `sec_battery async_probe=1` instead of the background insmod: battery reads right
      (100 %, Full, USB), chargers probe, no 20 s stall.
- [ ] (kexec) the tree with the real extcon (`USB_EXTCON=samsung`): dwc3 probes after the power
      stack, USB gadget/adb works, cable unplug/replug, OTG if wanted.
- [ ] (kexec) the two-entry `firmware_class.path` without `force_sysfs_fallback`: WPSS (from
      apnhlos, rollback 5), GPU (`a660_sqe.fw`, `a660_gmu.bin` from /vendor/firmware), venus,
      camera ICP, wlan cfg/bdf files all found (`dmesg | grep -i "firmware"`).
- [ ] (kexec, optional) audio loaded BEFORE the ADSP (fixed load order): if the card still
      registers, the vendor rc can go.
- [ ] Phone's partitions still equal the dumps (`rollback/SHA256SUMS`), else re-dump + rebuild.
- [ ] Where is `ro.bpf.kver_override=5.10.239` set (`grep -rn kver_override /system/build.prop
      /system_ext/etc/build.prop /vendor/build.prop /odm/etc/build.prop /product/etc/build.prop`)?
      Only matters if `/force_debuggable` is not wanted.
- [ ] `adb remount` mode (in place / overlayfs); `df /vendor` >= 30 MB free; vendor add-on
      installed, labels (`ls -Z`), sha256 = `vendor-addon.SHA256SUMS`; 5.4 still boots with it,
      Wi-Fi and sound unchanged on 5.4.
- [ ] Backups decided by the owner (metadata, persist, efs, sec_efs, modemst1/2, fsg, fsc,
      user data). Rollback images staged on /cache and checked.
- [ ] The harness on recovery still starts by keys and its telnet works (rescue path).

## First real boot
- [ ] ABL accepts boot/vendor_boot/dtbo (no Download mode; `/proc/last_kmsg` after the next
      boot shows the ABL log; look for "ApplyOverlay" / "ufdt").
- [ ] `/proc/cmdline`: starts with CONFIG_CMDLINE + our dtb bootargs, contains
      `android_arch_task_struct_size=512`, `androidboot.bootloader=`, `msm_drm.lcd_id=`, ends
      with the ABL's last argument (`androidboot.hardware.sku=`); compare with
      `out/<name>/cmdline-predicted-4096.txt`.
- [ ] `/proc/device-tree/soc/a52sxq,realboot` and `a52sxq,realboot-base` = build name;
      `/proc/device-tree/hypervisor` present; `uh_*_region` in /reserved-memory; watchdog
      node status as on 5.4.
- [ ] First stage: `dmesg | grep "Loaded .* kernel modules"` = 190 (6.12) / 189 (6.18); no "Failed to load" /
      "init_module" errors (with `first_stage_console=2` a failing module is only logged and skipped).
- [ ] Display: splash -> boot animation without a black gap; colours normal (UBWC fix);
      brightness; touch.
- [ ] /metadata mounted from the real partition (no format!), vold metadata encryption up,
      /data mounted (f2fs, inlinecrypt), user unlock works, the existing data is there.
- [ ] `getprop ro.bpf.kver_override` = 6.12.81 / 6.18.33; netd stays up (no `netd1shot` reboot).
- [ ] ADSP/CDSP: `/sys/kernel/a52sxq_dsp/*_running`, `cat /sys/class/remoteproc/*/state`;
      audio modules from `/vendor/lib/modules/6.12` loaded (`lsmod | grep machine_dlkm`);
      sound card; speaker, earpiece, mic (`tools/tone`, `tools/rec`); no StartAudioService hang.
- [ ] Wi-Fi: macloader log, `wlan0`, MAC from efs (not the Qualcomm default), scan, **join a
      network** (never done on 6.12), traffic.
- [ ] Bluetooth on, scan, pair once.
- [ ] NFC on; fingerprint HAL up (enrolment only with the owner's OK for a screen lock).
- [ ] Camera: front and rear preview + photo + video; torch (real SM5714 fled) and flash photo.
- [ ] 6.18 only: `cat /proc/cmdline` has `sched_proxy_exec=0`; no dwc3 SMMU fault lines
      (`dmesg | grep -i "context fault"`; non-fatal in the tree, so they would only be logged).
- [ ] Sensors (32), vibrator, keys, charging + percentage, USB-PD, `sec-battery` health.
- [ ] cpufreq policies and schedutil; thermal zones; temperatures idle/load vs 5.4.
- [ ] SELinux enforcing: `dmesg | grep avc` / `logcat -b events | grep avc`; HAL deaths
      (`logcat -b crash`). Decide on a permissive diagnostic build only with the owner.
- [ ] 10+ minutes stable, no reset (watchdog, SEA/SIGBUS, panics: pstore after a reboot).
- [ ] Reboot from Android; `reboot download` lands in Download mode (sec_core); power off and
      charge while off (charger mode = modules.load fallback).
- [ ] Roll back once on purpose (dumps -> 5.4) and confirm /data still opens on 5.4 after the
      6.12 boot wrote to it.

## Daily-driver gaps (after the first boot)
- [ ] Suspend / deep sleep (no USB cable, adb over Wi-Fi), standby drain.
- [ ] Drop `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` one at a time
      (`IGNORE_UNUSED=0` builds without all three).
- [ ] Hypervisor watchdog behaviour under long load; decide on `gh_virt_wdt`.
- [ ] Thermistors (`sec_thermistor`, PM7325 gpio1/4 ADC refusal) and the Samsung thermal HAL.
- [ ] microSD (`sdhci-msm`, `cqhci` are blocked).
- [ ] Modem: needs an accepted modem image on phone 2 and the IPA/rmnet data path; then
      `MODEM=1`, `msm_sharedmem`/rmtfs, RIL.
- [ ] LineageOS OTA handling (OTA rewrites boot with 5.4: rebuild from the new dump, or a ROM
      build that carries the 6.12 kernel; `androidboot/export-prebuilt.sh` + patches).
