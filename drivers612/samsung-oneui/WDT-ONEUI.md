# Hypervisor watchdog for the OneUI 9 builds on 6.12

**2026-11-24: final default design = `WDT=oneui` (section A). Built and proven offline (source + QEMU). Never run on a
phone.** The 2026-11-22 proposal (stock modules, `WDT=1`) is kept unchanged as section B; three of its statements are
corrected in A.6. Nothing here flashes anything; build-realboot.sh is not edited (proposed diff in `wdt/`).

Paths: `K` = bsp612/kernel, `SOC` = bsp612/soc-repo, `V` = drivers612/samsung-oneui/wdt (the variant; line numbers of
`V/qcom_wdt_core.c` and `V/gh_virt_wdt.c`), 5.4 = ~/git/kernel_a52sxq_bone.

## A. Final design (2026-11-24)

### A.1 The default
| Item | Value | Why |
|---|---|---|
| Modules | `V/out/qcom_wdt_core.ko` 5d3d3dfd... + `V/out/gh_virt_wdt.ko` 029df202... (same names, same 5 exports with the same CRCs as the dist modules), first stage right after stage `secure`, `qcom_soc_wdt` blocklisted | as WDT=1; the ABL disables /soc/qcom,wdt@17c10000 and adds /hypervisor/qcom,hh-watchdog |
| Pet | 9360 ms, RT kthread `gh-watchdog` (SCHED_FIFO 99), IPI ping of the CPUs that are not in idle power collapse | = 5.4 and stock 6.12 |
| Bark | **20000 ms** (stock 11000) | the bark handler bites at once (V core :797), so bark is the real limit. 11 s leaves 1.38 s for a late pet; 20 s survives one completely missed pet period (2 x 9.616 s = 19.23 s) |
| Bite | bark + 3 s = 23000 ms | stock rule; a hang with dead interrupts resets after at most 23 s of CPU-busy time (stock 14 s) |
| Panic | **normal restart path** (`bite_on_panic=0`); stock turns every panic into a watchdog reset | a panic then ends exactly as on today's builds without the watchdog (proven to reboot); the only new reset type is the bite on a real hang, where the alternative is a frozen phone |
| Suspend (s2idle, the only state the phone uses: 130 "suspend entry (s2idle)" lines in logs/, none deep) | disarmed in `suspend_late`, re-armed in `resume_early`; **a watchdog that cannot be disarmed refuses the suspend** | never asleep with an armed, unpetted watchdog |
| Armed at kernel entry (other bootloader, kexec) | **adopted** (stock: probe fails and leaves it armed without pets) | no dependence on the per-phone STATUS read any more |
| DT / cmdline / modules.options | none | parameters only for deviations: `qcom_wdt_core.bark_ms= pet_ms= bite_on_panic=`, `gh_virt_wdt.enable=0` (kernel command line or modules.options; Android's libmodprobe reads module options from /proc/cmdline, $ANDROID_TREE/system/core/libmodprobe/module_config.cpp:329) |
| Off switch for one boot | `gh_virt_wdt.enable=0`: probe disarms if armed and does not register (V gh :298-302) | recovery from an unexpected bite loop without a new build (needs a cmdline edit = a boot image; for the kexec rehearsal a plain cmdline word) |
| Userspace | no /dev/watchdog, userspace pet off (`# CONFIG_QCOM_WATCHDOG_USERSPACE_PET`, bsp612/out/lahaina/.config:9205); read-only `a52_stats` and `vwdt_status` in the device's sysfs dir | verification without the hhwdt test module |

Build line = the kernel line's current OneUI command with `WDT=oneui` (needs
`wdt/build-realboot-WDT_oneui.proposed.diff`: adds the option next to WDT=1, checks vermagic + that the two files are
the variant, blocklists qcom_soc_wdt, BUILDINFO `wdt=oneui`). Expected differences to the same build with wdt=0:
first.load +2, blocklist swap, nothing else.
Packaging trial 2026-11-24 (temporary patched copy of the script, `WDT=oneui QEMU_TEST=0`, rbou9's ramdisk s99ou9 and
the 9.3.173 dump, option list reconstructed; script copy and output deleted again): "WDT=oneui: a52 qcom_wdt_core
5d3d3dfd + gh_virt_wdt 029df202 after stage secure", modules.load lines 100/101, blocklist `qcom_soc_wdt`, insmod
simulation 282 ok / 0 FAIL, BUILDINFO `wdt=oneui`, all offline checks passed, tools/qemu-initrd-check.sh PASS.

