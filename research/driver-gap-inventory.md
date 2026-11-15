# a52sxq: driver gap inventory, downstream 5.4.302 (QGKI) vs ACK android17-6.18

Generated 2026-11-11. All numbers come from the trees on this PC; nothing was built, flashed or
run on a phone.

## 0. Inputs, method, and how to regenerate

| Input | Path | State used |
|---|---|---|
| Downstream kernel | `$ANDROID_TREE/kernel/samsung/sm7325` | 5.4.302, defconfig `vendor/lineage-a52sxq_defconfig` (`device/samsung/a52sxq/BoardConfig.mk:22`) |
| Built config | `$ANDROID_TREE/out/target/product/a52sxq/obj/KERNEL_OBJ/.config` | 2,197 symbols set to y/m (built 2026-11-10) |
| Built objects | same `KERNEL_OBJ` tree | 4,216 `.o` files mapped back to their `.c` = 4,434,967 source lines actually compiled |
| Booted device tree | `downstream-dt/a52sxq-r02.dts` | 835 enabled nodes with a `compatible`, 349 unique compatible strings |
| Upstream target | `ack/` | android17-6.18, commit `00c8666046c2`, 6.18.33 |
| Hint tree | `linux/` | sc7280-7.2.y (7.2.8) |

Method:
- **Compatibles**: `research/work/dtcompat.py` parses the decompiled DTS and keeps nodes whose own
  and ancestors' `status` is okay. Each string was searched (quoted, fixed-string, `*.c`/`*.h`) in
  the downstream tree, in `ack/` and in `linux/` (`ds_hits.txt`, `ack_hits.txt`, `l72_hits.txt`),
  joined by `join.py`, and annotated by the rule list in `gen_compat.py`.
- **Config**: `kc.py` collects every `config`/`menuconfig` symbol from all Kconfig files of a tree
  and lists the enabled downstream symbols that have no definition in `ack/` (617 of 2,197).
  `classify.py` sorts them into the four classes.
- **LOC**: `loc.py` counts lines only of `.c` files that have a `.o` in the real build output, so
  the numbers are what this phone compiles, not what the tree contains. Header lines are counted
  separately per directory (`api.py`). `cloc` is not installed, so the counts are raw `wc -l` lines
  (comments and blanks included; real code is roughly 70-75 % of that).
- **API evidence**: `api.py` counts regex hits for API families that changed between 5.4 and 6.18
  (ION, dma-buf, msm_bus, SCM, PIL/SSR, power_supply, DRM, V4L2, ALSA, ...) per item. The hit
  counts are in the last column of the tables in section 3; they show where the churn is, they are
  not a line-by-line audit.

Limits to keep in mind:
- A compatible with status okay means a driver *can* bind, not that it does. Three nodes are
  enabled with no driver built (section 1.3).
- Techpack options for audio and camera are not Kconfig symbols (they come from
  `techpack/audio/config/lahaina_a52s.conf` and `techpack/camera/config/*.conf`), so they do not
  appear in the 617; the built-object count covers them instead.
- Which device node each closed blob opens was inferred from the driver side (the UAPI each driver
  exposes), not confirmed by inspecting the vendor blobs. Marked "to verify" where it matters.
- Statements about newer Qualcomm/Samsung source releases that could serve as a better porting
  base (section 3.3) are from general knowledge, not checked here.

## 1. Device tree: enabled compatibles vs 6.18

### 1.1 Totals

349 unique enabled compatible strings. Status counts from `gen_compat.py`: `{'n/a': 9, 'NONE': 101, 'SAME': 43, 'ALT': 82, 'ALT*': 112, 'NONE*': 1, 'SAME*': 1}`

| Status | Meaning | Count |
|---|---|---|
| SAME | the same string is matched by a 6.18 driver | 44 (incl. 1 with different properties) |
| ALT | same hardware, different upstream compatible/binding, functionally equivalent | 82 |
| ALT* | upstream driver exists for the hardware but with a different userspace ABI, so the closed blob for that function cannot use it | 112 |
| NONE | nothing in 6.18 (101, of which about 35 are debug-only and about 30 are Samsung) | 102 |
| n/a | property-only node, or enabled node with no driver built | 9 |

Nothing was found that exists in 7.2 but not in 6.18 by compatible string. By file, one thing
differs: `drivers/gpu/drm/panel/panel-samsung-s6e3fc2x01.c` exists in `linux/` (7.2) and not in
`ack/` (6.18). Neither tree has an S6E3FC3 panel driver, SM5714, PCA9468, S2MPB03, ET7xx, an FTS5
touch driver, or any of the camera sensors (IMX682, IMX616, S5KGW1, S5KGD2, GC5035).

### 1.2 Summary by subsystem

| Subsystem | Downstream (5.4) | 6.18 upstream | Binding differences that matter |
|---|---|---|---|
| Clocks | `qcom,yupik-{gcc,camcc,dispcc,gpucc,videocc,debugcc}`, `qcom,gdsc`, `qcom,aop-qmp-clk` | `qcom,gcc-sc7280`, `qcom,sc7280-{camcc,dispcc,gpucc,videocc}`, lpass cc | Clock IDs are a different numbering. GDSCs are power domains, not regulators: every downstream consumer does `regulator_get("...-gdsc")`. No `clk_set_flags`, no vdd-class voting, no debugcc |
| Pinctrl / irq | `qcom,yupik-pinctrl`, `qcom,yupik-pdc` | `qcom,sc7280-pinctrl`, `qcom,sc7280-pdc` | pin function names differ; `gpio-reserved-ranges` for secure pins 56-59 |
| Interconnect / LLCC / cpufreq | `qcom,yupik-*_noc`, `qcom,yupik-llcc`, `qcom,cpufreq-hw-epss`, `qcom,lahaina-epss-l3-cpu` | `qcom,sc7280-*`, `qcom,sc7280-cpufreq-epss`, `qcom,sc7280-epss-l3` | node IDs differ (`dt-bindings/interconnect/qcom,sc7280.h`) |
| RPMh | `qcom,rpmh-rsc`, `qcom,cmd-db`, `qcom,bcm-voter` same; `qcom,rpmh-vrm-regulator` (40 nodes), `qcom,rpmh-arc-regulator` | `qcom,pm7325/pm8350c/pmr735a-rpmh-regulators`, `qcom,sc7280-rpmhpd` | per-PMIC regulator nodes; no proxy-consumer, no `qcom,init-voltage`; pin min == max (the private project log rule) |
| QUP | `qcom,qupv3-geni-se`, `qcom,i2c-geni` (7), `qcom,msm-geni-console`, `qcom,msm-geni-serial-hs` (2), `qcom,gpi-dma` | `qcom,geni-se-qup`, `qcom,geni-i2c`, `qcom,geni-debug-uart`, `qcom,geni-uart`, `qcom,sc7280-gpi-dma` | none of note. The fingerprint SPI SE is TZ-owned and has no kernel SPI node downstream |
| UFS / SD | `qcom,ufshc`, `qcom,ufs-phy-qmp-v4-yupik`, `qcom,sdhci-msm-v5`, `qcom,hwkm` | `qcom,sc7280-ufshc`, `qcom,sc7280-qmp-ufs-phy`, `qcom,inline-crypto-engine` | ICE is its own node. fstab uses `inlinecrypt_optimized` without wrapped keys (`device/samsung/sm7325-common/init/fstab.qcom:50`), so upstream ICE is enough |
| USB | `qcom,dwc-usb3-msm`, `qcom,usb-hsphy-snps-femto`, `qcom,usb-ssphy-qmp-dp-combo` | `qcom,sc7280-dwc3`, `qcom,usb-snps-hs-7nm-phy`, `qcom,sc7280-qmp-usb3-dp-phy` | role comes from extcon/Samsung `usb_notify` + SM5714 PDIC downstream; upstream wants `usb-role-switch`/typec |
| Remoteprocs / IPC | `qcom,pil-tz-generic`, `qcom,glink`, `qcom,smp2p`, `qcom,smem`, `qcom,ipcc`, `qcom,glinkpkt`, `qcom,qmp-mbox` | `qcom,sc7280-{adsp,cdsp,mpss,wpss}-pas`, glink-edge, `qcom,sc7280-aoss-qmp`; smp2p/smem/ipcc same | no subsystem-restart sysfs, no `/dev/subsys_*`, no `/dev/glinkpkt_*` |
| TrustZone | `qcom,scm`, `qcom,qseecom`, `qcom,smcinvoke`, `qcom,tee-shared-memory-bridge`, `qcom,secure-buffer`, `qcom,tz-log` | `qcom,scm`, `qcom_tzmem`, `drivers/tee/qcomtee`, `qcom_qseecom` (in-kernel bus only) | no `/dev/qseecom`, no `/dev/smcinvoke` |
| Memory | `qcom,msm-ion`, `ion,rbin_heap`, `removed-dma-pool` | dma-buf heaps (system, cma) | no `/dev/ion`, no secure heaps |
| Display | `qcom,sde-kms`, `qcom,dsi-ctrl-hw-v2.5`, `qcom,dsi-phy-v4.1`, `qcom,dsi-display`, `qcom,sde-rsc`, `qcom,dp-display` | `qcom,sc7280-mdss`, `qcom,sc7280-dpu`, `qcom,sc7280-dsi-ctrl`, `qcom,sc7280-dsi-phy-7nm` | panel is described by 100+ `qcom,mdss-dsi-*` / `samsung,*` properties downstream; upstream needs a `drm_panel` driver |
| GPU | `qcom,kgsl-3d0`, `qcom,adreno-gpu-a642l`, `qcom,gpu-gmu`, `qcom,kgsl-smmu-v2` | `qcom,adreno-635.0`+`qcom,adreno`, `qcom,adreno-gmu-635.0`, `qcom,adreno-smmu` | no KGSL UAPI |
| Video | `qcom,msm-vidc`, `qcom,yupik-vidc` | `qcom,sc7280-venus` (iris in 6.18 has no sc7280 entry) | different V4L2 device model and private controls |
| Camera | 30 `qcom,cam-*`/`csid`/`vfe`/`csiphy`/`cci` strings, 6 `qcom,cam-sensor`, 5 `qcom,eeprom`, actuator, OIS, flash | `qcom,sc7280-camss`, `qcom,sc7280-cci` | raw capture only; no ICP/IPE/BPS/JPEG, no request manager |
| Audio | 45 strings: `qcom,msm-audio-apr`, `qcom,msm-pcm-*`, `qcom,msm-dai-*`, `qcom,lahaina-asoc-snd`, `qcom,bolero-codec`, `qcom,wcd938x-codec`, `qcom,swr-mstr`, `ti, tas256x` | `qcom,apr-v2`, `qcom,q6afe`, `qcom,q6asm`, `qcom,q6adm`, `qcom,sc7280-lpass-*-macro`, `qcom,wcd9380-codec`, `qcom,soundwire-v1.6.0`, `ti,tas2562`/`ti,tas2564` | different card, DAI link and mixer control names |
| Data | `qcom,ipa`, `qcom,rmnet-ipa3`, `qcom,msm_gsi` | `qcom,sc7280-ipa` | no `/dev/ipa`, no `wwan_ioctl` |
| Wi-Fi / BT | `qcom,wcn6750` (icnss2 + qcacld), `qcom,wcn6750-bt` (btpower), `qcom,slim-ngd`, `qcom,btfmslim_slave` | `qcom,wcn6750-wifi` (ath11k ahb), `qcom,wcn6750-bt` (hci_qca), `qcom,slim-ngd-v2.1.0` | BT node must be a serdev child of the UART; BT audio over SLIMbus has no upstream driver |
| Thermal | `qcom,tsens26xx`, `qcom,adc-tm7`, `qcom,msm-hw-limits`, `qcom,bcl-v5`, qmi cooling/sensors, cpu-isolate/hotplug | `qcom,sc7280-tsens`, `qcom,spmi-adc-tm5-gen2`, `qcom,sdm845-lmh` fallback | no QMI cooling devices, no BCL |
| PMIC misc | `qcom,qpnp-power-on`, `qcom,pwm-lpg`, `qcom,tri-led`, `qcom,pm8350c-flash-led`, gpio/rtc/adc/sdam/temp-alarm same | `qcom,pmk8350-pon` + `qcom,pmk8350-pwrkey`/`-resin`, `qcom,pm8350c-pwm`, `qcom,spmi-flash-led` | - |
| Samsung board | `siliconmitus,sm5714mfd`, `sm5714-usbpd`, `nxp,pca9468`, `samsung,s2mpb03pmic`, `samsung,sec-battery`, `samsung,sec-direct-charger`, `stm,stm_ts`, `etspi,et7xx`, `sec-nfc`, `sx9360`, `hall_ic`, `samsung,dc_vibrator`, `samsung,sec-thermistor`, `samsung,usb-notifier`, abc, argos, input_booster, sec-debug | only `semtech,sx9360` (IIO), `gpio-keys`, `gpio-vibrator`; `samsung,s3fwrn5-i2c` is a different NFC stack | everything else has to be ported or rewritten |

### 1.3 Surprises in the device tree

- **PMIC-glink is enabled in the DT but not built.** `qcom,pmic-glink`, `qcom,battery-charger`,
  `qcom,ucsi-glink`, `qcom,altmode-glink` are status okay, yet `# CONFIG_QTI_PMIC_GLINK is not set`
  in the built `.config`. Charging and Type-C on this phone are 100 % SM5714 + PCA9468. Do not copy
  the `pmic-glink` node from the Fairphone 5 or Edge 30 device trees.
- **Touch is on I2C, not SPI.** `stm,stm_ts` is at address 0x49 on `i2c@a94000` (QUP SE13),
  firmware `tsp_stm/fts5cu56a_a52sxq.bin` (`a52sxq-r02.dts:20753`). the private project log says SPI; that is
  wrong for this revision. The driver that binds is `drivers/input/sec_input/stm/stm_i2c.c`.
  Upstream `st,stmfts` (`drivers/input/touchscreen/stmfts.c`) is for the older FingerTip S
  protocol, not FTS5.
- **The speaker amplifier is a TI TAS256x**, not WSA883x (`ti, tas256x` at 0x4c on `i2c@984000`,
  with a space in the compatible). `qcom,wsa883x` and `qcom,wsa-macro` are disabled. The codec is
  WCD938x (`qcom,wcd938x-codec`); `qcom,wcd937x-codec` is disabled.
- **PM8008 is disabled** (`qcom,pm8008-chip`, `qcom,pm8008-regulator`). Camera rails come from the
  Samsung S2MPB03 (`s2mpb03_pmic@56` on `i2c@980000`).
- **The grip sensor sits on a bit-banged bus** (`i2c-gpio` node `/soc/i2c@17`, `sx9360-i2c@28`).
- **No driver exists downstream for** `sec-mst` and `samsung,security_mz1..3` (nodes only), so
  they need nothing.
- **Built but never bound** (no enabled node): `cnss2` (17 k lines, no QCA6490 node, PCIe
  disabled), `spcom`/`spss_utils` (no secure processor on SM7325), `qbt_handler` (Qualcomm
  ultrasonic fingerprint), `qcom-hv-haptics` (node disabled; the phone uses a DC vibrator),
  Synaptics/Novatek/Focaltech/ST-trusted touch drivers, `pci-msm`, FSA4480, the NB7VPQ904M
  redriver, 40+ TV tuner modules. All of these drop out with no loss.
- **Haven hypervisor nodes are enabled** (`qcom,guestvm-loader`, `qcom,neuron-*`, `qcom,mem-buf`,
  `qcom,qrtr-haven`), 10 k lines built. Nothing in the ROM depends on a trusted VM.
- **Samsung's security LSMs are already gone.** `security/` in the build contains only SELinux,
  keys, integrity and `sdp`; no FIVE, DEFEX, PROCA, DSMS, HDM, Knox/UH/RKP object was compiled
  (the Lineage defconfig turns them off). The phone runs today without them, which is the proof
  that they are not needed for boot or for the blobs in this ROM.
- **No `diag` character driver** is built (`CONFIG_DIAG_CHAR` absent), so the modem stack already
  works without it.

### 1.4 Full per-compatible table

Columns: compatible, number of enabled nodes, downstream driver file(s), status, 6.18 equivalent
and note. "(generic)" = matched by many core files.

