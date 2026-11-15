# boarddt: the a52sxq board device tree for the Qualcomm 6.12 base

Successor of `bsp612/dts/a52sxq-bringup-overlay.dts`. The whole Samsung board description of the
phone's 5.4 kernel, as a source tree that builds into three dtbo entries for `yupik.dtb` of
`bsp612/`, plus the tools that prove it applies and measure how far it is from the phone's tree.
Nothing here was booted or flashed. `./check-dt.sh` rebuilds and re-verifies everything.

## What is here

| File | What |
|---|---|
| `a52sxq-r00-overlay.dts`, `-r01-`, `-r02-` | one overlay per dtbo entry (written by `check-dt.sh`; root properties verbatim from the stock entry) |
| `a52sxq-common.dtsi` | includes the subsystem files that all revisions share |
| `a52sxq-{sec-platform,memory,pinctrl,regulators,pmic,thermal,buses,storage,usb,sensors,nfc,input,misc}.dtsi` | the phone's board nodes by subsystem, GENERATED, 5.4 values verbatim, phandles as `&label` |
| `a52sxq-r00.dtsi`, `-r01`, `-r02` | what only that hardware-revision entry has (GENERATED) |
| `a52sxq-bsp612-fixups.dtsi`, `a52sxq-r0N-fixups.dtsi` | HAND-WRITTEN: every place where the 6.12 base or a 6.12 driver needs something else than the 5.4 tree says (included last, wins) |
| `placeholders/a52sxq-<agent>-placeholder.dtsi` | nodes of subsystems owned by other agents, copied verbatim (TODO-binding); used while `drivers612/<agent>/a52sxq-<agent>.dtsi` is missing or does not integrate |
| `placeholders/a52sxq-*-labels.dtsi` | the 53 labels of the 5.4 base that the 6.12 base lacks, as inert nodes under `/soc/a52sxq-todo-*` so every phandle of the phone's tree resolves |
| `BINDINGS.md` | per node: is there a 6.12 driver for its `compatible` (generated; hand review below) |
| `REGULATORS.md` | all 53 RPMh regulators (44 VRM + ARC/XOB), phone vs our merged tree: identical |
| `tools/gen.py` | stock dtbo entries -> this source tree (common = intersection of all entries) |
| `tools/dtdiff.py`, `regcheck.py`, `bindings.py`, `rootprops.py`, `fdt.py` | tree diff by label, regulator check, binding table, root properties, dtb reader |
| `out/dtbo-a52sxq-bsp612-rom.img` | dtbo table, body from the ROM kernel's Samsung dts (= `downstream-dt/`) |
| `out/dtbo-a52sxq-bsp612-stock1.img` | same, body from the dtbo dumped from test phone 1 (see "Open questions" 1) |
| `out/dt-diff-r0N.txt`, `out/agents-status.txt`, `out/check-*.log` | reports of the last runs |

The generated files are rewritten by every `check-dt.sh` run; which nodes they contain depends
on which agent fragments integrated (a node an agent defines itself is left out of ours).
`NOAGENTS=1 ./check-dt.sh` gives the pure phone tree with placeholders only.

## How the source was made (and why it is generated)

Samsung's "sources" in the ROM kernel
(`arch/arm64/boot/dts/samsung/a52/a52sxq/a52sxq_kor_single_w00_r0{0,1,2}.dts`) are not real
sources: they are decompiled dtbo entries (8,474 lines each, numeric phandles, `__fixups__`).
There are no shared a52/a73/m52 includes in this tree. So `tools/gen.py` reads the three
entries, turns every phandle cell back into a label reference (external labels from
`__fixups__`, internal ones from `__local_fixups__` + `__symbols__`), splits the result by
subsystem and factors out what all three entries share. Check of the method: 5.4 values that
reach the merged 6.12 tree are compared with `downstream-dt/a52sxq-r02.dts` by `dtdiff.py`;
with placeholders only, the board part differs in nothing but the intended changes below.