### A.2 What was changed in the driver and why (`V/a52-wdt-core.diff`, `V/a52-wdt-gh.diff`; originals in `V/orig`)
1. **Adopt an armed watchdog.** Stock `gh_enable_wdt` always sends CONTROL 3; its own comment says the hypervisor
   answers with an error when it is already enabled (SOC/drivers/virt/gunyah/gh_virt_wdt.c:153-155). `qcom_wdt_init`
   then returns the error (SOC core :819-834) AFTER it has rewritten bark/bite to 11/14 s (:793-794) and the probe
   fails (:909-912): an armed watchdog, no pet thread = reset loop. That is the real reason the rehearsal needs
   `KEXEC_WDT=0`, and it would hit any bootloader that hands over an armed watchdog. Variant: STATUS first, armed ->
   return 0 (V gh :160-185). STATUS a1 bit 0 = armed is proven on the phone (a1=0x0 before, 0x1 after loading, rb56;
   "vWdog-CTL: 1" in logs/wdt-rb56/console-ramoops-after-panic.txt:2133).
2. **Suspend with a failed disable.** Stock ignores the result of `disable_wdt`, sets `enabled = false` and has
   already deleted the pet timer (SOC core :186-193). If the hypervisor refused, the phone sleeps armed and unpetted.
   Variant: the gh backend reports what STATUS says after CONTROL 2 (V gh :224-233); on an error the core puts the pet
   timer back and returns -EBUSY (V core :218-236); the PM core then aborts the suspend and does not call
   `resume_early` for the device whose `suspend_late` failed (K/drivers/base/power/main.c:1447-1457, :800).
   Visible as `/sys/power/suspend_stats/last_failed_dev` = the watchdog device and `suspend_aborts` in a52_stats.
   Cost if it ever happens: no suspend (battery), no reset.
3. **Resume with a failed enable**: recorded (`resume_enable_fails`), `enabled` stays false, so the next suspend does
   not ask the hypervisor to disable a disabled watchdog (which would hit rule 2); the next resume tries again
   (V core :255-266). Stock set `enabled = true` regardless.
4. **Panic**: `restart_wdog_handler` bites only with `bite_on_panic=1` (V core :400). The panic notifier still runs:
   with `CONFIG_PANIC_TIMEOUT=-1` (bsp612/out/gki/.config:8005) it pets and sets bark = bite = 9 s (V core :317-321,
   :335-338), then `panic()` calls `emergency_restart()` (K/kernel/panic.c:435-443). So a panic whose restart hangs
   is still ended by the watchdog after 9 s.
5. **u16 clamp**: the hypervisor takes u16 milliseconds (`(u16) time`, SOC gh :75, :105). Stock passes
   `(panic_timeout + 10) * 1000` unchecked: `panic=60` would arm 4.4 s. Clamped to 1..60 s (V core :317); bark_ms is
   clamped to pet + 1 s .. 57 s (V core :945-946).