| Compatible | Nodes | Downstream driver | Status | 6.18 equivalent / note |
|---|---|---|---|---|
| `android,firmware` | 1 | - | n/a | no driver needed (property-only node) |
| `android,vbmeta` | 1 | - | n/a | no driver needed (property-only node) |
| `arm,arch-cache` | 9 | - | n/a | no driver needed (property-only node) |
| `arm,arm64-kryo-cpu-erp` | 1 | drivers/edac/kryo_arm64_edac.c | NONE | debug/statistics only; drop |
| `arm,armv7-timer-mem` | 1 | drivers/clocksource/arm_arch_timer.c | SAME |  |
| `arm,armv8-pmuv3` | 1 | arch/arm/kernel/perf_event_v7.c, arch/arm64/kernel/perf_event.c | SAME |  |
| `arm,armv8-timer` | 1 | arch/arm/kernel/vdso.c, drivers/clocksource/arm_arch_timer.c | SAME |  |
| `arm,coresight-dynamic-replicator` | 2 | - | NONE | debug/statistics only; drop |
| `arm,coresight-static-funnel` | 1 | drivers/hwtracing/coresight/coresight-funnel.c | NONE | debug/statistics only; drop |
| `arm,gic-v3` | 1 | drivers/irqchip/irq-gic-v3.c, drivers/of/irq.c | SAME |  |
| `arm,idle-state` | 10 | drivers/cpuidle/cpuidle-arm.c, drivers/cpuidle/cpuidle-big_little.c … | SAME |  |
| `arm,primecell` | 105 | (generic) | SAME |  |
| `arm,psci-1.0` | 1 | drivers/firmware/psci/psci.c | SAME |  |
| `arm,scmi` | 1 | drivers/firmware/arm_scmi/driver.c | SAME |  |
| `arm,scp-shmem` | 1 | - | SAME |  |
| `etspi,et7xx` | 1 | drivers/fingerprint/et7xx-spi.c | NONE | Samsung/vendor driver; see class (c) table |
| `fixed-clock` | 5 | (generic) | SAME |  |
| `gpio-keys` | 1 | (generic) | SAME |  |
| `hall_ic` | 1 | drivers/input/misc/hall/hall_ic.c | NONE | Samsung/vendor driver; see class (c) table |
| `i2c-gpio` | 1 | (generic) | SAME |  |
| `input_booster` | 1 | drivers/input/input_boost/input_booster.c, drivers/input/input_boost/input_booster_lsi.c … | NONE | Samsung/vendor driver; see class (c) table |
| `iommu-debug-test` | 3 | arch/arm/mm/dma-mapping.c, drivers/iommu/dma-iommu.c … | NONE | debug/statistics only; drop |
| `ion,rbin_heap` | 1 | drivers/staging/android/ion/heaps/ion_rbin_heap.c | NONE | ION removed in 5.11; only dma-heap system/cma in ACK |
| `mmio-sram` | 1 | (generic) | SAME |  |
| `modem-removed-dma-pool` | 1 | kernel/dma/coherent.c | NONE | downstream reserved-memory type; use plain `no-map` regions |
| `nxp,pca9468` | 1 | drivers/battery/charger/pca9468_charger/pca9468_charger.c | NONE | Samsung/vendor driver; see class (c) table |
| `operating-points-v2` | 3 | (generic) | SAME |  |
| `qcom,actuator` | 1 | techpack/camera/drivers/cam_sensor_module/cam_actuator/cam_actuator_dev.c | NONE | CamX-style sub-devices; upstream needs per-chip V4L2 lens/flash drivers |
| `qcom,adc-tm7` | 1 | drivers/thermal/qcom/adc-tm.c | ALT | `qcom,spmi-adc-tm5-gen2` (qcom-spmi-adc-tm5.c) |
| `qcom,adreno-gpu-a642l` | 1 | drivers/gpu/msm/adreno-gpulist.h, drivers/gpu/msm/adreno.h | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,adreno-gpu-a643` | 2 | drivers/gpu/msm/adreno-gpulist.h | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,adsp-loader` | 1 | techpack/audio/dsp/adsp-loader.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,altmode-glink` | 1 | drivers/soc/qcom/altmode-glink.c | n/a | DT node enabled but CONFIG_QTI_PMIC_GLINK is not set downstream: nothing binds (A52s charges via SM5714, not PMIC-glink) |
| `qcom,aop-qmp-clk` | 1 | drivers/clk/qcom/clk-aop-qmp.c | ALT | `qcom,sc7280-aoss-qmp`,`qcom,aoss-qmp` (soc/qcom/qcom_aoss.c) |
| `qcom,arm-compute-mon` | 5 | drivers/devfreq/arm-memlat-mon.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,arm-memlat-cpugrp` | 1 | drivers/devfreq/arm-memlat-mon.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,arm-memlat-mon` | 6 | drivers/devfreq/arm-memlat-mon.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,audio-ref-clk` | 10 | techpack/audio/asoc/codecs/audio-ext-clk-up.c, techpack/audio/asoc/codecs/audio-ext-clk.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,battery-charger` | 1 | drivers/power/supply/qti_battery_charger.c | n/a | DT node enabled but CONFIG_QTI_PMIC_GLINK is not set downstream: nothing binds (A52s charges via SM5714, not PMIC-glink) |
| `qcom,battery-debug` | 1 | drivers/soc/qcom/qti_battery_debug.c | NONE | debug/statistics only; drop |
| `qcom,bcl-v5` | 1 | drivers/thermal/qcom/bcl_pmic5.c | NONE | battery current limit thermal sensors; not upstream |
| `qcom,bcm-voter` | 2 | drivers/interconnect/qcom/bcm-voter.c | SAME |  |
| `qcom,bimc-bwmon4` | 2 | drivers/devfreq/bimc-bwmon.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,bimc-bwmon5` | 1 | drivers/devfreq/bimc-bwmon.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,bolero-clk-rsc-mngr` | 1 | techpack/audio/asoc/codecs/bolero/bolero-clk-rsc.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,bolero-codec` | 1 | techpack/audio/asoc/codecs/bolero/bolero-cdc.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,btfmslim_slave` | 1 | - | NONE | BT/FM audio over SLIMbus codec; not upstream |
| `qcom,cam-a5` | 1 | techpack/camera/drivers/cam_icp/icp_hw/a5_hw/a5_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-bps` | 1 | techpack/camera/drivers/cam_icp/icp_hw/bps_hw/bps_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-cdm-intf` | 1 | techpack/camera/drivers/cam_cdm/cam_cdm_intf.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-cpas` | 1 | techpack/camera/drivers/cam_cpas/cam_cpas_intf.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-icp` | 1 | techpack/camera/drivers/cam_icp/cam_icp_subdev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-ipe` | 1 | techpack/camera/drivers/cam_icp/icp_hw/ipe_hw/ipe_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-isp` | 1 | techpack/camera/drivers/cam_isp/cam_isp_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-jpeg` | 1 | techpack/camera/drivers/cam_jpeg/cam_jpeg_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-lrme` | 1 | techpack/camera/drivers/cam_lrme/cam_lrme_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-req-mgr` | 1 | techpack/camera/drivers/cam_req_mgr/cam_req_mgr_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-res-mgr` | 1 | techpack/camera/drivers/cam_sensor_module/cam_res_mgr/cam_res_mgr.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-sensor` | 6 | techpack/camera/drivers/cam_sensor_module/cam_sensor/cam_sensor_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam-sync` | 1 | techpack/camera/drivers/cam_sync/cam_sync.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam170-cpas-cdm0` | 1 | techpack/camera/drivers/cam_cdm/cam_cdm_soc.h | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam_jpeg_dma_165` | 1 | techpack/camera/drivers/cam_jpeg/jpeg_hw/jpeg_dma_hw/jpeg_dma_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,cam_jpeg_enc_165` | 1 | techpack/camera/drivers/cam_jpeg/jpeg_hw/jpeg_enc_hw/jpeg_enc_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,camera-flash` | 1 | techpack/camera/drivers/cam_sensor_module/cam_flash/cam_flash_dev.c | NONE | CamX-style sub-devices; upstream needs per-chip V4L2 lens/flash drivers |
| `qcom,cc-cooling-devices` | 1 | drivers/thermal/qcom/cpu_voltage_cooling.c | NONE | not upstream; thermal-engine blob expects these cdevs |
| `qcom,cci` | 2 | techpack/camera/drivers/cam_sensor_module/cam_cci/cam_cci_dev.c | ALT | `qcom,sc7280-cci` (i2c-qcom-cci.c) |
| `qcom,cdsp-loader` | 1 | drivers/soc/qcom/qdsp6v2/cdsp-loader.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,cmd-db` | 1 | drivers/of/platform.c, drivers/soc/qcom/cmd-db.c | SAME |  |
| `qcom,core-hang-detect` | 1 | drivers/soc/qcom/core_hang_detect.c | NONE | debug/statistics only; drop |
| `qcom,coresight-csr` | 2 | drivers/hwtracing/coresight/coresight-csr.c | NONE | debug/statistics only; drop |
| `qcom,coresight-dummy` | 5 | drivers/hwtracing/coresight/coresight-dummy.c | NONE | debug/statistics only; drop |
| `qcom,coresight-hwevent` | 1 | drivers/hwtracing/coresight/coresight-hwevent.c | NONE | debug/statistics only; drop |
| `qcom,coresight-remote-etm` | 5 | drivers/hwtracing/coresight/coresight-remote-etm.c | NONE | debug/statistics only; drop |
| `qcom,cpu-hotplug` | 1 | drivers/thermal/qcom/cpu_hotplug.c | NONE | not upstream; thermal-engine blob expects these cdevs |
| `qcom,cpu-isolate` | 1 | drivers/thermal/qcom/cpu_isolate.c | NONE | not upstream; thermal-engine blob expects these cdevs |
| `qcom,cpufreq-hw-epss` | 1 | drivers/cpufreq/qcom-cpufreq-hw.c | ALT | `qcom,sc7280-cpufreq-epss`,`qcom,cpufreq-epss` |
| `qcom,cpufreq-hw-epss-debug` | 1 | drivers/cpufreq/qcom-cpufreq-hw-debug.c | NONE | debug; drop |
| `qcom,csid-lite165` | 2 | techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/ife_csid_hw/cam_ife_csid_lite17x.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,csid165_204` | 3 | techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/ife_csid_hw/cam_ife_csid17x.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,csiphy` | 5 | techpack/camera/drivers/cam_sensor_module/cam_csiphy/cam_csiphy_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,csiphy-v1.2.1` | 5 | techpack/camera/drivers/cam_sensor_module/cam_csiphy/cam_csiphy_soc.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,dcc-v2` | 1 | drivers/soc/qcom/dcc_v2.c | NONE | debug/statistics only; drop |
| `qcom,ddr-stats` | 1 | drivers/soc/qcom/ddr_stats.c | NONE | debug/statistics only; drop |
| `qcom,debugfs-qmp-client` | 1 | drivers/soc/qcom/qmp-debugfs-client.c | NONE | debug/statistics only; drop |
| `qcom,devfreq-icc` | 4 | drivers/devfreq/devfreq_icc.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,devfreq-icc-ddr` | 6 | drivers/devfreq/devfreq_icc.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,devfreq-icc-l3` | 1 | drivers/devfreq/devfreq_icc.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,devfreq-icc-l3bw` | 1 | drivers/devfreq/devfreq_icc.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,devfreq-qoslat` | 3 | drivers/devfreq/devfreq_qcom_qoslat.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,dload-mode` | 1 | drivers/firmware/qcom_scm.c, drivers/power/reset/qcom-dload-mode.c | SAME | handled inside qcom_scm (qcom,dload-mode = <&tcsr ...>) |
| `qcom,dp-display` | 1 | techpack/display/msm/dp/dp_display.c | ALT | `qcom,sc7280-dp` (not wired on A52s: USB 2.0 only port) |
| `qcom,dsi-ctrl-hw-v2.5` | 1 | techpack/display/msm/dsi/dsi_ctrl.c | ALT | `qcom,sc7280-dsi-ctrl`,`qcom,mdss-dsi-ctrl` |
| `qcom,dsi-display` | 1 | techpack/display/msm/dsi/dsi_display.c | NONE | panel = `drm_panel` driver; no S6E3FC3 driver in 6.18 (7.2 has s6e3fc2x01 only) |
| `qcom,dsi-phy-v4.1` | 1 | techpack/display/msm/dsi/dsi_phy.c | ALT | `qcom,sc7280-dsi-phy-7nm` |
| `qcom,dwc-usb3-msm` | 1 | drivers/usb/dwc3/dwc3-msm.c | ALT | `qcom,sc7280-dwc3`,`qcom,dwc3` (dwc3-qcom.c); no extcon/EUD/BAM glue, role via usb-role-switch |
| `qcom,eeprom` | 5 | techpack/camera/drivers/cam_sensor_module/cam_eeprom/cam_eeprom_dev.c | NONE | CamX-style sub-devices; upstream needs per-chip V4L2 lens/flash drivers |
| `qcom,gdsc` | 18 | drivers/clk/qcom/gdsc-regulator.c | ALT | GDSCs are genpd providers inside gcc/dispcc/...; consumers use power-domains, not *-supply |
| `qcom,glink` | 1 | drivers/soc/qcom/glink_probe.c | ALT | `glink-edge` children of the remoteproc nodes (rpmsg/qcom_glink_smem) |
| `qcom,glinkpkt` | 1 | drivers/soc/qcom/glink_pkt.c | NONE | no upstream; rpmsg_char/rpmsg_ctrl give different device names (blobs open /dev/glinkpkt_*) |
| `qcom,gpi-dma` | 2 | drivers/dma/qcom/gpi.c | ALT | `qcom,sc7280-gpi-dma` |
| `qcom,gpu-gmu` | 1 | drivers/gpu/msm/adreno.c, drivers/gpu/msm/adreno_a6xx_gmu.c … | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,gpu-mempools` | 1 | drivers/gpu/msm/kgsl_pool.c | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,gpu-models` | 1 | drivers/gpu/msm/adreno.c | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,gpu-pwrlevel-bins` | 1 | drivers/gpu/msm/adreno.c, drivers/gpu/msm/kgsl_pwrscale.c | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,guestvm-loader` | 1 | drivers/soc/qcom/guestvm_loader.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,hwkm` | 1 | drivers/soc/qcom/hwkm.c | ALT | wrapped-key support inside soc/qcom/ice.c |
| `qcom,hyp-core-ctl` | 1 | drivers/soc/qcom/hyp_core_ctl.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,i2c-geni` | 7 | drivers/i2c/busses/i2c-msm-geni.c | ALT | `qcom,geni-i2c` |
| `qcom,ipa` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,ipa-smmu-11ad-cb` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,ipa-smmu-ap-cb` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,ipa-smmu-uc-cb` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,ipa-smmu-wlan-cb` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,ipcc` | 1 | drivers/soc/qcom/qcom_ipcc.c | SAME |  |
| `qcom,ipcc-self-ping` | 3 | - | NONE | debug/statistics only; drop |
| `qcom,jtagv8-mm` | 8 | drivers/soc/qcom/jtagv8-etm.c, drivers/soc/qcom/qcom_proxy_of_consumer.c | NONE | debug/statistics only; drop |
| `qcom,kgsl-3d0` | 1 | drivers/gpu/drm/msm/adreno/adreno_device.c, drivers/gpu/drm/msm/msm_drv.c … | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,kgsl-smmu-v2` | 1 | drivers/gpu/msm/kgsl_iommu.c | ALT | `qcom,sc7280-smmu-500`,`qcom,adreno-smmu`,`arm,mmu-500` |
| `qcom,kryo` | 8 | - | n/a | no driver needed (property-only node) |
| `qcom,l3-pwrlevels` | 1 | drivers/gpu/msm/adreno.c | ALT* | `qcom,adreno-635.0`,`qcom,adreno` + `qcom,adreno-gmu-635.0` (drm/msm). No KGSL UAPI: Adreno blobs cannot run on it |
| `qcom,lahaina-asoc-snd` | 1 | techpack/audio/asoc/lahaina.c | ALT* | `qcom,qcm6490-idp-sndcard` (sound/soc/qcom/sc8280xp.c) or sc7280.c machine |
| `qcom,lahaina-epss-l3-cpu` | 1 | drivers/interconnect/qcom/epss-l3.c | ALT | `qcom,sc7280-epss-l3`,`qcom,epss-l3` (interconnect/qcom/osm-l3.c) |
| `qcom,llcc-pmu-ver2` | 1 | drivers/perf/qcom_llcc_pmu.c | NONE | debug/statistics only; drop |
| `qcom,llcc-v2` | 1 | drivers/soc/qcom/llcc-slice.c, techpack/display/msm/sde/sde_hw_catalog.c | ALT | `qcom,sc7280-llcc` (soc/qcom/llcc-qcom.c) |
| `qcom,lpi-pinctrl` | 1 | techpack/audio/soc/pinctrl-lpi.c | ALT | `qcom,sc7280-lpass-lpi-pinctrl` |
| `qcom,lpm-levels` | 1 | drivers/cpuidle/lpm-levels-legacy.c, drivers/cpuidle/lpm-levels.c | ALT | PSCI OSI cpuidle (`arm,psci-1.0` power-domains + domain-idle-states); rpmh-rsc handles system PM |
| `qcom,lrme` | 1 | techpack/camera/drivers/cam_lrme/lrme_hw_mgr/lrme_hw/cam_lrme_hw_dev.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,mem-buf` | 1 | drivers/soc/qcom/mem-buf.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,mem-dump` | 1 | drivers/soc/qcom/memory_dump_v2.c | NONE | debug/statistics only; drop |
| `qcom,mem-offline` | 1 | drivers/soc/qcom/mem-offline.c | NONE | debug/statistics only; drop |
| `qcom,memshare` | 1 | drivers/soc/qcom/memshare/msm_memshare.c | NONE | not upstream (modem/GPS DHMS memory); needed by modem for diag/GPS buffers |
| `qcom,memshare-peripheral` | 4 | drivers/soc/qcom/memshare/msm_memshare.c | NONE | not upstream (modem/GPS DHMS memory); needed by modem for diag/GPS buffers |
| `qcom,mpm2-sleep-counter` | 1 | drivers/soc/qcom/boot_stats.c | NONE | debug/statistics only; drop |
| `qcom,msm-adsprpc-mem-region` | 1 | drivers/char/adsprpc.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,msm-audio-apr` | 1 | techpack/audio/ipc/apr.c, techpack/audio/ipc/apr_vm.c | ALT | `qcom,apr-v2` under adsp `glink-edge` (soc/qcom/apr.c) |
| `qcom,msm-audio-ion` | 1 | techpack/audio/dsp/msm_audio_ion.c, techpack/audio/dsp/msm_audio_ion_vm.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-audio-ion-cma` | 1 | techpack/audio/dsp/msm_audio_ion.c, techpack/audio/dsp/msm_audio_ion_vm.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-auxpcm-dev` | 6 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-cam-smmu` | 1 | techpack/camera/drivers/cam_smmu/cam_smmu_api.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,msm-cam-smmu-cb` | 6 | techpack/camera/drivers/cam_smmu/cam_smmu_api.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,msm-cam-smmu-fw-dev` | 1 | techpack/camera/drivers/cam_smmu/cam_smmu_api.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,msm-cdc-pinctrl` | 7 | techpack/audio/asoc/codecs/msm-cdc-pinctrl.c | ALT | `qcom,sc7280-lpass-lpi-pinctrl` |
| `qcom,msm-cdsp-rm` | 1 | drivers/soc/qcom/cdsprm.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,msm-cdsprm-rpmsg` | 1 | drivers/soc/qcom/cdsprm.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,msm-compr-dsp` | 1 | - | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-compress-dsp` | 1 | techpack/audio/asoc/msm-compress-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-cdc-dma` | 1 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-cdc-dma-dev` | 22 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-fe` | 1 | techpack/audio/asoc/msm-dai-fe.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-mi2s` | 1 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6` | 1 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6-dev` | 21 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6-hdmi` | 3 | techpack/audio/asoc/msm-dai-q6-hdmi-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6-mi2s` | 12 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6-spdif` | 4 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-q6-tdm` | 20 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-dai-tdm` | 20 | techpack/audio/asoc/msm-dai-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-eud` | 1 | drivers/soc/qcom/eud.c | ALT | `qcom,sc7280-eud`,`qcom,eud` (usb/misc/qcom_eud.c) |
| `qcom,msm-ext-disp` | 1 | drivers/platform/msm/msm_ext_display.c | NONE | DP audio/HDCP glue; drop (no DP out on this phone) |
| `qcom,msm-ext-disp-audio-codec-rx` | 1 | techpack/audio/asoc/codecs/msm_hdmi_codec_rx.c | NONE | DP audio/HDCP glue; drop (no DP out on this phone) |
| `qcom,msm-fastrpc-compute` | 1 | drivers/char/adsprpc.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,msm-fastrpc-compute-cb` | 16 | drivers/char/adsprpc.c | ALT* | `qcom,fastrpc` + `qcom,fastrpc-compute-cb` under glink-edge (misc/fastrpc.c). /dev/fastrpc-* and a subset of the adsprpc ioctls: libadsprpc/libcdsprpc blobs need the downstream UAPI |
| `qcom,msm-geni-console` | 1 | drivers/soc/qcom/qcom_proxy_of_consumer.c, drivers/tty/serial/msm_geni_serial.c … | ALT | `qcom,geni-debug-uart` |
| `qcom,msm-geni-serial-hs` | 2 | drivers/tty/serial/msm_geni_serial.c | ALT | `qcom,geni-uart` |
| `qcom,msm-hdcp` | 1 | techpack/display/hdcp/msm_hdcp.c, techpack/display/msm/dp/dp_parser.c | NONE | DP audio/HDCP glue; drop (no DP out on this phone) |
| `qcom,msm-hdmi-dba-codec-rx` | 1 | - | NONE | DP audio/HDCP glue; drop (no DP out on this phone) |
| `qcom,msm-hw-limits` | 1 | drivers/thermal/qcom/msm_lmh_dcvs.c | ALT | `qcom,sc7280-lmh` fallback `qcom,sdm845-lmh` (thermal/qcom/lmh.c) |
| `qcom,msm-imem` | 1 | - | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-boot_stats` | 1 | drivers/soc/qcom/boot_stats.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-diag-dload` | 1 | drivers/usb/gadget/function/f_diag.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-dload-type` | 1 | drivers/power/reset/msm-poweroff.c, drivers/power/reset/qcom-dload-mode.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-kaslr_offset` | 1 | drivers/power/reset/msm-poweroff.c, drivers/power/reset/qcom-dload-mode.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-mem_dump_table` | 1 | drivers/soc/qcom/memory_dump_v2.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-pil` | 1 | drivers/soc/qcom/peripheral-loader.c | ALT | `qcom,pil-reloc-info` under `qcom,sc7280-imem` |
| `qcom,msm-imem-pil-disable-timeout` | 1 | drivers/soc/qcom/peripheral-loader.c | ALT | `qcom,pil-reloc-info` under `qcom,sc7280-imem` |
| `qcom,msm-imem-restart_reason` | 1 | drivers/power/reset/msm-poweroff.c, drivers/samsung/debug/sec_debug.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-imem-upload_cause` | 1 | drivers/samsung/debug/sec_debug.c | NONE | imem cells: Samsung/QC restart-reason + dload cookies; only syscon upstream (`qcom,sc7280-imem`) |
| `qcom,msm-ion` | 1 | drivers/staging/android/ion/heaps/msm_ion.c | NONE | ION removed in 5.11; only dma-heap system/cma in ACK |
| `qcom,msm-lsm-client` | 1 | techpack/audio/asoc/msm-lsm-client.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-afe` | 1 | techpack/audio/asoc/msm-pcm-afe-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-dsp` | 3 | techpack/audio/asoc/msm-pcm-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-dsp-noirq` | 1 | techpack/audio/asoc/msm-pcm-q6-noirq.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-dtmf` | 1 | techpack/audio/asoc/msm-pcm-dtmf-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-hostless` | 1 | techpack/audio/asoc/msm-pcm-hostless.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-loopback` | 2 | techpack/audio/asoc/msm-pcm-loopback-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-routing` | 1 | techpack/audio/asoc/msm-pcm-routing-auto.c, techpack/audio/asoc/msm-pcm-routing-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-pcm-voice` | 1 | techpack/audio/asoc/msm-pcm-voice-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-rng` | 1 | drivers/char/hw_random/msm_rng.c | ALT | `qcom,prng-ee` (crypto/qcom-rng.c) |
| `qcom,msm-rtb` | 1 | kernel/trace/msm_rtb.c | NONE | debug/statistics only; drop |
| `qcom,msm-sps-4k` | 1 | drivers/platform/msm/sps/sps.c | ALT | `qcom,bam-v1.7.0` (dma/qcom/bam_dma.c); only SLIMbus/USB-BAM use it, drop |
| `qcom,msm-stub-codec` | 1 | techpack/audio/asoc/codecs/msm_stub.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-transcode-loopback` | 1 | techpack/audio/asoc/msm-transcode-loopback-q6-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-vidc` | 1 | techpack/video/msm/vidc/msm_v4l2_vidc.c | ALT* | `qcom,sc7280-venus` (venus V4L2 stateful codec). UAPI differs from msm_vidc: codec2/OMX blobs need msm_vidc |
| `qcom,msm-vidc,context-bank` | 4 | techpack/video/msm/vidc/msm_v4l2_vidc.c | ALT* | `qcom,sc7280-venus` (venus V4L2 stateful codec). UAPI differs from msm_vidc: codec2/OMX blobs need msm_vidc |
| `qcom,msm-voip-dsp` | 1 | techpack/audio/asoc/msm-pcm-voip-v2.c | ALT* | q6afe/q6asm/q6adm/q6routing (`qcom,q6afe-dais`,`qcom,q6asm-dais`,`qcom,q6adm-routing`). Different ALSA card/mixer names, no voice/LSM/compress-offload parity: audio HAL blob + mixer_paths incompatible |
| `qcom,msm-watchdog` | 1 | drivers/samsung/debug/sec_debug.c, drivers/soc/qcom/qcom_soc_wdt.c | ALT | `qcom,apss-wdt-sc7280`,`qcom,kpss-wdt` (watchdog/qcom-wdt.c) |
| `qcom,msm_gsi` | 1 | techpack/dataipa/drivers/platform/msm/gsi/gsi.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,neuron-block-server` | 1 | drivers/block/neuron_block_server.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,neuron-channel-haven-shmem` | 2 | net/neuron/channel/ch_haven_recv.c, net/neuron/channel/ch_haven_send.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,neuron-protocol-block` | 1 | net/neuron/protocol/prot_block_client.c, net/neuron/protocol/prot_block_server.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,neuron-service` | 1 | net/neuron/neuron_service.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,ois` | 1 | techpack/camera/drivers/cam_sensor_module/cam_ois/cam_ois_dev.c | NONE | CamX-style sub-devices; upstream needs per-chip V4L2 lens/flash drivers |
| `qcom,pil-tz-generic` | 7 | drivers/char/adsprpc.c, drivers/soc/qcom/subsys-pil-tz.c | ALT* | `qcom,sc7280-{adsp,cdsp,mpss,wpss}-pas` (remoteproc/qcom_q6v5_pas.c); no /dev/subsys_* or subsys sysfs for blobs |
| `qcom,pil-tz-scm-pas` | 1 | drivers/soc/qcom/subsys-pil-tz.c | ALT* | `qcom,sc7280-{adsp,cdsp,mpss,wpss}-pas` (remoteproc/qcom_q6v5_pas.c); no /dev/subsys_* or subsys sysfs for blobs |
| `qcom,pm7325-gpio` | 1 | drivers/pinctrl/qcom/pinctrl-spmi-gpio.c | SAME |  |
| `qcom,pm8350c-flash-led` | 1 | drivers/leds/leds-qti-flash.c | ALT | `qcom,pm8350c-flash-led`,`qcom,spmi-flash-led` (leds/flash/leds-qcom-flash.c); child binding differs |
| `qcom,pm8350c-gpio` | 1 | drivers/pinctrl/qcom/pinctrl-spmi-gpio.c | SAME |  |
| `qcom,pmic-glink` | 2 | drivers/soc/qcom/pmic_glink.c | n/a | same compatible exists in 6.18 but the downstream driver is not even built (see above); leave node out |
| `qcom,pmk8350-gpio` | 1 | drivers/pinctrl/qcom/pinctrl-spmi-gpio.c | SAME |  |
| `qcom,pmk8350-rtc` | 1 | drivers/rtc/rtc-pm8xxx.c | SAME |  |
| `qcom,pmr735a-gpio` | 1 | drivers/pinctrl/qcom/pinctrl-spmi-gpio.c | SAME |  |
| `qcom,pwm-lpg` | 2 | drivers/pwm/pwm-qti-lpg.c | ALT | `qcom,pm8350c-pwm` (leds/rgb/leds-qcom-lpg.c) covers PWM + RGB |
| `qcom,q6core-audio` | 1 | techpack/audio/dsp/q6core.c | ALT | `qcom,q6core` |
| `qcom,qcedev` | 1 | drivers/crypto/msm/qcedev.c | ALT* | `qcom,sc7280-qce`,`qcom,qce` (crypto/qce) - kernel crypto API only, no /dev/qce UAPI |
| `qcom,qcedev,context-bank` | 2 | drivers/crypto/msm/qcedev.c | ALT* | `qcom,sc7280-qce`,`qcom,qce` (crypto/qce) - kernel crypto API only, no /dev/qce UAPI |
| `qcom,qcrypto` | 1 | drivers/crypto/msm/qcrypto.c | ALT* | `qcom,sc7280-qce`,`qcom,qce` (crypto/qce) - kernel crypto API only, no /dev/qce UAPI |
| `qcom,qfprom` | 1 | drivers/nvmem/qfprom.c | SAME |  |
| `qcom,qfprom-sys` | 1 | drivers/soc/qcom/qfprom-sys.c | NONE | debug/statistics only; drop |
| `qcom,qmi-cooling-devices` | 1 | drivers/thermal/qcom/qmi_cooling.c | NONE | not upstream; thermal-engine blob expects these cdevs |
| `qcom,qmi-sensors` | 1 | drivers/thermal/qcom/qmi_sensors.c | NONE | not upstream; thermal-engine blob expects these cdevs |
| `qcom,qmp-mbox` | 1 | drivers/mailbox/msm_qmp.c | ALT | `qcom,sc7280-aoss-qmp`,`qcom,aoss-qmp` (soc/qcom/qcom_aoss.c) |
| `qcom,qpnp-power-on` | 2 | drivers/input/misc/qpnp-power-on.c | ALT | `qcom,pmk8350-pon` + `qcom,pmk8350-pwrkey`/`-resin` (pm8941-pwrkey.c) |
| `qcom,qrtr-haven` | 1 | net/qrtr/haven.c | NONE | Haven hypervisor stack; ACK has drivers/virt/gunyah but nothing on this phone needs it; drop |
| `qcom,qseecom` | 1 | drivers/misc/qseecom.c | NONE* | `drivers/firmware/qcom/qcom_qseecom.c` is an in-kernel client bus (uefisecapp only, allow-listed); no /dev/qseecom ioctl UAPI |
| `qcom,qsmmu-v500` | 2 | drivers/gpu/msm/kgsl_iommu.c, drivers/iommu/arm-smmu.c | ALT | `qcom,sc7280-smmu-500`,`arm,mmu-500` |
| `qcom,qsmmuv500-tbu` | 11 | drivers/iommu/arm-smmu.c | NONE | TBU nodes optional upstream (debug only) |
| `qcom,qupv3-geni-se` | 2 | drivers/platform/msm/msm-geni-se.c | ALT | `qcom,geni-se-qup` |
| `qcom,reboot-reason` | 1 | drivers/power/reset/qcom-reboot-reason.c | ALT | `nvmem-reboot-mode` on PMK8350 SDAM / `qcom,pmk8350-pon` reboot-mode |
| `qcom,refgen-kona-regulator` | 1 | drivers/regulator/refgen.c | ALT | `qcom,sc7280-refgen-regulator`→`qcom,sm8250-refgen-regulator` |
| `qcom,rimps` | 1 | drivers/soc/qcom/qcom_rimps.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,rimps-log` | 1 | drivers/soc/qcom/rimps_log.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,rimps-memlat-cpugrp` | 3 | drivers/soc/qcom/rimps_memlat.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,rimps-memlat-mon-l3` | 3 | drivers/soc/qcom/rimps_memlat.c | ALT* | bus scaling: `qcom,sc7280-cpu-bwmon`/`-llcc-bwmon` (icc-bwmon.c); memlat/RIMPS have no upstream |
| `qcom,rmnet-ipa3` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/rmnet_ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,rpmh-arc-regulator` | 7 | drivers/regulator/rpmh-regulator.c | ALT | per-PMIC `qcom,pm7325/pm8350c/pmr735a-rpmh-regulators` (qcom-rpmh-regulator.c); ARC rails via `qcom,sc7280-rpmhpd` power domains. No proxy-consumer / parent-supply voting semantics |
| `qcom,rpmh-master-stats-v1` | 1 | drivers/soc/qcom/rpmh_master_stat.c | NONE | debug/statistics only; drop |
| `qcom,rpmh-rsc` | 2 | drivers/soc/qcom/rpmh-rsc.c | SAME |  |
| `qcom,rpmh-sleep-stats` | 1 | drivers/soc/qcom/soc_sleep_stats.c | ALT | `qcom,rpmh-stats` (soc/qcom/qcom_stats.c) |
| `qcom,rpmh-vrm-regulator` | 40 | drivers/regulator/rpmh-regulator.c | ALT | per-PMIC `qcom,pm7325/pm8350c/pmr735a-rpmh-regulators` (qcom-rpmh-regulator.c); ARC rails via `qcom,sc7280-rpmhpd` power domains. No proxy-consumer / parent-supply voting semantics |
| `qcom,rx-macro` | 1 | techpack/audio/asoc/codecs/bolero/rx-macro.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,scm` | 1 | drivers/firmware/qcom_scm.c | SAME |  |
| `qcom,sde-kms` | 1 | techpack/display/msm/msm_drv.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,sde-rsc` | 1 | techpack/display/msm/sde_rsc.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,sde-rsc-rpmh` | 1 | techpack/display/msm/sde_rsc.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,sdhci-msm-v5` | 1 | drivers/mmc/host/sdhci-msm.c | SAME |  |
| `qcom,secure-buffer` | 1 | drivers/soc/qcom/secure_buffer.c | ALT | `qcom_scm_assign_mem()`; no secure dma-buf heaps upstream |
| `qcom,sharedmem-uio` | 1 | drivers/uio/msm_sharedmem/msm_sharedmem.c | ALT* | `qcom,rmtfs-mem` (/dev/qcom_rmtfs_mem*, open rmtfs daemon) vs UIO used by rmt_storage blob |
| `qcom,slim-ngd` | 1 | drivers/slimbus/qcom-ngd-ctrl.c, drivers/slimbus/slim-msm-ngd.c | ALT | `qcom,slim-ngd-v2.1.0` (slimbus/qcom-ngd-ctrl.c) |
| `qcom,smcinvoke` | 1 | drivers/soc/qcom/smcinvoke.c | ALT* | `drivers/tee/qcomtee` (TEE subsystem, /dev/tee*); UAPI differs from /dev/smcinvoke |
| `qcom,smem` | 1 | drivers/soc/qcom/smem.c, drivers/soc/qcom/smp2p.c | SAME |  |
| `qcom,smmu-kgsl-cb` | 3 | - | ALT | `qcom,sc7280-smmu-500`,`qcom,adreno-smmu`,`arm,mmu-500` |
| `qcom,smmu_sde_sec` | 1 | techpack/display/msm/msm_smmu.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,smmu_sde_unsec` | 1 | techpack/display/msm/msm_smmu.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,smp2p` | 4 | drivers/soc/qcom/smp2p.c | SAME |  |
| `qcom,smp2p-interrupt-rdbg-2-in` | 1 | drivers/char/rdbg.c | NONE | rdbg: debug, drop; sleepstate: tiny, tells DSPs about AP suspend |
| `qcom,smp2p-interrupt-rdbg-2-out` | 1 | drivers/char/rdbg.c | NONE | rdbg: debug, drop; sleepstate: tiny, tells DSPs about AP suspend |
| `qcom,smp2p-interrupt-rdbg-5-in` | 1 | drivers/char/rdbg.c | NONE | rdbg: debug, drop; sleepstate: tiny, tells DSPs about AP suspend |
| `qcom,smp2p-interrupt-rdbg-5-out` | 1 | drivers/char/rdbg.c | NONE | rdbg: debug, drop; sleepstate: tiny, tells DSPs about AP suspend |
| `qcom,smp2p-map-ipa-1-in` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,smp2p-map-ipa-1-out` | 1 | techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/ipa.c | ALT* | `qcom,sc7280-ipa` (drivers/net/ipa). No /dev/ipa, wan ioctl, IPACM/offload HAL interface |
| `qcom,smp2p-sleepstate` | 1 | drivers/soc/qcom/smp2p_sleepstate.c | NONE | rdbg: debug, drop; sleepstate: tiny, tells DSPs about AP suspend |
| `qcom,spmi-adc7` | 1 | drivers/iio/adc/qcom-spmi-adc5.c | SAME |  |
| `qcom,spmi-glink-debug` | 1 | drivers/spmi/spmi-glink-debug.c | NONE | debug/statistics only; drop |
| `qcom,spmi-pmic` | 7 | drivers/mfd/qcom-spmi-pmic.c | SAME |  |
| `qcom,spmi-pmic-arb` | 1 | drivers/spmi/spmi-pmic-arb.c | SAME |  |
| `qcom,spmi-sdam` | 9 | drivers/nvmem/qcom-spmi-sdam.c | SAME |  |
| `qcom,spmi-temp-alarm` | 3 | drivers/thermal/qcom/qcom-spmi-temp-alarm.c | SAME |  |
| `qcom,swr-mstr` | 2 | techpack/audio/soc/swr-mstr-ctrl.c | ALT | `qcom,soundwire-v1.6.0` (soundwire/qcom.c) |
| `qcom,system-pm` | 1 | drivers/soc/qcom/system_pm.c | ALT | PSCI OSI cpuidle (`arm,psci-1.0` power-domains + domain-idle-states); rpmh-rsc handles system PM |
| `qcom,tcsr-mutex` | 1 | drivers/hwspinlock/qcom_hwspinlock.c | SAME |  |
| `qcom,tee-shared-memory-bridge` | 1 | drivers/firmware/qtee_shmbridge.c | ALT | `qcom_tzmem` (built into SCM, no DT node) |
| `qcom,tri-led` | 1 | drivers/leds/leds-qti-tri-led.c | ALT | `qcom,pm8350c-pwm` (leds/rgb/leds-qcom-lpg.c) covers PWM + RGB |
| `qcom,tsens26xx` | 2 | drivers/thermal/msm-tsens.c | ALT | `qcom,sc7280-tsens`,`qcom,tsens-v2` |
| `qcom,tx-macro` | 1 | techpack/audio/asoc/codecs/bolero/tx-macro.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,tz-log` | 1 | drivers/firmware/qcom/tz_log.c | NONE | debug; drop |
| `qcom,ucsi-glink` | 1 | drivers/usb/typec/ucsi/ucsi_glink.c | n/a | DT node enabled but CONFIG_QTI_PMIC_GLINK is not set downstream: nothing binds (A52s charges via SM5714, not PMIC-glink) |
| `qcom,ufs-phy-qmp-v4-yupik` | 1 | drivers/phy/qualcomm/phy-qcom-ufs-qmp-v4-yupik.c | ALT | `qcom,sc7280-qmp-ufs-phy` |
| `qcom,ufshc` | 1 | drivers/scsi/ufs/ufs-qcom.c | SAME | +`qcom,sc7280-ufshc`; ICE is a separate `qcom,inline-crypto-engine` node |
| `qcom,usb-audio-qmi-dev` | 1 | sound/usb/usb_audio_qmi_svc.c | ALT | sound/usb/qcom/qc_audio_offload.c (USB audio offload, in 6.18) |
| `qcom,usb-hsphy-snps-femto` | 1 | drivers/usb/phy/phy-msm-snps-hs.c | ALT | `qcom,sc7280-usb-hs-phy`,`qcom,usb-snps-hs-7nm-phy` |
| `qcom,usb-ssphy-qmp-dp-combo` | 1 | drivers/usb/phy/phy-msm-ssusb-qmp.c | ALT | `qcom,sc7280-qmp-usb3-dp-phy` |
| `qcom,va-macro` | 1 | techpack/audio/asoc/codecs/bolero/va-macro.c | ALT | `qcom,sc7280-lpass-{rx,tx,va}-macro` + lpassaudiocc/lpasscorecc-sc7280 |
| `qcom,vfe-lite165` | 2 | techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/vfe_hw/vfe17x/cam_vfe.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,vfe165_160` | 3 | techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/vfe_hw/vfe17x/cam_vfe.c | ALT* | `qcom,sc7280-camss` (CAMSS: CSIPHY/CSID/VFE raw capture only). No ICP/IPE/BPS/JPEG/LRME/CDM, no cam_req_mgr UAPI: CamX blobs incompatible |
| `qcom,wb-display` | 1 | techpack/display/msm/sde/sde_wb.c | ALT* | `qcom,sc7280-mdss` + `qcom,sc7280-dpu` (drm/msm/dpu1). No SDE custom properties/ioctls (SDE HWC blob incompatible) |
| `qcom,wcd938x-codec` | 1 | techpack/audio/asoc/codecs/wcd938x/wcd938x.c | ALT | `qcom,wcd9380-codec`/`qcom,wcd9385-codec` (sound/soc/codecs/wcd938x.c) |
| `qcom,wcd938x-slave` | 2 | techpack/audio/asoc/codecs/wcd938x/wcd938x-slave.c | ALT | SoundWire slave `sdw20217010d00` (wcd938x-sdw.c) |
| `qcom,wcn6750` | 1 | drivers/soc/qcom/icnss2/main.c | ALT* | `qcom,wcn6750-wifi` (ath11k ahb) + `qcom,sc7280-wpss-pas`. Replaces icnss2+qcacld; needs ath11k firmware pack, cnss-daemon/wifi HAL blobs not used |
| `qcom,wcn6750-bt` | 1 | drivers/bluetooth/btpower.c | SAME* | hci_qca (serdev child of the UART); supply names/properties differ from btpower |
| `qcom,yupik` | 1 | - | n/a | no driver needed (property-only node) |
| `qcom,yupik-aggre1_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-aggre2_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-camcc` | 1 | drivers/clk/qcom/camcc-yupik.c | ALT | `qcom,sc7280-camcc` (clk/qcom/camcc-sc7280.c) |
| `qcom,yupik-clk_virt` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-cnoc2` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-cnoc3` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-dc_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-debugcc` | 1 | drivers/clk/qcom/debugcc-yupik.c | NONE | debug clock mux; drop |
| `qcom,yupik-dispcc` | 1 | drivers/clk/qcom/dispcc-yupik.c | ALT | `qcom,sc7280-dispcc` (clk/qcom/dispcc-sc7280.c) |
| `qcom,yupik-gcc` | 1 | drivers/clk/qcom/gcc-yupik.c | ALT | `qcom,gcc-sc7280` (clk/qcom/gcc-sc7280.c); clock IDs differ, GDSCs become power-domains |
| `qcom,yupik-gem_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-gpucc` | 1 | drivers/clk/qcom/gpucc-yupik.c | ALT | `qcom,sc7280-gpucc` (clk/qcom/gpucc-sc7280.c) |
| `qcom,yupik-llcc` | 1 | drivers/soc/qcom/llcc-yupik.c | ALT | `qcom,sc7280-llcc` (soc/qcom/llcc-qcom.c) |
| `qcom,yupik-lpass_ag_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-mc_virt` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-mmss_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-nsp_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-pdc` | 1 | drivers/irqchip/qcom-pdc.c | ALT | `qcom,sc7280-pdc`,`qcom,pdc` |
| `qcom,yupik-pinctrl` | 1 | drivers/pinctrl/qcom/pinctrl-yupik.c | ALT | `qcom,sc7280-pinctrl` |
| `qcom,yupik-rpmh-clk` | 1 | drivers/clk/qcom/clk-rpmh.c | ALT | `qcom,sc7280-rpmh-clk` |
| `qcom,yupik-system_noc` | 1 | drivers/interconnect/qcom/yupik.c | ALT | `qcom,sc7280-*-noc` etc. (interconnect/qcom/sc7280.c); node IDs differ |
| `qcom,yupik-vidc` | 1 | techpack/video/msm/vidc/msm_vidc_platform.c | ALT* | `qcom,sc7280-venus` (venus V4L2 stateful codec). UAPI differs from msm_vidc: codec2/OMX blobs need msm_vidc |
| `qcom,yupik-videocc` | 1 | drivers/clk/qcom/videocc-yupik.c | ALT | `qcom,sc7280-videocc` (clk/qcom/videocc-sc7280.c) |
| `ramoops` | 1 | drivers/of/platform.c, drivers/platform/chrome/chromeos_pstore.c … | SAME |  |
| `regulator-fixed` | 1 | drivers/gpio/gpiolib-of.c, drivers/regulator/fixed.c | SAME |  |
| `removed-dma-pool` | 4 | - | NONE | downstream reserved-memory type; use plain `no-map` regions |
| `resource` | 9 | (generic) | NONE | Samsung/vendor driver; see class (c) table |
| `rtc6226` | 1 | drivers/media/radio/rtc6226/radio-rtc6226-i2c.c | NONE | FM radio chip node inherited from QRD; drop |
| `samsung,abc_hub` | 1 | drivers/sti/abc/abc_hub_core.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,argos` | 1 | drivers/samsung/misc/sec_argos.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,audio-sysfs` | 1 | sound/soc/samsung/sec_audio_sysfs.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,dc_vibrator` | 1 | drivers/vibrator/dc/dc_vibrator.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,q6audio-adaptation` | 1 | techpack/audio/asoc/sec_audio_adaptation.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,s2mpb03pmic` | 1 | drivers/regulator/s2mpb03/s2mpb03.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec-battery` | 1 | drivers/battery/common/a73xq/sec_battery.c, drivers/battery/common/sec_battery.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec-debug-summary` | 1 | drivers/samsung/debug/sec_debug_summary.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec-direct-charger` | 1 | drivers/battery/common/a73xq/sec_direct_charger.c, drivers/battery/common/sec_direct_charger.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec-smem` | 1 | drivers/samsung/misc/sec_smem.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec-thermistor` | 3 | drivers/hwmon/sec_thermistor/sec_thermistor.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,sec_abc` | 1 | drivers/sti/abc/abc_common.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,security_mz1` | 1 | - | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,security_mz2` | 1 | - | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,security_mz3` | 1 | - | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,ss_touch` | 1 | drivers/input/sec_input/sec_secure_touch.c | NONE | Samsung/vendor driver; see class (c) table |
| `samsung,usb-notifier` | 1 | drivers/usb/notify/usb_notifier.c, drivers/usb/notify/usb_notifier_qcom.c | NONE | Samsung/vendor driver; see class (c) table |
| `sec-mst` | 1 | - | NONE | Samsung/vendor driver; see class (c) table |
| `sec-nfc` | 1 | drivers/nfc/nfc_logger/nfc_logger.c, drivers/nfc/sec_nfc.h | NONE | Samsung/vendor driver; see class (c) table |
| `shared-dma-pool` | 10 | drivers/of/of_reserved_mem.c, kernel/dma/coherent.c … | SAME |  |
| `siliconmitus,sm5714-fled` | 1 | drivers/leds/leds-sm5714-fled.c | NONE | Samsung/vendor driver; see class (c) table |
| `siliconmitus,sm5714mfd` | 1 | drivers/mfd/sm/sm5714/sm5714_core.c, drivers/muic/sm/sm5714/sm5714-muic.c | NONE | Samsung/vendor driver; see class (c) table |
| `simple-bus` | 5 | (generic) | SAME |  |
| `sm5714-usbpd` | 1 | drivers/usb/typec/sm/sm5714/sm5714_typec.c | NONE | Samsung/vendor driver; see class (c) table |
| `snps,dwc3` | 1 | drivers/usb/dwc3/core.c, drivers/usb/dwc3/dwc3-meson-g12a.c | SAME |  |
| `ss_plog` | 1 | drivers/of/platform.c, fs/pstore/ss_platform_log.c | NONE | Samsung/vendor driver; see class (c) table |
| `stm,stm_ts` | 1 | drivers/input/sec_input/stm/stm_i2c.c | NONE | Samsung/vendor driver; see class (c) table |
| `sx9360` | 1 | drivers/sensors/sx9360.c | ALT* | `semtech,sx9360` (iio/proximity/sx9360.c): IIO ABI, not the Samsung grip_sensor input+sysfs ABI |
| `syscon` | 12 | (generic) | SAME |  |
| `ti, tas256x` | 1 | techpack/audio/asoc/codecs/tas256x/os_layer/src/tas256x-regmap.c | ALT* | `ti,tas2562`/`ti,tas2564` (tas2562.c) - plain amp, no TI SmartAmp calibration/ADSP algo interface |
| `usb-nop-xceiv` | 1 | drivers/phy/phy-core.c, drivers/usb/phy/phy-generic.c | SAME |  |


## 2. Config symbols enabled downstream with no definition in 6.18

617 of 2,197 enabled bool/tristate symbols do not exist in any Kconfig file of `ack/`.
(Against `linux/` 7.2 the number is 660: ACK still carries ASHMEM (Rust), vendor hooks, dm-bow,
dm-default-key, incfs, uid_sys_stats, cpufreq_times and the GKI_HIDDEN_* symbols.)

| Class | Symbols | What it is |
|---|---|---|
| (a) Qualcomm SoC plumbing with an upstream replacement | 132 | use the upstream driver, write DT |
| (b) Qualcomm downstream-only, wanted by blobs | 107 | port, shim, or replace the blob |
| (c) Samsung-specific | 215 | port, rewrite small, or drop |
| (d) debug / renamed core option / irrelevant | 163 | drop |

Not in the 617 because they are not Kconfig symbols: the audio techpack (62 options in
`techpack/audio/config/lahaina_a52s.conf`, e.g. `CONFIG_SND_SOC_LAHAINA`, `CONFIG_SND_SOC_BOLERO`,
`CONFIG_SND_SOC_WCD938X`, `CONFIG_SND_SOC_TAS256x`, `CONFIG_SEC_SND_ADAPTATION`), the camera
techpack (`CONFIG_SPECTRA_CAMERA` family), display (`CONFIG_DRM_MSM` is *not set*; the SDE driver
is built through the techpack Kbuild), video, dataipa and datarmnet.

### 2.a Qualcomm plumbing with an upstream replacement (132)

| Downstream symbol(s) | Upstream 6.18 replacement |
|---|---|
| `ARCH_YUPIK` (+LAHAINA, SHIMA) | `ARCH_QCOM` |
| `SM_GCC_YUPIK`, `SM_{CAMCC,DISPCC,GPUCC,VIDEOCC}_YUPIK` | `SC_GCC_7280`, `SC_CAMCC_7280`, `SC_DISPCC_7280`, `SC_GPUCC_7280`, `SC_VIDEOCC_7280` (+ `SC_LPASS_CORECC_7280`); `SM_DEBUGCC_YUPIK`: none, drop; the LAHAINA/SHIMA clock, pinctrl, interconnect and LLCC symbols are other SoCs, drop |
| `PINCTRL_YUPIK` | `PINCTRL_SC7280` (+ `PINCTRL_SC7280_LPASS_LPI`) |
| `INTERCONNECT_QCOM_YUPIK`, `_EPSS_L3`, `_QOS` | `INTERCONNECT_QCOM_SC7280`, `INTERCONNECT_QCOM_OSM_L3` |
| `QCOM_YUPIK_LLCC` | `QCOM_LLCC` |
| `MSM_GENI_SE`, `SERIAL_MSM_GENI*`, `I2C_MSM_GENI`, `SPI_MSM_GENI`, `MSM_GPI_DMA` | `QCOM_GENI_SE`, `SERIAL_QCOM_GENI(_CONSOLE)`, `I2C_QCOM_GENI`, `SPI_GENI_QCOM`, `QCOM_GPI_DMA` |
| `SCSI_UFSHCD_QTI`, `SCSI_UFS_CRYPTO_QTI`, `QTI_CRYPTO_COMMON/TZ`, `PHY_QCOM_UFS*` | `SCSI_UFS_QCOM`, `QCOM_INLINE_CRYPTO_ENGINE`, `PHY_QCOM_QMP_UFS` |
| `SDC_QTI`, `MMC_CQHCI_CRYPTO(_QTI)` | `MMC_SDHCI_MSM`, `MMC_CRYPTO` |
| `USB_DWC3_MSM`, `MSM_HSUSB_PHY`, `USB_MSM_SSPHY_QMP`, `USB_QCOM_EMU_PHY` | `USB_DWC3_QCOM`, `PHY_QCOM_SNPS_EUSB2`/`PHY_QCOM_USB_SNPS_FEMTO_V2`, `PHY_QCOM_QMP_COMBO` |
| `REGULATOR_RPMH`, `REGULATOR_REFGEN`, `REGULATOR_PROXY_CONSUMER`, `REGULATOR_STUB`, `REGULATOR_QTI_FIXED_VOLTAGE` | `REGULATOR_QCOM_RPMH`, `REGULATOR_QCOM_REFGEN`, `QCOM_RPMHPD`; proxy/stub: none (see 3.4) |
| `MSM_QMP`, `MSM_CLK_AOP_QMP` | `QCOM_AOSS_QMP` |
| `RPMSG_QCOM_GLINK_NATIVE`, `QCOM_GLINK`, `MSM_GLINK_SSR` | `RPMSG_QCOM_GLINK`, `RPMSG_QCOM_GLINK_SMEM` |
| `MSM_PIL`, `MSM_PIL_SSR_GENERIC`, `MSM_SUBSYSTEM_RESTART`, `MSM_SERVICE_LOCATOR`, `MSM_SERVICE_NOTIFIER`, `*SSR_NOTIF*` | `QCOM_Q6V5_PAS`, `QCOM_SYSMON`, `QCOM_PDR_HELPERS`, `QCOM_PIL_INFO`. In-kernel API and sysfs differ: section 3.4 |
| `MSM_PM`, `ARM_QCOM_LPM_CPUIDLE`, `QTI_SYSTEM_PM`, `QGKI_PSCI_OSI_SUPPORT` | `ARM_PSCI_CPUIDLE(_DOMAIN)`, rpmh-rsc |
| `QCOM_SOC_WATCHDOG`, `QCOM_WDT_CORE`, `QCOM_WATCHDOG_*`, `QCOM_FORCE_WDOG_BITE_ON_PANIC` | `QCOM_WDT` |
| `QCOM_SOC_SLEEP_STATS`, `QCOM_SUBSYSTEM_SLEEP_STATS`, `MSM_BOOT_STATS` | `QCOM_STATS`; boot stats: none, drop |
| `QTEE_SHM_BRIDGE` | `QCOM_TZMEM_MODE_SHMBRIDGE` |
| `QCOM_QFPROM`, `QCOM_QFPROM_SYSFS`, `QCOM_QFPROM_SYS` | `NVMEM_QCOM_QFPROM` |
| `HW_RANDOM_MSM_LEGACY` | `CRYPTO_DEV_QCOM_RNG` |
| `POWER_RESET_QCOM_DOWNLOAD_MODE*`, `POWER_RESET_QCOM_REBOOT_REASON`, `INPUT_QPNP_POWER_ON` | `POWER_RESET_QCOM_PON`, `NVMEM_REBOOT_MODE`, `INPUT_PM8941_PWRKEY`, dload inside `QCOM_SCM` |
| `PWM_QTI_LPG`, `LEDS_QTI_TRI_LED`, `LEDS_QTI_FLASH` | `LEDS_QCOM_LPG`, `LEDS_QCOM_FLASH` |
| `THERMAL_TSENS`, `QTI_ADC_TM`, `QTI_THERMAL_LIMITS_DCVS`, `QTI_THERMAL` | `QCOM_TSENS`, `QCOM_SPMI_ADC_TM5`, `QCOM_LMH` |
| `MFD_I2C_PMIC` | `MFD_QCOM_PM8008` (unused: PM8008 disabled on this board) |
| `QCOM_EUD` | `USB_QCOM_EUD` |
| `QPNP_PBS`, `QCOM_PROXY_OF_CONSUMER`, `INPUT_QCOM_HV_HAPTICS`, `PCI_MSM`, `PCI_QTI`, `QTI_TZ_LOG`, `EFI_ARMSTUB`, `PWM_SYSFS`, `THERMAL_WRITABLE_TRIPS` | none needed / renamed core option |
| `HAVEN_*`, `HH_*`, `NEURON*`, `QRTR_HAVEN`, `HVC_HAVEN`, `QCOM_GUESTVM` | `drivers/virt/gunyah` exists in ACK; not needed here, drop |

Raw list by Kconfig directory:

- `arch/arm64`: ARCH_LAHAINA ARCH_SHIMA ARCH_YUPIK
- `drivers/block`: NEURON_APP_BLOCK_SERVER
- `drivers/char/hw_random`: HW_RANDOM_MSM_LEGACY
- `drivers/clk/qcom`: MSM_CAMCC_LAHAINA MSM_CLK_AOP_QMP MSM_DEBUGCC_LAHAINA MSM_DISPCC_LAHAINA MSM_GCC_LAHAINA MSM_GPUCC_LAHAINA MSM_VIDEOCC_LAHAINA SM_CAMCC_SHIMA SM_CAMCC_YUPIK SM_DEBUGCC_SHIMA SM_DEBUGCC_YUPIK SM_DISPCC_SHIMA SM_DISPCC_YUPIK SM_GCC_SHIMA SM_GCC_YUPIK SM_GPUCC_SHIMA SM_GPUCC_YUPIK SM_VIDEOCC_SHIMA SM_VIDEOCC_YUPIK
- `drivers/cpuidle`: ARM_QCOM_LPM_CPUIDLE QGKI_LPM_IPI_CHECK
- `drivers/dma/qcom`: MSM_GPI_DMA MSM_GPI_DMA_DEBUG
- `drivers/firmware`: QTEE_SHM_BRIDGE
- `drivers/firmware/efi`: EFI_ARMSTUB
- `drivers/firmware/psci`: QGKI_PSCI_OSI_SUPPORT
- `drivers/firmware/qcom`: QTI_TZ_LOG
- `drivers/i2c/busses`: I2C_MSM_GENI
- `drivers/input/misc`: INPUT_QCOM_HV_HAPTICS INPUT_QPNP_POWER_ON
- `drivers/interconnect/qcom`: INTERCONNECT_QCOM_EPSS_L3 INTERCONNECT_QCOM_LAHAINA INTERCONNECT_QCOM_QOS INTERCONNECT_QCOM_SHIMA INTERCONNECT_QCOM_YUPIK
- `drivers/iommu`: ARM_SMMU_SKIP_MAP_POWER_ON
- `drivers/leds`: LEDS_QTI_FLASH LEDS_QTI_TRI_LED
- `drivers/mailbox`: MSM_QMP
- `drivers/mfd`: MFD_I2C_PMIC
- `drivers/mmc/core`: SDC_QTI
- `drivers/mmc/host`: MMC_CQHCI_CRYPTO MMC_CQHCI_CRYPTO_QTI
- `drivers/nvmem`: QCOM_QFPROM QCOM_QFPROM_SYSFS
- `drivers/pci/controller`: PCI_MSM PCI_QTI
- `drivers/phy/qualcomm`: PHY_QCOM_UFS PHY_QCOM_UFS_14NM PHY_QCOM_UFS_QRBTC_SDM845 PHY_QCOM_UFS_V3 PHY_QCOM_UFS_V4
- `drivers/pinctrl/qcom`: PINCTRL_LAHAINA PINCTRL_SHIMA PINCTRL_YUPIK
- `drivers/platform/msm`: MSM_GENI_SE
- `drivers/power/reset`: POWER_RESET_QCOM_DOWNLOAD_MODE POWER_RESET_QCOM_DOWNLOAD_MODE_DEFAULT POWER_RESET_QCOM_REBOOT_REASON
- `drivers/pwm`: PWM_QTI_LPG PWM_SYSFS
- `drivers/regulator`: REGULATOR_PROXY_CONSUMER REGULATOR_QTI_FIXED_VOLTAGE REGULATOR_REFGEN REGULATOR_RPMH REGULATOR_STUB
- `drivers/rpmsg`: RPMSG_QCOM_GLINK_NATIVE
- `drivers/scsi/ufs`: SCSI_UFSHCD_QTI SCSI_UFS_CRYPTO_QTI
- `drivers/soc/qcom`: MSM_BOOT_STATS MSM_GLINK_SSR MSM_PIL MSM_PIL_SSR_GENERIC MSM_PM MSM_SERVICE_LOCATOR MSM_SERVICE_NOTIFIER MSM_SUBSYSTEM_RESTART PANIC_ON_SSR_NOTIF_TIMEOUT QCOM_EUD QCOM_FORCE_WDOG_BITE_ON_PANIC QCOM_GLINK QCOM_GUESTVM QCOM_LAHAINA_LLCC QCOM_PROXY_OF_CONSUMER QCOM_QFPROM_SYS QCOM_SHIMA_LLCC QCOM_SOC_SLEEP_STATS QCOM_SOC_WATCHDOG QCOM_SUBSYSTEM_SLEEP_STATS QCOM_WATCHDOG_IPI_PING QCOM_WATCHDOG_WAKEUP_ENABLE QCOM_WDT_CORE QCOM_YUPIK_LLCC QGKI QPNP_PBS QTI_CRYPTO_COMMON QTI_CRYPTO_TZ QTI_SYSTEM_PM SETUP_SSR_NOTIF_TIMEOUTS
- `drivers/spi`: SPI_MSM_GENI
- `drivers/thermal`: QTI_THERMAL THERMAL_TSENS THERMAL_WRITABLE_TRIPS
- `drivers/thermal/qcom`: QTI_ADC_TM QTI_THERMAL_LIMITS_DCVS
- `drivers/tty/hvc`: HVC_HAVEN
- `drivers/tty/serial`: SERIAL_MSM_GENI SERIAL_MSM_GENI_CONSOLE SERIAL_MSM_GENI_EARLY_CONSOLE SERIAL_MSM_GENI_HALF_SAMPLING
- `drivers/usb/dwc3`: USB_DWC3_MSM
- `drivers/usb/phy`: MSM_HSUSB_PHY USB_MSM_SSPHY_QMP USB_QCOM_EMU_PHY
- `drivers/virt/haven`: HAVEN_DRIVERS HH_CTRL HH_DBL HH_IRQ_LEND HH_MEM_NOTIFIER HH_MSGQ HH_RM_DRV HH_VIRT_WATCHDOG
- `net/neuron`: NEURON NEURON_SERVICE
- `net/neuron/channel`: NEURON_CH_HAVEN
- `net/neuron/protocol`: NEURON_PROT_BLOCK_SERVER
- `net/qrtr`: QRTR_HAVEN

### 2.b Qualcomm downstream-only, wanted by blobs (107)

- `drivers/bluetooth`: BTFM_SLIM MSM_BT_POWER
- `drivers/char`: ADSPRPC_QGKI MSM_ADSPRPC
- `drivers/crypto`: CRYPTO_DEV_QCEDEV CRYPTO_DEV_QCOM_MSM_QCE CRYPTO_DEV_QCRYPTO
- `drivers/devfreq`: ARM_MEMLAT_MON ARM_QCOM_DEVFREQ_QOSLAT DEVFREQ_GOV_CPUFREQ DEVFREQ_GOV_MEMLAT DEVFREQ_GOV_QCOM_BW_HWMON DEVFREQ_SIMPLE_DEV QCOM_BIMC_BWMON QCOM_DEVFREQ_ICC
- `drivers/dma-buf`: DMABUF_DESTRUCTOR_SUPPORT
- `drivers/firmware`: QTI_SCMI_MEMLAT_PROTOCOL QTI_SCMI_PLH_PROTOCOL
- `drivers/gpu/msm`: DEVFREQ_GOV_QCOM_ADRENO_TZ DEVFREQ_GOV_QCOM_GPUBW_MON QCOM_KGSL QCOM_KGSL_CONTEXT_DEBUG QCOM_KGSL_IOCOHERENCY_DEFAULT
- `drivers/hwmon`: SENSORS_QTI_AMOLED_ECM
- `drivers/iommu`: IOMMU_DYNAMIC_DOMAINS IOMMU_IO_PGTABLE_FAST QCOM_IOMMU_IO_PGTABLE_QUIRKS QCOM_IOMMU_TLBI_QUIRKS QCOM_LAZY_MAPPING QTI_IOMMU_SUPPORT
- `drivers/media/platform/msm/cvp`: MSM_CVP
- `drivers/media/platform/msm/synx`: MSM_GLOBAL_SYNX
- `drivers/misc`: HDCP_QSEECOM QSEECOM
- `drivers/net/wireless`: CLD_LL_CORE
- `drivers/net/wireless/cnss`: BUS_AUTO_SUSPEND CNSS_ASYNC
- `drivers/net/wireless/cnss2`: CNSS2 CNSS2_QMI
- `drivers/net/wireless/cnss_genl`: CNSS_GENL
- `drivers/net/wireless/cnss_prealloc`: WCNSS_MEM_PRE_ALLOC
- `drivers/net/wireless/cnss_utils`: CNSS_QMI_SVC CNSS_UTILS
- `drivers/platform/msm`: IPA3 IPA_WDI_UNIFIED_API MSM_EXT_DISPLAY SPS SPS_SUPPORT_NDP_BAM USB_BAM
- `drivers/regulator`: REGULATOR_QPNP_AMOLED
- `drivers/rpmsg`: RPMSG_QCOM_GLINK_SPSS
- `drivers/slimbus`: SLIMBUS_MSM_NGD
- `drivers/soc/qcom`: MSM_CDSP_LOADER MSM_PERFORMANCE MSM_PERFORMANCE_QGKI MSM_QBT_HANDLER MSM_SPCOM MSM_SPSS_UTILS QCOM_CDSP_RM QCOM_FSA4480_I2C QCOM_GLINK_PKT QCOM_HYP_CORE_CTL QCOM_MEM_BUF QCOM_RIMPS QCOM_RUN_QUEUE_STATS QCOM_SECURE_BUFFER QCOM_SMCINVOKE QCOM_SMP2P_SLEEPSTATE QSEE_IPC_IRQ QSEE_IPC_IRQ_BRIDGE QTI_HW_MEMLAT QTI_HW_MEMLAT_LOG QTI_HW_MEMLAT_SCMI_CLIENT QTI_PLH QTI_PLH_SCMI_CLIENT
- `drivers/soc/qcom/icnss2`: CNSS_QCA6750 ICNSS2 ICNSS2_QMI ICNSS2_RESTART_LEVEL_NOTIF
- `drivers/spu_verify`: SPU_VERIFY
- `drivers/staging/android/ion`: ION
- `drivers/staging/android/ion/heaps`: ION_MSM_HEAPS ION_SYSTEM_HEAP
- `drivers/staging/qcacld-3.0`: QCA_CLD_WLAN
- `drivers/thermal/qcom`: MAX31760_FAN_CONTROLLER QTI_CPU_HOTPLUG_COOLING_DEVICE QTI_CPU_ISOLATE_COOLING_DEVICE QTI_CPU_VOLTAGE_COOLING_DEVICE QTI_DDR_COOLING_DEVICE QTI_POLICY_ENGINE_SENSOR QTI_QMI_COOLING_DEVICE QTI_QMI_SENSOR QTI_SDPM_CLOCK_MONITOR
- `drivers/uio`: UIO_MSM_SHAREDMEM
- `drivers/usb/gadget`: USB_CONFIGFS_F_CCID USB_CONFIGFS_F_CDEV USB_CONFIGFS_F_DIAG USB_CONFIGFS_F_GSI USB_CONFIGFS_F_QDSS USB_F_CCID USB_F_CDEV USB_F_DIAG USB_F_FS_IPC_LOGGING USB_F_GSI USB_F_QDSS
- `init`: SCHED_WALT
- `sound/soc`: AUDIO_QGKI

Sub-grouping and verdict (details and LOC in section 3.1):
- Memory: `ION`, `ION_MSM_HEAPS`, `ION_SYSTEM_HEAP`, `QCOM_SECURE_BUFFER`, `DMABUF_DESTRUCTOR_SUPPORT`, `QCOM_MEM_BUF` -> ION compat module + secure dma-buf heaps.
- TrustZone: `QSEECOM`, `HDCP_QSEECOM`, `QCOM_SMCINVOKE`, `CRYPTO_DEV_QCEDEV/QCRYPTO/QCOM_MSM_QCE` -> port qseecom + smcinvoke; qcedev only if a blob opens it.
- DSP: `MSM_ADSPRPC`, `ADSPRPC_QGKI`, `MSM_CDSP_LOADER`, `QCOM_CDSP_RM`, `QCOM_GLINK_PKT`, `QCOM_SMP2P_SLEEPSTATE`, `UIO_MSM_SHAREDMEM`.
- GPU: `QCOM_KGSL*`, `DEVFREQ_GOV_QCOM_ADRENO_TZ`, `DEVFREQ_GOV_QCOM_GPUBW_MON`.
- Data: `IPA3`, `IPA_WDI_UNIFIED_API`, `SPS`, `USB_BAM`, `USB_F_GSI/DIAG/CDEV/QDSS/CCID`.
- WLAN/BT: `ICNSS2*`, `CNSS_QCA6750`, `QCA_CLD_WLAN`, `CNSS_UTILS`, `CNSS_GENL`, `WCNSS_MEM_PRE_ALLOC`, `CNSS2*` (unbound), `MSM_BT_POWER`, `BTFM_SLIM`, `SLIMBUS_MSM_NGD`.
- Media: `MSM_CVP`, `MSM_GLOBAL_SYNX`, `MSM_EXT_DISPLAY`.
- Perf/thermal (blobs tolerate absence): `SCHED_WALT`, `MSM_PERFORMANCE*`, `QCOM_HYP_CORE_CTL`, `QCOM_RUN_QUEUE_STATS`, memlat/bwmon/RIMPS/PLH/SCMI vendor protocols, `QTI_QMI_COOLING_DEVICE`, `QTI_QMI_SENSOR`, cpu isolate/hotplug/voltage cooling, `QTI_SDPM_CLOCK_MONITOR`.
- IOMMU extensions the techpacks call: `IOMMU_IO_PGTABLE_FAST`, `IOMMU_DYNAMIC_DOMAINS`, `QCOM_LAZY_MAPPING`, `QCOM_IOMMU_*_QUIRKS`, `QTI_IOMMU_SUPPORT`. No upstream equivalent of the `DOMAIN_ATTR_*` API (removed in 5.13); each techpack's SMMU glue has to be rewritten against plain `iommu_paging_domain_alloc()` + `qcom,iommu-*` DT handling of its own.
- Unbound on this phone: `MSM_SPCOM`, `MSM_SPSS_UTILS`, `RPMSG_QCOM_GLINK_SPSS`, `QSEE_IPC_IRQ*`, `SPU_VERIFY`, `MSM_QBT_HANDLER`, `QCOM_FSA4480_I2C`, `MAX31760_FAN_CONTROLLER`, `REGULATOR_QPNP_AMOLED`, `SENSORS_QTI_AMOLED_ECM` -> drop.

### 2.c Samsung-specific (215)

- `arch/arm64`: MACH_A52SXQ_EUR_OPEN SEC_A52SXQ_PROJECT SEC_PM
- `block`: BLK_SEC_STATS BLOCK_SUPPORT_STLOG MQ_IOSCHED_SSG
- `drivers/adsp_factory`: ADSP_FACTORY AK09918_FACTORY FLIP_COVER_DETECTOR_FACTORY LSM6DSO_FACTORY STK31610_FACTORY
- `drivers/battery/charger/pca9468_charger`: BATTERY_SAMSUNG CHARGER_PCA9468 SEC_PD SEND_PDMSG_IN_PPS_REQUEST_WORK
- `drivers/battery/charger/sm5714_charger`: CHARGER_SM5714
- `drivers/battery/common`: AFC_CHARGER_MODE BATTERY_AGE_FORECAST BATTERY_CISD BATTERY_GKI DIRECT_CHARGING STEP_CHARGING SUPPORT_HV_CTRL
- `drivers/battery/fuelgauge/sm5714_fuelgauge`: FUELGAUGE_SM5714
- `drivers/block/zram`: ZRAM_LRU_WRITEBACK
- `drivers/connector`: PROC_CONNECTOR_SELECT_EVENTS
- `drivers/cpufreq`: CPU_FREQ_LIMIT
- `drivers/fingerprint`: FINGERPRINT_SECURE SENSORS_ET7XX SENSORS_FINGERPRINT SENSORS_FINGERPRINT_QCOM
- `drivers/hwmon/sec_thermistor`: SENSORS_SEC_THERMISTOR
- `drivers/input/input_boost`: SEC_INPUT_BOOSTER SEC_INPUT_BOOSTER_QC
- `drivers/input/misc/hall`: HALL_LOGICAL HALL_NOTIFIER INPUT_HALL_IC
- `drivers/input/sec_input`: INPUT_SEC_INPUT INPUT_SEC_NOTIFIER INPUT_SEC_SECURE_TOUCH INPUT_TOUCHSCREEN_TCLMV2 SEC_DEBUG_TSP_LOG TOUCHSCREEN_DUMP_MODE
- `drivers/input/sec_input/stm`: TOUCHSCREEN_STM
- `drivers/leds`: LEDS_SM5714
- `drivers/mfd/sm/sm5714`: MFD_SM5714
- `drivers/misc/drb`: DEV_RIL_BRIDGE
- `drivers/mmc`: MMC_SUPPORT_STLOG
- `drivers/mmc/core`: SEC_STORAGE_MMC
- `drivers/muic/common`: HICCUP_CHARGER MUIC_HV MUIC_NOTIFIER MUIC_SUPPORT_PDIC USE_MUIC
- `drivers/muic/sm/sm5714`: MUIC_BCD_RESCAN MUIC_SM5714
- `drivers/nfc`: SAMSUNG_NFC SEC_NFC SEC_NFC_DUPLICATED_IRQ_WQ_QC SEC_NFC_LOGGER
- `drivers/pci`: SEC_PCIE SEC_PCIE_AER SEC_PCIE_L1SS
- `drivers/perf_mgr`: SEC_PERF_MANAGER SEC_PERF_MANAGER_QC
- `drivers/regulator/s2mpb03`: REGULATOR_S2MPB03
- `drivers/samsung`: DRV_SAMSUNG SAMSUNG_LMKD_DEBUG SAMSUNG_PRODUCT_SHIP SEC_DEBUG SEC_EXT SEC_MPARAM SEC_PARAM SEC_SYSUP
- `drivers/samsung/debug`: KERNEL_MODE_NEON_DEBUG SEC_BOOTSTAT SEC_DEBUG_DUMP_TASK_STACK SEC_DEBUG_MDM_FILE_INFO SEC_DEBUG_MODULE_INFO SEC_DEBUG_SCHED_LOG SEC_DEBUG_SCHED_LOG_IRQ_V2 SEC_DEBUG_SCHED_LOG_PER_CPU SEC_DEBUG_SUMMARY SEC_DEBUG_SUMMARY_DRIVER SEC_LOG_BUF SEC_LOG_BUF_NO_CONSOLE SEC_LOG_LAST_KMSG SEC_LOG_STORE_LAST_KMSG SEC_LOG_STORE_LPM_KMSG SEC_NOEYEINFO SEC_SSR_DEBUG_LEVEL_CHK SEC_STORE_POWER_ONOFF_HISTORY SEC_USER_RESET_DEBUG
- `drivers/samsung/misc`: ARGOS SEC_DEBUG_APPS_CLK_LOGGING SEC_MISC SEC_SMEM VBUS_NOTIFIER
- `drivers/samsung/quest`: SEC_QUEST SEC_QUEST_DDR_SCAN_USER SEC_QUEST_UEFI
- `drivers/scsi/ufs`: SEC_UFS_WB_FEATURE
- `drivers/sensors`: SENSORS SENSORS_SSC SENSORS_SX9364
- `drivers/soc/qcom/icnss2`: SEC_SS_CNSS_FEATURE_SYSFS
- `drivers/soc/qcom/memshare`: CP_DYNAMIC_MEM_RESERVE
- `drivers/staging/android`: SAMSUNG_FREECESS
- `drivers/staging/android/ion/heaps`: ION_POOL_AUTO_REFILL ION_RBIN_HEAP
- `drivers/sti/abc`: SEC_ABC SEC_ABC_COMMON SEC_ABC_HUB SEC_ABC_HUB_BOOTC SEC_ABC_HUB_CORE SEC_ABC_SPEC_TYPE1
- `drivers/sti/common`: SEC_STI
- `drivers/switch`: SWITCH SWITCH_GPIO
- `drivers/tty/serial`: SERIAL_UART_SAMSUNG_USE
- `drivers/usb/dwc3`: USB_CHARGING_EVENT
- `drivers/usb/gadget`: USB_ANDROID_SAMSUNG_COMPOSITE USB_CONFIGFS_F_ACC USB_CONFIGFS_F_AUDIO_SRC USB_CONFIGFS_F_CONN_GADGET USB_CONFIGFS_F_MTP USB_CONFIGFS_F_PTP USB_CONFIGFS_F_SS_MON_GADGET USB_CONFIGFS_UEVENT USB_DUN_SUPPORT USB_F_ACC USB_F_AUDIO_SRC USB_F_CONN_GADGET USB_F_MTP USB_F_PTP USB_F_SS_MON_GADGET USB_G_ANDROID
- `drivers/usb/notify`: DISABLE_LOCKSCREEN_USB_RESTRICTION USB_AUDIO_ENHANCED_DETECT_TIME USB_DEBUG_DETAILED_LOG USB_EXTERNAL_NOTIFY USB_HOST_NOTIFY USB_HOST_SAMSUNG_FEATURE USB_HW_PARAM USB_INTERFACE_LPM_LIST USB_NOTIFIER USB_NOTIFY_LAYER USB_NOTIFY_PROC_LOG USB_STORAGE_DETECT
- `drivers/usb/typec`: SUPPORT_USB_TYPEC_OPS
- `drivers/usb/typec/common`: PDIC_NOTIFIER PDIC_USE_MODULE_PARAM
- `drivers/usb/typec/manager`: IF_CB_MANAGER USB_TYPEC_MANAGER_NOTIFIER
- `drivers/usb/typec/sm/sm5714`: PDIC_SM5714 SM5714_FACTORY_MODE SM5714_SUPPORT_SBU SM5714_WATER_DETECTION_ENABLE
- `drivers/vibrator/common`: SEC_VIBRATOR SEC_VIB_NOTIFIER
- `drivers/vibrator/dc`: DC_VIBRATOR
- `fs`: SEC_DEBUG_FPUT_WATCHDOG
- `fs/crypto`: FSCRYPT_SDP
- `fs/f2fs`: F2FS_SEC_BLOCK_OPERATIONS_DEBUG F2FS_SEC_SUPPORT_DNODE_RELOCATION F2FS_STRICT_BUG_ON
- `fs/fat`: FAT_SUPPORT_STLOG FAT_UEVENT
- `fs/fuse`: FUSE_SUPPORT_STLOG
- `fs/proc`: PROC_AVC PROC_DLOG PROC_FSLOG PROC_STLOG
- `fs/pstore`: PSTORE_PMSG_SSPLOG SEC_EVENT_LOG
- `fs/sdfat`: SDFAT_ALIGNED_MPAGE_WRITE SDFAT_DBG_MSG SDFAT_DEBUG SDFAT_DELAYED_META_DIRTY SDFAT_FS SDFAT_STATISTICS SDFAT_SUPPORT_STLOG SDFAT_UEVENT SDFAT_USE_FOR_EXFAT
- `init`: MEMCG_FORCE_USE_VM_SWAPPINESS VM_EVENT_COUNT_CLEAN_PAGE_RECLAIM
- `mm`: BALANCE_ANON_FILE_RECLAIM DIRECT_RECLAIM_FILE_PAGES_ONLY INCREASE_MAXIMUM_SWAPPINESS MEMBLOCK_MEMSIZE MEMCG_HEIMDALL MM_STAT_UNRECLAIMABLE_PAGES PAGE_BOOST PAGE_BOOST_RECORDING RBIN
- `mm/sec_mm`: SEC_MM
- `net`: NET_ANALYTICS
- `security`: SDP
- `sound/soc/samsung`: SND_SOC_SAMSUNG_AUDIO
- `techpack/camera/drivers`: CAMERA_FRAME_CNT_CHECK CAMERA_FRAME_CNT_DBG CAMERA_SSM_I2C_ENV CAMERA_SYSFS_V2 GC5035_MACRO_OTP_DD_AUTOLOAD SAMSUNG_CAMERA_OTP SAMSUNG_FRONT_EEPROM SAMSUNG_OIS_MCU_STM32 SAMSUNG_OIS_Z_AXIS_CAL SAMSUNG_REAR_DUAL SAMSUNG_REAR_QUADRA SAMSUNG_REAR_TRIPLE SAMSUNG_SUPPORT_MULTI_MODULE USE_CAMERA_HW_BIG_DATA
- `techpack/display/msm/samsung`: DISPLAY_SAMSUNG
- `techpack/display/msm/samsung/S6E3FC3_AMS646YD01_LO`: PANEL_S6E3FC3_AMS646YD01_LO_FHD

### 2.d Debug, renamed core options, other hardware (163): safe to drop

- `KernelSU-Next/kernel`: KSU_KPROBES_HOOK
- `KernelSU/kernel`: KSU
- `arch`: 64BIT_TIME ARCH_SUPPORTS_THINLTO CC_HAS_STACKPROTECTOR_NONE CFI_CLANG_SHADOW HAVE_ARCH_STACKLEAK HAVE_CONTEXT_TRACKING HAVE_COPY_THREAD_TLS HAVE_RCU_TABLE_FREE SHADOW_CALL_STACK_VMAP THINLTO
- `arch/arm`: SYS_SUPPORTS_HUGETLBFS
- `arch/arm64`: ARM64_MODULE_PLTS ARM64_SSBD ARM64_UAO ARM64_VHE BUILD_ARM64_DT_OVERLAY BUILD_ARM64_UNCOMPRESSED_KERNEL HARDEN_EL2_VECTORS HOLES_IN_ZONE RODATA_FULL_DEFAULT_ENABLED TLB_CONF_HANDLER
- `arch/arm64/crypto`: ARM64_CRYPTO CRYPTO_SHA1_ARM64_CE CRYPTO_SHA256_ARM64 CRYPTO_SHA2_ARM64_CE
- `block`: BLK_MQ_PCI BLK_MQ_VIRTIO BLK_SCSI_REQUEST BLOCK_COMPAT
- `crypto`: CRYPTO_BLKCIPHER CRYPTO_BLKCIPHER2 CRYPTO_GF128MUL CRYPTO_MANAGER_DISABLE_TESTS CRYPTO_NULL2 CRYPTO_POLY1305
- `drivers/android`: ANDROID
- `drivers/bus/mhi/devices`: MHI_UCI
- `drivers/char`: MSM_RDBG RANDOM_TRUST_BOOTLOADER
- `drivers/clk`: CLKDEV_LOOKUP
- `drivers/dax`: DAX_DRIVER
- `drivers/edac`: EDAC_KRYO_ARM64 EDAC_KRYO_ARM64_PANIC_ON_UE EDAC_QCOM_LLCC_PANIC_ON_UE EDAC_QGKI
- `drivers/gpu/drm`: DRM_GEM_CMA_HELPER DRM_KMS_CMA_HELPER
- `drivers/hid`: AKSYS_QRD_FF HID_AKSYS_QRD HID_QVR
- `drivers/hwtracing/coresight`: CORESIGHT_CSR CORESIGHT_CTI_SAVE_DISABLE CORESIGHT_HWEVENT CORESIGHT_OST CORESIGHT_QGKI CORESIGHT_REMOTE_ETM CORESIGHT_TGU
- `drivers/input/touchscreen`: TOUCHSCREEN_PROPERTIES TOUCHSCREEN_SYNAPTICS_DSX
- `drivers/input/touchscreen/focaltech_touch`: FTS_TRUSTED_TOUCH TOUCHSCREEN_FTS
- `drivers/input/touchscreen/nt36xxx`: NOVATEK_TRUSTED_TOUCH TOUCHSCREEN_NT36XXX
- `drivers/input/touchscreen/st`: ST_TRUSTED_TOUCH TOUCHSCREEN_ST
- `drivers/input/touchscreen/synaptics_dsx`: TOUCHSCREEN_SYNAPTICS_DSX_CORE TOUCHSCREEN_SYNAPTICS_DSX_FW_UPDATE TOUCHSCREEN_SYNAPTICS_DSX_FW_UPDATE_EXTRA_SYSFS TOUCHSCREEN_SYNAPTICS_DSX_I2C TOUCHSCREEN_SYNAPTICS_DSX_RMI_DEV TOUCHSCREEN_SYNAPTICS_DSX_TEST_REPORTING
- `drivers/iommu`: DMA_CONFIGURE_ALIGNMENT IOMMU_LIMIT_IOVA_ALIGNMENT IOMMU_TLBSYNC_DEBUG
- `drivers/irqchip`: ARM_GIC_V3_ITS_PCI PARTITION_PERCPU QCOM_SHOW_RESUME_IRQ QGKI_SHOW_S2IDLE_WAKE_IRQ
- `drivers/md`: DM_ANDROID_VERITY_AT_MOST_ONCE_DEFAULT_ENABLED
- `drivers/media/platform`: CEC_PLATFORM_DRIVERS
- `drivers/media/v4l2-core`: VIDEO_V4L2
- `drivers/net/phy`: MDIO_DEVICE
- `drivers/of`: OF_NET
- `drivers/pci`: PCI_MSI_IRQ_DOMAIN
- `drivers/perf`: QCOM_LLCC_PMU
- `drivers/power/avs`: POWER_AVS
- `drivers/soc/qcom`: MSM_CORE_HANG_DETECT QCOM_DCC_V2 QCOM_LLCC_PERFMON QCOM_MEMORY_DUMP_V2 QCOM_MICRODUMP QCOM_RTIC QCOM_SYSMON_SUBSYSTEM_STATS QTI_DDR_STATS_LOG QTI_PMIC_PON_LOG QTI_RPM_STATS_LOG
- `drivers/spmi`: SPMI_MSM_PMIC_ARB_DEBUG
- `drivers/staging/android`: ANDROID_VSOC
- `drivers/tty/serial`: SERIAL_SAMSUNG_UARTS_4
- `drivers/usb/misc`: USB_REDRIVER USB_REDRIVER_NB7VPQ904M
- `drivers/video/backlight`: BACKLIGHT_GENERIC
- `drivers/video/fbdev`: FB_CMDLINE
- `fs`: MANDATORY_FILE_LOCKING
- `fs/ntfs`: NTFS_DEBUG
- `fs/pstore`: PSTORE_DEFLATE_COMPRESS PSTORE_DEFLATE_COMPRESS_DEFAULT
- `init`: BASE_FULL BUILDTIME_EXTABLE_SORT CC_HAS_ASM_GOTO EMBEDDED GKI_OPT_FEATURES KALLSYMS_BASE_RELATIVE MEMCG_KMEM MEMCG_SWAP MEMCG_SWAP_ENABLED PERF_KERNEL_SHARE PRINTK_NMI
- `kernel/dma`: ARCH_HAS_DMA_COHERENT_TO_PFN DMA_COHERENT_HINT_CACHED DMA_REMAP
- `kernel/irq`: GENERIC_MSI_IRQ_DOMAIN HANDLE_DOMAIN_IRQ
- `kernel/rcu`: RCU_FAST_NO_HZ SRCU
- `kernel/time`: PRINT_SUSPEND_EPOCH_QGKI
- `kernel/trace`: HAVE_FTRACE_MCOUNT_RECORD IPC_LOGGING KPROBES_QGKI QCOM_RTB QCOM_RTB_QGKI QCOM_RTB_SEPARATE_CPUS
- `lib`: ARCH_HAS_UBSAN_SANITIZE_ALL CC_HAS_SANCOV_TRACE_PC CRC32_SLICEBY8 LIBCRC32C OPTIMIZE_INLINING SCHED_DEBUG
- `lib/crypto`: CRYPTO_LIB_BLAKE2S_GENERIC
- `lib/vdso`: GENERIC_COMPAT_VDSO
- `lib/xz`: XZ_DEC_IA64
- `mm`: ARCH_HAS_PTE_DEVMAP ARCH_SUPPORTS_SPECULATIVE_PAGE_FAULT FAULT_AROUND_4KB FRAME_VECTOR HAVE_FAST_GUP HAVE_MEMORY_PRESENT HAVE_USERSPACE_LOW_MEMORY_KILLER MULTIPLE_KSWAPD PRIORITIZE_OOM_TASKS PROCESS_RECLAIM SPECULATIVE_PAGE_FAULT
- `net/bluetooth`: BT_HS
- `net/bridge`: HYFI_BRIDGE_HOOKS
- `net/dsa`: HAVE_NET_DSA
- `net/netfilter`: NF_CT_PROTO_DCCP NF_LOG_COMMON
- `net/unix`: UNIX_SCM
- `net/wireless`: WEXT_SPY
- `security`: HAVE_HARDENED_USERCOPY_ALLOCATOR
- `security/keys`: KEYS_COMPAT

Notes on (d):
- `KSU`, `KSU_KPROBES_HOOK`: KernelSU is a ROM feature added by the owner, not hardware. On a 6.18
  GKI kernel it is used as its own module/manager build, not as an in-tree patch.
- `IPC_LOGGING`: debug, but every techpack and most `drivers/soc/qcom` files call
  `ipc_log_string()`. Provide a header of no-op stubs instead of porting it.
- `QCOM_RTB`, `QCOM_DCC_V2`, `QCOM_MEMORY_DUMP_V2`, `CORESIGHT_*`, `EDAC_KRYO_ARM64`,
  `MSM_CORE_HANG_DETECT`: only useful for Qualcomm ramdump analysis.
- The Synaptics/Novatek/Focaltech/ST touch options, `HID_QVR`, `HID_AKSYS_QRD`, `MHI_UCI`,
  `USB_REDRIVER_NB7VPQ904M` are QRD reference-board leftovers.
- The rest are core options that were renamed, became unconditional or were removed
  (`CRYPTO_BLKCIPHER`, `MEMCG_SWAP`, `SRCU`, `ARM64_UAO`, `THINLTO`, `CFI_CLANG_SHADOW`, ...).

## 3. Porting cost per driver, classes (b) and (c)

Difficulty scale: S = days, mostly mechanical (signatures, renamed helpers). M = 1-3 weeks, some
subsystem API rework. L = 1-2 months, core dependency replaced (ION, PIL, SCM, typec). XL =
several months or a rewrite; hundreds of API call sites in a subsystem that was restructured.
"drop" = not needed on this phone. Estimates are for one experienced person compiling against
6.18 and assume the shims of section 3.4 exist; they are judgment, not measurement.

### 3.1 Class (b): Qualcomm downstream drivers (38 items, 1,707,710 built `.c` lines)

Without qcacld/qca-wifi-host-cmn (746,293 lines) and the drop items, the part worth porting is
about 811 k lines (151 k lines are drop items); the breakdown is in 3.5.

| Item | built .c files | LOC (.c built) | LOC (.h in dirs) | Difficulty | Blob / userspace consumer | Why (APIs that changed 5.4 -> 6.18) | grep evidence (pattern hits) |
|---|---|---|---|---|---|---|---|
| display-sde | 70 | 94,736 | 15,604 | XL | SDE HWC/composer + libsdmcore, gralloc (SDE DRM custom props, sde ioctls) | DRM atomic/bridge/DSC helper churn (drm_dsc moved to drm/display, connector/encoder helper signatures, `drm_gem` object funcs, fb helpers), iommu domain attrs removed (5.13), pm_qos API (5.7), sde_rsc on rpmh, dma-buf locking rules (6.2), procfs `proc_ops` | drm 683, procfs 29, dma-buf 26, sysfs/class 20, iommu 18 |
| display-dsi | 24 | 37,855 | 6,508 | L | part of the SDE stack | mipi_dsi helpers, regulator set_load, legacy GPIO, clk handoff; panel timing/DSC parser tied to `qcom,mdss-dsi-*` DT | drm 74, gpio-legacy 32, procfs 10, reg-ext 9, strlcpy 8 |
| display-dp | 22 | 32,663 | 3,586 | drop | none on this phone (USB 2.0-only connector) | - | drm 65, gpio-legacy 25, procfs 23, strlcpy 14, extcon 4 |
| camera-core(isp,icp,jpeg,lrme,cdm,cpas,req_mgr,smmu,sync,utils,core,cust) | 113 | 109,092 | 53,377 | XL | CamX/CHI (camera.qcom.so, com.qti.chi.override.so) via cam_req_mgr/cam_sync UAPI | v4l2 subdev pad-state + async notifier API, media controller, vb2, iommu attrs (fast map, secure CB), ION fd->dma-buf, msm_bus->icc, regulator_set_load, `clk_set_flags`, strlcpy x27, timeval in UAPI structs | v4l2/media 220, dma-buf 38, strlcpy 27, iommu 23, remove-int/probe2 17 |
| camera-sensor-module(+Samsung ois/eeprom/sysfs) | 32 | 39,550 | 32,419 | L | CamX sensor drivers (com.qti.sensormodule.*.bin) + Samsung camera HAL sysfs (/sys/class/camera) | CCI/I2C/SPI IO, i2c probe signature, sysfs class (181 hits), `filp_open`/kernel file IO for calibration, PMIC flash via SM5714 fled, S2MPB03 regulators | v4l2/media 237, sysfs/class 181, spi/i2c 70, strlcpy 30, set_fs/vfs 17 |
| audio-asoc-platform(routing,dai,pcm,compress,lsm,voice) | 21 | 94,032 | 0 | XL | audio HAL (audio.primary.lahaina.so), mixer_paths, ACDB loader, voice (CSD/QMI), sound trigger | ALSA SoC: 9085 API hits. `snd_soc_dai_link` components, `snd_soc_pcm_runtime` accessors, `snd_pcm_ops.copy_user`->`copy` (iov_iter, 6.5), compress ops, kcontrol/TLV, DAPM locking, `snd_soc_component` driver callbacks | alsa 9085, strlcpy 33, remove-int/probe2 28, ipc/qmi/glink 19, sysfs/class 8 |
| audio-dsp-q6(afe,asm,adm,voice,lsm,core,cal,ion) | 48 | 69,722 | 1,187 | L | same (ACDB cal ioctls, /dev/msm_audio_cal, rtac) | APR over rpmsg (stable), SSR/PDR notifier (downstream subsys API -> upstream remoteproc/pdr), msm_audio_ion (ION->dma-buf heaps), scm (hyp_assign) | ipc/qmi/glink 951, pil/ssr 75, procfs 42, strlcpy 28, scm 24 |
| audio-codecs-bolero+wcd938x+mbhc | 26 | 31,381 | 1,249 | L | same card; mixer control names used by mixer_paths | ASoC component API, soundwire (downstream swr bus, not upstream soundwire), regmap, wakeup sources, extcon/jack | alsa 1895, strlcpy 15, wakelock 15, remove-int/probe2 9, reg-ext 7 |
| audio-machine-lahaina | 1 | 10,049 | 0 | M | card name/dai-link ids the HAL expects | dai_link layout macros, pm_qos, snd_soc_card API | alsa 837, pm_qos 6, remove-int/probe2 1 |
| audio-soc(swr,lpi pinctrl,snd_event)+ipc(apr) | 9 | 8,882 | 1,304 | M | - | pinctrl gpio_chip callbacks, rpmsg, pm_runtime | ipc/qmi/glink 413, pil/ssr 7, pm_qos 6, procfs 4, remove-int/probe2 4 |
| audio-tas256x | 11 | 8,883 | 2,825 | M | TI SmartAmp calibration lib in audio HAL (tas25xx algo via AFE) | ASoC, regmap, i2c probe, legacy GPIO | alsa 265, sysfs/class 29, gpio-legacy 7, procfs 2, spi/i2c 2 |
| dataipa(ipa3+gsi)+ipa_fmwk | 50 | 107,492 | 69,498 | XL | ipacm, IPA offload HAL, netmgrd/qcrild data path (/dev/ipa, wwan_ioctl, rmnet_ipa0) | netdev/skb/NAPI API, iommu attrs, msm_bus->icc, PIL notifier, smp2p, f_gsi coupling, wakeup sources, 69k lines of headers/UAPI | net 538, ipc/qmi/glink 271, iommu 47, strlcpy 32, sysfs/class 25 |
| datarmnet(core+shs+offload) | 28 | 13,780 | 2,957 | M | netmgrd (rmnet rtnl attrs, QMAPv5, DFC/QMI flow control) | netdev features/GRO/GSO helpers, rcu, per-cpu stats, genl; upstream `rmnet` exists but lacks DFC/QMAPv5 coalescing/SHS | net 526, ipc/qmi/glink 70, sched/cpu 17, mm 15, timer/ktime 8 |
| video-msm_vidc | 19 | 34,159 | 8,011 | L | Codec2/OMX vidc blobs (c2.qti.*, /dev/video32,33 msm_vidc UAPI + private V4L2 controls) | v4l2 ioctl/ctrl framework, vb2, ION->dma-buf, PIL (venus fw) -> qcom_mdt_loader/PAS, icc, regulator/gdsc | v4l2/media 571, ipc/qmi/glink 62, strlcpy 23, dma-buf 14, ion 9 |
| cvp+synx | 21 | 19,042 | 5,343 | drop | CVP (EVA) only for optional camera features; camera techpack does not link synx | - | ipc/qmi/glink 25, sysfs/class 16, dma-buf 16, ion 7, procfs 6 |
| kgsl | 51 | 57,921 | 18,737 | L | Adreno GLES/Vulkan blobs (libGLESv2_adreno, vulkan.adreno) via /dev/kgsl-3d0 | mm (vm_flags accessors 6.3, shrinker API 6.7, page pools, `get_user_pages` changes), io-pgtable/iommu domain attrs + per-process pagetables (upstream uses adreno-smmu-priv), devfreq governors, gdsc-as-regulator, scm, clk | iommu 92, sysfs/class 62, mm 41, clk-ext 37, scm 23 |
| ion+msm heaps+rbin | 17 | 8,033 | 644 | M | every HAL blob using libion (/dev/ion ABI: camera, video, audio, display, DRM/Widevine, keymaster) | ION core deleted in 5.11. Port = compat char device translating ION_IOC_ALLOC/HEAP_QUERY to dma-buf heaps + qcom secure/CMA heaps (hyp_assign). Samsung rbin heap dropped | ion 626, mm 32, dma-buf 11, sysfs/class 5, sched/cpu 5 |
| qseecom(+compat,hdcp) | 3 | 12,571 | 0 | L | qseecomd, KeyMint/Gatekeeper TAs, Widevine, Samsung TAs, fingerprint TA (libQSEEComAPI) | SCM API rewritten (scm_call2 -> qcom_scm_*), qtee_shmbridge -> qcom_tzmem, ION fd handling -> dma-buf, ICE/UFS key ioctls, compat ioctl, bus scaling | scm 135, dma-buf 28, strlcpy 16, ion 4, icc 4 |
| smcinvoke+shmbridge+tz_log | 3 | 4,436 | 0 | M | newer TAs/mink clients (libminkdescriptor), DRM | scm, shmbridge->tzmem, dma-buf, anon_inode fd objects; upstream `qcomtee` is the replacement but has a different UAPI | scm 96, dma-buf 9, ipc/qmi/glink 8, mm 4, sysfs/class 4 |
| secure_buffer+mem-buf | 3 | 3,156 | 0 | S | kernel API for secure heaps (hyp_assign_phys) | thin wrapper over `qcom_scm_assign_mem`; mem-buf (Haven) dropped | dma-buf 33, scm 16, ion 10, sysfs/class 4, procfs 3 |
| adsprpc(fastrpc downstream)+cdsprm+cdsp-loader | 4 | 10,440 | 0 | L | libadsprpc/libcdsprpc/libsdsprpc: sensors (sscrpcd), camera (CDSP), audio; /dev/adsprpc-smd(-secure) | rpmsg, dma-buf, mm (vma/vm_flags, mmap_lock), SSR/PDR notifiers, scm hyp_assign, pm_qos, wakeup source | ipc/qmi/glink 168, mm 27, pil/ssr 25, dma-buf 23, sysfs/class 12 |
| PIL/SSR(peripheral-loader,subsys-pil-tz,ssr,sysmon,ramdump,svc loc/notif,glink_ssr,microdump) | 10 | 8,706 | 0 | M (shim) | pm-service/per_mgr, ssr tools read /sys/bus/msm_subsys; kernel clients call subsystem_get/notif | do NOT port: use upstream qcom_q6v5_pas + sysmon + pdr; write a small shim exposing `subsys_notif_register_notifier`/`subsystem_get` on top of remoteproc for the techpacks | pil/ssr 315, ipc/qmi/glink 143, strlcpy 18, sysfs/class 11, scm 9 |
| glink_pkt+glink_probe+smp2p_sleepstate+smsm | 4 | 1,872 | 0 | S | /dev/glinkpkt_* nodes (GPS/loc, ss bt/wlan helper daemons, slate) | rpmsg char-style driver; glink_probe replaced by remoteproc glink-edge | ipc/qmi/glink 214, net 13, sysfs/class 7, wakelock 3, pil/ssr 3 |
| memshare+sharedmem-uio+rdbg | 2 | 1,463 | 329 | S | modem (QMI DHMS memory for GPS/diag), rmt_storage blob (UIO) | QMI server, dma_alloc_attrs; rdbg dropped; or use upstream rmtfs_mem + open rmtfs | ipc/qmi/glink 44, sysfs/class 4, scm 4, procfs 1, mm 1 |
| icnss2(WCN6750 platform) | 5 | 10,276 | 920 | L | cnss-daemon, wifi HAL/wpa_supplicant-qcacld, wlan firmware ini | QMI, PIL->remoteproc(wpss), iommu, regulators, SMP2P, power_supply; QC ships newer icnss2 for 6.x | ipc/qmi/glink 223, net 24, pil/ssr 23, sysfs/class 11, strlcpy 11 |
| qcacld-3.0+qca-wifi-host-cmn | 597 | 746,293 | 412,770 | XL | same | cfg80211/mac80211-less fullmac against 5.4 nl80211: wiphy locking, MLO link ids, channel/BSS API, netdev ops, wext removal, `ndo_do_ioctl` split, wakeup sources (402 hits) | net 7471, wakelock 402, sysfs/class 117, crypto 41, strlcpy 31 |
| cnss2+cnss_utils+prealloc+genl | 14 | 23,766 | 270,193 | drop (cnss2) / S (utils) | cnss2 is built but nothing binds (no QCA6490 node, PCIe disabled) | cnss_utils/prealloc are needed only if qcacld is kept | ipc/qmi/glink 208, net 38, pil/ssr 34, gpio-legacy 13, sysfs/class 12 |
| btpower+btfm_slim | 4 | 2,783 | 0 | S / M | vendor BT HAL (btpower ioctl on /dev/btpower, UART ttyHS0); btfm_slim = SCO/A2DP/FM audio over SLIMbus | legacy GPIO (41), regulator, ASoC codec DAI over slimbus | gpio-legacy 41, alsa 29, reg-ext 6, sysfs/class 6, procfs 2 |
| slimbus-msm-ngd | 2 | 4,183 | 0 | M | only for btfm_slim | upstream `qcom-ngd-ctrl` covers the controller | ipc/qmi/glink 49, pil/ssr 9, iommu 6, wakelock 6, sysfs/class 6 |
| WALT sched | 7 | 7,076 | 1,046 | drop | perf HAL (libqti-perfd) writes WALT sysctls; failures are non-fatal | scheduler internals; ACK offers vendor hooks only. Use EAS/schedutil + uclamp | sched/cpu 368, input 4, sysfs/class 3, mm 2 |
| msm_performance+hyp_core_ctl+rq_stats | 3 | 2,462 | 0 | drop/stub | perf HAL sysfs nodes | - | sched/cpu 80, sysfs/class 7, procfs 1, timer/ktime 1 |
| devfreq memlat/bwmon/rimps | 13 | 7,653 | 0 | drop | none (perf tuning) | upstream icc-bwmon covers DDR/L3 scaling | sysfs/class 26, ipc/qmi/glink 12, icc 6, remove-int/probe2 4, sched/cpu 1 |
| thermal-qcom downstream(qmi cooling/sensors,bcl,cpu isolate/hotplug,lmh_dcvs,adc-tm,tsens2xxx) | 22 | 10,332 | 856 | S (qmi_cooling only) | thermal-engine blob (replace with AOSP thermal HAL) | use upstream tsens/adc-tm5/lmh; port only qmi_cooling (575 LOC) if modem/PA mitigation is wanted | ipc/qmi/glink 55, remove-int/probe2 11, spi/i2c 9, icc 6, strlcpy 5 |
| usb gadget functions downstream(gsi,diag,cdev,qdss,ccid,mtp_samsung,acc,audio_src,conn_gadget,ss_mon) | 12 | 16,890 | 0 | drop | diag/QDSS/rmnet-over-USB only for QPST-style tools; MTP is FunctionFS in AOSP; ACK ships f_accessory | - | usb 488, alsa 38, sysfs/class 19, procfs 13, strlcpy 12 |
| qce/qcedev/qcrypto | 5 | 15,087 | 1,386 | M (only if needed) | /dev/qce: check whether any shipped blob opens it (HDCP/DRM libs sometimes do) | crypto API (ablkcipher removed 5.5 -> skcipher), icc, dma-buf | crypto 319, icc 23, dma-buf 7, mm 4, sysfs/class 4 |
| haven hypervisor+neuron+guestvm+qrtr-haven | 20 | 10,287 | 617 | drop | none (trusted-VM touch/UI not used) | - | net 97, ipc/qmi/glink 74, scm 7, sysfs/class 5, pil/ssr 5 |
| qcom debug(dcc,mem dump,wdt core,rtb,coresight ext,eud,hang detect,llcc perfmon,boot/ddr/sleep stats,kryo edac) | 27 | 19,731 | 0 | drop | none | upstream qcom-wdt, qcom_stats, qcom_eud cover what matters; `ipc_logging` needs a no-op stub header for techpacks | sysfs/class 159, ipc/qmi/glink 136, scm 21, remove-int/probe2 15, strlcpy 10 |
| pci-msm | 2 | 10,975 | 0 | drop | none (PCIe node disabled) | - | ipc/qmi/glink 72, spi/i2c 27, gpio-legacy 20, procfs 11, sysfs/class 10 |

### 3.2 Class (c): Samsung drivers (24 items, 216,272 built `.c` lines)

The Samsung camera additions (OIS MCU, EEPROM/OTP, `/sys/class/camera`, about 15 k lines) are
inside "camera-sensor-module" in table 3.1 because they are edits to Qualcomm files.

| Item | built .c files | LOC (.c built) | LOC (.h in dirs) | Difficulty | Blob / userspace consumer | Why (APIs that changed 5.4 -> 6.18) | grep evidence (pattern hits) |
|---|---|---|---|---|---|---|---|
| samsung-panel-ss_dsi | 43 | 63,411 | 121,224 | XL as-is / M as new drm_panel | Samsung display HAL bits: mDNIe, HBM/finger-mask for the optical fingerprint, AOD self-display, MAFPC, brightness tables (/sys/class/lcd/panel, /sys/class/mdnie) | glued into SDE `dsi_panel` (not a drm_panel); 121k lines of headers/tables; sysfs x134, `filp_open` x50 (flash/POC), SPI DDI flash read, smart dimming | sysfs/class 134, set_fs/vfs 50, procfs 33, drm 31, spi/i2c 29 |
| S: sec_battery framework | 13 | 23,501 | 7,127 | L | Samsung health/battery sysfs ABI (/sys/class/power_supply/battery/* with 200+ custom attrs); AOSP health HAL needs only standard props | patches core `power_supply.h` (POWER_SUPPLY_EXT_PROP_*, extra types) - impossible against GKI KMI unless kept private (BATTERY_GKI path); 2318 Samsung-psy hits; wakeup sources x92; muic/pdic/vbus notifier web; alarmtimer | psy-samsung 2318, psy 988, wakelock 92, gpio-legacy 34, usb 32 |
| S: sm5714 charger+fuelgauge | 3 | 5,022 | 764 | M | - | power_supply desc/props, i2c, irq via MFD | psy 98, psy-samsung 47, gpio-legacy 8, spi/i2c 7, wakelock 4 |
| S: pca9468 direct charger | 1 | 5,193 | 646 | M | - | power_supply, PPS requests through sec_pd/pdic manager | psy 56, psy-samsung 31, spi/i2c 8, gpio-legacy 6, wakelock 3 |
| S: sm5714 mfd+muic+afc+fled | 9 | 7,367 | 0 | M | - | mfd cells, i2c probe signature, regmap-less raw i2c, wakeup sources, sysfs; fled used by camera flash | spi/i2c 48, wakelock 23, sysfs/class 18, gpio-legacy 16, psy 8 |
| S: sm5714 usbpd/typec+pdic+manager+usb notify | 18 | 23,144 | 155 | L | USB HAL (Samsung) reads /sys/class/usb_notify, ccic sysfs; AOSP USB HAL wants typec class | typec class API (ports/partners/altmodes, role switch), dual_role class removed, usb role/otg notifier, dwc3-msm private hooks (must be re-done for dwc3-qcom) | usb 558, spi/i2c 74, sysfs/class 24, gpio-legacy 21, psy 16 |
| S: s2mpb03 regulator | 1 | 749 | 0 | S | camera rails (VDD for sensors) | regulator_desc/of_match, i2c probe | spi/i2c 23, remove-int/probe2 3, sysfs/class 2 |
| S: sec_input+stm_ts touch | 13 | 18,884 | 4,708 | M | Samsung touch sysfs cmd interface (/sys/class/sec/tsp) used by ROM features (glove, AOT, SPAY) | input MT stable; i2c probe/remove signatures, `proc_ops`, kernel file IO (fw/log dump), secure-touch (drop), notifier to panel | input 74, sysfs/class 45, gpio-legacy 11, set_fs/vfs 10, spi/i2c 10 |
| S: input_booster | 3 | 1,677 | 0 | drop | - | - | icc 4, pm_qos 4, sysfs/class 3, input 2, strlcpy 1 |
| S: hall_ic | 2 | 874 | 0 | S (or gpio-keys SW_LID) | - | input, legacy GPIO | sysfs/class 15, input 14, wakelock 6, gpio-legacy 1, remove-int/probe2 1 |
| S: et7xx fingerprint | 5 | 3,127 | 750 | M | Egis TA + Samsung fingerprint HAL blob: /dev/esfp0 ioctls, /sys/class/fingerprint | SPI is TZ-owned (FINGERPRINT_SECURE): kernel only does power/reset/IRQ + QUP clock enable; needs a clock hook into spi-geni-qcom/geni-se; wakeup sources; pm_qos | spi/i2c 186, gpio-legacy 21, sysfs/class 18, wakelock 16, pm_qos 3 |
| S: sec-nfc | 2 | 1,894 | 2,741 | S | Samsung NFC HAL blob: /dev/sec-nfc ioctl + read/write | i2c, legacy GPIO x43, wakeup sources x39, clk-req irq | gpio-legacy 43, wakelock 39, spi/i2c 11, sysfs/class 8, procfs 3 |
| S: sx9360 grip+sensors_core | 2 | 2,300 | 1,535 | S | Samsung sensor HAL (grip via input + /sys/class/sensors) | or upstream `semtech,sx9360` IIO with an open HAL | sysfs/class 47, input 28, usb 8, gpio-legacy 7, spi/i2c 7 |
| S: adsp_factory+sensors_ssc | 8 | 3,859 | 198 | S | Samsung sensors HAL/factory: netlink to SSC, /sys/class/sensors/* | netlink, sysfs, kernel file IO for cal data | sysfs/class 77, set_fs/vfs 22, pil/ssr 7, net 4, remove-int/probe2 2 |
| S: vibrator | 2 | 1,578 | 29 | S | Samsung vibrator HAL sysfs (/sys/class/timed_output or sec_vibrator); AOSP HAL can use ff/gpio-vibrator | hrtimer, regulator/GPIO, sysfs | sysfs/class 31, gpio-legacy 5, psy 2, psy-samsung 1, remove-int/probe2 1 |
| S: abc | 5 | 2,327 | 0 | drop | - | - | sysfs/class 14, strlcpy 11, remove-int/probe2 2 |
| S: sec_thermistor | 1 | 370 | 39 | S | thermal HAL reads sec-thermistor sysfs (AP/PA/XO NTCs via ADC) | iio consumer; or `generic-adc-thermal` upstream | sysfs/class 7, remove-int/probe2 1, strlcpy 1 |
| S: sec_debug/log/param/quest/misc | 26 | 14,419 | 227 | S (keep 3 small pieces) / drop rest | bootloader reads imem restart_reason + upload_cause; `sec_class` gives /sys/class/sec for all Samsung drivers | sched/irq log hooks patched through core kernel (drop), kernel file IO on `param` partition, panic/reboot notifiers | sysfs/class 91, procfs 35, strlcpy 33, set_fs/vfs 28, ipc/qmi/glink 14 |
| S: sec perf (argos in misc, perf_mgr, cpufreq_limit) | 2 | 1,550 | 0 | drop | - | - | sched/cpu 20, sysfs/class 7, procfs 1 |
| S: sec gpio pinmux/switch/drb | 4 | 951 | 0 | drop | - | - | net 20, sysfs/class 6, gpio-legacy 3, procfs 2, remove-int/probe2 1 |
| S: sdp+fscrypt_sdp | 13 | 6,684 | 521 | drop | Knox SDP only; AOSP FBE does not use it | - | crypto 51, net 32, sysfs/class 4, procfs 3, timer/ktime 1 |
| S: mm (sec_mm, io_record/page_boost, freecess) | 7 | 1,371 | 18 | drop | - | - | net 8, mm 4, fb/notifier 2, strlcpy 1 |
| S: block/fs (ssg-iosched, blk-sec-stats, sdfat, stlog) | 18 | 21,766 | 2,593 | drop | - | upstream exfat replaces sdfat | mm 5, timer/ktime 5, sysfs/class 3, procfs 2 |
| audio-samsung-adaptation | 5 | 4,254 | 604 | M | Samsung audio HAL features (SoundAlive/voice adaptation via APR) | APR packets to ADSP modules, sysfs | alsa 109, ipc/qmi/glink 37, sysfs/class 24, remove-int/probe2 2 |

### 3.3 A better base than the 5.4 sources (to verify, not checked here)

For most (b) items, forward-porting the 5.4 file is the expensive way. Qualcomm publishes the same
drivers as out-of-tree modules for later kernels (5.10, 5.15, 6.1, 6.6 and newer) in separate
repositories (camera-kernel, display-drivers, video-driver, dataipa, datarmnet, securemsm-kernel
with qseecom/smcinvoke/qcedev, dsp-kernel with adsprpc, graphics-kernel with KGSL, mm-drivers,
wlan platform + qcacld-3.0, bt-kernel). Taking the newest release of each and re-adding the
yupik/SM7325 hardware tables and the 5.4-era UAPI is likely far less work than carrying 5.4 code
across 14 kernel releases. The risks are that newer releases dropped the hardware (camera IFE/CSID
version 165, Iris2 for video, A642L in KGSL) or changed UAPI structures the 5.4-era blobs were
compiled against. Each needs a one-day check before committing to a route. The audio techpack is
the exception: newer Qualcomm audio is AudioReach, and this phone's ADSP firmware is Elite (APR,
q6afe/q6asm/q6adm), so the newest usable base is whatever last Elite branch exists.

Likewise, Samsung publishes kernel sources for newer phones (5.10 to 6.6) containing later
versions of sec_battery, MUIC/PDIC, sec_input and sec_debug that already follow GKI rules (the
`BATTERY_GKI` option in this tree is a trace of that work). The A73 5G shares this exact tree
(`drivers/battery/common/a73xq/`), so it gives no newer base by itself.

### 3.4 Shims that many drivers need (do these first)

| Shim | Used by | Size |
|---|---|---|
| `ipc_logging` no-op header | all techpacks, soc/qcom | trivial |
| GDSC as regulator: keep `gdsc-regulator.c` (1,077 lines) or teach consumers `power-domains` | display, camera, video, kgsl, usb | S-M |
| Downstream regulator semantics (`regulator_set_load` mode switching on RPMh, proxy-consumer) | display, camera, touch, usb | S; upstream rpmh-regulator supports `regulator-allow-set-load` |
| `subsystem_get/put`, `subsys_notif_register_notifier`, service-notifier on top of remoteproc/pdr | audio, adsprpc, icnss2, ipa, vidc, camera ICP | M |
| `msm_bus` is already gone in 5.4 for this SoC (interconnect is used: 6-23 `icc_*` hits per techpack, 5 leftover `msm_bus` hits in SDE) | - | none |
| ION in-kernel API (`ion_alloc`, `msm_ion` heap ids) -> `dma_heap_buffer_alloc` | audio (msm_audio_ion), camera, vidc, qseecom, kgsl | part of the ION compat module |
| `qtee_shmbridge_*` -> `qcom_tzmem`; `scm_call2`-era wrappers -> `qcom_scm_*` | qseecom, smcinvoke, kgsl, adsprpc, display HDCP | M |
| IOMMU: `DOMAIN_ATTR_*`, fast-map, `qcom,iommu-dma` DT handling | display, camera, vidc, kgsl, ipa, adsprpc | M per techpack |
| `sec_class` / `sec_device_create` (90 lines) | every Samsung driver | trivial |
| Samsung notifier buses (`muic_notifier`, `pdic_notifier`, `vbus_notifier`, `usb_typec_manager`, `sec_input_notifier`, panel notifier) | charger, USB, touch, fingerprint, sensors | port together with charging |

Mechanical changes that hit almost every file: `strlcpy` -> `strscpy` (removed 6.8; 600+ uses in
scope), platform/i2c/spi `remove` returning void, i2c `probe` without the id argument (6.3),
`class_create()` without the module argument (6.4), `proc_ops` (5.6), `mmap_sem` -> `mmap_lock`
(5.8), `vm_flags` accessors (6.3), no `set_fs()`/`get_fs()` (5.10/5.18; Samsung code reads files
from the kernel in 150+ places), `timer_setup`/`from_timer` renames, `ktime`/`timespec64` only,
`wakeup_source_register(dev, name)`, `pm_qos` -> `cpu_latency_qos_*`/`dev_pm_qos`, of_gpio flag
variants removed (`of_get_named_gpio_flags`), `ioremap_nocache`, MODULE_IMPORT_NS for dma-buf.
GKI adds one more rule: vendor modules may only use symbols on the KMI list and cannot patch core
enums (this is what makes sec_battery's `POWER_SUPPLY_EXT_PROP_*` and WALT hard).

### 3.5 Totals

| Class | Items | Built `.c` lines | Split by difficulty (first word) |
|---|---|---|---|
| (b) Qualcomm downstream | 38 | 1,707,710 | {'XL': 5, 'L': 9, 'drop': 9, 'M': 9, 'S': 5, 'drop/stub': 1} |
| (c) Samsung | 24 | 216,272 | {'XL': 1, 'L': 2, 'M': 6, 'S': 8, 'drop': 7} |

Largest items (built `.c` lines, headers extra):

| Item | Lines | Difficulty | Alternative that avoids the port |
|---|---|---|---|
| qcacld-3.0 + qca-wifi-host-cmn (+ icnss2 10 k) | 746 k (+413 k headers) | XL | ath11k (`qcom,wcn6750-wifi`), already in 6.18: zero kernel porting, open Wi-Fi HAL |
| Audio techpack (platform 94 k, dsp 70 k, codecs 31 k, machine 10 k, soc/ipc 9 k, tas256x 9 k, Samsung 4 k) | 227 k | XL | upstream q6afe/q6asm + lpass macros + wcd938x + tas2562 with an open audio HAL (loses voice-call parity until done) |
| Display: SDE 95 k + DSI 38 k + Samsung panel 63 k (+121 k header tables) | 196 k | XL | upstream DPU + a new 600-line `drm_panel` for S6E3FC3 (loses HBM/finger-mask, AOD, mDNIe, secure display) |
| Camera techpack (core 109 k + sensor module 40 k, +86 k headers) | 149 k | XL | CAMSS + new sensor drivers + libcamera: raw only, no vendor image quality |
| dataipa (IPA3 + GSI) | 107 k (+69 k headers) | XL | upstream `drivers/net/ipa` + downstream or upstream rmnet |
| KGSL | 58 k | L | drm/msm + Turnip/freedreno |
| msm_vidc | 34 k | L | venus + V4L2 codec2 HAL |
| sec_battery + SM5714 chg/fg + PCA9468 + MFD/MUIC + USB-PD/notify | 64 k | L (as a set) | new small upstream-style SM5714 power_supply/typec drivers |

## 4. Samsung security and debug drivers: what can go

Evidence base: the list of objects in the real build, and the fact that this ROM boots and runs
its blobs on that build.

| Component | State today | Needed on 6.18? | Why |
|---|---|---|---|
| FIVE, DEFEX, PROCA, DSMS, HDM, Knox UH/RKP/KDP, TIMA, MST driver | not compiled (`security/samsung`, `security/hdm` exist in the tree, no objects built) | no | already absent |
| `security/sdp`, `FSCRYPT_SDP` (6.7 k lines) | built | no | Knox Sensitive Data Protection; AOSP FBE never calls it. It patches fscrypt, so dropping it also removes a merge conflict |
| `sec_debug.c` restart-reason part (1.2 k lines) | built; maps imem `restart_reason` and `upload_cause` (`drivers/samsung/debug/sec_debug.c:90-126`), sets PON reason | **keep a 200-line equivalent** | The Samsung bootloader reads these cells after a reset. Without a clean "normal" marker a panic or watchdog reset may land in upload mode ("RDX"), which only a key combination leaves. Also needed for `reboot recovery/download/bootloader`. Upstream route: `nvmem-reboot-mode`/`syscon-reboot-mode` with Samsung's magic values from `sec_debug.h`. Which cells the A528B bootloader actually checks is being looked at separately (`research/bl-scout`) |
| `sec_param.c` (465 lines) | built; reads/writes the `param` partition by path from the kernel (`sec_param.c:43`) | no for boot | Stores debug level, CP debug, power-off charging flags. Uses `filp_open` from kernel context, which is not acceptable on 6.18. Userspace can write `param` if a flag is ever needed |
| `sec_log_buf`, `sec_debug_summary`, `sec_debug_sched_log`, `sec_debug_user_reset`, `sec_hw_param`, `sec_bootstat`, `sec_crashkey*` (about 7 k lines) | built | no | Samsung service-centre diagnostics. ramoops/pstore replaces last_kmsg (`ramoops` node is already in the DT). `sec_debug_summary` needs SMEM vendor items the bootloader fills; nothing reads it in AOSP |
| `sec_quest` (2.8 k) | built | no | factory self-test |
| `sec_class.c` (90 lines) | built | **yes** | creates `/sys/class/sec`, which touch, battery, vibrator, fingerprint, grip and camera drivers attach to; HAL blobs open those paths |
| `sec_abc` (2.3 k), `sec_argos`, `sec_perf_manager`, `input_booster`, `cpufreq_limit`, `sec_smem`, `sec_misc`, `lmkd_debug`, `drb` | built | no | telemetry and performance hints; consumers ignore their absence (to verify for the Samsung power HAL if one is in use) |
| Samsung mm/block/fs additions (`sec_mm`, page_boost/io_record, rbin, freecess, ssg-iosched, blk-sec-stats, `*_STLOG`, sdfat, zram LRU writeback, F2FS_SEC_*) | built | no | tuning and logging. Use upstream exfat. `fs/proc` AVC/dlog/stlog nodes are logging only |
| `spu_verify`, `QCOM_RTIC` | built | no | Samsung firmware-signature helper for sensor hub/SPU updates and Qualcomm runtime integrity; no secure processor here |
| Secure touch (`sec_secure_touch`, `INPUT_SEC_SECURE_TOUCH`), trusted-VM touch | built | no | Samsung Trusted UI; not used by AOSP |
| `FINGERPRINT_SECURE` | built | **yes, as behaviour** | means the SPI bus belongs to TrustZone and the kernel must only power the sensor and keep the QUP clocks on. A 6.18 port must not instantiate an SPI controller on that SE |
| Qualcomm: `tz_log`, `qfprom-sys`, `dcc`, `memory_dump_v2`, `msm_rtb`, coresight extensions, `core_hang_detect`, EUD | built | no | debug |
| Qualcomm: `qseecom`, `smcinvoke`, `secure_buffer`, shm bridge | built | **yes** | KeyMint and Gatekeeper trustlets are reached through them; without KeyMint, `vold` cannot unlock FBE keys and Android does not get past the encrypted `/data` |
| Qualcomm dload mode (`qcom-dload-mode`, `msm-poweroff`) | built | partly | upstream SCM handles `qcom,dload-mode`. Make sure download mode is *disabled* on normal reboot, same reason as restart-reason |
| Watchdog (`qcom_wdt_core`, Samsung watchdog hooks) | built | use upstream `qcom-wdt` | the bootloader leaves the APSS watchdog running on some Samsung firmware; a kernel that does not pet or stop it resets after about 20-30 s. Enable `QCOM_WDT` from the first test image |

## 5. Proposed porting order for bring-up

"Gate" = cannot reach the stage without it. "Path A" = forward-port the downstream driver so the
blob keeps working (the 2026-11-08 decision). "Path B" = upstream driver, used either permanently
or as the temporary stand-in that lets later stages start early. Work that is only upstream DT is
listed so nothing is forgotten, but costs no driver port.

**Stage 0, groundwork (before any stage)**: build layout for out-of-tree vendor modules against
the ACK KMI; `ipc_logging` stub; GDSC-as-regulator decision; `sec_class`; restart-reason writer;
`QCOM_WDT`. `ack/arch/arm64/boot/dts/qcom/sm7325-samsung-a52sxq.dts` (375 lines, untracked) and
`ack/arch/arm64/configs/a52sxq_gki.fragment` already exist from the other session.

| # | Stage | Gates (upstream, DT only) | Gates (to port/write) | Not needed yet |
|---|---|---|---|---|
| 1 | Serial / pstore console | `gcc-sc7280`, `pinctrl-sc7280`, rpmh-rsc, cmd-db, PDC, GIC, timer, `qcom,geni-debug-uart` on SE5 (`qup_uart@994000`), `ramoops` at 0xf0b00000, simple-framebuffer at 0xe1000000, `qcom-wdt`, `protected-clocks` | restart-reason/upload-cause writer (S). Physical UART is reachable only through the USB connector via the SM5714 MUIC, so pstore + framebuffer console are the practical channels | everything else |
| 2 | UFS + USB adb in recovery | `qcom,sc7280-ufshc` + QMP UFS PHY + ICE, `qcom-rpmh-regulator` with pinned voltages, `dwc3-qcom` + SNPS femto HS PHY with `dr_mode = "peripheral"`, configfs + FunctionFS (ACK), `pmk8350` RTC | none. No SM5714 driver is needed while the port is forced to device mode | Type-C role switching, charging control |
| 3 | Display with the Samsung panel | dispcc, MDSS/DPU, DSI ctrl + 7 nm PHY, IOMMU, panel supplies | **Path B first**: new `drm_panel` driver for S6E3FC3/AMS646YD01 using the on/off command sets from the DT (`qcom,mdss-dsi-on-command`), M. **Path A**: SDE (95 k) + DSI (38 k) + ss_dsi panel (63 k + tables), XL, needs GDSC shim, IOMMU glue, sde_rsc, ION compat for the composer blobs | DP, HDCP, self-display/MAFPC |
| 4 | Touch + keys | `gpio-keys` (volume up on PM7325 GPIO), `pmk8350-pwrkey`/`-resin`, `geni-i2c` SE13 | `sec_input` + `stm_ts` (18.9 k, M) with `sec_cmd`; or a small FTS5 driver first (S-M). `hall_ic` or `gpio-keys` SW_LID (S) | secure touch, TCLM, input booster |
| 5 | Charging / battery | `geni-i2c` SE3 (`i2c@98c000`) and SE on `i2c@a80000`, ADC (`spmi-adc7`) for thermistors | SM5714 MFD + MUIC + AFC (7.4 k, M), SM5714 charger + fuel gauge (5 k, M), sec_battery (23.5 k, L), SM5714 USB-PD + PDIC + manager + usb_notify (23.1 k, L; also replaces the forced device mode with real role switching and OTG VBUS), PCA9468 (5.2 k, M; only for 25 W), `sec_thermistor` (S), DC vibrator (S). Until this stage the charger IC runs on its power-on defaults: check what current it takes before long sessions | CISD, ABC, step-charging extras |
| 6 | Android boot with GPU | binder, Rust ashmem, dm-verity, f2fs + blk inline crypto (all ACK), zram, PSCI cpuidle, cpufreq-epss, tsens | **ION compat module (M)**, **qseecom (L)** + smcinvoke (M) + secure_buffer (S) for qseecomd/KeyMint/Gatekeeper (FBE unlock), SCM/tzmem glue. GPU path A: KGSL (58 k, L) + GDSC/IOMMU shims for the Adreno blobs; path B: drm/msm + Mesa, no port. Without path A display, composer is drm_hwcomposer | WALT, msm_performance, thermal QMI (perf/thermal HALs tolerate absence or are replaced) |
| 7 | Audio | `qcom,sc7280-adsp-pas`, glink, APR, PDR/sysmon, lpass clock controllers, LPI pinctrl | Path A: audio techpack (227 k, XL): APR/q6 dsp (L), platform (XL), bolero + WCD938x + MBHC (L), lahaina machine (M), swr/LPI (M), TAS256x (M), Samsung adaptation (M), SSR/PDR shim (M), msm_audio_ion on dma-heaps. Path B: upstream q6 + lpass macros + wcd938x + tas2562 | LSM/voice wake-up, compress offload, HDMI/DP audio |
| 8 | Modem / Wi-Fi / BT | `qcom,sc7280-mpss-pas`, qrtr, smp2p, smem, rmtfs memory, IPA (upstream), `wpss-pas` + ath11k, hci_qca | Path A data: dataipa (107 k, XL) + datarmnet (13.8 k, M) for netmgrd/ipacm; memshare (S); sharedmem-uio (S) for the rmt_storage blob; glink_pkt (S); qmi_cooling (S). Path A Wi-Fi: icnss2 (L) + qcacld (XL), not recommended. BT: btpower (S) if the vendor BT HAL stays; btfm_slim + slim-msm-ngd (M) for SCO/A2DP offload audio | f_gsi/diag USB functions, cnss2 |
| 9 | Camera | camcc, CCI pins, CDSP PAS | camera techpack core (109 k, XL) + sensor module with Samsung OIS/EEPROM/sysfs (40 k, L), S2MPB03 (S), SM5714 flash LED (in MFD set), cam_smmu IOMMU glue, ION compat, ICP firmware loading through the PIL shim, adsprpc for CDSP. Path B: CAMSS + new sensor drivers | CVP/EVA, synx, LRME if unused |
| 10 | Sensors | `adsp-pas` (from stage 7), qrtr, glink | adsprpc (10.4 k, L) for sscrpcd (`/dev/adsprpc-smd`), `sensors_ssc` + `adsp_factory` (3.9 k, S), SX9360 grip Samsung driver (S) or IIO, smp2p sleepstate (S), hall | factory test nodes |
| 11 | Fingerprint / Widevine | - | ET7xx (3.1 k, M) with the QUP clock hook and no kernel SPI controller on the TZ-owned SE; qseecom/smcinvoke from stage 6; panel HBM / finger-mask brightness control, which lives in the Samsung panel driver (so optical fingerprint effectively requires display path A or re-implementing that control in the new panel driver); Widevine L1 needs secure dma-buf heaps (secure display/pixel), the SDE secure context bank and HDCP, i.e. display path A. L3 works without any of it | - |

Order of the ports themselves, by dependency: shims (3.4) -> ION compat + secure heaps ->
qseecom/smcinvoke -> Samsung notifier buses + SM5714 set -> touch -> PIL/SSR shim -> adsprpc ->
audio -> rmnet/IPA -> display path A -> KGSL -> camera -> video -> fingerprint/Widevine.
Display path A and camera are the two long poles; both can start in parallel once the shims and
ION compat exist, because path B display keeps the phone usable in the meantime.

## 6. Open questions this inventory could not answer offline

1. Which device nodes the shipped blobs really open (`/dev/qce`, `/dev/glinkpkt_*`,
   `/sys/bus/msm_subsys`, `/dev/btpower`, WALT sysctls). A `strings` pass over `vendor/` decides
   several "only if needed" rows.
2. Whether newer Qualcomm techpack releases still carry SM7325 hardware tables (section 3.3).
3. Which imem cells and PON reasons the A528B bootloader checks (section 4, restart-reason).
4. What the SM5714 charger does with no driver bound (default input current, safety timer).
5. Whether the ROM's audio, camera and sensor HALs are the stock Samsung blobs (which need the
   Samsung sysfs ABIs listed in 3.2) or Qualcomm/AOSP ones.
