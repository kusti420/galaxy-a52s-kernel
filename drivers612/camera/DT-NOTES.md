# a52sxq camera device tree for the 6.12 base: notes

Files (all under `drivers612/camera/`):
- `a52sxq-camera.dtsi`: the fragment (generated, about 2,450 lines).
- `dt-work/gen.py`: generator. Reads `downstream-dt/a52sxq-r02.dts` (phone), the decompiled 6.12
  base and the 5.4 / 6.12 binding headers; re-run with `python3 drivers612/camera/dt-work/gen.py`.
  Do not hand-edit the dtsi: change the generator.
- `dt-work/gen-report.txt`: label resolution report of the last run.
- `dt-work/check.sh`: compile check. `dt-work/table.py`: the tables below.
- `dt-work/yupik-base612.dts`: decompiled `bsp612/out/dist/dtb/yupik.dtb`.

## How it was made
The 6.12 base dtb has NO camera nodes (only camcc, the camera GDSCs, generic cam/cci pinctrl
and the reserved memory). Every camera node of the phone's merged 5.4 tree was transplanted
with all values unchanged. Only references were retargeted:
- numeric phandle -> label (label looked up in the phone tree, then checked in the base
  `__symbols__`);
- camcc / gcc clock numbers -> macro of the same name in the 6.12 headers
  `dt-bindings/clock/qcom,camcc-sc7280.h`, `qcom,gcc-sc7280.h` (6.12 base camcc is
  `qcom,sc7280-camcc`; the 5.4 `qcom,camcc-yupik.h` numbering is different, so raw numbers
  would be wrong). Every clock used had a same-named 6.12 macro;
- interconnect IDs -> same-named macros in 6.12 `dt-bindings/interconnect/qcom,yupik.h`
  (all found);
- interrupts -> `GIC_SPI n type`.
The decompiler printed 7 cell properties as strings (for example `iova-region-start = "\a@", ""`
= 0x7400000, four `reg-cam-base`); the generator restores them, each is marked with a comment,
and the two ICP/LRME shared-region values were checked against
`vendor/qcom/camera/yupik-camera.dtsi` (0x7400000 / 0x9600000 / 0x6400000).

## Contents
- `&soc`: camera-flash + qcom,torch_0/flash_0, cam-req-mgr, cam-sync, cam-res-mgr, CSIPHY0-4
  (`qcom,csiphy-v1.2.1`), CCI0/CCI1 (pinctrl, 100k/400k/1M/custom i2c tables, sensors, eeproms,
  actuator), cam_smmu (ife, jpeg, icp + fw-dev, cpas-cdm, secure, lrme), cdm-intf,
  cpas-cdm0 (`qcom,cam170-cpas-cdm0`), cam-isp, csid0-2 (`qcom,csid165_204`), vfe0-2
  (`qcom,vfe165_160`), csid-lite0/1, vfe-lite0/1, cam-icp, a5 (`fw_name = "CAMERA_ICP_170.elf"`),
  ipe0, bps, cam-jpeg, jpegenc/jpegdma (`_165`), cam-lrme + lrme, cam-cpas
  (`qcom,cam-cpas`, `arch-compat = "cpas_top"`, with the camera-bus-nodes tree).
  Qualcomm's own 6.12 camera-kernel would use a cpastop v570_200 style binding; we keep the 5.4
  driver's binding because the 5.4 Samsung techpack is what is being ported.
- OPE: the phone tree has NO OPE node (not present on yupik 5.4). Nothing emitted.
- `&qupv3_se0_i2c`: S2MPB03 at 0x56. `&qupv3_se3_i2c`: `sm5714-fled` child (reg 0x49).
  `&qupv3_se4_i2c`: `ois_rear` qcom,ois@62 (reg 0x51 in DT, slave-addr 0xc4).
- 6.12 ADAPTATION section (the only content that is not on the phone): `cam_iova`
  `iommu-addresses` reservation + `memory-region = <&cam_iova>` on five context banks, because
  6.12 dropped `qcom,iommu-dma-addr-pool`. Computed from the phone pools; the result is
  identical to `donors/redwood-6.12/qcom/redwood-camera.dtsi`. Redwood's note also applies:
  LRME must stay (CamX acquires it for every ZSL preview pipeline); it is kept.