6. `delay_time` in the pet thread was only set while enabled (0 = a timer firing every jiffy after rule 3); now always
   the pet time (V core, pet thread). Counters + `a52_stats`, `vwdt_status` (read-only STATUS, the call the diag
   Image's a52bc already makes at every boot).

Not changed: pet period, IPI ping, the bark handler, `panic_timeout == 0` -> watchdog disabled (stock; our builds use
-1: a build with `panic=0` on the command line must not enable the watchdog), no `.shutdown` (armed through
reboot/power-off: a hung shutdown is reset after 23 s instead of freezing; a clean one reaches PSCI reset/off first).

### A.3 Safety claims and their proof
| # | Claim | Proof |
|---|---|---|
| 1 | Before the module loads nothing can bite on bit-2 and bit-5 bootloaders | STATUS at kernel entry `a0=0 a1=0x0` measured on both. Other bootloaders: unknown at entry, but an armed one is adopted at ~1.7 s (A.2-1); 5.4 pets from 0.43 s |
| 2 | The pet thread is not stopped by the freezer | kthreads are PF_NOFREEZE (K/kernel/kthread.c:751), the thread never calls set_freezable (0 hits in V core); freezer skips PF_NOFREEZE (K/kernel/freezer.c:44) |
| 3 | A slow device suspend/resume callback cannot starve the pet | pets come from that separate SCHED_FIFO 99 thread (V core :629) woken by a non-deferrable timer (V core :887, flags 0); the suspend thread blocking in a callback does not hold either. (Corrects B: "callback longer than 14 s = reset" is wrong. It also means the watchdog does not catch a hung suspend callback; 5.4 had DPM_WATCHDOG 5 s for that, 6.12 has none) |
| 4 | Pet period worst case 9.616 s | 9360 ms at HZ=250 is wheel level 2, granularity 256 ms (K/kernel/time/timer.c:131-136); QEMU measured max gap 9473-9571 ms |
| 5 | From suspend_late to resume_early the watchdog is disarmed | V core :207-241: pet, timer deleted, `disable_wdt` for PM_SUSPEND_TO_IDLE; `pm_suspend_target_state` is set before any device callback and cleared after all of them (K/kernel/power/suspend.c:512, :548; dpm_suspend_late :416, dpm_resume_early :493). QEMU: 26 s and 27 s inside suspend with bite at 23 s, 0 barks |
| 6 | Before suspend_late and after resume_early it is armed AND petted | timer runs until V core :213 (`del_timer_sync` in suspend_late), re-added in resume_early before `freeze_in_progress` is cleared (V core :281-285); race with the pet thread closed by `freeze_lock` (stock). QEMU step pmtest-devices (suspend stopped before suspend_late): stays armed, pets continue |
| 7 | An aborted suspend leaves it armed and petted | abort before suspend_late: nothing was touched; abort in/after suspend_late: `dpm_resume_early` runs for every late-suspended device (K main.c:1521, :1543); own failure: A.2-2. QEMU steps faildisable, faildisable+12 |
| 8 | Never asleep armed | A.2-2. QEMU negative control with the STOCK dist core and the same refused disable: "WDTSIM: BARK ... 11029 ms since the last pet" (`wdt/qemu-test/result-dist.txt`) |
| 9 | A panic behaves as without the watchdog | A.2-4; stock path for comparison: logs/wdt-rb56/console-ramoops-after-panic.txt ("Causing a QCOM Apps Watchdog bite!") |
| 10 | A bite ends in a normal boot without keys | bit 2: measured, hang -> Android in 75 s. Bit B (A528BXXSBGYI3) under OneUI 5.4: the testers' "random reboots" of 11-11 and 11-13 were watchdog bites that rebooted by themselves (TZBSP_ERR_FATAL_NON_SECURE_WDT; "Causing a QCOM Apps Watchdog bite"). **Bit 5: not measured** (bracketed by 2 and B) |
| 11 | Idle and power-off charging cannot bite | the pet timer is not deferrable (wakes an idle CPU); measured: 9 min doze on bit 5, 15 min screen off on the modem phone |
| 12 | Existing modules are unaffected | exports + CRCs identical to dist qcom_wdt_core.ko (`wdt/build.sh` checks); vermagic checked by samsung-oneui/build.sh |

### A.4 QEMU test (`wdt/qemu-test/run.sh`, ~2.5 min, offline)
The hypervisor calls cannot run in QEMU, so `wdt/sim/a52_wdt_sim.ko` stands in for gh_virt_wdt: same six ops, same
dev_pm_ops, and a model of the hypervisor side (armed flag, bark time, boot-time clock since the last pet, which
includes the time asleep). It prints "WDTSIM: BARK" whenever an armed watchdog went unpetted longer than the bark
time. The core under test is the shipped binary `wdt/out/qcom_wdt_core.ko` on the bsp612 GKI Image with the real
minidump/qcom-scm dependency chain. Result 2026-11-24: **PASS, 17/17** (`wdt/qemu-test/result-a52.txt`):
armed at load 20000/23000; pets while idle; pm_test=devices (stops before suspend_late) stays armed; pm_test=platform
5 s and 26 s: disarm/re-arm, no bark; refused disable: `echo freeze > /sys/power/state` fails, last_failed_dev names the
device, errno -16, pets continue, 0 barks over a further 26 s attempt; failed enable on resume: recorded, disarmed,
next resume re-arms; real s2idle with an RTC wake after 27 s: 0 barks; 0 WARNING/BUG/Oops.
`CORE=dist qemu-test/run.sh` = negative control with the stock dist core: 2 barks in the refused-disable step.
Not covered by QEMU: the three changed gh_virt_wdt functions (reviewed, compile-checked only), the real hypervisor.

### A.5 Residual risks
1. **Never run on a phone.** No suspend/resume with any watchdog module has been recorded on hardware (0 logs with
   both "QCOM Apps Watchdog Initialized" and "PM: suspend exit").
2. Bite behaviour of the bit-5 bootloader is inferred (A.3-10), not measured. If it stopped in upload mode the phone
   would need keys, which is also what a frozen phone needs today.
3. The hypervisor's answer to CONTROL 2/3 in every state is known only from the proven sequences (arm at load,
   disarm by the harness and a52bc.wdt=off). A refusal now costs suspend (rule A.2-2), not a reset.
