# lpm: power-off charging (Samsung `lpm`) on 6.12 — nodes, the real gap, what else it needs

2026-11-22, OFFLINE (sources, ROM work dir strings, QEMU). Nothing here was loaded on a phone. Power-off charging has
never been run on 6.12.

## 1. The nodes that were asked for: what 5.4 really has

Readers (strings of `~/git/MonsterROM/out/target/a52sxq/work_dir/system/system/bin/{lpm,resetreason}`): `lpm` names
all of them; `resetreason` names `/proc/extra`, `/proc/pwrsrc`, `/proc/store_lastkmsg` (it appends the pwrsrc line to
the eRR.p log: `AppendInfoFromPwrsrc`). Both binaries are generic Samsung (Exynos/MTK/sprd paths too); a path in
them is not proof that it exists on an A52s.

| Node | 5.4 source (kernel_a52sxq_bone = sm7325 tree) | On the ROM's 5.4 (a52sxq_kor_single_defconfig) | 6.12 | Done here |
|---|---|---|---|---|
| `/proc/pwrsrc` | none. `sec_hw_param.c:1397` has a sysfs `pwrsrc` attr whose body is commented out (`return 0; //sec_get_pwrsrc`) and whose group is never registered | absent | absent | NOT created (no data, see below) |
| `/sys/class/sec/pm/pwr_on_off_src` | none in either 5.4 tree | absent | absent | NOT created |
| `/proc/extra` | `sec_hw_param.c:1460`, `CONFIG_SEC_DEBUG`; mode `S_IWUGO` (0222) + seq read; prints ` RR:.. PANIC:.. PC:.. LR:..` only after a crash reset stored in the debug partition, else 0 bytes | absent (`# CONFIG_SEC_DEBUG is not set`, line 6115); present on stock/Lineage configs | absent | `a52sxq_lpm_nodes.ko`: 0222, empty read (= 5.4 after a clean boot) |
| `/proc/reset_reason`, `/proc/store_lastkmsg` | `sec_debug_user_reset.c:1290/1310`, `CONFIG_SEC_USER_RESET_DEBUG` | absent (not set, line 6151) | absent | not created: 6.12 cannot know the crash reason; a constant "NPON" after a panic would be a lie |
| `/dev/power_on_alarm`, `/sys/class/rtc/rtc0/alarm_boot` | `drivers/rtc/power-on-alarm.c`, `drivers/rtc/sysfs.c:126`, `CONFIG_RTC_AUTO_PWRON` | absent (`# CONFIG_RTC_AUTO_PWRON is not set`, line 4860, also in the Lineage config) | absent | nothing: "alarm rings while powered off" does not exist on 5.4 either |
| `/dev/batt_misc` | `sec_battery_misc.c`, only with `CONFIG_WIRELESS_AUTH` (`drivers/battery/common/Makefile:11`) | absent (no wireless charging) | absent (not in `drivers612/power/Kbuild`) | nothing |
| `usb_notify/usb_control/lpm_charging_type_done` | no such attribute in 5.4 `drivers/usb` | absent | absent (our typec manager calls `set_lpm_charging_type_done()` only under its ifdef) | nothing |
| `/sys/class/sec/rtc/rtc_status`, `/sys/power/rtc_status` | none | absent | absent | nothing |

**PON reason: there is no data source.** The PMK8350 PON is GEN3; 5.4 `qpnp-power-on.c:2411` returns before the
reason read with "PON_GEN3 does not have PON/POFF reason registers". The Exynos-style `OFFSRC/ONSRC/RST_STAT` values
`resetreason` prints come from `ro.boot.offsrc_m/offsrc_s/onsrc/rststat`, which this bootloader does not pass (not in
the 5.4 cmdline). Inventing ONSRC bits from nothing could steer `lpm` (it also opens these two paths) -> not created.
The SELinux side would be ready (`genfscon proc /pwrsrc`, `/extra`, `/reset_reason`, `/store_lastkmsg` are in the ROM
policy), so a later real implementation needs no ROM change.

Conclusion: power-off charging works on the ROM's 5.4 with NONE of these nodes. They are not what 6.12 is missing.

## 2. The real gap found: `lpcharge` is never set on 6.12

