# bsp612 first bring-up image for the a52sxq (`first1`)

Built 2026-11-11 20:30, offline, `images/a52sxq-bsp612-first1-recovery.img`, sha256
`977cab5c9cd32aa7...` (rebuilding changes the AVB salt, so the hash changes). **Never booted.** Nothing in this directory flashes anything; tests run
with `./test-cycle.sh` on the test phones only.

    bsp612/mkimage-612.sh first1          -> images/a52sxq-bsp612-first1-recovery.img
    NET=43 bsp612/mkimage-612.sh first1p2 -> same for the second test phone (172.16.43.1)
    EXTRA_CMDLINE="a52.skip=sched-walt" bsp612/mkimage-612.sh x   # never load a module
    EXTRA_CMDLINE="a52.nomods=1" bsp612/mkimage-612.sh gkionly    # GKI alone (no USB: see below)

Test: `./test-cycle.sh images/a52sxq-bsp612-first1-recovery.img 180`
(the gadget needs the whole module stage first; allow more than the 6.18 flow's 20 s).

## What the image contains

| Part | Source | Size |
|---|---|---|
| Kernel | `out/dist/Image`, pure GKI 6.12.81 (`6.12.81-4k-g8a69376da734`), uncompressed | 41,052,672 bytes, header `image_size` 41,811,968 |
| Ramdisk | `mkramdisk-612.sh` -> `out/bringup/ramdisk-612.cpio.gz` (gzip) | 3.55 MB (91 modules, 9.5 MB stripped) |
| dtb area | `out/dist/dtb/yupik.dtb` ONLY (msm-id 475/515, board-id 0 0, has `__symbols__`) | 345,882 bytes |
| recovery dtbo | ONE entry: `dts/a52sxq-bringup-overlay.dts` (board-id `<0x22 2>`, hw_rev 0..0xff, has `__fixups__`) | 7.9 kB |
| AVB | hash footer, SHA256_RSA4096, `~/.android-certs/avb.pem`, rollback index 1780617600, partition size 81,788,928 | image is exactly 81,788,928 bytes |

Header v2, `--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x01000000 --tags_offset 0x100
--dtb_offset 0x01f00000 --pagesize 4096`, as `mkimage-ack.sh`.
Size arithmetic: `image_size` + ramdisk = 45,359,882 <= 84,934,656 (81 MiB); boot image before
the footer 44,965,888 of 81,788,928. Nothing had to be cut for size.

Command line: `loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused
regulator_ignore_unused a52.deadman=300 a52.net=42`. No `console=`: the ABL replaces it with
ttynull and GKI has no VT, fbcon or serial driver loaded. The log goes to ramoops and `dmesg`.

`mkimage-612.sh` fails on: missing `__symbols__`/`__fixups__`, missing labels the hypervisor
overlay may use (`soc intc reserved_memory aliases firmware wdog arch_timer qcom_tzlog`), wrong
ids, `fdtoverlay` failure, merged dtb >= 2 MB (it is 350 kB), missing `/soc/qcom,wdt@17c10000`
or `/soc/timer`, kaslr/ADSP/ramoops regions not Samsung's, secure gpios not reserved,
`RELOCATABLE` off, no ARMd magic, `image_size` + ramdisk > 81 MiB, final size != partition.

### Device tree (`dts/a52sxq-bringup-overlay.dts`, plain dtc, literal numbers)

- Root: model, compatible, `qcom,msm-id`, `qcom,board-id = <0x22 2>`, `dtbo-version`,
  `dtbo-hw_rev` 0..0xff, as `dtbo/a52sxq-mainline-overlay.dts`.
- Reserved memory, after a diff of ALL regions (phone 5.4 merged tree vs 6.12 base; 22 fixed
  regions were already identical, incl. hyp, xbl/aop, cmd_db, smem, TZ `removed_region` start,
  cdsp, mpss, wlan, ipa, splash):

  | Region | Phone 5.4 | 6.12 base | Overlay |
  |---|---|---|---|
  | ADSP | 0x84700000 + 0x4800000 | 0x86700000 + 0x2800000 | `&pil_adsp_mem` reg = phone's |
  | `video_region@85b00000` (0x700000), `camera@86200000` (0x500000) | do not exist (inside the ADSP range) | reserved | `status = "disabled"` (no node references them) |
  | `cvp@8b200000` 0x500000 | no-map | absent | added |
  | `removed_region@c0000000` | size 0x6a00000 | size 0x5100000 | size = phone's |
  | `dummy_mem@9c700000` 0x100000, `hdm@9fb00000` 0x1000, `kaslr@a0001000` 0x1000, `tima@b0100000` 0x100000, `sec_debug@f0000000` 0x900000, `ss_plog@f0900000` 0x200000 | no-map | absent | added |
  | `modem_shared_mem@d0000000` | size 0 | absent | 0xd0000000 + 0x800000 no-map (gap up to the trusted-VM block, as the proven 6.18 dts) |
  | `ramoops@f0b00000` 0x100000, 4 x 0x40000 | `compatible = "ramoops"` | absent (base has a dynamic 2 MB `ramoops-region` for `qcom,ramoops`, whose module is not loaded) | added, same layout as 5.4 and 6.18 |
  | `cdsp_secure_heap@81800000`, `pil_trustedvm@d0800000` | present but `disabled` | reserved | left reserved (superset) |

  Dynamic (CMA-style, no fixed address) regions differ in a few sizes (qseecom 0x1c00000 on
  the phone vs 0x1400000) and are left as in the base: nothing in this stage uses them.
- TLMM: `qcom,gpios-reserved = <32 33 48 49 50 51 56 57 58 59>`. The 6.12 pinctrl driver has
  no built-in list (`.reserved_gpios = NULL`) and takes it from this property; the phone's 5.4
  driver reserves 56..59 in C (`CONFIG_FINGERPRINT_SECURE=y`; `CONFIG_MST_LDO` is off, so not
  99/100) and has no DT list. The base's six pins are kept: a superset is safe.
- GCC `protected-clocks`: the base's 41 + 15 (QSPI x3, CFG_NOC_LPASS, MSS x6, WPSS x3,
  EDP_CLKREF_EN, SEC_CTRL_CLK_SRC). Finding: the 6.12 `gcc-sc7280` driver registers 14 clocks
  the phone's 5.4 `gcc-yupik` driver does not have, exactly the ones the 6.18 dts protects
  because touching them resets retail SM7325 phones; Qualcomm's list does not cover them.