Include order (matters: dtc resolves `&label { }` at parse time):
`a52sxq-agents-labels.dtsi` (placeholders) -> `a52sxq-common.dtsi` (`sec-platform` first, it
defines `&smd`, the `samsung_mobile_device` bus) -> `a52sxq-agents-nodes.dtsi` (agent fragment
or its placeholder) -> `a52sxq-r0N.dtsi` -> `a52sxq-bsp612-fixups.dtsi` -> `a52sxq-r0N-fixups.dtsi`.

## Per-revision differences

Selection (stock dtbo of test phone 1, copied exactly; the ABL matches `qcom,board-id =
<0x22 N>` with N <= hardware revision, `dtbo-hw_rev*` are not read by the ABL):

| Entry (table order as stock) | board-id | dtbo-hw_rev..end | model |
|---|---|---|---|
| 0: r02 | `<0x22 2>` | 2..0x20 | Samsung A52SXQ PROJECT (board-id,02) |
| 1: r01 | `<0x22 1>` | 1..1 | ... (board-id,01) |
| 2: r00 | `<0x22 0>` | 0..0 | ... (board-id,00) |

All entries: `qcom,msm-id = <0x1db 0x10000 0x203 0x10000>`, `dtbo-version = <0>`, compatible
`qcom,yupik-idp, qcom,yupik, qcom,idp`. Table: magic d7b7ab1e, page 4096, version 0, id/rev/custom 0.

- **r03, r04 and later have no entry of their own.** Both bench phones (rev 3 and rev 4) use
  r02. There is nothing revision-specific above 2 in the device tree.
- **r01 and r02 are identical** except for the root properties.
- **r00 vs r01/r02** (the only real difference):
  - r00 only: `fixed_regulator0` (TLMM 106 enable, pin state `ldo_gpio0`) as the touch
    `tsp_io_ldo-supply`; Qualcomm's `pm7325_sdm_skin_therm` on ADC 0x146 (VADC + ADC_TM).
  - r01/r02 only: three `sec_thermistor` nodes (ap 0x146, pa 0x148, wf 0x14c) with their VADC
    channels (`qcom,scale-fn-type = <5>`) and PM7325 GPIO1/GPIO4 ADC pin states; the touch IO
    rail is no longer the GPIO regulator.
- The ROM kernel's r00 source (and the dtbo on test phone 2) says `dtbo-hw_rev_end = <0x20>`
  for r00 and orders the table r00, r01, r02; stock (test phone 1) says 0..0 and r02, r01, r00.
  Ours follows stock.

## Binding review (task step 2)

`BINDINGS.md` lists every node with a `compatible` (132 on the phone): 81 have a matching
of_match string in the 6.12 trees, 51 do not (list at the end of this section). That table is
generated from string matches only. Checked by hand against the 6.12 driver source:

| Node | 5.4 -> 6.12 | Result |
|---|---|---|
| all RPMh regulators (`qcom,rpmh-vrm-regulator` etc.) | unchanged driver binding; nodes moved one level down (`rsc@18200000/drv@2/...`), labels unchanged | values identical to the phone (`REGULATORS.md`); the one path-based override (`&apps_rsc { rpmh-regulator-ldoc6 }`) repeated at the new path in fixups |
| `pmk8350_vadc` `qcom,spmi-adc7` | unchanged: soc-repo `qcom-spmi-adc5.c` parses `qcom,ratiometric`, `qcom,hw-settle-time`, `qcom,pre-scaling`, `qcom,scale-fn-type` | kept verbatim |
| `pmk8350_adc_tm` `qcom,adc-tm7` | CHANGED -> `qcom,spmi-adc-tm5-gen2`: child `reg` = monitor index, per-child `io-channels`, `qcom,hw-settle-time` -> `qcom,hw-settle-time-us`, zones reference the index | translated in fixups, zones retargeted; `sdm-skin-therm-usr` disabled on r01+ (its channel is gone there) |
| PON `qcom,qpnp-power-on` (pon_hlos@1300, pon_pbs@800) | CHANGED -> `qcom,pmk8350-pon` with `pwrkey`/`resin` children | added in fixups (key codes and IRQs of the phone); the 5.4 nodes stay, inert |
| `soc/reboot_reason` `qcom,reboot-reason` + `sdam@7100/restart@48` | unchanged (nvmem cell) | verbatim; "download" still needs `sec_core.ko` (BRINGUP.md) |
| `soc/gpio_keys`, PMIC GPIO blocks, SDAMs, RTC, temp-alarm, BCL | unchanged (of_match present) | verbatim; property parsing not re-read line by line |
| `tlmm` pin states | unchanged generic pinconf | verbatim; NEW in fixups: `qcom,gpios-reserved` incl. 56..59 (5.4 reserves them in C) |
| `gcc` | NEW: `protected-clocks` + 15 firmware clocks | fixups (from BRINGUP.md) |
| UFS (`ufshc_mem`, `ufsphy_mem`) | unchanged | verbatim (same values as the bring-up overlay) |
| USB `dwc3` | base differs: `usb-phy` second PHY, QMP PHY | fixups: `usb-phy = <&usb2_phy0>, <&usb_nop_phy>`, QMP/DP PHY disabled |
| `pwms@e800/eb00` `qcom,pwm-lpg`, `qcom,tri-led` | CHANGED -> `qcom,pm8350c-pwm` (LED children) | NOT translated: the phone has no RGB LED consumer; inert |
| `/firmware/android` | node missing in the 6.12 base | `compatible = "android,firmware"` added in fixups |
| reserved memory | see BRINGUP.md | phone's map; fixups add `cvp@8b200000`, disable the base's `video_region`/`camera` inside Samsung's ADSP range |

No 6.12 driver found (node kept, owner in brackets): `samsung,sec_abc`, `samsung,abc_hub`,
`samsung,sec-thermistor`, `samsung,sec-debug-summary`, `samsung,sec-smem`, `samsung,argos`,
`samsung,security_mz*`, `ss_plog`, `qcom,msm-imem-upload_cause`, `input_booster` [TODO, Samsung
platform drivers: `samsung612/`]; `hall_ic`, `sx9360` (upstream `semtech,sx9360` exists, other
binding), `samsung,dc_vibrator` [TODO]; `sec-nfc`, `qcom,sn-nci` [conn/TODO]; `etspi,et7xx`,
`sec-mst` [secure]; `nxp,pca9468` [power; donor only]; `qcom,cam-*`, `qcom,eeprom`, `qcom,ois`,
`qcom,actuator`, `qcom,camera-flash`, `qcom,pm8008-*`, `qcom,qpnp-revid` [camera];
`samsung,ss_touch`, `novatek,NVT-ts` (IDP leftover) [touch]; `samsung,q6audio-adaptation`
[audio]; `ion,rbin_heap`, `modem-removed-dma-pool` [memory: Samsung ION/rbin, no 6.12 user];
`android,vbmeta` (read by userspace, no driver needed); `qcom,pm8350c-flash-led` (unused).

## Integration of other agents' fragments

`check-dt.sh` preprocesses `drivers612/<agent>/a52sxq-<agent>.dtsi` (cpp with the soc-repo
`dt-bindings`), drops our copy of every node whose label the fragment defines, includes it in
place of the placeholder, and keeps it only if r02 still compiles and applies; labels left
undefined are stubbed and named. State at the last run (`out/agents-status.txt`):

- display, touch, power, secure: integrated. Display drops the IDP `nt36672e` panels (three
  labels stubbed) and the IDP `dsi_panel_pwr_supply*` nodes; power leaves `fixed_regulator1`
  undefined (stubbed).
- camera: integrates alone, but together with power it fails: both define `s2mpb03_pmic_0`
  (`s2mpb03_pmic@56`). One of the two agents has to drop it.
- conn: does not build: uses `GCC_QUPV3_WRAP0_S5_CLK` without including the clock header.
- audio, gpu-video: no fragment yet -> placeholder.

## check-dt.sh

    ./check-dt.sh                 # body = ROM kernel's Samsung dts (default)
    SRC=stock1 ./check-dt.sh      # body = dtbo of test phone 1
    NOAGENTS=1 ./check-dt.sh      # placeholders only
    REINDEX=1 ./check-dt.sh       # rebuild the driver compatible index first (about 20 s)

