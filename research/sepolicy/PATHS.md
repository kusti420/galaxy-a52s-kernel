# 5.4 sysfs paths on 6.12 / 6.18 (SELinux genfscon labels)

2026-11-15. Offline work only: nothing was flashed or run on a phone.

The ROM's SELinux labels for sysfs (`genfscon-sysfs-lineage-a52sxq.txt`, 478 entries) are keyed
to 5.4 device paths. On the 6.12 real boot (rb10, enforcing) a device whose path differs falls
back to plain `sysfs`, and the HALs are denied (`avc-rb10-612.txt`):

* `hal_power_default` write `enabled` (294 times): the power HAL turns touch off with the screen
  through `/sys/class/sec/tsp/input/enabled`. That is a symlink to
  `.../a94000.i2c/i2c-25/25-0049/input/inputN/enabled` on 5.4 (`sysfs_power_writable`) and to
  `.../ac0000.qcom,qupv3_1_geni_se/a94000.i2c/i2c-23/23-0049/input/input3/enabled` on 6.12.
  Touch stayed powered while the screen was off, which costs battery.
* `hal_health_default` read `type` (12 times): the SM5714 fuel gauge,
  `98c000.i2c/i2c-21/21-0049/...` (`sysfs_battery`), is at
  `9c0000.qcom,qupv3_0_geni_se/98c000.i2c/i2c-20/20-0049/...` on 6.12.

## 1. Why the paths differ

Two things move the devices. Both are visible in the device tree.

1. **The QUP serial engines sit under their wrapper.** Qualcomm's 6.12 tree puts every I2C, SPI
   and UART engine node under `qcom,qupv3_N_geni_se@...` (`qcom,geni-se-qup`). The GKI wrapper
   driver populates them, so their platform devices become children of
   `9c0000.qcom,qupv3_0_geni_se` or `ac0000.qcom,qupv3_1_geni_se`. On 5.4 the engine nodes are
   direct children of `/soc` and name their wrapper with a `qcom,wrapper-core` phandle
   (`downstream-dt/a52sxq-r02.dts`).
2. **The i2c bus numbers.** Both kernels follow the same rule (`i2c_add_adapter`). An
   `/aliases/i2cN` entry fixes the number N. Every other adapter gets the lowest free number
   above the highest alias, in the order the adapters register. Only `i2c18` (984000) has an
   alias, so the numbers depend on probe order:

   | bus | 5.4 (phone 1 `last_kmsg`, phone 2 policy) | 6.12 rb10 | why |
   |---|---|---|---|
   | `soc:i2c@17` (i2c-gpio, sx9360) | 19 (built-in, registers first at 0.50 s) | none | i2c-gpio is `=m` and in no load list |
   | 980000 (s2mpb03 camera PMIC) | 20 | 19 | |
   | 984000 (tas256x, fsa4480) | 18 (alias) | 18 (alias) | |
   | 98c000 (SM5714 `21-0049`, PCA9468 `21-0057`) | 21 | 20 | |
   | 990000 (camera OIS/EEPROM `22-0051`) | 22 | 21 | |
   | a80000 (SM5714 USB-PD `23-0033`) | 23 | does not probe | `pin-32 (a80000.i2c) EINVAL`: the 6.12 tlmm has `qcom,gpios-reserved = 32 33 48 49 50 51 56 57 58 59` (the 5.4 tlmm reserves nothing) |
   | a84000 (sec-nfc `24-0027`) | 24 | 22 | |
   | a94000 (stm_ts touch `25-0049`) | 25 | 23 | |

   The Samsung overlay already carried `i2c21 = "/soc/i2c@98c000"` and `i2c23 = "/soc/i2c@a80000"`
   in /aliases. Those are 5.4 paths that do not exist in the 6.12 layout, so the kernel ignored
   them. After the change below they are valid.

Can the 6.12 drivers use the 5.4 layout as they are? **No.** `i2c-msm-geni`, `spi-msm-geni` and
`msm_geni_serial` (soc-repo r70) find the wrapper only as `dev->parent`. They use it for the
wrapper drvdata (`SE Wrapper is NULL, deferring probe` otherwise), for the `m-ahb`/`s-ahb`
clocks, and for every DMA/IOMMU mapping (`wrapper_dev`). The shared header
`qcom-geni-se-common.h` uses it for the vote properties and for the timestamp register mapping.
None of these drivers reads `qcom,wrapper-core`. A tree that only moves the nodes would leave
every geni bus deferred forever: no touch, no charger, no NFC, no amplifiers.

The GKI built-in `qcom_geni_serial` (the debug console `qcom,geni-debug-uart` at 994000) also uses
`dev->parent`. That node is not in the genfscon list, so it stays under its wrapper.

## 2. What was changed