4. A CPU that keeps interrupts off for more than ~10 s is reset (stock: ~1.4 s). No such section is known on 6.12; a
   driver that has one will show as bites with "cpu alive mask" in console-ramoops.
5. `panic=0` on the command line disables the watchdog at a panic (stock behaviour, kept).
6. Hang inside the window where it is disarmed (suspend_late .. resume_early, incl. s2idle itself) is not caught, as
   on stock 6.12. (5.4 keeps it armed in suspend and relies on the counter freezing: 5.4 qcom_wdt_core.c:320-331.)
7. qcom_wdt_core's sysfs `disable` (root, 0600) followed by a suspend re-arms the watchdog on resume without its bark
   IRQ (stock bug, unchanged; nothing in the ROM writes that file).

### A.6 Corrections to section B
* "A slow device suspend/resume callback longer than 14 s = reset": wrong, see A.3-3.
* "an 'armed at entry' bootloader is safe WITH the driver": wrong for the stock modules (A.2-1), true for the variant.
* "disabled across suspend by the driver": only if the hypervisor accepts the disable; the stock core does not check.

### A.7 Verification on a phone
Read-only, any phone with a `WDT=oneui` build (root shell; nothing is written):

    D=$(dirname "$(find /sys/devices/platform -name a52_stats 2>/dev/null | head -1)"); echo "dev=$D"
    cat "$D/a52_stats" "$D/vwdt_status"; grep . /sys/module/qcom_wdt_core/parameters/* /sys/module/gh_virt_wdt/parameters/*
    cat /proc/sys/kernel/random/boot_id; cat /proc/uptime
    grep . /sys/power/suspend_stats/success /sys/power/suspend_stats/fail /sys/power/suspend_stats/last_failed_dev
    dmesg | grep -iE 'watchdog|vWDT|vWDOG'; ls /dev/watchdog* 2>/dev/null
Expected right after boot: `enabled=1 bark_ms=20000 bite_ms=23000 pet_ms=9360 bite_on_panic=0`, `armed=1 expired=0`,
`since_pet` below ~9700, "QCOM Apps Watchdog Initialized" (or "vWDT already armed: adopted" first), no /dev/watchdog.
On a build WITHOUT the watchdog: no /sys/module/gh_virt_wdt, and the diag Image's `a52 vwdt STATUS` line in dmesg
must say `a1=0x0`.

Order on broken screen (PHONE1), stop at the first failure:
1. Build with the proposed diff; insmod simulation count = base + 2; tools/qemu-initrd-check.sh; `wdt/qemu-test/run.sh`.
2. Kexec rehearsal, once with `KEXEC_WDT=0`, once with the harness watchdog armed (expect "already armed: adopted").
3. Real boot through the proven zip route; the read-only block above.
4. 10 min idle + the OneUI sweep, 5 min load (rb78 recipe), 15 min screen off on USB: boot_id unchanged,
   `max_pet_gap_ms` < 10000, `suspend_aborts=0 resume_enable_fails=0`.
5. Suspend, key-free and passive: leave the phone off the cable (dwc3 holds a wakeup source while the PC link is
   up) for the night or use adb over Wi-Fi; afterwards the read-only block: boot_id unchanged, uptime continuous,
   `suspends` = `resumes` > 0 and equal to the rise of suspend_stats/success, `suspend_aborts=0`,
   last_failed_dev not the watchdog, `max_pet_gap_ms` < 10000.
6. Reboot, reboot recovery, reboot download, power off, kernel switcher 6.12 -> 5.4 -> 6.12: no bite (the phone does
   what was asked; after the next boot ro.boot.bootreason is not watchdog).
7. Power-off charging: one full charge in lpm without a reset.
**Needs someone at the phone (test phone only, never the daily or a tester's phone):**
8. `echo c > /proc/sysrq-trigger`: expect a normal reboot, bootreason kernel_panic, console-ramoops WITHOUT
   "Causing a QCOM Apps Watchdog bite".
9. Deliberate hang: `insmod drivers612/realboot/modules/wdttest/a52_wdttest.ko mode=2` (all CPUs spin, IRQs off):
   expect a self reset within ~25 s and a normal boot without keys; if the phone stays in upload mode or dark, the
   bit-5 bootloader does not reboot after a bite: hold Vol-down+Power, and the default goes back to wdt=0 for bit 5.
Only after 1-7: `WDT=oneui` in the switcher build; 8-9 decide whether it stays the default for public bit-5 phones.

### A.8 Files
`wdt/build.sh` (re-bases check + build + export check), `wdt/Kbuild`, `wdt/qcom_wdt_core.c`, `wdt/gh_virt_wdt.c`,
`wdt/orig/*` (soc-repo de95aa3), `wdt/a52-wdt-core.diff`, `wdt/a52-wdt-gh.diff`, `wdt/out/*.ko`,
`wdt/sim/{Kbuild,a52_wdt_sim.c,out/a52_wdt_sim.ko}` (dc89f425..., QEMU only, never shipped),
`wdt/qemu-test/{run.sh,init.sh,result-a52.txt,result-dist.txt}`, `wdt/build-realboot-WDT_oneui.proposed.diff`.
sha256: qcom_wdt_core.ko 5d3d3dfde567aaeea7ac3f7064a02bd099ee5d9403601eca8fae9f958ebfeca5,
gh_virt_wdt.ko 029df202b8ecfbf8a462747d81f4fa68efad339e6458478df656c48e23ba6ba1.

---

## B. History: the 2026-11-22 proposal (stock modules, WDT=1), unchanged

### Hypervisor watchdog (WDT=1) for the OneUI 9 builds: what it does, what to verify first (2026-11-22, offline)

Nothing here was run on a phone today. Proposal only: build-realboot.sh is not edited.

### What WDT=1 does (drivers612/realboot/build-realboot.sh)
- :499-505 adds dist `qcom_wdt_core.ko` + `gh_virt_wdt.ko` to the first-stage load list right after stage `secure`.
- :654-658 takes both off the modules.blocklist and blocklists `qcom_soc_wdt` instead (the ABL sets
  `/soc/qcom,wdt@17c10000` status=disabled and adds `/hypervisor/qcom,hh-watchdog`).
- :1299 records `wdt=1` in BUILDINFO. No cmdline word, no modules.options line, no DT change.
- `hhwdt` is only the bring-up test module (STATUS read, raw arming); the build refuses it in any load list (:554, :571, :725).
- Driver settings, bsp612/out/lahaina/.config:9195-9204 and :9403 = the 5.4 values
  (kernel_a52sxq_bone a52sxq_kor_single_defconfig:4930, :5447-5458): bark 11000 ms, pet 9360 ms, bite = bark + 3 s,
  IPI ping on, WAKEUP_ENABLE on, userspace pet off, `QCOM_FORCE_WDOG_BITE_ON_PANIC=y`.
- Suspend: gh_virt_wdt.c:265-271 `suspend_late`/`freeze_late` -> `qcom_wdt_pet_suspend`, `resume_early`/`restore_early` ->
  `qcom_wdt_pet_resume`. qcom_wdt_core.c:186-202: pet once, delete the pet timer, and for PM_SUSPEND_MEM or
  PM_SUSPEND_TO_IDLE `disable_wdt`; :231-241 on resume: timer back, bark/bite times set again, enabled.
  So the watchdog is off between suspend_late and resume_early and live during the earlier suspend phases.
- Panic: qcom_wdt_core.c:270-284 + :346-352: with FORCE_WDOG_BITE_ON_PANIC a panic ends in a deliberate bite
  ("Causing a QCOM Apps Watchdog bite!"), i.e. the reset the bootloader sees is a WATCHDOG reset, not a clean restart.

### What is already proven
- rb56, white cable, bit-2 bootloader, LineageOS: STATUS before `a0=0 a1=0x0` (ABL leaves it disarmed),
  with WDT=1 `a1=0x1`; deliberate all-CPU hang -> self reset, booted again in 75 s without keys; sysrq-c panic -> bite,
  back in 59 s, pstore kept.
- bit 5: STATUS at kernel entry `a0=0 a1=0x0`; rbich14 with WDT=1 booted, 9 min doze idle, no reset.
- rb78, modem phone: 5 min full load + 15 min screen off, no bite.
- NOT proven anywhere: a real suspend/resume with the watchdog loaded; any run under OneUI; any run on a bit-A
  bootloader; a bite or panic on bit 5 (what the bit-5 bootloader does after a watchdog reset).

### What must be verified under OneUI before it is enabled in the switcher build
1. STATUS at kernel entry on the phone that gets the build. Broken screen is bit 5 = already read once (disarmed).
   A public build cannot do the read; the driver arms and pets either way, so an "armed at entry" bootloader is safe WITH
   the driver. The read matters for the builds WITHOUT it (today's state).
2. Real suspend. OneUI suspends more often than the test ROMs (Freecess, sync_on_suspend 0). The window of risk is the
   part of suspend BEFORE suspend_late and of resume AFTER resume_early: the pet kthread must keep running there.
   A slow device suspend/resume callback longer than 14 s (bark 11 + 3) = reset. 5.4 had `DPM_WATCHDOG` 5 s for that
   case, 6.12 has none. Needs the cable pulled (dwc3 blocks suspend while the PC link is up) = an owner step.
3. Panic path under this bootloader. With WDT=1 every panic becomes a watchdog bite. Samsung's XBL classifies
   warm resets ("Warm Reset by Kernel Panic / Watchdog Bite", FIRMWARE-KERNEL-ASSUMPTIONS.md:105-111). On bit 2 the phone
   came back by itself; on bit 5 it is unverified. If the bit-5 bootloader stops in upload mode after a bite the user
   needs keys, so do NOT provoke a bite on a phone until a reset without WDT (plain panic, panic_timeout reboot) has been
   seen to boot normally there, and do the first deliberate bite with someone at the phone.
4. ksuinit crash guard: after a bite pstore holds a panic record, the next boot skips KernelSU once (root missing for
   one boot is expected, not a failure).
5. Power-off charging (lpm): the modules load in first stage in charger mode as well; the phone sits idle for hours
   with the screen off. Check one full charge in lpm without a reset once lpm works on 6.12.
6. Kexec rehearsal needs `KEXEC_WDT=0` (the harness's own 60 s arming conflicts). TWRP is unaffected
   (its own kernel).
7. Nothing in OneUI userspace opens a watchdog device: the driver registers no /dev/watchdog and userspace pet is off
   (config above). Unverified on the phone: `ls /dev/watchdog*` should be empty on both kernels.

### Proposed build line
The rbou5d command itself is not recorded; this is rebuilt from drivers612/realboot/out/rbou5d/BUILDINFO
(check it against the shell history before use; DUMP = the ROM version on the phone at that time):

    DUMP=$PWD/testdev-PHONE1/oneui9-9.3.165 REF=$PWD/drivers612/androidboot/out/s99tb-rd.cpio.gz \
    DIAG=1 DIAG_BOOTARGS=none MODEM=1 SDCARD=1 USBAUDIO=1 QRNG=1 HALL=1 VOLKEY=1 BWCOMPAT=1 ADSPFAC=1 KSU=1 LPM=1 \
    ICE_RAW=1 UFS_QOS=0 UFS_WB=always THERMAL_X="qmi adctm bclmap secth" ARGOS=1 SHM_BRIDGE_OFF=1 \
    WDT=1 drivers612/realboot/build-realboot.sh rbou6w

Expected differences to rbou5d: first.load +2 (qcom_wdt_core, gh_virt_wdt after stage secure), blocklist swaps the two
for qcom_soc_wdt, BUILDINFO wdt=1. Everything else byte-equal inputs.

### Test list (broken screen PHONE1, in this order; stop at the first failure)
1. Build, insmod simulation count = rbou5d + 2, tools/qemu-initrd-check.sh PASS.
2. Rehearsal (kexec) with KEXEC_WDT=0: reaches the same stage as the rbou5d rehearsal.
3. Real boot via the proven zip route. dmesg: "QCOM Apps Watchdog Initialized"; no "bark" line.
   `cat /sys/devices/platform/hypervisor/hypervisor:qcom,hh-watchdog/wakeup_enable` (path unverified: find the
   `hh-watchdog` platform device) = 1.
4. 10 min idle screen on + the OneUI sweep (tools/selftest/oneui/sweep.sh): same PASS count as rbou5d, boot_id unchanged.
5. 5 min load (the rb78 recipe: 8 busy loops + fsync writes + GL): boot_id unchanged.
6. 15 min screen off on USB (doze, no suspend): boot_id unchanged.
7. OWNER STEP (attention bell): cable out for 10 min, screen off; then cable in: boot_id unchanged,
   /sys/power/suspend_stats success > 0, last_failed_dev empty, uptime continuous. Repeat once with Wi-Fi + SIM active.
8. Kernel switcher 6.12 -> 5.4 -> 6.12 once (reboot paths with the watchdog loaded: clean reboot must not bite;
   reboot recovery / reboot download likewise).
9. Power off (shutdown path: qcom_wdt_core shutdown must not bite during a slow OneUI shutdown; watch that the phone
   stays off).
10. Only with someone at the phone and after item 3 of the verify list: sysrq-c panic -> back by itself?
    Then the all-CPU hang (drivers612/realboot/modules/wdttest/a52_wdttest.ko mode=2).
Only after 1-9: propose WDT=1 for the switcher zip; 10 decides whether it is safe for public users on bit 5.