Fails (exit 1) on: dtc error, `fdtoverlay` not applying on `yupik.dtb`, no `__fixups__` in an
overlay, no `__symbols__` in the base, a label the base lacks, root properties != stock entry,
merged dtb >= 2 MB (now about 0.5 MB), missing `/soc/qcom,wdt@17c10000`, `/soc/timer`,
`/chosen`, `/reserved-memory`, `/memory`, lost labels `soc intc reserved_memory aliases
firmware wdog arch_timer qcom_tzlog`, kaslr/ADSP region not Samsung's, GPIO 56..59 not
reserved, any RPMh regulator property != phone, dtbo table header/entries != stock, image
larger than the partition. Then prints the diff summary; `soc-base` = Qualcomm's own 5.4 base
vs 6.12 base (not board data, shown so that it stays visible).

Intended differences in the board part (placeholders only): `modem_shared_mem` size (0 on the
phone, 0x800000 here, as the proven 6.18 dts), ADC_TM (4 nodes/8 properties, translated), the
`ldoc6` path, `dwc3` `usb-phy`/`reg` cells (base), 12 audio LPI pin nodes that live in the 5.4
base and have no 6.12 counterpart yet.

## Open questions (only hardware or the owner can answer)

1. **Which body is right for test phone 1?** Its dtbo (One UI based) differs from the ROM tree:
   `removed_region@c0000000` is 0x5f00000 long (ROM tree and test phone 2: 0x6a00000), no
   `sec-mst` node/pin, and three SX9360 register values differ. The memory map belongs to the
   firmware on the device, so flash `-stock1.img` on test phone 1 and `-rom.img` on test phone 2
   unless someone shows the region size does not depend on the firmware.
2. The ABL's libufdt was not run on these overlays (only `fdtoverlay`). They are 30x larger
   than the bring-up overlay and use plain fragments (the `/delete-node/` lines are resolved by dtc, none reaches the dtbo), local phandles and
   102 base labels; the bring-up overlay has not been booted either.
3. Rails with `regulator-boot-on` (L7C, L8C, L13C: touch and panel) are now exactly the
   phone's. Without their consumer drivers loaded the regulator core may switch them off at
   late init; keep `regulator_ignore_unused` on the command line until display and touch probe.
4. Bluetooth (`bt_wcn6750`, TLMM 84/85/86) and SE1 I2C are no longer disabled as in the
   bring-up overlay: the phone's tree has both. Do not load their drivers before conn/audio
   are ready.
5. 5.4-binding nodes whose compatible also exists in 6.12 (81 nodes) were not all re-read
   property by property; a driver may bind and read a property differently. First boot with
   this tree should load modules one subsystem at a time (as the bring-up ramdisk does).
6. Placeholders make `fw_devlink` see suppliers that never probe; consumers of a stubbed label
   wait for the deferred-probe timeout.
7. `sdm-skin-therm-usr` on r01+: disabled here; on 5.4 it references a channel that does not
   exist. Confirm on the phone (`/sys/class/thermal`) that the zone is absent on 5.4 too.

## First on-device test (main session only; nothing here flashes)

Pack `out/build/r02.dtbo` (or the table image) as the recovery dtbo of the bring-up image
instead of the bring-up overlay, same ramdisk. Expected: `Machine model` line, then in the
shell

    ls /proc/device-tree/samsung_mobile_device          # the Samsung bus arrived
    cat /proc/device-tree/soc/samsung-overlay-marker/samsung,stage   # bsp612-boarddt
    cat /sys/kernel/debug/regulator/regulator_summary | grep -e pm8350c_l8 -e pm8350c_l13
    cat /proc/bus/input/devices                         # gpio-keys, pmic_pwrkey, pmic_resin
    cat /sys/kernel/debug/devices_deferred

Likely failures: Download mode with `ufdt apply overlay failed` (bisect by removing includes
from `a52sxq-common.dtsi`, placeholders first); a 6.12 driver binding to a 5.4-binding node and
failing in probe (see `BINDINGS.md`, load order); panel going dark after 30 s (question 3).