5.4: the bootloader's lpm boot is seen by built-in code: `sec_mparam.c:21` (`module_param(lpcharge)` -> cmdline
`sec_mparam.lpcharge=1`; the normal-boot cmdline carries `sec_mparam.pmic_info=3 sec_mparam.fg_reset=0`) and
`early_param("androidboot.mode")` == `charger` (`sec_debug_user_reset.c:91`, `sec_log_buf.c:58`, `pdic_param.c`).
6.12: `sec-battery.ko` and `sm5714_fuelgauge.ko` each have a private `static lpcharge` module param
(`sec_battery.c:50`, `sm5714_fuelgauge.c:53`) that only `sec-battery.lpcharge=1` / `sm5714_fuelgauge.lpcharge=1` could
set; nothing writes those words (README of drivers612/power line 163: sec_mparam not ported). Only the PDIC side was
fixed on 11-18 (`pdic_param.c is_lpcharge_pdic_param()` reads `/chosen/bootargs`). So in power-off charging on 6.12
the battery driver would run its NORMAL-boot logic.

What `lpcharge` changes in 5.4 `sec_battery.c` (same code in our port): 2301 VBUS back to 5 V after 2nd full; 3293
store-mode; 3521 no wireless auth retry; 3766/4238/4390 USB (SDP) cable current rules; 4108 usb_thm reset; 4869/4878
store mode; 4921 slow-charging-until-bootcomplete is skipped in lpm; 4940 health OVP/UVLO/DC_ERR reported GOOD (so
`lpm` keeps the animation instead of an error screen); 5256 undefined-range event; 6084 PD/MUIC notify order; 6164
usb thermistor; `sec_battery_sysfs.c:588` `batt_lp_charging` (prints 1 only in lpm); thermal `check_lpm_power`; ttf.
Fuelgauge: 1571 no low-voltage alarm irq handling, 1944 no SW V-empty in lpm (an empty battery on the charger must
not power the phone off again).

Fix (module side only, no cmdline/ROM change):
* `a52_lpm_bootargs.h`: `a52_bootargs_lpm()` = whole-word match in `/chosen/bootargs` of `androidboot.mode=charger`,
  `sec_mparam.lpcharge=1`, `sec-battery.lpcharge=1`, `sec_battery.lpcharge=1`, `lpcharge=1`.
* `0001-sec-battery-fuelgauge-lpcharge-from-bootargs.patch` (`patch -p1` in `drivers612/power`; NOT applied there):
  both module inits set `lpcharge = 1` when the param is 0 and the bootargs say lpm; sec-battery logs
  `sec_battery_init: lpcharge=N`.
* `build-power.sh` builds a patched COPY (`tree/`, ignored) -> `out/sec-battery.ko` (685088 B, 21a918f9b34caab2),
  `out/sm5714_fuelgauge.ko` (148424 B, e2b6c0df740da4f6). `CRC-CHECK.txt` vs the modules shipped in rbou5d: 79/79
  export CRCs identical, modinfo identical, imports = the old list + `of_chosen`, `strstr`
  (+ `of_property_read_string` in the fuelgauge), all three GKI vmlinux exports -> drop-in swap, no other rebuild.
* `a52sxq_lpm_nodes.ko` (15184 B, 4c6e36df374b37e0, no deps): `/proc/extra` + read-only
  `/sys/module/a52sxq_lpm_nodes/parameters/lpm` (the same detection, to read from a shell / dmesg line
  `a52sxq_lpm_nodes: lpm=N`).
* `mk-s99u.sh` -> `drivers612/androidboot/out/s99u-rd.cpio.gz` (sha256 feab4a86...f7d328) = s99tb (rbou5d) with the
  two modules swapped (stage powerpd) + `a52sxq_lpm_nodes.ko` appended to stage vibrator. No build made from it yet.

Tests: `qemu/run.sh` PASS 31/31 on the dist GKI Image: 5 command lines (normal + `sec_mparam.lpcharge=0` -> 0;
`androidboot.mode=charger` -> 1; `sec_mparam.lpcharge=1` -> 1; near misses `charger2`, `xlpcharge=1`, `lpcharge=10`
-> 0; trailing `lpcharge=1` -> 1), `/proc/extra` 0222 root:root, 0-byte read, write refused, rmmod removes it,
reload, no WARN. NOT tested: the patched sec-battery/fuelgauge at runtime (QEMU has no sm5714; only compiled +
CRC-checked; the detection code they call is the header the QEMU test covers).

UNVERIFIED: the exact words this bootloader (FWK4, bit 5) writes for an lpm boot. `androidboot.mode=charger` is what
the 5.4 code and the ROM's `on charger` trigger depend on, so it must be there; the rest of the list is belt and braces.

## 3. What else power-off charging needs from the kernel (read from 5.4 + the ROM)

