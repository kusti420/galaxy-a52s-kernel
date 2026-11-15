#!/usr/bin/env python3
"""Markdown audit table from tools/ko-pm-audit.sh output (audit-<run>.tsv) plus the review notes
written for the 2026-11-14 audit. Usage: tools/audit-table.py audit-s68.tsv > table.md"""
import csv, sys

NOTES = {
 'qcom-scm': 'freeze/thaw/restore = hibernation only; nothing for s2idle',
 'arm_smmu': 'suspend = runtime power-off (apps_smmu has no clocks); **resume always runs '
             'arm_smmu_device_reset()** (its own comment says only hibernation needs it). With '
             'usbkeep the dwc3 keeps its SMMU mappings live across that reset: a context fault '
             'would panic (recoverable, cf. the 6.18 dwc3 fault)',
 'qcom_rpmh': 'apps_rsc is a CLUSTER_PD genpd child: sleep/wake votes are flushed by the '
              'GENPD_NOTIFY_PRE_OFF notifier (works without qcom_lpm); yupik apps_rsc has '
              'CONTROL_TCS 0 (no next-wakeup write); noirq ops only with CONFIG_DEEPSLEEP (off)',
 'sched-walt': 'syscore resume hook (Qualcomm-tested); needs android_arch_task_struct_size=512 '
               '(on the cmdline since s66)',
 'qcom_cpu_vendor_hooks': 'syscore ops (Qualcomm)',
 'qcom-pmu-lib': 'cpu_pm notifier around power collapse (already exercised by runtime idle)',
 'gunyah_loader': 'PM notifier only for proxy-scheduled secondary VMs (none in tests)',
 'minidump': 'PM notifier (minidump table)',
 'gh_msgq': 'Gunyah message-queue IRQs, wake capable (resource manager RPC)',
 'gh_dbl': 'Gunyah doorbell IRQs, wake capable',
 'debug-regulator': 'debugfs names only',
 'icc-debug': 'debugfs names only',
 'clk-qcom': 'hibernation restore + debugfs only: system sleep does not gate clocks',
 'gdsc-regulator': 'resume_early/restore_early (hibernation HW-trigger restore); GDSCs are '
                   'regulators here, not genpds: system sleep does not switch them',
 'crm-v2': 'restore_noirq = hibernation',
 'spmi-pmic-arb': 'child irq_set_wake -> irq_set_irq_wake(bus IRQ = PDC pin 1); chained parent '
                  '(never suspended), MASK_ON_SUSPEND for the rest: the RTC wake path',
 'rtc-pm8xxx': '**dev_pm_ops defined but not hooked up in r70 (.pm missing)**: no driver '
               'callback runs. The alarm IRQ is armed by the PM core (dev_pm_set_wake_irq + '
               'device_init_wakeup) at dpm_suspend_noirq: fine. Wake source of every test',
 'qcom-pdc': 'MASK_ON_SUSPEND|SKIP_SET_WAKE; register save/restore (with an unbounded udelay '
             'loop in pdc_resume) armed only for hibernation: pm_suspend_target_state is still '
             'ON at PM_SUSPEND_PREPARE',
 'pinctrl-msm': 'TLMM wakeups through the PDC; save/restore only for PM_SUSPEND_MEM/hibernation',
 'qcom_tsens': 'suspend/resume re-init; fine for s2idle',
 'qcom-ipcc': 'IRQF_NO_SUSPEND + wake: DSP messages are handled during s2idle but do not end it',
 'qcom_aoss': 'noirq/early ops (AOSS QMP)',
 'msm_qmp': 'noirq/early ops (QMP mailbox)',
 'qrtr': 'wakeup source per rx burst',
 'qcom_ice': 'inline crypto engine suspend/resume',
 'ufs-qcom': 'spm-level 3 (UFS sleep + hibern8) for s2idle, **power-off (level 5) only for '
             'PM_SUSPEND_MEM**. Root, system, vendor live on UFS: a failed resume = I/O errors '
             '-> hung tasks -> hung_task panic after PM_POST_SUSPEND, or the a52susp deadman',
 'wcd_usbss_i2c': 'WCD939x USB-C switch: flag only (no such chip on the A52s)',
 'dwc3-msm': '**BLOCKER**: dwc3_core_prepare -EBUSY "peripheral mode still active" and '
             'dwc3_msm_pm_suspend -EBUSY "USB is outside LPM" while the PC link is up. '
             'Device-mode bus-suspend is dead code in r70 (mdwc->suspend never written). Holds '
             'a wakeup source while out of LPM. Test fix: a52susp usbkeep=1',
 'phy-msm-snps-hs': 'prepare/complete only act with fw_managed_pwr (not on yupik)',
 'pinctrl-spmi-gpio': 'resume/restore (deep/hibernation)',
 'pm8941-pwrkey': 'power key: wake source',
 'eud': 'noirq ops gate the AHB2PHY clock only when EUD is enabled; wake IRQ set at probe',
 'phy-generic': 'nop PHY',
 'si_core_module': 'hibernation ops only',
 'qseecom_dlkm': 'drops/restores bus votes and clocks; nothing refused while idle',
 'smcinvoke_dlkm': 'standard',
 'qce50_dlkm': 'crypto engine clocks',
 'qcedev-mod_dlkm': 'crypto engine clocks',
 'sps_drv': 'BAM, wake capable',
 'qcom_glink': 'noirq suspend/resume of the glink edges',
 'qti_pmic_glink': 'pmic_glink core (Qualcomm charger node is disabled in the board tree)',
 'qti-battery-charger': 'pulled in by leds-qti-flash; its DT node is disabled: no device',
 'fsa4480_i2c': 'USB-C audio switch: wakeup source on switch events',
 'msm_drm': 'Samsung + SDE suspend: nothing to do with the screen already off (the plan '
            'sends KEYCODE_SLEEP first). With the screen on it would run the ported Samsung '
            'panel off/on sequence (untested)',
 'drm_display_helper': 'DP MST helpers (no DP in use)',
 'msm_kgsl': 'PM + genpd (gpu_cx) notifiers; system suspend waits for GMU slumber: screen off '
             'first',
 'msm_gpi': 'GPI DMA resume',
 'i2c-msm-geni': 'suspend_late/resume_early (PM_SUSPEND_MEM path differs); Samsung clients '
                 'wait for their own resume flags',
 'nfc_sec': 'NFC IRQ is a wake source while NFC is on (RF field may end a test early)',
 'sec_common_fn': 'touch IRQ during suspend waits for resume_done (500 ms), no I/O while '
                  'suspended',
 'stm_ts': 'suspend/resume only toggle resume_done; screen-off LP mode keeps the touch IRQ as '
           'a wake source',
 'fingerprint': 'et7xx suspend/resume; wakeup source on the sensor IRQ',
 'qcom-spmi-adc5': 'hibernation ops only',
 'usb_notify_layer': 'wakeup sources on cable events',
 'mfd_sm5714': 'enable_irq_wake; its IRQ thread waits 200 ms for resume, then returns IRQ_NONE '
               '(the level IRQ re-fires until the MFD resumed: noisy, harmless). Charger '
               'events are an expected early wake source',
 'muic_sm5714': 'standard',
 'sec-battery': '.prepare cancels monitoring and switches to the sleep-polling alarm '
                '(alarmtimer: periodic RTC wake-ups = expected early wakes); .complete restarts',
 'sm5714_fuelgauge': 'standard',
 'sm5714-charger': 'standard',
 'pca9468_charger': 'idle unless PD PPS charging',
 'sec-direct-charger': 'standard',
 'pdic_sm5714': 'enable_irq_wake; same 200 ms suspend_wait pattern; CC events wake',
 'camera': 'cam_* PM matters only with a camera open: keep it closed',
 'qcom_dma_heaps': 'hibernation ops only',
 'smem': 'hibernation ops only',
 'smp2p': 'wake capable, wake left disabled until userspace enables it; freeze/restore = '
          'hibernation',
 'qcom_q6v5': '"remoteproc SSR wake lock" only on a subsystem crash',
 'qcom_q6v5_pas': 'no sleep callbacks: ADSP/CDSP/WPSS keep running on their own votes',
 'frpc-adsprpc': 'trace names only; wakeup sources during invokes',
 'rfkill': 'standard',
 'cfg80211': 'calls wlan.ko suspend (WoW) when Wi-Fi is on: Wi-Fi off for the first levels',
 'icnss2': 'forwards to wlan.ko and the WLAN firmware; may refuse (-EBUSY) or time out '
           '(an abort is safe)',
 'msm_geni_serial': 'BT UART: **sys_suspend -EBUSY while the BT HAL holds its TIOCPM clock '
                    'vote** ("Active userspace vote"): Bluetooth off for the first levels',
 'q6_dlkm': 'names only',
 'native_dlkm': 'wake-capable codec IRQ',
 'pinctrl_lpi_dlkm': 'LPI TLMM suspend/resume',
 'swr_dlkm': 'SoundWire bus',
 'swr_ctrl_dlkm': 'SoundWire master: wake IRQ, runtime PM',
 'platform_dlkm': 'names only',
 'wcd938x_dlkm': 'codec suspend/resume (ASoC)',
 'tas256x_dlkm': 'speaker amp suspend/resume',
 'wsa883x_dlkm': 'no WSA883x on the A52s: no device',
 'wcd937x_dlkm': 'not this board (WCD938x): no device',
 'swr_dmic_dlkm': 'standard',
 'swr_haptics_dlkm': 'not on the A52s',
 'wlan': 'qcacld: ~190 PM-named functions, WoW + firmware handshake: the most complex suspend '
         'path in the set. Wi-Fi off until s2idle-shallow has passed',
}

rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
seen, out, rest = set(), [], []
for r in rows:
    m = r['module']
    if m in seen:
        continue
    seen.add(m)
    if not (int(r['pm_cbs']) or int(r['wake']) or int(r['wsrc']) or r['notif'] != '-' or m in NOTES):
        rest.append(m)
        continue
    hooks = r['notif'].replace(',', ', ') if r['notif'] != '-' else ''
    out.append(f"| {r['stage']} | {m} | {r['pm_cbs']} | {r['wake']} | {r['wsrc']} | {hooks} | "
               f"{NOTES.get(m, 'standard callbacks, nothing found')} |")
print("| stage | module | sleep cbs | wake | wsrc | PM hooks | verdict |")
print("|---|---|---|---|---|---|---|")
print("\n".join(out))
print()
print(f"No system-sleep callbacks, no wake IRQ, no wakeup source, no PM hook ({len(rest)} "
      "modules: stateless for system sleep): " + ", ".join(rest) + ".")