- `&tlmm`: 20 pinctrl states the phone uses that have no label in the base, and 4 overrides.

## Compile check
Command: `sh drivers612/camera/dt-work/check.sh` =
`cpp -nostdinc -undef -x assembler-with-cpp -P -I drivers612/camera -I bsp612/soc-repo/include
-I bsp612/kernel/include` on a `/dts-v1/; /plugin/;` wrapper, then
`bsp612/out/lahaina/scripts/dtc/dtc -@ -I dts -O dtb`.
Result (2026-11-11): dtc ACCEPTED it, 0 errors, `check-overlay.dtbo` 76 KB. 160 warnings, all of
the kind expected for a downstream fragment compiled alone as an overlay (default
#address-cells for the overlay target, missing interrupt-parent, unit-address style,
`shared-gpios` not a phandle). NOT done: applying it onto the base dtb (fdtoverlay) and booting.

## Missing labels
None. Every label referenced from outside the fragment exists in the 6.12 base `__symbols__`:
`soc tlmm camcc gcc apps_smmu refgen cam_cc_titan_top_gdsc cam_cc_bps_gdsc cam_cc_ife_0_gdsc
cam_cc_ife_1_gdsc cam_cc_ife_2_gdsc cam_cc_ipe_0_gdsc pm7325_l6 pm8350c_l10 pm8350c_l2
pil_camera_mem gem_noc cnoc2 mmss_noc mc_virt qupv3_se0_i2c qupv3_se3_i2c qupv3_se4_i2c
cci0_active cci0_suspend cci1_active cci1_suspend cci2_active cci2_suspend cci3_active
cci3_suspend cam_sensor_{active,suspend}_rst0..4`.
Things to know about them:
- `pm7325_l6` (csi 1.2 V), `pm8350c_l10` (csi 0.9 V), `pm8350c_l2` (OIS vio 1.8 V): same label,
  but in the base they sit under `rsc/drv@2/...`. Their VOLTAGE RANGES in the 6.12 base come
  from Qualcomm's reference board and must be pinned by the board/power fragment from
  `downstream-dt/regulators-r02.txt`. This fragment only references them. The CSIPHY node asks
  for 1.2-1.26 V and 0.88-1.05 V (phone values).
- `pil_camera_mem` is `/reserved-memory/video@8ad00000` (5 MB) in both trees (Qualcomm's label
  and node name disagree; the ICP firmware region is this one, as on the phone). The base's
  `camera@86200000` is labelled `pil_cvp_mem` and is not used by the camera DT.
