# drivers612/suspend: first system-suspend test of the 6.12 test Android

Written 2026-11-14 offline (no phone touched). Audits whether the best 6.12 Android run (ab-s68 /
ab-s70: `bsp612/out/dist/Image` + `s68-rd`, `a52.mods=debug,secure,display,kgsl,i2c,nfc,touch,
fingerprint,powerpd,vibrator,camera,dsp,wlanb,audio@adsp,wlan@adsp`) can suspend and resume, and
gives a test that does not detach USB, does not need the owner, and cannot leave the phone
wedged in a state only the owner's keys can end (up to the last, optional level).

Nothing here was run on hardware. "Verified" below means read in the source that is built.

## Files

| file | what |
|---|---|
| `a52susp/a52susp.c`, `build.sh` | test-only safety module (gate, deadman, wake backstops, wake-IRQ interlock, s2idle-only, usbkeep). Builds clean against `bsp612/out/lahaina` (M= build, nothing in bsp612 changed); `a52susp/a52susp-strip.ko` (48 KB) is the copy to push |
| `susp2.sh` | on-device test, one level per run (busybox sh, helper namespace) |
| `run-level.sh` | PC side of one level: pushes the two files with `tools/tput.py`, starts the script detached with `tools/tsh.py`, collects the log |
| `tools/ko-pm-audit.sh`, `tools/audit-table.py` | the offline audit (llvm-nm over every loaded .ko, unstripped build output where the shipped copy is stripped) |
| `audit-s68.tsv`, `audit-table.md` | audit output for the s68 module set (259 loads, 219 unique modules) |

## Verdict

The kernel side is closer than the logs suggest: the s2idle machinery itself (PSCI OSI cpuidle,
CLUSTER_PD genpd, rpmh-rsc flush, PDC, SPMI RTC wake) is the same code runtime idle has used
through the 45-min soak. What has never run is the device-suspend phase of ~70 modules, and
the safety net the helper arms does not cover it. Four things block or endanger a first test;
all four have a fix here:

1. **USB (hard blocker while the cable is in).** The r70 `dwc3-msm` refuses system suspend
   whenever the PC link is enumerated: `dwc3_core_prepare()` returns -EBUSY ("peripheral mode
   still active") unless the dwc3 core is runtime-suspended, which `dwc3_runtime_checks()`
   forbids while `dwc->connected`; `dwc3_msm_pm_suspend()` returns -EBUSY ("Abort PM suspend!!
   (USB is outside LPM)"). Device-mode bus-suspend LPM is **dead code in r70**: `mdwc->suspend`
   is read in `dwc3_ext_event_notify()` but never written (5.4 wrote it from
   `DWC3_CONTROLLER_NOTIFY_OTG_EVENT`, and only with `snps,bus-suspend-enable`, which the A52s
   tree never had: a 5.4 A52s on a PC with adb never sleeps either). So host-side tricks cannot
   help: even a PC that selectively suspends the port would not get the phone into LPM. (They
   would also need `adb kill-server`, since an open usbfs handle blocks host autosuspend, and the
   host `cdc_ncm` interface down, since usbnet needs remote wakeup.)
   Fix for tests: `a52susp usbkeep=1` marks `a600000.ssusb` and `a600000.dwc3` as syscore
   devices (the flag cpuidle already sets on its CPU PD devices, `dt_idle_genpd.c`). The PM core
   then skips their prepare/suspend/resume/complete; the controller stays powered and
   enumerated, the host just sees NAKs while the phone sleeps, adb and telnet continue after
   resume. No detach, no UDC rewrite, no re-enumeration. Cost: USB keeps CX/DDR votes, so the
   SoC cannot reach CX collapse; that is a later test with the cable out (owner).
2. **No hang protection inside suspend/resume.** The helper's hung_task_panic does not cover
   it: `kernel/hung_task.c` sets `hung_detector_suspended` from PM_SUSPEND_PREPARE to
   PM_POST_SUSPEND. This GKI has no `CONFIG_DPM_WATCHDOG`. The hypervisor watchdog counts busy
   time only. So a driver that blocks in a callback with idle CPUs (the typical I2C/firmware
   wait) is caught by nothing. Fix: `a52susp` deadman: two pinned timers (first and last online
   CPU) started at PM_SUSPEND_PREPARE, cancelled at PM_POST_SUSPEND; on expiry (default 120 s
   of awake time) they dump blocked tasks (sysrq w) and panic; `panic=-1` reboots, the harness or
   Android comes back by itself, ramoops keeps the console (`console_suspend=N` is set, so
   messages written during suspend reach it).
   (Correction to a guess in the audit brief: `softlockup_panic` does work: the running GKI Image
   is built from `bsp612/out/gki/.config` with `CONFIG_SOFTLOCKUP_DETECTOR=y`; only the module
   build config `bsp612/out/lahaina/.config` says "not set". No hardlockup detector exists.)
3. **A suspend that nobody wakes needs the owner.** Fix: wake IRQ interlock + backstops + a
   "shallow" s2idle level (below): `a52susp` refuses the suspend in its `suspend_noirq` unless the
   RTC alarm IRQ is wake-set and armed; an hrtimer calls `pm_system_wakeup()` after 30 s; an
   ALARM_BOOTTIME alarm (45 s) is programmed into the PMIC RTC by `alarmtimer_suspend()` even if
   the script's own wakealarm write failed; the script first proves while awake that the RTC
   alarm IRQ fires (`/proc/interrupts` count rises), or it stops.
4. **The old method (`../androidboot/susptest.sh`) must not be used.** Detaching USB lost phone 2
   twice. Two mechanisms explain why even its own deadman never fired (not proven, both visible
   in the code): (a) it ran inside a session (adb shell or telnet) that died with the USB link;
   the session's end hangs up its process group, which includes the `( sleep; sysrq b ) &`
   deadman; (b) after the unbind the helper's 3-second USB hand-over loop in
   `kexec-rd/helper2.sh` sees g1's UDC empty and races the script's UDC rewrite. Separately: the
   helper's `/leave` uses `reboot -f` and then `/rb reboot`, both of which run
   `device_shutdown()`, which blocks forever if a USB device lock is held by a wedged
   bind/unbind; only `sysrq b` (emergency_restart) skips it. Suggested for the main session
   (not changed here, shared file): in `/leave`, start `( sleep 20; echo b > /proc/sysrq-trigger ) &`
   before `reboot -f`.

Other findings, none blocking:
- **mem_sleep must be s2idle, never deep.** Upstream sc7280 suspends with s2idle on PSCI OSI;
  Qualcomm's mobile 6.12 BSP does too. "deep" exists only if Gunyah's PSCI answers
  SYSTEM_SUSPEND (unknown; the script logs `/sys/power/mem_sleep`), and the r70 drivers treat
  `PM_SUSPEND_MEM` as automotive "deepsleep": UFS goes to spm level 5 (power-off), pinctrl-msm,
  pinctrl-spmi-gpio, i2c/spi/uart geni, tsens, aoss, msm_qmp, crm, ADC take teardown/restore paths
  that lahaina never runs. `susp2.sh` writes `s2idle` and checks it; `a52susp` refuses any other
  target state in `.prepare`.
- `qcom_lpm` is not loaded (cpuidle governor is `menu`). Not needed for s2idle: the deepest PSCI
  state carries `enter_s2idle`, the CLUSTER_PD genpd powers off in `dev_pm_genpd_suspend`, and
  `apps_rsc` (a CLUSTER_PD child) flushes its sleep/wake votes from the genpd PRE_OFF notifier.
  `rpmh_rsc_write_next_wakeup()` is a no-op on yupik (`CONTROL_TCS 0`).
- `rtc-pm8xxx` in r70 defines `pm8xxx_rtc_pm_ops` but never hooks it up (`.pm` missing): its own
  `enable_irq_wake`/"free the IRQ for MEM" code never runs. The alarm IRQ is armed by the PM core
  (`dev_pm_set_wake_irq` + `device_init_wakeup`), which is enough. Wake path: PMK8350 RTC ->
  SPMI arbiter (chained, never suspended) -> PDC pin 1 -> GIC.
- `msm_show_resume_irq` is not worth loading: it copies a private `struct gic_chip_data` layout.
  `/sys/power/pm_wakeup_irq` and `pm_debug_messages` give the same answer.
- Expected early wake sources (a short sleep is still a pass): SM5714 MFD/PDIC charger and CC
  events (USB is powering the phone), sec-battery's sleep-polling alarm, touch LP-mode gestures,
  NFC field detection, power key. DSP messages (IPCC, `IRQF_NO_SUSPEND`) run their handlers but
  do not end s2idle.
- SM5714 MFD and PDIC IRQ threads wait 200 ms for their device's resume and then return
  `IRQ_NONE`; a wake by a charger event can therefore re-fire the level IRQ a few times. Noisy,
  not harmful (far from the "nobody cared" limit).
- Bluetooth on = abort: `msm_geni_serial_sys_suspend` returns -EBUSY while the BT HAL holds its
  TIOCPM clock vote. Wi-Fi on = qcacld WoW + firmware handshake, the most complex path in the
  set. Both are switched off for the first levels (they are back on after the run ends).
- Android itself does not suspend in test runs: `*telephony-radio*` (modem off) and, before s59,
  NfcService wakelocks. Even without them it would block: `dwc3-msm` holds its wakeup source
  while out of LPM, so Android's read of `/sys/power/wakeup_count` never returns. The test
  writes `/sys/power/state` directly (no `wakeup_count` handshake, so active wakeup sources do
  not abort it), and `a52susp` refuses every suspend not started by the test process
  (`allow_tgid`), so Android cannot start one in the middle.
- UFS (root, system, vendor) suspends at spm level 3 (UFS sleep + link hibern8). It is the
  scariest resume in the set; a failure shows as I/O errors, then hung tasks: hung_task panics
  once PM_POST_SUSPEND has re-enabled it, the deadman covers a hang inside the resume.
- `arm_smmu_pm_resume()` always calls `arm_smmu_device_reset()`. With usbkeep the dwc3's SMMU
  context stays in use while it is reprogrammed (same values). If that ever faults, it is a
  context-fault panic, which reboots on its own (the 6.18 run ab618-a2s1 showed that path).

## Audit table

`sleep cbs` = defined functions named like system-sleep callbacks, `wake` = imports that arm or
declare wake IRQs, `wsrc` = imports that hold wakeup sources, `PM hooks` = PM/syscore/cpu_pm/genpd
notifiers. Counted with `tools/ko-pm-audit.sh s68`, then the relevant sources were read.
Duplicate loads (the camera and dsp stages re-insmod BSP modules: "File exists") are listed
once. Not in the lists but loaded: `hhwdt`, `testguard`, `zram`/`zsmalloc` (no sleep callbacks).

| stage | module | sleep cbs | wake | wsrc | PM hooks | verdict |
|---|---|---|---|---|---|---|
| first | qcom-scm | 14 | 1 | 0 |  | freeze/thaw/restore = hibernation only; nothing for s2idle |
| first | arm_smmu | 8 | 0 | 0 |  | suspend = runtime power-off (apps_smmu has no clocks); **resume always runs arm_smmu_device_reset()** (its own comment says only hibernation needs it). With usbkeep the dwc3 keeps its SMMU mappings live across that reset: a context fault would panic (recoverable) |
| first | gh_msgq / gh_dbl | 0 | 1 | 0 |  | Gunyah message-queue / doorbell IRQs, wake capable |
| first | qcom_dma_heaps, smem | 6, 2 | 0 | 0 |  | hibernation ops only |
| first | minidump | 0 | 0 | 0 | register_pm_notifier | minidump table |
| first | crm-v2 | 1 | 0 | 0 |  | restore_noirq = hibernation |
| first | debug-regulator, icc-debug | 4 | 0 | 0 |  | debugfs names only |
| first | gdsc-regulator | 3 | 0 | 0 |  | resume_early/restore_early (hibernation HW-trigger restore); GDSCs are regulators here, not genpds: system sleep does not switch them |
| first | clk-qcom | 15 | 0 | 0 |  | hibernation restore + debugfs only: system sleep does not gate clocks |
| first | qcom_rpmh | 2 | 0 | 0 | cpu_pm_register_notifier, dev_pm_genpd_add_notifier | apps_rsc is a CLUSTER_PD child: votes flushed on GENPD_NOTIFY_PRE_OFF (works without qcom_lpm); CONTROL_TCS 0 on yupik; noirq ops only with CONFIG_DEEPSLEEP (off) |
| first | sched-walt | 5 | 0 | 0 | register_syscore_ops | syscore resume hook; needs android_arch_task_struct_size=512 (on the cmdline since s66) |
| first | qcom_cpu_vendor_hooks | 0 | 0 | 0 | register_syscore_ops | Qualcomm syscore ops |
| first | qcom-pmu-lib | 0 | 0 | 0 | cpu_pm_register_notifier | PMU save/restore around power collapse (runtime idle uses it already) |
| first | spmi-pmic-arb | 0 | 1 | 0 |  | child irq_set_wake -> irq_set_irq_wake(bus IRQ = PDC pin 1); chained parent never suspended: **the RTC wake path** |
| first | rtc-pm8xxx | 0 | 3 | 0 |  | **dev_pm_ops defined but not hooked up in r70**; alarm IRQ armed by the PM core (dev_pm_set_wake_irq): fine. Wake source of every test |
| first | qcom-pdc | 2 | 0 | 0 | register_pm_notifier, register_syscore_ops | MASK_ON_SUSPEND, SKIP_SET_WAKE; save/restore (unbounded udelay loop in pdc_resume) armed only for hibernation |
| first | pinctrl-msm | 6 | 1 | 0 | register_pm_notifier, register_syscore_ops | TLMM wakeups through the PDC; save/restore only for PM_SUSPEND_MEM / hibernation |
| first | qcom_tsens | 10 | 1 | 0 |  | suspend/resume re-init; fine |
| first | qcom-ipcc | 1 | 1 | 0 |  | IRQF_NO_SUSPEND + wake: DSP messages handled during s2idle, do not end it |
| first | qcom_aoss, msm_qmp | 4 | 1 | 0 |  | noirq/early mailbox ops |
| first | qrtr | 1 | 0 | 2 |  | wakeup source per rx burst |
| first | gunyah_loader | 0 | 1 | 2 | register_pm_notifier | only for proxy-scheduled secondary VMs (none in tests) |
| first | qcom_ice | 2 | 0 | 0 |  | inline crypto engine |
| first | ufs-qcom | 9 | 0 | 0 |  | spm-level 3 for s2idle, **power-off (5) only for PM_SUSPEND_MEM**; see findings |
| first | wcd_usbss_i2c | 2 | 3 | 1 |  | WCD939x switch, not on the A52s |
| first | dwc3-msm | 6 | 3 | 2 |  | **BLOCKER 1** (see Verdict); test fix usbkeep=1 |
| first | phy-msm-snps-hs | 3 | 0 | 0 |  | prepare/complete act only with fw_managed_pwr (not on yupik) |
| first | pinctrl-spmi-gpio | 2 | 0 | 0 |  | resume/restore (deep/hibernation) |
| first | pm8941-pwrkey | 3 | 3 | 0 |  | power key: wake source |
| first | eud | 2 | 3 | 0 |  | AHB2PHY clock gating only with EUD enabled |
| first | phy-generic | 1 | 1 | 0 |  | nop PHY |
| secure | si_core_module | 3 | 0 | 0 |  | hibernation ops only |
| secure | qseecom_dlkm | 2 | 0 | 0 |  | drops/restores bus votes and clocks |
| secure | smcinvoke_dlkm, qce50_dlkm, qcedev-mod_dlkm | 2 | 0 | 0 |  | crypto clocks, standard |
| secure | sps_drv | 0 | 1 | 0 |  | BAM, wake capable |
| display | qcom_glink | 2 | 0 | 1 |  | noirq suspend/resume of the glink edges |
| display | qti_pmic_glink, qti-battery-charger | 0 | 2 | 1-2 |  | Qualcomm charger node disabled: no device |
| display | fsa4480_i2c | 0 | 0 | 1 |  | wakeup source on switch events |
| display | drm_display_helper | 2 | 0 | 0 |  | DP MST helpers (no DP) |
| display | msm_drm | 21 | 1 | 1 |  | nothing to do with the screen already off (KEYCODE_SLEEP first); screen on = ported Samsung panel off/on sequence (untested) |
| kgsl | msm_kgsl | 35 | 0 | 0 | dev_pm_genpd_add_notifier, register_pm_notifier | waits for GMU slumber: screen off first |
| i2c | msm_gpi, i2c-msm-geni | 1, 4 | 0 | 0 |  | GPI resume; geni suspend_late/resume_early |
| nfc | nfc_sec | 2 | 1 | 3 |  | NFC IRQ is a wake source while NFC is on |
| touch | sec_common_fn, stm_ts | 1, 4 | 0, 3 | 1, 2 |  | resume_done gating (500 ms); LP-mode touch IRQ is a wake source |
| fingerprint | fingerprint (et7xx) | 2 | 0 | 2 |  | standard; wakeup source on the sensor IRQ |
| powerpd | qcom-spmi-adc5 | 2 | 0 | 0 |  | hibernation ops only |
| powerpd | usb_notify_layer | 0 | 0 | 2 |  | wakeup sources on cable events |
| powerpd | mfd_sm5714, pdic_sm5714 | 2 | 3 | 2 |  | enable_irq_wake; 200 ms suspend_wait then IRQ_NONE (noisy); charger/CC events wake |
| powerpd | muic_sm5714, sm5714_fuelgauge, sm5714-charger, pca9468_charger, sec-direct-charger | 2 | 0-1 | 2-3 |  | standard |
| powerpd | sec-battery | 3 | 0 | 3 |  | .prepare: monitoring off, sleep-polling alarm (periodic RTC wakes); .complete restarts |
| camera | camera | 4 | 0 | 0 |  | only matters with a camera open |
| dsp | smp2p | 2 | 3 | 0 |  | wake capable, left disabled until userspace enables it |
| dsp | qcom_q6v5, qcom_q6v5_pas | 0 | 0-2 | 0-2 |  | no sleep callbacks; DSPs keep their own votes; SSR wake lock on crash only |
| dsp | frpc-adsprpc | 4 | 0 | 2 |  | trace names; wakeup sources during invokes |
| wlanb | rfkill, cfg80211 | 3, 7 | 0 | 0 |  | cfg80211 calls wlan.ko WoW suspend when Wi-Fi is on |
| wlanb | icnss2 | 4 | 2 | 1 |  | forwards to wlan.ko + firmware; may refuse/time out (abort = safe) |
| wlanb | msm_geni_serial | 3 | 1 | 2 |  | **-EBUSY while the BT HAL holds its UART vote**: BT off |
| audio | pinctrl_lpi, swr, swr_ctrl, wcd938x, tas256x, swr_dmic, native | 2-4 | 0-3 | 0-1 |  | ASoC/SoundWire standard; idle audio = nothing to do |
| audio | wsa883x, wcd937x, swr_haptics | 2-4 | 0 | 0 |  | no such hardware on the A52s: no device |
| wlan | wlan (qcacld) | 194 | 1 | 4 |  | WoW + firmware handshake, most complex path: Wi-Fi off until s2idle-shallow passed |

The full per-module list with every count is `audit-table.md` / `audit-s68.tsv`. The remaining
149 modules have no system-sleep callback, no wake IRQ, no wakeup source and no PM hook (libraries,
notifier chains, clock/interconnect providers, Samsung class modules, audio helpers): listed at
the end of `audit-table.md`.

## The test design

### Why not adb over Wi-Fi (asked)
It does not remove blocker 1: while the cable is in and enumerated, dwc3-msm refuses suspend
whatever channel adb uses. It becomes the channel for the later "cable out" test (the only way
to test CX collapse). What it needs, each item needing the owner's OK:
- a network for the test phone to join (SSID + password typed into a test Android whose /data is
  zram, so nothing persists), preferably an isolated SSID or a hotspot: the test Android is
  `force_debuggable` with a root adbd, so adb on TCP must not be reachable by other LAN hosts;
- `service.adb.tcp.port=5555` in the test ramdisk's `adb_debug.prop` BEFORE adbd starts:
  `adb tcpip` or an adbd restart makes Android's init write `none` to g1's UDC
  (sys.usb.ffs.ready=0), which is a USB detach as seen from the PC: forbidden;
- the PC on the same L2 network with Mullvad's local-network access working (inbound to the PC
  timed out on 2026-11-11; PC -> phone has not been tried);
- Wi-Fi joining, DHCP and WoW across suspend are all untested on 6.12: the channel would itself
  be under test.

### Safety layers (what catches which failure)

| failure | caught by | outcome |
|---|---|---|
| a device callback refuses (-EBUSY ...) | PM core | suspend aborted, devices resumed, script logs `last_failed_dev` |
| a callback blocks with idle CPUs (I2C, firmware wait) | a52susp deadman (120 s awake time) | sysrq w + panic -> reboot -> harness/Android, console in ramoops |
| a callback spins, IRQs on | softlockup_panic (20 s), workqueue panic_on_stall (script sets 1) | panic -> reboot |
| a callback spins, IRQs off | only the hypervisor watchdog, if `A52_WDT=1` (30 s busy / 35 s bite, pet every 2 s; also pet in suspend_late/resume_early as 5.4 does) | watchdog bite -> harness safe mode -> Android |
| oops in a callback | panic_on_oops | panic -> reboot |
| deep state / wrong mem_sleep | script check + a52susp `.prepare` | refused before any device suspends |
| RTC wake path dead | awake self-test; a52susp `suspend_noirq` interlock | run stops / suspend refused |
| no wake-up at all, shallow level | hrtimer backstop 30 s -> `pm_system_wakeup()` (tick keeps running); deadman 120 s | wakes; worst case panic |
| no wake-up at all, deep level | alarm backstop 45 s through the same RTC | **nothing else: owner's keys**. Hence deep is the last level and needs his OK |
| Android starts its own suspend | a52susp gate (`allow_tgid`) | refused at PM_SUSPEND_PREPARE |
| script session dies | `setsid`, `trap '' HUP` | script continues |
| UFS resume fails | hung_task_panic after PM_POST_SUSPEND / deadman inside resume | panic -> reboot |

The helper's own dead-man (`a52.deadman`, default 600 s, `/leave`) still ends the session; give
the test sessions `a52.deadman=1500`.

### Levels
Each level is one test session (one kexec run), as learned on 2026-11-14 ("one pm_test level per
session"). Stop at the first level that does not come back clean and read its log first.

| level | what runs | new risk | needs |
|---|---|---|---|
| preflight | facts + RTC alarm IRQ self-test, no suspend | none | - |
| freezer | freeze all tasks 5 s, thaw | freezer (no device callbacks, USB untouched) | - |
| devices | + all prepare/suspend/resume/complete callbacks (usbkeep on) | the ~70 driver callbacks | - |
| platform | + suspend_late/noirq, wake IRQ interlock (usbkeep on) | noirq phase, IRQ suspend | - |
| s2idle-shallow | REAL suspend to idle, deepest cpuidle state disabled on every CPU, RTC wake +15 s | wake by RTC through PDC with the GIC up; real sleep duration | - |
| s2idle-deep | REAL suspend to idle with CPU + cluster power collapse and frozen tick | PDC wake from cluster collapse | owner's OK (`A52_DEEP_OK=1`) |
| later | Wi-Fi/BT on; then cable out + adb over Wi-Fi (CX collapse) | WoW, dwc3 LPM | owner |

Why "shallow" is a real suspend and still safe: `cpuidle-psci` puts `enter_s2idle` only on each
CPU's deepest state (state2: `cpu-sleep-0-1` / `cpu-sleep-1-1`, the rail power-down states). With it disabled, `cpuidle_enter_s2idle()`
finds no state, so s2idle idles every CPU in state1 with the tick running (no `tick_freeze`, no
timekeeping suspend) and the CPU PDs never power off, so the cluster stays on. Userspace is
frozen, every device is suspended, `/sys/power/suspend_stats/success` counts it, and only a wake
IRQ (or the backstop) ends it. Kernel timers keep working the whole time, which is what lets
the hrtimer backstop and the deadman guarantee a way out.

## Step by step (main session, PHONE=2 = PHONE2; PHONE=1 works the same with net 42)

0. Before 21:15 (PC sleeps at 22:00). Phone in its own Android, harness on recovery as usual.
   `drivers612/suspend/build.sh` (already built: `a52susp/a52susp-strip.ko`).
1. Start the current best run, held, with a longer helper dead-man:
   ```
   A=drivers612/androidboot; PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img \
   KEXEC_BASE=out-ack/kx/android-r02.dtb KEXEC_OVERLAY=none KX_HOLD=1 kexec/kx-cycle.sh susp-pre \
   bsp612/out/dist/Image $A/out/s68-rd.cpio.gz gen "$(cat $A/out/android-cmdline.txt) log_buf_len=4M \
   a52.deadman=1500 a52.mods=debug,secure,display,kgsl,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,audio@adsp,wlan@adsp"
   ```
   Wait for `sys.boot_completed=1` (`adb -s PHONE2 shell getprop sys.boot_completed`).
2. `PHONE=2 drivers612/suspend/run-level.sh preflight`. Read `logs/susp-preflight-*/result.txt`:
   `mem_sleep before:` (does Gunyah offer deep?), `rtc alarm self-test: irq N count a -> b`
   (b > a is required), cpuidle states (state2 must be `cpu-sleep-0-1`/`cpu-sleep-1-1`, desc
   `little-`/`big-rail-power-down`), the
   cluster genpd idle-state usage (non-zero = cluster collapse already happens at runtime), the
   active wakeup sources (expect `a600000.ssusb`). End the session:
   `TSH_IP=172.16.43.1 tools/tsh.py /leave; adb -s PHONE2 shell reboot; PHONE=2 kexec/kx-finish.sh susp-pre`.
3. New session (step 1 with name `susp-frz`), then `run-level.sh freezer`. Pass: `RESULT
   level=freezer rc=0`, `success` +1, dmesg shows "Freezing user space processes completed" and
   "Restarting tasks ... done". End the session as in step 2.
4. New session, `run-level.sh devices`. Pass: rc=0, no `returns -` lines, adb still answers
   afterwards (`adb -s PHONE2 shell uptime`). The log keeps every "calling X" line
   (`pm_print_times`, `pm_async=0`): note the slowest callbacks. If rc != 0:
   `last_failed_dev` names the refuser; that is a finding, not a danger.
5. New session, `run-level.sh platform`. Same checks plus `a52susp: wake_irq N armed`.
6. New session, `run-level.sh s2idle-shallow`. Pass: rc=0, `a52susp: back after ~15000 ms`,
   `wakeup_irq=<the RTC IRQ>` (an earlier wake by a charger/touch/NFC IRQ is still a pass; the
   backstop at 30 s means the RTC wake did not work: a finding), `success` +1, adb answers,
   screen comes back. This is the first real suspend.
7. Optional, main session's decision: repeat 4-6 with `A52_WDT=1` (hypervisor watchdog net for
   IRQs-off spins). PHONE-RULES forbids agents to arm it.
8. Only with the owner's OK and him reachable: `run-level.sh s2idle-deep A52_DEEP_OK=1`.
   Then Wi-Fi/BT on (`A52_KEEP_RADIOS=1` after switching them on), then the cable-out test.

If a level does not come back (`no RESULT line`): touch nothing for 10 minutes (panic -> reboot
-> harness/Android takes 1-3 min), then `adb -s PHONE2 get-state`. Once it is in Android,
read `/sys/fs/pstore/console-ramoops-0` (or `prev-console.txt` from kx-finish): the last
`calling ...+` line without its `returned` is the device that hung, the `DEADMAN` lines and
the sysrq-w dump follow. If the phone is not back after 10 minutes: stop and tell the owner.

## The same test on 6.18 (bsp618/android package a5)

`a52susp.c` builds for both kernels (LINUX_VERSION_CODE guards: `hrtimer_setup` from 6.13, void
alarm callback from 6.18; the 6.12 object code is unchanged). The 6.18 build is the port-tree copy
`bsp618/src/drivers612/suspend/a52susp` (bsp618/build-survey.sh `extra`: `Mk a52susp`), mapped into
`bsp618/android/stage-618/susp` by mkstages-618.py like every other stage. `out/a5-rd.cpio.gz` =
a4 + `/a52/mods/susp{,.list}` only (packed with `LEAVE=` = a4's pre-1f273ce `leave`). Run it as
step 1 above with the 6.18 inputs (`KEXEC_BASE=bsp618/android/out/android-r02-618.dtb`,
`bsp618/android/out/dist/Image`, `bsp618/android/out/a5-rd.cpio.gz`,
`$(cat bsp618/android/android-cmdline-618.txt)`) and `a52.deadman=1500
a52.mods=debug,secure,display,kgsl,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,susp,audio@adsp,wlan@adsp`;
run-level.sh accepts 6.12 and 6.18. Checked in the 6.18 config/source: everything susp2.sh uses
exists with the same semantics (PM_DEBUG/PM_ADVANCED_DEBUG/PM_SLEEP_DEBUG=y: pm_test,
pm_print_times, pm_debug_messages, pm_wakeup_irq; suspend_stats; rtc-pm8xxx in the first stage
with the same wakeup setup; cpuidle-psci with enter_s2idle on the deepest state; workqueue
panic_on_stall uint as on 6.12). New on 6.18: CONFIG_DPM_WATCHDOG=y (warning 10 s, panic 25 s
in one device callback), an extra net under a52susp's deadman.

## What the logs should show (pass)

```
a52susp: loaded: every suspend refused until allow_tgid is set; rtc for alarms: rtc0
a52susp-test: rtc alarm self-test: irq 1xx count 0 -> 1
a52susp: usbkeep: a600000.ssusb now skipped by system sleep (was syscore=0)
a52susp: usbkeep: a600000.dwc3 now skipped by system sleep (was syscore=0)
a52susp-test: ===== s2idle-shallow begin =====
PM: suspend entry (s2idle)
Freezing user space processes completed ...
a52susp: suspend by sh[NNN]: deadman 120 s, backstop 30000 ms, rtc alarm 45 s, wake_irq 1xx, usbkeep 1
calling  ...+ @ ..., parent: ...           (pm_print_times, one pair per device)
a52susp: wake_irq 1xx armed, entering the last suspend phase
PM: suspend-to-idle
PM: Triggering wakeup from IRQ 1xx
PM: resume from suspend-to-idle
a52susp: resume_noirq
PM: suspend exit
a52susp: back after 15xxx ms (boottime), wakeup irq 1xx
a52susp-test: RESULT level=s2idle-shallow rc=0 ... success=1 fail=0
```

## Known unknowns (only hardware answers)
- whether `/sys/power/mem_sleep` lists `deep` (Gunyah PSCI SYSTEM_SUSPEND); irrelevant for the
  plan, recorded by preflight;
- callback-level behaviour of the ~70 drivers (levels devices/platform answer it);
- whether the PC's adb server keeps the link through a 15-30 s NAK window (it has no USB
  keepalive; an issued `adb shell` simply waits): run-level.sh does not call adb during a level;
- the RTC wake from CPU/cluster power collapse (deep level only).
