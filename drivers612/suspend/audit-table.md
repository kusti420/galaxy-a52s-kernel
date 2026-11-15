| stage | module | sleep cbs | wake | wsrc | PM hooks | verdict |
|---|---|---|---|---|---|---|
| first | qcom-scm | 14 | 1 | 0 |  | freeze/thaw/restore = hibernation only; nothing for s2idle |
| first | arm_smmu | 8 | 0 | 0 |  | suspend = runtime power-off (apps_smmu has no clocks); **resume always runs arm_smmu_device_reset()** (its own comment says only hibernation needs it). With usbkeep the dwc3 keeps its SMMU mappings live across that reset: a context fault would panic (recoverable, cf. the 6.18 dwc3 fault) |
| first | smem | 2 | 0 | 0 |  | hibernation ops only |
| first | gh_msgq | 0 | 1 | 0 |  | Gunyah message-queue IRQs, wake capable (resource manager RPC) |
| first | gh_dbl | 0 | 1 | 0 |  | Gunyah doorbell IRQs, wake capable |
| first | qcom_dma_heaps | 6 | 0 | 0 |  | hibernation ops only |
| first | minidump | 0 | 0 | 0 | register_pm_notifier | PM notifier (minidump table) |
| first | crm-v2 | 1 | 0 | 0 |  | restore_noirq = hibernation |
| first | debug-regulator | 4 | 0 | 0 |  | debugfs names only |
| first | gdsc-regulator | 3 | 0 | 0 |  | resume_early/restore_early (hibernation HW-trigger restore); GDSCs are regulators here, not genpds: system sleep does not switch them |
| first | clk-qcom | 15 | 0 | 0 |  | hibernation restore + debugfs only: system sleep does not gate clocks |
| first | qcom_rpmh | 2 | 0 | 0 | cpu_pm_register_notifier, dev_pm_genpd_add_notifier | apps_rsc is a CLUSTER_PD genpd child: sleep/wake votes are flushed by the GENPD_NOTIFY_PRE_OFF notifier (works without qcom_lpm); yupik apps_rsc has CONTROL_TCS 0 (no next-wakeup write); noirq ops only with CONFIG_DEEPSLEEP (off) |
| first | sched-walt | 5 | 0 | 0 | register_syscore_ops | syscore resume hook (Qualcomm-tested); needs android_arch_task_struct_size=512 (on the cmdline since s66) |
| first | qcom_cpu_vendor_hooks | 0 | 0 | 0 | register_syscore_ops | syscore ops (Qualcomm) |
| first | icc-debug | 4 | 0 | 0 |  | debugfs names only |
| first | qcom-pmu-lib | 0 | 0 | 0 | cpu_pm_register_notifier | cpu_pm notifier around power collapse (already exercised by runtime idle) |
| first | spmi-pmic-arb | 0 | 1 | 0 |  | child irq_set_wake -> irq_set_irq_wake(bus IRQ = PDC pin 1); chained parent (never suspended), MASK_ON_SUSPEND for the rest: the RTC wake path |
| first | rtc-pm8xxx | 0 | 3 | 0 |  | **dev_pm_ops defined but not hooked up in r70 (.pm missing)**: no driver callback runs. The alarm IRQ is armed by the PM core (dev_pm_set_wake_irq + device_init_wakeup) at dpm_suspend_noirq: fine. Wake source of every test |
| first | qcom-pdc | 2 | 0 | 0 | register_pm_notifier, register_syscore_ops | MASK_ON_SUSPEND|SKIP_SET_WAKE; register save/restore (with an unbounded udelay loop in pdc_resume) armed only for hibernation: pm_suspend_target_state is still ON at PM_SUSPEND_PREPARE |
| first | pinctrl-msm | 6 | 1 | 0 | register_pm_notifier, register_syscore_ops | TLMM wakeups through the PDC; save/restore only for PM_SUSPEND_MEM/hibernation |
| first | qcom_tsens | 10 | 1 | 0 |  | suspend/resume re-init; fine for s2idle |
| first | qcom-ipcc | 1 | 1 | 0 |  | IRQF_NO_SUSPEND + wake: DSP messages are handled during s2idle but do not end it |
| first | qcom_aoss | 4 | 1 | 0 |  | noirq/early ops (AOSS QMP) |
| first | qrtr | 1 | 0 | 2 |  | wakeup source per rx burst |
| first | msm_qmp | 4 | 1 | 0 |  | noirq/early ops (QMP mailbox) |
| first | gunyah_loader | 0 | 1 | 2 | register_pm_notifier | PM notifier only for proxy-scheduled secondary VMs (none in tests) |
| first | qcom_ice | 2 | 0 | 0 |  | inline crypto engine suspend/resume |
| first | ufs-qcom | 9 | 0 | 0 |  | spm-level 3 (UFS sleep + hibern8) for s2idle, **power-off (level 5) only for PM_SUSPEND_MEM**. Root, system, vendor live on UFS: a failed resume = I/O errors -> hung tasks -> hung_task panic after PM_POST_SUSPEND, or the a52susp deadman |
| first | wcd_usbss_i2c | 2 | 3 | 1 |  | WCD939x USB-C switch: flag only (no such chip on the A52s) |
| first | dwc3-msm | 6 | 3 | 2 |  | **BLOCKER**: dwc3_core_prepare -EBUSY "peripheral mode still active" and dwc3_msm_pm_suspend -EBUSY "USB is outside LPM" while the PC link is up. Device-mode bus-suspend is dead code in r70 (mdwc->suspend never written). Holds a wakeup source while out of LPM. Test fix: a52susp usbkeep=1 |
| first | phy-msm-snps-hs | 3 | 0 | 0 |  | prepare/complete only act with fw_managed_pwr (not on yupik) |
| first | pinctrl-spmi-gpio | 2 | 0 | 0 |  | resume/restore (deep/hibernation) |
| first | pm8941-pwrkey | 3 | 3 | 0 |  | power key: wake source |
| first | eud | 2 | 3 | 0 |  | noirq ops gate the AHB2PHY clock only when EUD is enabled; wake IRQ set at probe |
| first | phy-generic | 1 | 1 | 0 |  | nop PHY |
| secure | si_core_module | 3 | 0 | 0 |  | hibernation ops only |
| secure | qseecom_dlkm | 2 | 0 | 0 |  | drops/restores bus votes and clocks; nothing refused while idle |
| secure | smcinvoke_dlkm | 2 | 0 | 0 |  | standard |
| secure | sps_drv | 0 | 1 | 0 |  | BAM, wake capable |
| secure | qce50_dlkm | 2 | 0 | 0 |  | crypto engine clocks |
| secure | qcedev-mod_dlkm | 2 | 0 | 0 |  | crypto engine clocks |
| display | qcom_glink | 2 | 0 | 1 |  | noirq suspend/resume of the glink edges |
| display | qti_pmic_glink | 0 | 2 | 1 |  | pmic_glink core (Qualcomm charger node is disabled in the board tree) |
| display | fsa4480_i2c | 0 | 0 | 1 |  | USB-C audio switch: wakeup source on switch events |
| display | drm_display_helper | 2 | 0 | 0 |  | DP MST helpers (no DP in use) |
| display | msm_drm | 21 | 1 | 1 |  | Samsung + SDE suspend: nothing to do with the screen already off (the plan sends KEYCODE_SLEEP first). With the screen on it would run the ported Samsung panel off/on sequence (untested) |
| kgsl | msm_kgsl | 35 | 0 | 0 | dev_pm_genpd_add_notifier, register_pm_notifier | PM + genpd (gpu_cx) notifiers; system suspend waits for GMU slumber: screen off first |
| i2c | msm_gpi | 1 | 0 | 0 |  | GPI DMA resume |
| i2c | i2c-msm-geni | 4 | 0 | 0 |  | suspend_late/resume_early (PM_SUSPEND_MEM path differs); Samsung clients wait for their own resume flags |
| nfc | nfc_sec | 2 | 1 | 3 |  | NFC IRQ is a wake source while NFC is on (RF field may end a test early) |
| touch | sec_common_fn | 1 | 0 | 1 |  | touch IRQ during suspend waits for resume_done (500 ms), no I/O while suspended |
| touch | stm_ts | 4 | 3 | 2 |  | suspend/resume only toggle resume_done; screen-off LP mode keeps the touch IRQ as a wake source |
| fingerprint | fingerprint | 2 | 0 | 2 |  | et7xx suspend/resume; wakeup source on the sensor IRQ |
| powerpd | qcom-spmi-adc5 | 2 | 0 | 0 |  | hibernation ops only |
| powerpd | usb_notify_layer | 0 | 0 | 2 |  | wakeup sources on cable events |
| powerpd | mfd_sm5714 | 2 | 3 | 2 |  | enable_irq_wake; its IRQ thread waits 200 ms for resume, then returns IRQ_NONE (the level IRQ re-fires until the MFD resumed: noisy, harmless). Charger events are an expected early wake source |
| powerpd | muic_sm5714 | 2 | 1 | 2 |  | standard |
| powerpd | sec-battery | 3 | 0 | 3 |  | .prepare cancels monitoring and switches to the sleep-polling alarm (alarmtimer: periodic RTC wake-ups = expected early wakes); .complete restarts |
| powerpd | sm5714_fuelgauge | 2 | 0 | 2 |  | standard |
| powerpd | sm5714-charger | 2 | 0 | 2 |  | standard |
| powerpd | pca9468_charger | 2 | 0 | 3 |  | idle unless PD PPS charging |
| powerpd | sec-direct-charger | 2 | 0 | 3 |  | standard |
| powerpd | pdic_sm5714 | 2 | 3 | 2 |  | enable_irq_wake; same 200 ms suspend_wait pattern; CC events wake |
| camera | qti-battery-charger | 0 | 2 | 2 |  | pulled in by leds-qti-flash; its DT node is disabled: no device |
| camera | camera | 4 | 0 | 0 |  | cam_* PM matters only with a camera open: keep it closed |
| dsp | smp2p | 2 | 3 | 0 |  | wake capable, wake left disabled until userspace enables it; freeze/restore = hibernation |
| dsp | qcom_q6v5 | 0 | 0 | 2 |  | "remoteproc SSR wake lock" only on a subsystem crash |
| dsp | qcom_q6v5_pas | 0 | 2 | 0 |  | no sleep callbacks: ADSP/CDSP/WPSS keep running on their own votes |
| dsp | frpc-adsprpc | 4 | 0 | 2 |  | trace names only; wakeup sources during invokes |
| wlanb | rfkill | 3 | 0 | 0 |  | standard |
| wlanb | cfg80211 | 7 | 0 | 0 |  | calls wlan.ko suspend (WoW) when Wi-Fi is on: Wi-Fi off for the first levels |
| wlanb | icnss2 | 4 | 2 | 1 |  | forwards to wlan.ko and the WLAN firmware; may refuse (-EBUSY) or time out (an abort is safe) |
| wlanb | msm_geni_serial | 3 | 1 | 2 |  | BT UART: **sys_suspend -EBUSY while the BT HAL holds its TIOCPM clock vote** ("Active userspace vote"): Bluetooth off for the first levels |
| audio | q6_dlkm | 2 | 0 | 2 |  | names only |
| audio | native_dlkm | 0 | 2 | 1 |  | wake-capable codec IRQ |
| audio | pinctrl_lpi_dlkm | 2 | 0 | 0 |  | LPI TLMM suspend/resume |
| audio | swr_dlkm | 2 | 0 | 0 |  | SoundWire bus |
| audio | swr_ctrl_dlkm | 3 | 3 | 1 |  | SoundWire master: wake IRQ, runtime PM |
| audio | platform_dlkm | 2 | 0 | 2 |  | names only |
| audio | wcd938x_dlkm | 4 | 0 | 0 |  | codec suspend/resume (ASoC) |
| audio | tas256x_dlkm | 2 | 0 | 0 |  | speaker amp suspend/resume |
| audio | wsa883x_dlkm | 4 | 0 | 0 |  | no WSA883x on the A52s: no device |
| audio | wcd937x_dlkm | 2 | 0 | 0 |  | not this board (WCD938x): no device |
| audio | swr_dmic_dlkm | 2 | 0 | 0 |  | standard |
| audio | swr_haptics_dlkm | 2 | 0 | 0 |  | not on the A52s |
| wlan | wlan | 194 | 1 | 4 |  | qcacld: ~190 PM-named functions, WoW + firmware handshake: the most complex suspend path in the set. Wi-Fi off until s2idle-shallow has passed |