- PMICs: the base's SPMI bus is empty. Added only PMK8350 `pon@1300` (power key, resin =
  KEY_VOLUMEDOWN as on the phone), `sdam@7100` with `restart@48` bits 7:1, PM7325
  `pinctrl@8800` with the vol-up pin state, `/soc/reboot_reason` (consumer of the cell) and
  `/soc/gpio_keys` (vol-up = PM7325 GPIO 6, active low, 15 ms). No ADC, no thermal, no RTC,
  no PM8350C/PMR735A children.
- UFS: `&ufshc_mem`/`&ufsphy_mem` enabled with the phone's values (table below).
- USB: `&dwc3_0` `maximum-speed = "high-speed"`, `usb-phy = <&usb2_phy0>, <&usb_nop_phy>`
  (what the phone's 5.4 tree has), QMP/DP PHY disabled.
- Disabled: `&bluetooth`, `&qupv3_se1_i2c` (table below).
- No simple-framebuffer: **skipped.** GKI 6.12 has no `SYSFB_SIMPLEFB`, `DRM_SIMPLEDRM`,
  `FB`, fbcon or VT, and the vendor module set has no simple framebuffer driver, so a node
  would bind to nothing. The splash region stays reserved (base) and the display clocks/GDSC
  are left on by the three `*_ignore_unused` options, so the bootloader's last frame should
  simply stay on the panel.

### Ramdisk (`ramdisk/init`, `ramdisk/leave`, `mkramdisk-612.sh`)

Same contract as the 6.18 ramdisk: gadget `1209:a528` (NCM + ACM), `172.16.<a52.net>.1`,
telnetd on port 23, `/leave`, `/rb`, `/tmp/crashed`, `/tmp/prev-console.txt`, `/tmp/keep`,
`a52.net`/`a52.wdt`/`a52.deadman`, pstore, `/extra` (from `bsp612/ramdisk/extra/`).
`test-cycle.sh`'s assumptions hold unchanged. New:

1. No devtmpfs in GKI: `/dev` is a tmpfs; `mkdevs` (shell function, re-run every 4 s for two
   minutes) creates nodes from `/sys/dev/{char,block}/*/uevent`. From the telnet shell UFS
   shows in `/proc/partitions` and `/sys/block` at once; `/dev/sdXN` follow within seconds.
2. `hhwdt.ko` (rebuilt for 6.12 in `out/bringup/hhwdt/`; the 6.18 `.ko` is untouched) is
   loaded and armed FIRST (30 s, pet every 5 s), before any vendor module.
3. Module stage: `/lib/modules/load.list` (89 modules) with plain `insmod`, in dependency
   order computed from `modules.dep` at build time. Before each one: `a52sxq-init: insmod
   <name>` in the kernel log; a failure logs `a52sxq-init: insmod FAILED <name>: <error>` and
   goes on (`/tmp/insmod-failed.txt`). End marker: `a52sxq-init: modules done: N loaded, M
   failed`.
4. Crash guard extended: if the previous boot did not end with "clean exit" and its last
   stage line is an `insmod`, that module is the culprit; it and everything that boot had
   already skipped are skipped this time (`a52sxq-init: skip <name>`, `/tmp/culprit`).
   Dead-man is 90 s after a crash, as before.
5. `sec_core.ko` (samsung612/modules/sec_core) after the list, retried for 20 s (its init
   returns -EPROBE_DEFER until the SDAM nvmem provider has probed), with `clear_on_load=0`.
   It is what makes `reboot download` work (below). `/tmp/sec_core` = 0/1.
6. USB device mode: `echo peripheral > /sys/devices/platform/soc/a600000.ssusb/mode`
   (dwc3-msm `mode_store`), retried while waiting for the UDC.

Module list = `out/dist/first-stage.a52sxq.list` (94) + dependencies, with these changes:

| Module | Change | Why |
|---|---|---|
| `qcom-dload-mode` | dropped | arms Qualcomm's ramdump "download mode" through TCSR/SCM; a crash would then end in upload mode, which needs keys |
| `gh_virt_wdt`, `qcom_wdt_core` | dropped | Qualcomm's driver for the same hypervisor watchdog; `hhwdt` is proven on this phone and uses seconds |
| `sdhci-msm`, `cqhci` | dropped | SD card not needed; no board data for it |
| `phy-msm-ssusb-qmp` | dropped | USB 2.0 only |
| `msm_sharedmem` | dropped | modem shared memory, no modem here |
| `eud` | added | `usb0`'s `extcon` phandle; without the driver dwc3-msm defers forever |
| `phy-generic` | added | `usb-nop-xceiv`, the second `usb-phy` |
| `hhwdt`, `sec_core` | added | watchdog, restart reasons |

Never in the ramdisk: `tz_log`, `qcom_edac` (README lessons), camcc/gpucc/videocc, all
remoteproc/PIL, geni serial/I2C/SPI, display, audio.

### Reboot into Download mode

The 6.12 `qcom-reboot-reason.ko` has a fixed table (recovery 1, bootloader 2, rtc 3, dm-verity
4/5, keys clear 6) and writes the nvmem cell `restart_reason` of the node
`compatible = "qcom,reboot-reason"`; it has no "download". There is no `nvmem-reboot-mode` in
GKI or soc-repo, and `qcom-pon.ko`'s reboot-mode writes the PON register, not the SDAM the
ABL reads. `sec_core.ko` registers a reboot notifier (priority 254, after Qualcomm's 255) and
writes PON reason **0x15 for "download"** into the same cell = PMK8350 SDAM 0x7148 bits 7:1,
plus the IMEM cell 0x146aa65c (0x77665501) as 5.4 does. The reset itself is PSCI (GKI).
So the chain for `/rb download` is: qcom-pdc -> spmi-pmic-arb -> qcom-spmi-pmic ->
nvmem_qcom-spmi-sdam -> sec_core. If only `sec_core` fails, `/leave` writes the same bits itself through the SDAM's nvmem
sysfs file (`/sys/bus/nvmem/devices/spmi_sdam*/nvmem`, offset 0x48, bit 0 preserved) and logs
old/new value. **If the SDAM driver is not there either, `/leave` is a plain restart and the
bootloader's sticky recovery flag boots this image again** (`/leave` logs that case).

### Regulator table (rule: every voltage is the phone's 5.4 value, never the reference board's)

Method: all 50 RPMh regulator nodes of the 6.12 `yupik.dtb` were compared with the phone's merged
5.4 tree (`downstream-dt/a52sxq-r02.dts`): min, max, `qcom,init-voltage`, always-on/boot-on.
44 are identical. The 6.12 `rpmh-regulator` driver works like the 5.4 one: it sends nothing for
a regulator until a consumer enables it or the core has to move the voltage into the min..max
window, and `is_enabled` is the driver's own cached state (so the late "disable unused" pass
never touches a rail Linux did not enable itself).

Rails this image USES (consumers probe and enable them). No value had to be changed:

| Rail | Consumer in this image | Phone 5.4 (min / max / init) | 6.12 base | Overlay |
|---|---|---|---|---|
| L7B `pm7325_l7` | UFS VCC (`vcc-voltage-level` 2.504/2.952 V, 800 mA) | 2.400 / 3.544 / 2.952 V | same | supply reference only |
| L9B `pm7325_l9` | UFS VCCQ + ref-clk rail (900 mA) | 1.200 / 1.304 / 1.200 V | same | supply reference only |
| L6B `pm7325_l6` | UFS PHY PLL (18.4 mA) | 1.140 / 1.260 / 1.200 V | same | supply reference only |
| L10C `pm8350c_l10` | UFS PHY core (97.5 mA), USB HS PHY vdd (`qcom,vdd-voltage-level` 0 / 0.88 / 0.88 V) | 0.720 / 1.050 / 0.880 V | same | supply reference only |
| L1C `pm8350c_l1` | USB HS PHY vdda18 | 1.800 / 1.980 / 1.800 V | same | untouched (base reference) |
| L2B `pm7325_l2` | USB HS PHY vdda33 | 2.700 / 3.544 / 3.072 V | same | untouched (base reference) |
| `gcc_ufs_phy_gdsc`, `gcc_usb30_prim_gdsc` | UFS host, USB controller | GDSC | same | reference only |
| VDD_CX / VDD_MX levels | clock controllers, proxy votes | ARC levels 16..65535 | same | untouched |

Rails where the Qualcomm 6.12 base DIFFERS from the phone. None is used by this image, no
consumer exists, so Linux sends no request for them and they stay as the bootloader left them.
They are deliberately NOT overridden in the first overlay: giving L8C/L13C the phone's
`min = max` with the lower init voltage makes the regulator core issue a set-voltage at
registration, and the phone's `regulator-boot-on` without a display driver would end with the
panel rails switched off at the late cleanup. Put the phone's values in when the consumer
(display, touch, fingerprint) is ported:

| Rail | Phone 5.4 (name; min / max / init; flags) | 6.12 base (min / max / init) | Used on the phone by |
|---|---|---|---|
| L3C `pm8350c_l3` | `VDD_BTP_3P3`; 3.300 / 3.300 / 3.300 V | 2.800 / 3.540 / 2.800 V | named for the fingerprint sensor (no DT consumer found) |
| L7C `pm8350c_l7` | 3.000 / 3.000 / 3.000 V; boot-on | 3.000 / 3.544 / 3.000 V | touch AVDD (`tsp_avdd_ldo-supply`) |
| L8C `pm8350c_l8` | `panel_vddi`; 1.800 / 1.800 / 1.620 V; boot-on | 1.620 / 2.000 / 1.620 V | panel VDDI |
| L12C `pm8350c_l12` | 1.800 / 1.800 / 1.800 V; always-on | 1.650 / 2.000 / 1.650 V | always-on 1.8 V rail (no DT consumer found) |
| L13C `pm8350c_l13` | `panel_vci`; 3.000 / 3.000 / 2.700 V; boot-on | 2.700 / 3.544 / 2.700 V | panel VCI |
| S1B `pm7325_s1` | 1.856 / 2.040 / 1.872 V | 1.840 / 2.040 / 1.872 V | buck feeding LDOs (init equal) |

`regulator_ignore_unused` is on the command line as a second belt: GDSC "regulators" report
the real hardware state, and without it the display GDSC and friends would be switched off
30 s after boot.

### Enabled nodes of the 6.12 base that own a GPIO, a regulator or an I2C/SPI device

The base `yupik.dtb` is SoC-only (Qualcomm puts the IDP/QRD board parts — panels, cameras,
charger, fuel gauge, haptics, NFC, touch, codecs, SD card, PMIC children — into its board
overlays, which are not in the image). So the list is short. A node can only drive hardware if
its driver is loaded; the "module in ramdisk" column is the second safety net.

| Node (label) | Owns | Module in ramdisk | Decision |
|---|---|---|---|
| `gcc` clock-controller@100000 | vdd_cx | gcc-sc7280 | keep; FIX: `protected-clocks` + 15 firmware-owned clocks (below) |
| `dispcc` @af00000 | vdd_cx | dispcc-sc7280 | keep (same as the 6.18 boot; `clk_ignore_unused`) |
| `camcc`, `gpucc`, `videocc` | vdd_cx/mx | not loaded | keep, inert |
| `qcom,limits-dcvs` (cpufreq-hw) | isens vref supplies | not loaded | keep, inert |
| `bluetooth` bt_wcn6750 | TLMM 84/85/86 enables, 9 rails | not loaded | DISABLED (reference-board enable pins) |
| `wpss_pas`, `modem_pas`, `adsp_pas`, `cdsp_pas` | cx/mx | not loaded | keep, inert (no remoteproc starts) |
| 6 camera GDSCs, 2 video GDSCs, `gpu_cx_gdsc`, `gpu_gx_gdsc` | parent-supply VDD_CX | gdsc-regulator (defer: their clock controllers are not loaded) | keep |
| `disp_cc_mdss_core_gdsc` | proxy vote | gdsc-regulator | keep (holds the splash's power domain) |
| `refgen` regulator@88e7000 | proxy vote | not loaded | keep, inert |
| `usb0` ssusb@a600000 | `gcc_usb30_prim_gdsc` | dwc3-msm | keep; FIX: USB 2.0 only, device mode from userspace |
| `usb2_phy0` hsphy@88e3000 | L10C, L1C, L2B | phy-msm-snps-hs | keep (supplies already the phone's) |
| `usb_qmp_dp_phy` ssphy@88e8000 | L1B, L6B, pinctrl | dropped | DISABLED (phone uses `usb_nop_phy` as second PHY) |
| `qcom,dma-heaps` | depends-on-supply | qcom_dma_heaps (symbol dependency) | keep |
| `kgsl_smmu`, 5 `*_tbu` of apps-smmu | GDSC vdd | arm_smmu | keep (same as 5.4) |
| `qupv3_se1_i2c` i2c@984000 + `rtc6226` (FM radio, fmint-gpio, 2 rails) + `fsa4480@42` | I2C devices | not loaded (no geni drivers at all) | DISABLED (bus and both devices) |
| `ufshc_mem`, `ufsphy_mem` (disabled in the base) | L7B, L9B, L10C, L6B, TLMM 175 | ufs-qcom, phy-qcom-ufs-qmp-v4-yupik | ENABLED with the phone's values |
| `tlmm` | all TLMM pins | pinctrl-yupik | keep; FIX: `qcom,gpios-reserved` + 56..59 |
| RPMh regulators (50) | PMIC rails | rpmh-regulator | keep; see regulator table |
| `spmi_bus` (empty in the base) | PMICs | spmi-pmic-arb | ADDED: PMK8350 pon + SDAM 0x7100, PM7325 GPIO block (vol-up) only |
| `wdog` qcom,wdt@17c10000 | hypervisor-owned watchdog | dropped (`qcom_wdt_core`, `gh_virt_wdt`) | keep the node (the hypervisor's overlay patches it to disabled); `hhwdt` is used instead |
| `eud` qcom,msm-eud@88e0000 | extcon of `usb0` | eud (added) | keep (enabled on the phone's 5.4 too) |

Everything else in the base (QUP serial engines other than SE1, PCIe, SD host `sdhc_2`, sound,
display, cameras) is `disabled` in `yupik.dtb` already or has no driver in the ramdisk.

## Expected boot log markers (dmesg / `logs/<tag>/`, or `console-ramoops-0` afterwards)

In order. "a52sxq-init:" lines are from the ramdisk.

1. `Linux version 6.12.81-4k-g8a69376da734` and `Machine model: Samsung A52SXQ PROJECT (bsp612
   bring-up)` -> the ABL accepted the image and merged our overlay.
2. `ramoops` / `pstore: Registered ramoops as persistent store backend`; `/sys/fs/pstore`
   holds the previous boot's `console-ramoops-0`.
3. `a52sxq-init: start bsp612 (previous test boot crashed: 0)`.
4. `a52sxq-init: watchdog armed, 30s` (hhwdt probe line before it).
5. ~89 x `a52sxq-init: insmod <name>`, then `a52sxq-init: modules done: 89 loaded, 0 failed`.
   Driver lines to look for in between: `qcom-scm`, `arm-smmu 15000000.apps-smmu: probing`,
   `pinctrl` yupik, `spmi` PMIC arb, rpmh regulators, `gcc-sc7280` (clock controller).
6. UFS: `ufshcd-qcom 1d84000.ufshc`, `scsi host0`, `sd 0:0:0:N: [sda] ...`; the init line
   `a52sxq-init: UFS partitions: <n>` (152 on the 6.18 boot; 0 here only means "not yet",
   check `/proc/partitions` again from the shell).
7. `a52sxq-init: sec_core loaded after Ns` and the module's own
   `class sec ready; imem reason mapped, pon reason present`.
8. `a52sxq-init: usb mode=peripheral via /sys/devices/platform/soc/a600000.ssusb/mode`,
   `a52sxq-init: gadget on a600000.dwc3 after Ns`; on the PC `1209:a528` and telnet.
9. `a52sxq-init: ready (deadman=300s, modules ok=89 failed=0, sec_core=1, skipped: none)`.
10. Keys: `cat /proc/bus/input/devices` shows `gpio-keys`, `pmic_pwrkey`, `pmic_resin`.
11. On `/leave`: `a52sxq-init: clean exit`, then sec_core's
    `restart reason: pon 0x15, imem 0x77665501`, and the phone appears in Download mode.

Useful from the shell: `cat /tmp/insmod-failed.txt`, `lsmod | wc -l`,
`cat /sys/kernel/debug/devices_deferred`, `cat /sys/kernel/debug/regulator/regulator_summary`,
`cat /sys/devices/platform/soc/a600000.ssusb/mode`, `mkdevs; ls /dev/sd*`.

## Assumptions only hardware can confirm

1. The ABL's libufdt applies this overlay (it adds nodes under `/reserved-memory`,
   `/soc/qcom,spmi@c440000`, `/soc` and rewrites properties). `fdtoverlay` applies it; the
   ABL's library could not be run on the PC. The hypervisor's overlay targets exist.
2. Samsung's hypervisor ("haven", 5.4 era) and the GKI/Qualcomm Gunyah guest code: the
   built-in `gunyah` driver and the `gh_*` modules (hard symbol dependencies of the DMA
   heaps, so they must load) meet a `/hypervisor` node written for 5.4 `qcom,haven-*`
   drivers. Expected: they find nothing to bind and stay idle. Not known: whether any of them
   makes a hypercall the old hypervisor answers badly.
3. `hhwdt` under 6.12: the same SMC interface as on 6.18 (proven there); nothing in GKI 6.12
   should differ, but it is the first run.
4. The 6.12 `gcc-sc7280`/`dispcc-sc7280` on Samsung firmware with the extended protected
   list. The 6.18 kernel's upstream drivers of the same name work on this phone.
5. `sched-walt` and `qcom_cpu_vendor_hooks` (dependencies of `ufs-qcom`) on this firmware.
6. UFS with the 6.12 `ufs-qcom` + `phy-qcom-ufs-qmp-v4-yupik` and the phone's supplies;
   ICE through `qcom_ice`/`ufshcd-crypto-qti`. Nothing mounts or writes any partition.
7. USB: `eud.ko` probes on this firmware (`qcom,secure-eud-en`; it is enabled in the phone's
   5.4 tree too), dwc3-msm then registers its role switch, and `mode` = peripheral starts
   the gadget without a Type-C/charger driver reporting VBUS.
8. SPMI: PMK8350 at USID 0 and PM7325 at USID 1 (from the 5.4 tree) with the 6.12
   `spmi-pmic-arb`; SDAM write of 0x15 is honoured by the ABL (proven with the 6.18 kernel's
   nvmem-reboot-mode on the same cell).
9. `fw_devlink.strict=1` is in the base dtb's `bootargs`. If the ABL keeps those bootargs,
   devices whose DT suppliers have no driver in the ramdisk wait for the deferred-probe
   timeout (10 s after the last module load) before they probe. Expect a pause, not a failure.
10. `regulator_ignore_unused`/`clk_ignore_unused`/`pd_ignore_unused` keep the bootloader's
    splash alive; the panel should keep showing the last bootloader frame.
11. Hardware revisions 3 and 4 behave the same: the overlay has nothing revision-specific.

## Most likely failure modes, and what to try next

| Symptom | Likely cause | Next step |
|---|---|---|
| Back in Download mode within ~16 s, bootloader log says `ufdt apply overlay failed` or `Board Dtbo blob not found` | overlay refused by the ABL's libufdt, or selection | read the bootloader log `test-cycle.sh` pulls; bisect the overlay: build with only the root properties + marker fragment (the 6.18 overlay's shape), then add fragments back one at a time (reserved-memory first) |
| No gadget, phone resets after ~30 s, then comes back with `/tmp/crashed` | a vendor module hung or panicked the kernel | automatic: the next boot skips the culprit; read `crash-console.txt` (last `a52sxq-init: insmod` line names it, `/tmp/culprit`). If the culprit is a base dependency (qcom-scm, arm_smmu, clk-qcom, gcc-sc7280) the fix is in DT/driver, not in the list |
| Reset loop that never reaches the gadget and never reaches Download mode | crash before `sec_core` can load on every boot (also with the culprit skipped), or kernel dies before the ramdisk | manual key presses (Vol Down + Power, then Vol Up + Vol Down). Then `EXTRA_CMDLINE=a52.nomods=1` image to confirm GKI + ramdisk + hhwdt alone survive 30 s (it has no USB and no Download reboot: it WILL need the keys once; only do it if the question is "does GKI itself start") |
| Runs, but no gadget; dead-man leaves after 300 s into Download mode | dwc3-msm did not probe (eud/extcon, PHY, GDSC, fw_devlink) or the mode request was refused | read the pstore console afterwards from Android: `usb mode` lines, `dwc3`, `eud`, `deferred`. Try `EXTRA_CMDLINE=fw_devlink=permissive`. If `eud` does not probe: dwc3-msm treats the `extcon` phandle as mandatory (`-EPROBE_DEFER`, or `-ENODEV` "no extcon device found") and an overlay cannot delete the property, so the fix is a small soc-repo patch (`patches/soc-repo/`) that ignores a missing extcon, or a rebuilt base dtb without `extcon` on `usb0` |
| Gadget up, UFS absent | PHY, regulator or ICE probe failed or is deferred | `dmesg \| grep -i -e ufs -e ice -e qmp`; `cat /sys/kernel/debug/devices_deferred`; `regulator_summary` must show L7B 2.952 V, L9B 1.2 V, L6B 1.2 V, L10C 0.88 V enabled; wait 15 s and look again (fw_devlink timeout) |
| Everything up but `/leave` restarts into this image again | SDAM chain or sec_core failed (`/tmp/sec_core` = 0) | `cat /tmp/insmod-failed.txt`; `dmesg \| grep -e spmi -e sdam -e sec_core`. Not dangerous while the gadget works (every boot gives a 300 s shell), but only a manual key press ends it |
| `insmod FAILED ... Unknown symbol` | dependency order or a dropped module is needed | `dmesg | grep "Unknown symbol"`; add the module in `mkramdisk-612.sh` (`ADD=`) |
| Watchdog reset exactly ~30-35 s after start although the log looks healthy | the `watchdog` feeder did not start (no `/dev/watchdog0` node) | log shows `watchdog feeder failed`; check `mkdevs`; `a52.wdt=0` to run without |
| Phone hangs with a black/frozen splash and never resets | kernel died before `hhwdt` was armed (GKI early boot, initramfs unpack) | keys; compare with the 6.18 image on the same phone; check the image with `a52.nomods=1` |

## Not done / open

- Module signatures: the 89 vendor modules, `hhwdt` and `sec_core` are unsigned (GKI does not
  enforce signatures; they taint the kernel). Symbol CRCs of `hhwdt.ko` and `sec_core.ko` were
  checked against `out/gki/Module.symvers` (all match). `mkramdisk-612.sh` re-strips every
  module; that would also remove the signature of a GKI module if one is ever added to the list
  (still loads, unsigned).

- Not booted. No part of the overlay was checked with the ABL's own libufdt.
- The regulator differences L3C/L7C/L8C/L12C/L13C/S1B are documented, not overridden (reason
  in the table).
- No display (no simple-framebuffer possible on GKI), no touch, no charger: the phone runs
  from the battery with the bootloader's charger settings for at most the dead-man time.
- `qcom,ramoops` node and the dynamic `ramoops-region` of the base are left in place (inert).
- Dynamic CMA region sizes follow the base, not the phone.