* **`bsp612/patches/soc-repo/0009-geni-se-wrapper-by-qcom-wrapper-core-phandle.patch`** adds
  `geni_se_common_wrapper_dev()` to `qcom-geni-se-common.h`. It returns the device of the
  `qcom,wrapper-core` phandle when the property is there, and `dev->parent` otherwise, so the
  modules work with both layouts. The three drivers and the two header helpers use it in place
  of `dev->parent`. The first use logs `a52sxq-wrapper-core: SE wrapper <name>` once per module;
  that string is also what `sysfscompat.py ko-patched` looks for.
  * The patch is applied in `bsp612/soc-repo` and `soc-repo-staging`. `./build.sh soc` rebuilt
    exactly three modules (i2c-msm-geni, spi-msm-geni, msm_geni_serial). After `./build.sh collect`,
    `bsp612/out/dist` differs from before only in those three `.ko` files (hash diff of all 412
    files).
  * The same patch is applied in the 6.18 port copy (`bsp618/src/bsp612/soc-repo{,-staging}`).
    It commutes with the port rules: the 6.12→6.18 diff of the four files is the same before and
    after. The next `port618.py` run gives the same result from `bsp612/soc-repo`.
    `build618.sh soc` rebuilt the same three modules. `bsp618/android/out/dist` is the old dist
    with only those three files replaced. A full `mkdist-618.sh` would also have added six
    modules built since the last dist (qca808x, qcom-phy-lib, slim-qcom-ngd-ctrl, mem-offline,
    ucsi_qti_glink, snd-usb-audio-qmi), so that run was rolled back.
  * The new symbols the modules need (`of_find_device_by_node`, `__of_parse_phandle_with_args`,
    `put_device`, `_dev_info`) are all in the GKI `Module.symvers`. The modules export nothing,
    and their `modules.dep` lines are unchanged.
* **`drivers612/boarddt/tools/sysfscompat.py`** works on the finished tree, after every overlay:
  * `apply` moves every ENABLED engine node of a `qcom,geni-se-qup` wrapper whose compatible
    belongs to one of those soc-repo modules to `/soc`, right after its wrapper, and adds
    `qcom,wrapper-core = <&wrapper>`. On this tree that is i2c@980000, 984000, 98c000, 990000,
    a80000, a84000, a94000 and qcom,qup_uart@99c000 (BT, `hsuart0` → ttyHS0).
  * It rewrites the moved paths in `/__symbols__` (55 labels), `/aliases` (`i2c18`, `hsuart0`)
    and `/chosen`, and sets `i2c18..i2c25` to the 5.4 numbers in the table above. Running it
    twice gives the same tree.
  * It refuses to run if the `ranges` or cells of /soc and the wrapper differ, a name collides,
    `interrupt-parent` would change, or any other string property still names an old path.
  * Disabled nodes, the debug console, and every other node and property stay as they were.
    `verify OLD NEW` proves that: NEW is exactly `apply(OLD)`, and the only differences are 70
    properties (55 symbols, 7 aliases, 8 `qcom,wrapper-core`) plus the 8 moved nodes.
  * `check` tests whether a tree is in the 5.4 layout. `sim` simulates sysfs paths: the
    `of_device_make_bus_id` names under the populating buses, SPMI devices, and i2c
    adapters/clients with the i2c core's numbering rule. The simulation reproduces every i2c
    path seen in the 5.4 and 6.12 logs (5.4 `22-0051`/`25-0049`, 6.12 `21-0051`/`23-0049`).
* **The same step runs in all three places**:
  * at the end of `kexec/mkandroidtree.sh` (`out-ack/kx/android-r02.dtb`);
  * in `bsp618/android/mkdtb-618.sh` (`android-r02-618.dtb`; it is idempotent, so an older input
    still comes out in the 5.4 layout);
  * in `drivers612/realboot/build-realboot.sh`, before the "= tested tree" diff.

  That build now also fails if a geni module of its plan lacks 0009, and if the simulated tree
  lacks `/devices/platform/soc/98c000.i2c/i2c-21/21-0049` or `.../a94000.i2c/i2c-25/25-0049`.
  A test with `REF=s74` fails as intended: `CHECK FAILED: geni modules of s74 lack soc-repo patch 0009`.
  * `kexec/mkandroidtree.sh` reproduced the previous `android-r02.dtb` input exactly
    (`verify old new` passed).
  * The old-layout trees are kept as `out-ack/kx/android-r02-wrapperlayout.dtb` and
    `bsp618/android/out/android-r02-618-wrapperlayout.dtb`. Use them with old ramdisks
    (s74, a8 and earlier, whose geni modules lack 0009). The new trees need s75, a9 or later.
* **Test ramdisks**: `drivers612/realboot/tools/rd-swap-ko.py` copies a tested ramdisk and
  replaces only the named modules (headers keep name, mode and mtime; everything else stays byte
  for byte; vermagic is checked). Swapping in the same modules gives a byte-identical stream.
  * `drivers612/androidboot/out/s75-rd.cpio.gz` = s74 + 0009 `i2c-msm-geni.ko` (stage i2c) +
    `msm_geni_serial.ko` (stage wlanb).
  * `bsp618/android/out/a9-rd.cpio.gz` = a8 + the same two 6.18 modules.

  `spi-msm-geni` is in no stage: no SPI engine is used, and the fingerprint SPI belongs to TZ.
  `build-realboot.sh` now defaults to `REF=s75` / `REF=a9`.
* **Builds**, offline, NOT flashed:
  * `drivers612/realboot/out/rb11`: `DIAG=1 KERNEL=612`, the same options as rb10. It differs
    from rb10 in the vendor_boot dtb (5.4 layout, 1302 bytes smaller) and in those two
    first-stage modules. `boot.img` is byte-identical to rb10.
  * `out/rb618-4`: KERNEL=618 with REF=a9, for comparison with rb618-3.
  * `out/rh-rh612d`: the real-boot rehearsal package of rb11 (`rehearse.sh 612 rh612d`, not run).