No system-sleep callbacks, no wake IRQ, no wakeup source, no PM hook (133 modules: stateless for system sleep): iommu-logger, qcom_iommu_util, gic_intr_routing, socinfo, llcc-qcom, icc-clk, deferred-free-helper, msm_dma_iommu_mapping, secure_buffer, gh_arm_drv, gh_rm_drv, gh_mem_notifier, mem_buf_dev, debug_symbol, qcom_ipc_logging, proxy-consumer, clk-dummy, cmd-db, clk-rpmh, clk-scmi, qcom-cpufreq-hw, gcc-sc7280, dispcc-sc7280, icc-bcm-voter, icc-rpmh, qcom_cpucp, qcom_scmi_vendor, qcom_scmi_client, dcvs_fp, qcom-dcvs, qcom_llcc_pmu, rpmh-regulator, stub-regulator, qti-regmap-debugfs, qcom-spmi-pmic, nvmem_qcom-spmi-sdam, pmic-pon-log, pinctrl-yupik, qcom-reboot-reason, qcom_hwspinlock, qnoc-qos, qnoc-yupik, qcom_iommu_debug, mem_buf_msgq, mdt_loader, mem_buf, qseecom_proxy, ufshcd-crypto-qti, phy-qcom-ufs, phy-qcom-ufs-qmp-v4-yupik, sg, nvmem_qfprom, redriver, reboot-mode, qcom-pon, seaprobe, ioncompat, refgen, qmi_helpers, qcom_pdr_msg, qcom_smd, qcom_glink_smem, rproc_qcom_common, pdr_interface, altmode-glink, panel_event_notifier, qcom_va_minidump, lcd, sec_panel_notifier_v2, msm_ext_display, qfprom-sys, gpucc-sc7280, msm_sysstats, msm_performance, sec_core, sec_tsp_log, sec_input_notifier, sec_cmd, sec_secure_touch, sec_tclm_v2, sec_tsp_dumpkey, fingerprint_sysfs, qcom-vadc-common, a52sxq_usb_glue, if_cb_manager, switch_class, vbus_notifier, sb-core, sec_pd, hwmon, s2mpb03, common_muic, pdic_notifier_module, usb_typec_manager, usb_notifier, sec_vibrator, dc_vibrator, leds-qti-flash, camcc-sc7280, sm5714_fled_stub, qcom_pil_info, qcom_sysmon, qcom_ramdump, qrtr-smd, qcom_glink_spss, glink_probe, subsys_compat, qcom_pd_mapper_a52, cnss_nl, cnss_prealloc, cnss_utils, wlan_firmware_service, btpower, snd_event_dlkm, q6_pdr_dlkm, q6_notifier_dlkm, apr_dlkm, adsp_loader_dlkm, wcd_core_dlkm, wcd9xxx_dlkm, stub_dlkm, hdmi_dlkm, mbhc_dlkm, bolero_cdc_dlkm, va_macro_dlkm, rx_macro_dlkm, tx_macro_dlkm, wcd938x_slave_dlkm, sec_audio_sysfs, pinctrl_wcd_dlkm, wcd937x_slave_dlkm, wsa_macro_dlkm, machine_dlkm.