Userspace path: `ro.bootmode=charger` -> init `on charger` (`init.sec-charger.rc`): mounts `sec_efs` on /efs and
`cache` on /cache (ext4), writes `battery/batt_update_data`, `class_start sec-charger` -> `service lpm`
(`user root`, **`critical`**). No SurfaceFlinger, no HWC, no modem, no adb.

1. **`critical` service**: if `lpm` dies 4 times in 4 min init reboots to the bootloader. On this phone that can
   end in Download mode = manual key presses. First test only with someone at the phone and the Odin rollback at hand.
2. **Display without HWC**: `lpm` opens `/dev/dri` itself (legacy/atomic KMS master) or `/dev/graphics/fb0`, and
   writes `/sys/class/backlight/panel0-backlight/brightness` (present on 6.12: sweep `display.backlight` 2/2). Our
   msm_drm port has only ever been driven by the Samsung HWC; a bare DRM client (modeset + page flip + DPMS off when
   the animation times out) is untested. 5.4 display code has no lpcharge special case for the DSI panel
   (`ss_dsi_panel_*` "lpm" there = AOD low-power mode); DisplayPort is refused in lpm (`dp_display.c:283`).
3. **Battery/charger**: section 2 (the patch). Also `battery/lcd`, `online`, `voltage_now`, `support_functions`,
   `batt_lp_charging` exist on 6.12 (sweep `battery.attrs`); `ac/online`, `usb/online` are read too.
4. **Type-C/MUIC**: `is_lpcharge_pdic_param()` already works on 6.12 (patch 0006 of drivers612/power): no water
   detection irq in lpm (`sm5714_typec.c:2368`), SNK-only release (3539), MUIC early return (`sm5714-muic.c:1987`),
   water report type (`usb_typec_manager_notifier.c:1581`).
5. **Keys/touch**: power key from `/dev/input` (long press = boot), `/sys/class/sec/tsp/enabled` or
   `tsp/input/enabled` to switch the touchscreen off: check that our touch port has one of them (not checked).
6. **RTC**: `/dev/rtc0` read for the lpm timestamp log (present). No boot alarm (section 1).
7. **Vibrator**: `/sys/class/timed_output/vibrator/enable` or `leds/vibrator/*` for the plug-in buzz: neither is
   the 6.12 vibrator interface (input FF); the buzz may be missing, harmless.
8. **NFC**: 5.4 `sec_nfc.c:470-496` keeps the NFC regulator off in lpm (`nfc_param_lpcharge`); our nfc_sec port was
   not checked for it: NFC may stay powered while charging off (small drain, not a blocker).
9. **Our own boot chain in charger mode** (never exercised): `rdinit=/ksuinit`, the a52 stage loader, dsp_boot
   tunables, KernelSU. Nothing in build-realboot.sh looks at the boot mode, so the same 280 modules load
   (modem/Wi-Fi/camera included) and the remoteprocs may start (not checked which do without their userspace):
   possibly more heat/drain than 5.4's lpm. Idle power in lpm must be measured.
10. **Idle/suspend + watchdog**: `lpm` writes `/sys/power/wakeup_count` (chmod in the rc) -> it presumably suspends between
    updates (inferred from the rc, not from the binary); with WDT=1 (WDT-ONEUI.md) the suspend path must be proven first.
11. **Power-off itself**: unplug in lpm -> `lpm` powers off (`reboot -p`): needs a real power-off and
    the restart-reason left as 5.4 leaves it, so that the next plug-in starts lpm again and not Android (to test;
    sec_core's power-off path was not re-read for this).

## 4. Test plan (broken screen only, someone at the phone, after the build owner makes a build with REF=s99u)

1. Normal boot: `cat /sys/module/a52sxq_lpm_nodes/parameters/lpm` = 0, `dmesg | grep lpcharge` = 0,
   `battery/batt_lp_charging` empty, `ls -lZ /proc/extra` (`proc_extra`), charging + pass_through unchanged, the
   OneUI sweep shows no new FAIL.
2. Power off, plug in: animation + percentage within ~15 s; film it. Power key long press boots Android.
3. After that boot: `/sys/fs/pstore/console-ramoops-0` (previous kernel log): `androidboot.mode=charger` on the
   cmdline (and which lpcharge word), `sec_battery_init: lpcharge=1`, `a52sxq_lpm_nodes: lpm=1`; `/efs/lpm_boot.log`,
   `/cache/lpm/last_lpm.log`.
4. Same on 5.4 once for the reference cmdline and timing. Then: full charge in lpm (VBUS back to 5 V), unplug ->
   powers off, plug again -> lpm again (not Android), 30 min idle temperature.