## 3. Mapping table

Generated by `research/sepolicy/mktable.py genfscon-sysfs-lineage-a52sxq.txt
testdev-PHONE2/live.dtb out-ack/kx/android-r02-wrapperlayout.dtb out-ack/kx/android-r02.dtb`.
The 6.18 trees give the identical table. "Exists on this phone" means the device is in phone 2's
own 5.4 live tree (`/sys/firmware/fdt`). The other 199 `/devices/platform` entries name devices of
other boards and SoCs (s2mu106, pm7250b, pmi632, qca6490, spss, npu, pcie, sdhci 8804000, other
i2c numbers on the same buses), and the ~110 `/devices/virtual|system` entries do not depend on
the device tree. Directories that drivers create below a DT device (input/, wakeup/,
power_supply/, subsysN/, MFD cells) keep the 5.4 suffix, so the DT decides their prefix.

| 5.4 genfscon path | label | 6.12 rb10 (before) | 6.12/6.18 now | |
|---|---|---|---|---|
| `…/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode` | sysfs_battery_writable | = | = | same as 5.4 |
| `…/samsung_mobile_device/samsung_mobile_device:battery/` | sysfs_battery | `…/samsung_mobile_device/samsung_mobile_device:battery` | `…/samsung_mobile_device/samsung_mobile_device:battery` | same as 5.4 |
| `…/samsung_mobile_device/samsung_mobile_device:fixed_regulator@1/` | sysfs_battery | `…/samsung_mobile_device/samsung_mobile_device:fixed_regulator@1` | `…/samsung_mobile_device/samsung_mobile_device:fixed_regulator@1` | same as 5.4 |
| `…/samsung_mobile_device/samsung_mobile_device:sec-direct-charger/` | sysfs_battery | `…/samsung_mobile_device/samsung_mobile_device:sec-direct-charger` | `…/samsung_mobile_device/samsung_mobile_device:sec-direct-charger` | same as 5.4 |
| `…/soc/0.etspi,et7xx/wakeup/` | sysfs_wakeup | `…/soc/0.etspi,et7xx/wakeup` | `…/soc/0.etspi,et7xx/wakeup` | same as 5.4 |
| `…/soc/0.qcom,rmtfs_sharedmem/uio` | vendor_sysfs_uio_file | = | = | same as 5.4 |
| `…/soc/17a10040.qcom,wcn6750/net` | sysfs_net | = | = | same as 5.4 |
| `…/soc/17a10040.qcom,wcn6750/` | sysfs_wifi_writable | `…/soc/17a10040.qcom,wcn6750` | `…/soc/17a10040.qcom,wcn6750` | same as 5.4 |
| `…/soc/17a10040.qcom,wcn6750/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sda/queue/discard_max_bytes` | vendor_sysfs_mmc_host | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:0/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:1/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:2/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:3/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:4/block/sde/queue/discard_max_bytes` | vendor_sysfs_mmc_host | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:4/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:5/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:6/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:7/scsi_generic` | vendor_sysfs_scsi_target | = | = | same as 5.4 |
| `…/soc/1d84000.ufshc/host0` | vendor_sysfs_scsi_host | = | = | same as 5.4 |
| `…/soc/1e00000.qcom,ipa/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/6002000.stm/coresight-stm` | vendor_sysfs_qdss_dev | = | = | same as 5.4 |
| `…/soc/6048000.tmc/coresight-tmc-etr` | vendor_sysfs_qdss_dev | = | = | same as 5.4 |
| `…/soc/6b05000.tmc/coresight-tmc-etf` | vendor_sysfs_qdss_dev | = | = | same as 5.4 |
| `…/soc/6b0f000.csr/coresight-swao-csr` | vendor_sysfs_qdss_dev | = | = | same as 5.4 |
| `…/soc/8804000.sdhci/mmc_host/` | vendor_sysfs_mmc_host | `…/soc/8804000.sdhci/mmc_host` | `…/soc/8804000.sdhci/mmc_host` | same as 5.4 |
| `…/soc/88e0000.qcom,msm-eud/extcon/extcon2/cable.1/name` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/88e0000.qcom,msm-eud/extcon` | sysfs_extcon | = | = | same as 5.4 |
| `…/soc/88e0000.qcom,msm-eud/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/98c000.i2c/i2c-21/21-0049/` | sysfs_battery | `…/soc/9c0000.qcom,qupv3_0_geni_se/98c000.i2c/i2c-20/20-0049` | `…/soc/98c000.i2c/i2c-21/21-0049` | FIXED |
| `…/soc/98c000.i2c/i2c-21/21-0057/power_supply/pca9468-charger/` | sysfs_wakeup | `…/soc/9c0000.qcom,qupv3_0_geni_se/98c000.i2c/i2c-20/20-0057/power_supply/pca9468-charger` | `…/soc/98c000.i2c/i2c-21/21-0057/power_supply/pca9468-charger` | FIXED |
| `…/soc/98c000.i2c/i2c-21/21-0057/wakeup/` | sysfs_wakeup | `…/soc/9c0000.qcom,qupv3_0_geni_se/98c000.i2c/i2c-20/20-0057/wakeup` | `…/soc/98c000.i2c/i2c-21/21-0057/wakeup` | FIXED |
| `…/soc/99c000.qcom,qup_uart/wakeup` | sysfs_wakeup | `…/soc/9c0000.qcom,qupv3_0_geni_se/99c000.qcom,qup_uart/wakeup` | = | FIXED |
| `…/soc/99c000.qcom,qup_uart/wakeup/` | sysfs_wakeup | `…/soc/9c0000.qcom,qupv3_0_geni_se/99c000.qcom,qup_uart/wakeup` | `…/soc/99c000.qcom,qup_uart/wakeup` | FIXED |
| `…/soc/a600000.ssusb/a600000.dwc3/udc/a600000.dwc3` | vendor_sysfs_usb_controller | = | = | same as 5.4 |
| `…/soc/a600000.ssusb/a600000.dwc3/xhci-hcd.2.auto/usb` | vendor_sysfs_usb_node | = | = | same as 5.4 |
| `…/soc/a600000.ssusb/mode` | vendor_sysfs_usb_device | = | = | same as 5.4 |
| `…/soc/a600000.ssusb/usb_data_enabled` | vendor_sysfs_usb_data_enabled | = | = | same as 5.4 |
| `…/soc/a600000.ssusb/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/a80000.i2c/i2c-23/23-0033/wakeup/` | sysfs_wakeup | `(absent)` | `…/soc/a80000.i2c/i2c-23/23-0033/wakeup` | FIXED (bus a80000 does not probe on 6.12 yet: GPIO 32/33 reserved) |
| `…/soc/a94000.i2c/i2c-25/25-0049/input/` | sysfs_power_writable | `…/soc/ac0000.qcom,qupv3_1_geni_se/a94000.i2c/i2c-23/23-0049/input` | `…/soc/a94000.i2c/i2c-25/25-0049/input` | FIXED |
| `…/soc/a94000.i2c/i2c-25/25-0049/wakeup/` | sysfs_wakeup | `…/soc/ac0000.qcom,qupv3_1_geni_se/a94000.i2c/i2c-23/23-0049/wakeup` | `…/soc/a94000.i2c/i2c-25/25-0049/wakeup` | FIXED |
| `…/soc/ae00000.qcom,mdss_mdp/c900000.qcom,mdss_mdp:qcom,mdss_fb_primary/leds` | sysfs_leds | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-0/fps_periodicity_ms` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-0/measured_fps` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-0/retire_frame_event` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-1/fps_periodicity_ms` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-1/measured_fps` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-1/retire_frame_event` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-2/fps_periodicity_ms` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-2/measured_fps` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/drm/card0/sde-crtc-2/retire_frame_event` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae00000.qcom,mdss_mdp/power/control` | vendor_sysfs_graphics | = | = | same as 5.4 |
| `…/soc/ae94000.qcom,mdss_dsi_ctrl0/uio/uio1/name` | vendor_sysfs_uio_file | = | = | same as 5.4 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_hlos@1300/wakeup` | sysfs_wakeup | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_hlos@1300/wakeup` | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_hlos@1300/wakeup` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_pbs@800/wakeup` | sysfs_wakeup | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_pbs@800/wakeup` | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_pbs@800/wakeup` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0` | sysfs_rtc | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0` | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0` | differs: 6.12 SPMI device is 0-NN, the policy has only the 5.4 spmi0-NN spelling |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0/wakeup` | sysfs_wakeup | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0/wakeup` | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0/wakeup` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/wakeup` | sysfs_wakeup | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/wakeup` | `…/soc/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/wakeup` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/blue` | vendor_sysfs_graphics | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/blue` | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/blue` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/green` | vendor_sysfs_graphics | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/green` | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/green` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/red` | vendor_sysfs_graphics | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/red` | `…/soc/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/red` | 5.4 SPMI device name (spmi0-NN); the policy's 0-NN twin entry matches 6.12 |
| `…/soc/soc:dummy_source/coresight-modem-diag` | vendor_sysfs_qdss_dev | = | = | same as 5.4 |
| `…/soc/soc:gpio_keys/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,dsi-display-primary/acl` | sysfs_livedisplay_tuneable | = | = | same as 5.4 |
| `…/soc/soc:qcom,dsi-display-primary/cabc` | sysfs_livedisplay_tuneable | = | = | same as 5.4 |
| `…/soc/soc:qcom,dsi-display-primary/dc` | sysfs_livedisplay_tuneable | = | = | same as 5.4 |
| `…/soc/soc:qcom,dsi-display-primary/hbm` | sysfs_livedisplay_tuneable | = | = | same as 5.4 |
| `…/soc/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/rx-macro/rx_swr_ctrl/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/tx-macro/tx_swr_ctrl/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/va-macro/va_swr_ctrl/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/wsa-macro/wsa_swr_ctrl/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:sound/Listen` | 1 | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink_log/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/extcon` | sysfs_extcon | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/battery` | vendor_sysfs_battery_supply | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/battery/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/usb` | vendor_sysfs_usb_supply | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/usb/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/wireless` | vendor_sysfs_usb_supply | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/wireless/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,pmic_glink/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,smp2p-adsp/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,smp2p-modem/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,smp2p-nsp/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,smp2p_sleepstate/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qcom,smp2p-wpss/wakeup` | sysfs_wakeup | = | = | same as 5.4 |
| `…/soc/soc:qfprom@0/feat_conf_m7` | vendor_sysfs_qfprom | = | = | same as 5.4 |