- Labels the phone uses that the base does NOT have, and that this fragment therefore defines
  itself under `&tlmm`: `cam_sensor_{active,suspend}_mclk0..4`, `cam_sensor_{active,suspend}_vana0..2`,
  `cam_flash_{active,suspend}`, `mcu_{active,suspend}`. (The base has differently named
  `cam_sensor_mclkN_active/suspend`; the Samsung ones are used so drive strength etc. are the
  phone's.)
- `cam_sensor_{active,suspend}_rst3/rst4` exist in the base with gpio78/gpio79 SWAPPED relative to
  the phone (phone: rst3 = gpio79, rst4 = gpio78). Overridden with the phone content.
- The I2C buses: phone uses `qupv3_se{0,3,4}_i2c_active` pin states; the base only has
  `..._sleep` under that name. Bus pinctrl/status belongs to the board fragment; this fragment
  only sets `status = "ok"` and leaves the phone's bus pinctrl as a comment.
- Not referenced but needed by the Samsung stack: `camera_heap` (reserved-memory, 500 MB
  `ion,recyclable` CMA-style heap, `alloc-ranges = <1 0x80000000 0 0x80000000>`) and
  `/soc/ion_camera_heap` (`ion,rbin_heap`). This is an ION heap, so it belongs to the
  ioncompat/secure work; not emitted here.

## Things that will not work as-is on 6.12 (driver side)
- `qcom,cam-res-mgr: shared-gpios = <0x15b>` (347) is a LEGACY GLOBAL GPIO NUMBER: 5.4 tlmm
  gpiochip base 336 + TLMM 11 (CAM_VANA0 / MCU_VANA, shared by the rear wide sensor and the
  OIS MCU). On 6.12 the gpiochip base is dynamic (normally 512+). The ported cam_res_mgr must
  translate (for example compare `desc_to_gpio()` of `<&tlmm 11>`), or the number must be
  recomputed. The base 336 is inferred (347 - 11, gpio 11 being the only shared camera GPIO);
  confirm on a phone with `cat /sys/kernel/debug/gpio` on 5.4.
- GDSCs are consumed as regulators (`gdscr-supply`, `camss-supply`, `ife0-supply`...). The 6.12
  base nodes are `qcom,gdsc@...` with the same labels, so this should hold if the soc-repo
  gdsc-regulator driver is loaded (check bsp612 first-stage list).
- `qcom,iommu-dma-addr-pool`, `qcom,iommu-faults`, `stall-disable` etc. are 5.4 SMMU properties;
  see the adaptation section.
- `interconnects` use the 5.4 node pairs with 6.12 macros; whether 6.12 `qnoc-yupik` exposes the
  same endpoints for camera (MASTER_CAMNOC_HF/SF/ICP -> SLAVE_EBI1 on mmss_noc/mc_virt) was
  resolved by name only.
- SM5714 fled: child of the SM5714 MFD bus; the MFD node (`sm5714@49`) is the power agent's.
  `drivers612/power/` was EMPTY when this was written, so both the S2MPB03 node and the fled
  child are defined here. If the power fragment later defines `s2mpb03_pmic_0` /
  `s2mpb03_0_l1..l7` or `sm5714-fled`, delete those sections here (labels are identical to the
  phone's, so the camera references keep working).

## Revision differences
The Samsung dts sources in the kernel tree are three decompiled overlays:
r00 (hw rev 0), r01 (hw rev 1 only), r02 (`dtbo-hw_rev = 2`, `dtbo-hw_rev_end = 0x20`).
Bench revisions 3 and 4 both select r02, so there is NO DT difference between them.
r01 vs r02: identical apart from model/board-id (diff with phandles masked: 2 lines).
r00 differs in many places (1,841 diff lines, camera labels in different fragments); not
analysed, no rev-0 hardware is in use.

## Unverifiable from the device tree
- Sensor model per slot and the sensor I2C address: the 5.4 CamX stack probes sensors from
  userspace (sensor module blobs), so `qcom,cam-sensor` nodes carry no address or name. The
  model column below is from the vendor blob names (the private project log), not from the DT. Slot 3 is
  LABELLED `sensor_rear_tele` by Samsung but the A52s has no tele: by its rails (1.2 V vdig +
  1.8 V vio, no vana, same as the macro slot) it is the second GC5035 (depth).
- `sensor_front` (cell 1) and `sensor_front_full` (cell 13) are the same physical front camera
  (same CSIPHY 4, same GPIOs/rails) exposed twice (binned / full-size).
- eeprom1 (front) and eeprom0 (rear wide) are real EEPROMs at 0x51 / 0x50 (8-bit 0xa2 / 0xa0) on
  CCI1 master 1; eeprom2/3/4 are sensor OTP (they carry the sensor's rails, mclk and reset).
- Macro and depth share VANA GPIO 14 and L4; UW has its own VANA GPIO 15 and NO vdig rail in DT
  (an on-module or GPIO-switched LDO).
- No hardware test of anything here.

## Sensor table (from the phone tree; voltages min == max)
| label | node | type | bus | cell-index | cci-master | csiphy-sd-index | addr | regulators (V) | TLMM gpios | links / mclk |
|---|---|---|---|---|---|---|---|---|---|---|
| ois_rear | qcom,ois@62 | ois | i2c@990000 | 0 | - | - | 0xc4 | cam_vio=pm8350c_l2 1.800; cam_vaf=s2mpb03_0_l7 2.800 | MCU_RESET0=45, MCU_VANA=11, MCU_BOOT0=46 |  status="ok" |
| sensor_rear_wide | qcom,cam-sensor0 | cam-sensor | qcom,cci0 | 0 | 0 | 0 | - | cam_vdig=s2mpb03_0_l2 1.100; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l5 2.800; cam_vaf=s2mpb03_0_l7 2.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK0=64, CAM_RESET0=20, CAM_VANA0=11 | eeprom=eeprom0 actuator=actuator_rear0 ois=ois_rear led-flash=led_flash_rear mclk=19200000 camcc:92 status="ok" |
| actuator_rear0 | qcom,actuator@0xC | actuator | qcom,cci1 | 0 | 1 | - | 0x18 | cam_vio=s2mpb03_0_l3 1.800; cam_vaf=s2mpb03_0_l7 2.800 |  |  |
| eeprom4 | qcom,eeprom@0x3F | eeprom | qcom,cci1 | 4 | 0 | 2 | 0x7e | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK3=67, CAM_RESET3=78, CAM_VANA1=14 |  mclk=24000000 camcc:98 status="ok" |
| eeprom3 | qcom,eeprom@37 | eeprom | qcom,cci1 | 3 | 0 | 1 | 0x6e | cam_vio=s2mpb03_0_l3 1.800; cam_vdig=s2mpb03_0_l4 1.200; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK1=65, CAM_RESET1=21, CAM_VANA1=14 |  mclk=24000000 camcc:94 status="ok" |
| eeprom2 | qcom,eeprom@0x2D | eeprom | qcom,cci1 | 2 | 0 | 2 | 0x5a | cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK2=66, CAM_RESET2=77, CAM_VANA2=15 |  mclk=24000000 camcc:96 status="ok" |
| eeprom1 | qcom,eeprom@51 | eeprom | qcom,cci1 | 1 | 1 | - | 0xa2 | cam_vio=s2mpb03_0_l3 1.800 |  |  |
| eeprom0 | qcom,eeprom@50 | eeprom | qcom,cci1 | 0 | 1 | - | 0xa0 | cam_vaf=s2mpb03_0_l7 2.800; cam_vio=s2mpb03_0_l3 1.800 |  |  |
| sensor_rear_macro | qcom,cam-sensor4 | cam-sensor | qcom,cci1 | 4 | 0 | 3 | - | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK3=67, CAM_RESET3=78, CAM_VANA1=14 | eeprom=eeprom4 led-flash=led_flash_rear mclk=24000000 camcc:98 status="ok" |
| sensor_front_full | qcom,cam-sensor13 | cam-sensor | qcom,cci1 | 13 | 0 | 4 | - | cam_vdig=s2mpb03_0_l1 1.050; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l6 2.900; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK4=68, CAM_RESET4=79 | eeprom=eeprom1 mclk=24000000 camcc:100 status="ok" |
| sensor_front | qcom,cam-sensor1 | cam-sensor | qcom,cci1 | 1 | 0 | 4 | - | cam_vdig=s2mpb03_0_l1 1.050; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l6 2.900; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK4=68, CAM_RESET4=79 | eeprom=eeprom1 mclk=24000000 camcc:100 status="ok" |
| sensor_rear_uw | qcom,cam-sensor2 | cam-sensor | qcom,cci1 | 2 | 0 | 2 | - | cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK2=66, CAM_RESET2=77, CAM_VANA2=15 | eeprom=eeprom2 mclk=19200000 camcc:96 status="ok" |
| sensor_rear_tele | qcom,cam-sensor3 | cam-sensor | qcom,cci1 | 3 | 0 | 1 | - | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK1=65, CAM_RESET1=21, CAM_VANA1=14 | eeprom=eeprom3 mclk=24000000 camcc:94 status="ok" |

Likely modules (not in DT): cell 0 rear wide = IMX682 or S5KGW1P (OIS + AF); cell 2 = ultrawide;
cell 3 = GC5035 depth; cell 4 = GC5035 macro; cells 1/13 = front IMX616 or S5KGD2.
CCI: sensor0 is alone on CCI0 master 0; everything else is on CCI1 (sensors master 0;
actuator, eeprom0, eeprom1 master 1). MCLK: camcc MCLK0 (19.2 MHz) wide, MCLK1 depth, MCLK2
(19.2 MHz) UW, MCLK3 macro, MCLK4 front (24 MHz); TLMM 64..68.

## S2MPB03 (I2C SE0 `qupv3_se0_i2c` i2c@980000, address 0x56, `samsung,s2mpb03pmic`)
| label | node | regulator-name | min uV | max uV |
|---|---|---|---|---|
| s2mpb03_0_l7 | s2mpb03-ldo7 | "CAM0_s2mpb03-l7" | 2800000 | 2800000 |
| s2mpb03_0_l6 | s2mpb03-ldo6 | "CAM0_s2mpb03-l6" | 2900000 | 2900000 |
| s2mpb03_0_l5 | s2mpb03-ldo5 | "CAM0_s2mpb03-l5" | 2800000 | 2800000 |
| s2mpb03_0_l4 | s2mpb03-ldo4 | "CAM0_s2mpb03-l4" | 1200000 | 1200000 |
| s2mpb03_0_l3 | s2mpb03-ldo3 | "CAM0_s2mpb03-l3" | 1800000 | 1800000 |
| s2mpb03_0_l2 | s2mpb03-ldo2 | "CAM0_s2mpb03-l2" | 1100000 | 1100000 |
| s2mpb03_0_l1 | s2mpb03-ldo1 | "CAM0_s2mpb03-l1" | 1050000 | 1050000 |
Users: L1 front vdig 1.05; L2 wide vdig 1.1; L3 vio 1.8 for all; L4 macro/depth vdig 1.2;
L5 wide vana 2.8; L6 front vana 2.9; L7 wide AF + OIS vaf 2.8. No buck is defined on the phone.

## Flash
`led_flash_rear` (`qcom,camera-flash@0`) -> `sm5714_flash0` / `sm5714_torch0` (trigger names
`flash0_trigger` / `torch0_trigger`, 1400 mA flash, 300 mA torch) and the `sm5714-fled` I2C
child (flash-en TLMM 96, torch-en TLMM 97). The cam_flash_active/suspend pin states are attached
to the rear wide and macro sensor nodes, as on the phone.

## Open questions
1. cam_res_mgr `shared-gpios` global number (above).
2. Does the reserved-memory style `iommu-addresses` node work when placed under `/soc` as
   redwood does, with the 6.12 arm-smmu in bsp612? (Copied layout, untested here.)
3. Who owns S2MPB03 / sm5714-fled / I2C bus pinctrl: this fragment or power/board.
4. Regulator ranges of L6B, L10C, L2C in the base must be pinned from the phone table.
5. `camera_heap` / `ion,rbin_heap` under ioncompat.

## Added by the driver port (2026-11-11 20:52)
- `qcom,iommu-faults = "stall-disable", "HUPCF", "non-fatal"` on the five `stall-disable`
  context banks (ife, jpeg, icp, cpas-cdm, lrme), in the 6.12 ADAPTATION section. Reason: the
  5.4 cam_smmu set `DOMAIN_ATTR_FAULT_MODEL_NO_STALL` and `_HUPCF` at run time; 6.12 has no
  domain attributes and soc-repo's arm-smmu reads these strings from the DT instead
  (`arm-smmu.c:2234`). Without them a camera page fault stalls the context bank.
- `shared-gpios = <347>` is harmless: the Samsung driver reads the property `sharedgpios`
  (no dash), which the phone tree does not have, so shared-GPIO handling is off on 5.4 too.
  No translation of the legacy GPIO number is needed.
- The ICP firmware carve-out is read from `msm_cam_icp_fw` (`memory-region = <&pil_camera_mem>`),
  a different node from `cam_smmu_icp`, so the `cam_iova` memory-region override does not hide it.