170 entries map to a device of the phone's 5.4 tree: 8 FIXED, 73 were the same as 5.4 already, 8 SPMI spellings (see status); 81 whose DT node is not in the 6.12 tree; 199 entries name devices this phone does not have (other boards/SoCs).

Device of the 5.4 tree with no node of the same path in the 6.12 tree:

| 5.4 genfscon path | label | 5.4 DT node | 6.12 |
|---|---|---|---|
| `…/samsung_mobile_device/samsung_mobile_device:hall_ic/wakeup/` | sysfs_wakeup | `/samsung_mobile_device/hall_ic` | hall sensor not ported (6.12 tree: hall_keys gpio-keys, disabled) |
| `…/soc/18590100.qcom,cpu7-cpu-l3-latfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu7-cpu-l3-latfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/18590100.qcom,snoop-l3-bw/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,snoop-l3-bw` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/3700000.qcom,lpass/subsys3/wakeup` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/3700000.qcom,lpass/subsys3/wakeup/` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/3700000.qcom,lpass/subsys4/wakeup` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/3700000.qcom,lpass/subsys4/wakeup/` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/3700000.qcom,lpass/subsys5/wakeup` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/3700000.qcom,lpass/wakeup` | sysfs_wakeup | `/soc/qcom,lpass@3700000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/subsys3/name` | vendor_sysfs_ssr | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys3/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys3/` | sysfs_wakeup | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys3/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/subsys4/name` | vendor_sysfs_ssr | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys4/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys4/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/subsys5/name` | vendor_sysfs_ssr | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys5/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys5/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/subsys6/name` | vendor_sysfs_ssr | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys6/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,mss@4080000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/4080000.qcom,mss/subsys8/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/subsys9/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/4080000.qcom,mss/wakeup` | sysfs_wakeup | `/soc/qcom,mss@4080000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/a300000.qcom,turing/subsys5/wakeup` | sysfs_wakeup | `/soc/qcom,turing@a300000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/a300000.qcom,turing/subsys6/wakeup` | sysfs_wakeup | `/soc/qcom,turing@a300000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/a300000.qcom,turing/wakeup` | sysfs_wakeup | `/soc/qcom,turing@a300000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/subsys10/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/subsys3/name` | vendor_sysfs_ssr | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys3/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys4/name` | vendor_sysfs_ssr | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys4/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys5/name` | vendor_sysfs_ssr | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys5/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,venus@aab0000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/aab0000.qcom,venus/subsys5/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/subsys6/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/subsys7/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/subsys9/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/aab0000.qcom,venus/wakeup` | sysfs_wakeup | `/soc/qcom,venus@aab0000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:hwevent/coresight-hwevent` | vendor_sysfs_qdss_dev | `/soc/hwevent` | CoreSight hwevent: no node in the 6.12 tree |
| `…/soc/soc:i2c@17/i2c-19/19-0028/wakeup/` | sysfs_wakeup | `/soc/i2c@17/sx9360-i2c@28` | i2c-gpio (=m) and sx9360 are not loaded on 6.12; /aliases i2c19 keeps the 5.4 number once they are |
| `…/soc/soc:qcom,cpu0-cpu-ddr-latfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu0-cpu-ddr-latfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu0-cpu-llcc-lat/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu0-cpu-llcc-lat` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu0-llcc-ddr-lat/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu0-llcc-ddr-lat` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu4-cpu-ddr-latfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu4-cpu-ddr-latfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu4-cpu-ddr-qoslat/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu4-cpu-ddr-qoslat` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu4-cpu-llcc-lat/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu4-cpu-llcc-lat` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu4-cpu-llcc-latfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu4-cpu-llcc-latfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu4-llcc-ddr-lat/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu4-llcc-ddr-lat` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu7-cpu-ddr-latfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu7-cpu-ddr-latfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu7-cpu-ddr-qoslatfloor/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu7-cpu-ddr-qoslatfloor` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu-cpu-llcc-bw/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu-cpu-llcc-bw` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,cpu-llcc-ddr-bw/devfreq` | vendor_sysfs_devfreq | `/soc/qcom,cpu-llcc-ddr-bw` | no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4) |
| `…/soc/soc:qcom,ipa_fws/subsys0/name` | vendor_sysfs_ssr | `/soc/qcom,ipa_fws` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,ipa_fws/subsys0/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,ipa_fws` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,ipa_fws/subsys0/wakeup` | sysfs_wakeup | `/soc/qcom,ipa_fws` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,ipa_fws/subsys0/wakeup/` | sysfs_wakeup | `/soc/qcom,ipa_fws` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,ipa_fws/subsys1/wakeup` | sysfs_wakeup | `/soc/qcom,ipa_fws` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,ipa_fws/subsys2/name` | vendor_sysfs_ssr | `/soc/qcom,ipa_fws` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,ipa_fws/subsys2/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,ipa_fws` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,ipa_fws/wakeup` | sysfs_wakeup | `/soc/qcom,ipa_fws` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,kgsl-hyp/subsys1/wakeup/` | sysfs_wakeup | `/soc/qcom,kgsl-hyp` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,kgsl-hyp/subsys2/name` | vendor_sysfs_ssr | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys2/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys2/wakeup` | sysfs_wakeup | `/soc/qcom,kgsl-hyp` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,kgsl-hyp/subsys3/name` | vendor_sysfs_ssr | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys3/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys3/wakeup` | sysfs_wakeup | `/soc/qcom,kgsl-hyp` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,kgsl-hyp/subsys4/name` | vendor_sysfs_ssr | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys4/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys6/name` | vendor_sysfs_ssr | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/subsys6/restart_level` | vendor_sysfs_ssr_toggle | `/soc/qcom,kgsl-hyp` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,kgsl-hyp/wakeup` | sysfs_wakeup | `/soc/qcom,kgsl-hyp` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,msm-ext-disp/extcon/extcon0/cable.1/` | vendor_sysfs_graphics | `/soc/qcom,msm-ext-disp` | external display (DP) not in the 6.12 tree (placeholder node only) |
| `…/soc/soc:qcom,msm-ext-disp/extcon/extcon0/state` | vendor_sysfs_graphics | `/soc/qcom,msm-ext-disp` | external display (DP) not in the 6.12 tree (placeholder node only) |
| `…/soc/soc:qcom,msm-ext-disp/extcon/extcon1/cable.1/` | vendor_sysfs_graphics | `/soc/qcom,msm-ext-disp` | external display (DP) not in the 6.12 tree (placeholder node only) |
| `…/soc/soc:qcom,msm-ext-disp/extcon` | sysfs_extcon | `/soc/qcom,msm-ext-disp` | external display (DP) not in the 6.12 tree (placeholder node only) |
| `…/soc/soc:qcom,wpss@8a00000/subsys2/` | sysfs_wakeup | `/soc/qcom,wpss@8a00000` | same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index |
| `…/soc/soc:qcom,wpss@8a00000/subsys3/wakeup` | sysfs_wakeup | `/soc/qcom,wpss@8a00000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,wpss@8a00000/subsys4/wakeup` | sysfs_wakeup | `/soc/qcom,wpss@8a00000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |
| `…/soc/soc:qcom,wpss@8a00000/wakeup` | sysfs_wakeup | `/soc/qcom,wpss@8a00000` | parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label |

Notes on the rows that are not plain matches:

* **SPMI.** On 5.4 the Qualcomm SPMI core names the PMIC devices `spmi0-NN`; 6.12 uses `0-NN`.
  The ROM policy has both spellings for the PON, RTC wakeup and tri-LED entries, but
  `.../0-00/...:rtc@6100/rtc/rtc0` has no `sysfs_rtc` twin. That directory is plain `sysfs` on 6.12.
  No denial was seen. A fix belongs in the ROM policy; no DT change can rename an SPMI device.
  * PON: in the 6.12 tree the upstream `pon@1300` (`qcom,pmk8350-pon`, `qcom-pon.ko` +
    `pm8941-pwrkey.ko`) binds. The downstream `pon_hlos@1300` / `pon_pbs@800` nodes
    (`qcom,qpnp-power-on`) are still in the tree but have no 6.12 driver. Their `/wakeup` entries
    therefore never exist; the power key's wakeup source is under
    `...:pon@1300/...:pon@1300:pwrkey/wakeup` (plain `sysfs`).
  * The pm8350c `qcom,leds@ef00` (tri-LED) has no 6.12 module.
* **a80000** (SM5714 USB-PD at 0x33). The path is right now (i2c-23), but the bus still does not
  probe on 6.12 because tlmm `qcom,gpios-reserved` lists GPIO 32/33 (SE8 SDA/SCL on this phone).
  The 6.12 USB-PD stack ("powerpd") therefore never reaches its chip. Removing 32 33 from that
  list is a separate fix; it is not made here, per "every other node unchanged".
* **i2c-gpio / sx9360** (grip sensor `19-0028`): not loaded on 6.12. The alias `i2c19` keeps the
  number free for it.
* **subsysN**: `subsys_compat.ko` already registers devices named like the 5.4 PIL devices
  (`4080000.qcom,mss`, `3700000.qcom,lpass`, `soc:qcom,wpss@8a00000`, ...) under /soc, each with
  `subsysN`. So `name` and `restart_level` keep their 5.4 paths. Those parents carry no wakeup
  source, so the `.../wakeup` entries have nothing to label.
* **A stale node is left as it was**: the Samsung overlay's `/soc/qcom,qup_hsuart@994000`, a 5.4
  binding with 5.4 clock ids, already a /soc child with `qcom,wrapper-core`. It still fails at
  pinctrl because GPIO 22 is taken by the debug console, the same as before. With 0009 its probe
  would get further if the console were ever disabled. Disable that node when SE5 is next
  touched.

## 4. Power-HAL nodes that do not exist on 6.12 (`perfmgr-missing-rb10-612.txt`)

| powerhint node (5.4) | 6.12 BSP replacement | state on rb10/rb11 |
|---|---|---|
| `/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/{min_freq, bw_hwmon/{hist_memory,hyst_length,hyst_trigger_count,io_percent,sample_ms}}` (5.4 `bw_hwmon` governor, CPU→LLCC) | `bwmon.ko` (`qcom,bwmon4` node `qcom,bwmon-llcc@90b6400`, target `qcom,dcvs/llcc`): `/sys/devices/system/cpu/bus_dcvs/LLCC/90b6400.qcom,bwmon-llcc/` with the same attribute names (`min_freq max_freq sample_ms hist_memory hyst_length hyst_trigger_count io_percent mbps_zones up_scale ...`) | **not loaded**: `bwmon.ko` is in no load list (rb11 first stage has `qcom-dcvs`, `dcvs_fp`, `qcom_llcc_pmu` only) |
| `/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/...` (LLCC→DDR) | `bwmon.ko`, `qcom,bwmon5` `qcom,bwmon-ddr@9091000` → `/sys/devices/system/cpu/bus_dcvs/DDR/9091000.qcom,bwmon-ddr/` (also `bwmon-l3@90b9100` → `.../L3/`) | not loaded |
| memlat devfreq devices (`soc:qcom,cpu*-cpu-llcc-lat`, `*-llcc-ddr-lat`, `*-latfloor`, `*-qoslat`, `18590100.qcom,cpu*-cpu-l3-lat`) | `memlat.ko` (+ `qcom-pmu-lib.ko`, `qcom_scmi_client.ko`): `/sys/devices/system/cpu/bus_dcvs/<DDR,LLCC,L3,DDRQOS>/memlat/...`, `.../memlat_settings` | not loaded (`qcom-pmu-lib` is in Qualcomm's lahaina first-stage list, memlat is second stage there) |
| `/sys/class/kgsl/kgsl-3d0/devfreq/{min,max}_freq` | The same nodes. kgsl adds the `devfreq` link when its `msm-adreno-tz` devfreq device registers | **missing**: the governor is the separate module `governor_msm_adreno_tz.ko` (`CONFIG_DEVFREQ_GOV_QCOM_ADRENO_TZ=m`, so kgsl's built-in stub returns 0); it is in no load list. Every 6.12 log has `kgsl-3d 3d00000.qcom,kgsl-3d0: devfreq_add_device: Unable to find governor` / `Failed to add devfreq device for msm-adreno-tz governor: -19`. The result: **no GPU DCVS at all on 6.12/6.18** (GPU stays at its default level) |
| `/sys/class/kgsl/kgsl-3d0/force_clk_on`, `force_rail_on` | They exist, but the 6.12 kgsl returns `-EOPNOTSUPP` while the GMU runs (`__force_on_store`: `if (gmu_core_gpmu_isenabled(device))`). 5.4 accepted the write | write fails by design; harmless (the GMU owns clocks and rails) |
| `/sys/class/sec/tsp/input/enabled` | same node | **fixed by this change**: the label was the problem, not the node |

The kgsl nodes have no genfscon entry on 5.4 either. The ROM's `hal_power_default.te` allows
`vendor_sysfs_kgsl`, but its comment names another SoC's path (`5000000.qcom,kgsl-3d0`). So the
GPU nodes are plain `sysfs` on both kernels, and the HAL's GPU writes are denied once the files
exist. That is a ROM policy gap, not a kernel one.

Is a compatibility shim reasonable?
* **GPU**: no shim needed. Load `governor_msm_adreno_tz.ko` (and `governor_gpubw_mon.ko`, the GPU
  bus governor) before `msm_kgsl.ko` in the kgsl stage. The 5.4 path then exists unchanged.
  Needs a kexec test: GPU DCVS has never run on 6.12.
* **CPU/bus DCVS**: first load `qcom-pmu-lib`, `memlat` and `bwmon` (they are Qualcomm's own
  6.12 lahaina set; the DT nodes are already in our tree). Without them DDR/LLCC/L3 do not scale
  with CPU load on 6.12.
* A kernel shim that registers fake `soc:qcom,cpu-*-bw` devfreq devices with a `bw_hwmon/`
  directory forwarding to bwmon is possible, but not worth it. The units differ: the 5.4 bw
  devfreq freq is MB/s, the 6.12 dcvs freq is kHz of the target. A shim would have to convert
  every value, and it would put a second governor interface next to the real one.
* The better fix is a 6.12 `powerhint.json`. The vendor add-on can bind it over
  `/vendor/etc/powerhint.json` from its rc, gated on `ro.boot.a52sxq.k61x`. It would point the
  CPUBW/LLCCBW nodes at `/sys/devices/system/cpu/bus_dcvs/{DDR,LLCC}/<bwmon>/...` with values
  converted.
  * That path is under `/sys/devices/system/cpu` (`sysfs_devices_system_cpu`), which
    `hal_power_default` may already write, so no new policy is needed.
  * The ROM's `init.kernel.post_boot-yupik.sh` writes the same 5.4 `bw_hwmon` paths at boot.
    On 6.12 those writes fail harmlessly; Qualcomm's 6.12 tunables come from the DT nodes.

## 5. Offline verification done

* Round trip: our FDT reader/writer reproduces both trees exactly (same `dtc` decompile, same
  normalized dtb).
* `sysfscompat.py verify` passes for 6.12 (`android-r02`) and 6.18 (`android-r02-618`): the new
  tree is exactly `apply(old)`, with 70 property changes and 8 moved nodes, nothing else.
* The simulated paths of the key nodes in the new trees are
  `/devices/platform/soc/98c000.i2c/i2c-21/21-0049` (SM5714),
  `/devices/platform/soc/a94000.i2c/i2c-25/25-0049` (touch) and
  `/devices/platform/soc/99c000.qcom,qup_uart` (BT). The full client list:
  `20-0056 18-004c 18-0064 21-0049 21-0057 22-0051 24-0027 25-0049`, all equal to the 5.4
  simulation of phone 2's live tree; 23-0033 follows once a80000 probes. The
  `build-realboot.sh` report shows them (`rb11/sysfs-sim.txt`).
* rb11 passes all `build-realboot.sh` checks:
  * ROM repack byte-identical;
  * DIAG kernel QEMU smoke test PASSED;
  * insmod simulation 223 ok / 0 FAIL, identical to rb10;
  * libmodprobe dry run 190/190 + 32/32;
  * no kexec artefacts;
  * ABL libufdt emulation (`tools/ufdt-host/check.sh`): slack 65399 bytes, as rb10;
  * merged size and the cmdline 3458 bytes with 637 bytes of headroom;
  * "tree = the tested android-r02.dtb (s75) except the extcon";
  * no blockers.
* rb618-4 passes the same checks: insmod 222 ok / 0 FAIL, identical to rb618-3, boot.img
  identical. The 6.18 test ramdisk check (`check-load.py`, best a52.mods): a8 and a9 both give
  225 ok, 40 already, 0 FAIL, the same output.
* The rehearsal package `rh-rh612d` (rb11) builds: libmodprobe 190/190 and 32/32, gen check
  with the latest phone-2 harness live tree OK.

## 6. Key-free kexec check before rb11 is flashed

Run the rehearsal (phone 2, the owner's OK for the run; nothing is flashed):
`drivers612/realboot/out/rh-rh612d/HOWTO.txt` has the kx-cycle line, which uses rb11's own modules
and tree.

It is SELinux permissive, but labels are assigned the same way, so `ls -Z` shows exactly what
enforcing would use. Avc lines still appear, with `permissive=1`. Through `adb shell`
(as root):

    dmesg | grep -E 'a52sxq-wrapper-core|SE Wrapper is NULL|i2c_geni|msm_geni_serial'
        # want 2 lines "a52sxq-wrapper-core: SE wrapper 9c0000.qcom,qupv3_0_geni_se" (i2c, serial),
        # "I2C probed" for 980000 984000 98c000 990000 a84000 a94000, no repeating "Wrapper is NULL"
    ls /sys/bus/i2c/devices/          # want 18-004c 18-0064 20-0056 21-0049 21-0057 22-0051 24-0027 25-0049
    ls -Zd /sys/devices/platform/soc/98c000.i2c/i2c-21/21-0049            # u:object_r:sysfs_battery:s0
    ls -Z  /sys/devices/platform/soc/98c000.i2c/i2c-21/21-0049/sm5714-fuelgauge/power_supply/sm5714-fuelgauge/type
                                                                          # sysfs_battery (the hal_health denial)
    readlink -f /sys/class/sec/tsp/input  # /sys/devices/platform/soc/a94000.i2c/i2c-25/25-0049/input/inputN
    ls -Z $(readlink -f /sys/class/sec/tsp/input)/enabled                 # u:object_r:sysfs_power_writable:s0
    ls -Zd /sys/devices/platform/soc/a94000.i2c/i2c-25/25-0049/wakeup/*   # sysfs_wakeup
    ls -Zd /sys/devices/platform/soc/98c000.i2c/i2c-21/21-0057/power_supply/pca9468-charger  # sysfs_wakeup
    ls -Zd /sys/devices/platform/soc/99c000.qcom,qup_uart/wakeup/*        # sysfs_wakeup
    ls -l /dev/ttyHS0                                                     # BT UART still ttyHS0 (alias hsuart0)
    dmesg | grep 'avc:.*denied' | grep -E 'hal_power|hal_health'          # want nothing (was 306 lines)

Then the functions on the moved buses:
* touch;
* battery percentage and charging (21-0049/21-0057);
* NFC on (24-0027);
* BT on (ttyHS0, BT patch download);
* speaker (tas256x on i2c-18);
* camera open (s2mpb03 20-0056, OIS/EEPROM 22-0051).

If any of them fails, the old layout is one variable away: build with the wrapper-layout tree
(revert the sysfscompat step).

## 7. Not done here / follow-ups

* No phone was touched. s75, a9, rb11, rb618-4 and rh-rh612d have not run.
* GPU and bus DCVS modules (section 4): add `governor_msm_adreno_tz`, `governor_gpubw_mon`,
  `qcom-pmu-lib`, `memlat`, `bwmon` to the stages, then run a kexec test.
* GPIO 32/33 in tlmm `qcom,gpios-reserved` keeps a80000 (the SM5714 USB-PD chip) dead on 6.12.
* ROM policy gaps that no kernel change can close: `0-00/...rtc@6100/rtc/rtc0` (`sysfs_rtc`) and
  the kgsl nodes (no genfscon on either kernel).
* Kexec runs that still use s74/a8 (or any ramdisk without 0009) must use the
  `*-wrapperlayout.dtb` trees.
