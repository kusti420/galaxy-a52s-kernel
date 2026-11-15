# Bluetooth on the 6.12 BSP: decision and evidence (2026-11-11)

## Decision
Keep the closed HAL (`android.hardware.bluetooth@1.0-service-qti`, 64-bit) and give it the
kernel face it has on 5.4:

| Piece | Source | Module |
|---|---|---|
| `/dev/btpower`, rfkill `bt_power` + `device/extldo` | **the phone's own 5.4 `drivers/bluetooth/btpower.c`**, 4 API fixes | `btpower/btpower.ko` |
| `/dev/btfmslim` + ASoC codec DAIs (SCO, A2DP offload) | bt-kernel `bt-kernel-css.lnx.16.0.r6-rel` `slimbus/`, unmodified | `btfmslim/bt_fm_slim.ko` |
| `/dev/ttyHS0` | soc-repo `msm_geni_serial.ko` (already in the BSP build) | - |

Not chosen: upstream `hci_qca` (serdev). Not chosen: the r6 `pwr/btpower.c`.

## Evidence

HAL contact points (strings of `lib64/hw/android.hardware.bluetooth@1.0-impl-qti.so`, blob tree
`vendor/samsung/sm7325-common/proprietary/vendor`):
- `/dev/btpower`, `/dev/ttyHS0` (hard-coded; also `/dev/smd2`, `/dev/smd3` for other SoC types),
  `/sys/class/rfkill/rfkill%d/{type,state,device/extldo}`, `/mnt/vendor/efs/bluetooth/bt_addr`,
  `MSM_GENI_SERIAL_TIOCFAULT` (0x54EC; plus PMGET/PMPUT/PMACT 0x54ED..EF by the UART clock code).
- Firmware is downloaded by the HAL over the UART, not by the kernel: default directory
  `/vendor/firmware/` (`msbtfw11.mbn`, `msbtfw11.tlv`, `msnv11.bin`, `bt_nvm_loading.xml`;
  optional `bt_nvm_loading_2nd.xml`), alternative `/bt_firmware/image/` and
  `/vendor/bt_firmware/image/` selected by `persist.vendor.bluetooth.alt_path_for_fw`
  (`CheckAndSetProperRampatchAltPath`). `vendor.qcom.bluetooth.soc=moselle` (vendor.prop).
- Files in the ROM's blob tree: `sm7325-common/proprietary/vendor/firmware/msbtfw11.mbn`
  (184620 B), `msbtfw11.tlv` (172400 B), `msnv11.bin` (6213 B);
  `a52sxq/proprietary/vendor/firmware/bt_nvm_loading.xml`. All land in `/vendor/firmware/`,
  the HAL's default path. So redwood's blocker (HAL going for `/bt_firmware/image/msbtfw11.mbn`,
  a partition that phone has and this one does not) should not apply: the A52s has no
  bt_firmware mount and the alt-path property is unset. NOT VERIFIED on hardware.

Why not `hci_qca`:
- It needs a different HAL (AOSP serial/"hci" HAL instead of the Qualcomm one) and loses the
  Samsung/Qualcomm vendor extensions the ROM is built around (`vendor.samsung.hardware.bluetooth`,
  A2DP offload through `bt_fm_slim`, the closed audio HAL's BT path). That is ROM work, outside
  "keep the blobs".
- It is possible later: GKI 6.12 has `SERIAL_DEV_BUS=y` and ships `hci_uart.ko` with
  `BT_HCIUART_QCA=y` + `btqca.ko` (`bsp612/out/gki/.config`, `modules-gki.list`), and upstream
  `hci_qca` knows `qcom,wcn6750-bt`. But soc-repo's `msm_geni_serial` is the UART driver here,
  the upstream binding wants other supply names (`vddio`, `vddaon`, ... / pwrseq) and
  `firmware-name`, and nobody loads `msbtfw11.mbn` through it on this board. Keep as fallback.
- Consequence for the DT: no serdev child under `&qupv3_se7_4uart`. As long as the BT node sits
  at `/soc/bt_wcn6750` (as on 5.4 and in 6.12 yupik.dtsi) hci_qca cannot bind and ttyHS0 stays a
  plain tty for the HAL.

Why the 5.4 `btpower.c` and not r6 `pwr/btpower.c` (3420 lines vs 1340):
- The seven numbers the HAL uses are the same in both (0xbfac..0xbfb1, 0xbfc0), but r6 changed
  what they do: `BT_CMD_PWR_CTRL` goes through a client state machine
  (`btpower_handle_client_request`) that expects `BT_CMD_REGISTRATION` (0xbfe2) and
  `BT_CMD_ACCESS_CTRL` (0xbfe4) from a newer HAL, with UWB arbitration, SIGIO to registered
  clients and gpiod-based DT parsing. A 5.4-era HAL never registers. Whether power-on still
  works for an unregistered client could only be found on hardware.
- The phone's own file is the ABI by construction (ioctl numbers, argument conventions, rfkill
  name `bt_power`, `extldo`, class `bt-dev`, DT properties `qcom,bt-*-supply/-config`,
  `qcom,bt-reset-gpio`, `qcom,bt-sw-ctrl-gpio`, `qcom,wl-reset-gpio`). It needed only
  `patches/0001-btpower-5.4-to-6.12-api.patch`: `pr_warning` -> `pr_warn`, platform `.remove`
  returns void, `class_create()` lost its module argument, local include of `btpower.h`.
  No Samsung change exists in that file (no SEC ifdefs).
- redwood's `modules/btpower` is a different, newer CLO revision (gpiod, mbox); not used.

Why r6 for `bt_fm_slim`: the 5.4 `btfm_slim*.c` is written for the old downstream SLIMbus API
(`slim-msm-ngd`), which 6.12 no longer has; r6 `slimbus/` is the same driver on the upstream
SLIMbus API and compiles **unmodified** with `-DCONFIG_BTFM_SLIM` (the lahaina configuration)
against our 5.4-ABI `btpower.h` (`btpower_register_slimdev`, `btpower_get_chipset_version`).
Same userspace/ASoC contract as 5.4: chrdev `btfm_slim` -> `/dev/btfmslim`, driver
`btfmslim-driver`, DAIs `btfm_bt_sco_a2dp_slim_rx`, `btfm_bt_sco_slim_tx`,
`btfm_bt_split_a2dp_slim_rx`, `btfm_fm_slim_tx`, same stream names. It needs soc-repo's
`slimbus.ko` (the `slim_stream_unprepare_disconnect_port` API is Qualcomm-only), hence the
soc-repo include path in `btfmslim/Kbuild`.

## ABI kept / changed / unverified
Kept identical to 5.4: `/dev/btpower` ioctls 0xbfac, 0xbfad, 0xbfae, 0xbfaf, 0xbfb0, 0xbfb1,
0xbfc0 (same code); rfkill `bt_power` type bluetooth with `device/extldo`; `/dev/btfmslim`;
`/dev/ttyHS0` with `MSM_GENI_SERIAL_TIOC{FAULT,PMGET,PMPUT,PMACT}` 0x54EC..0x54EF (same numbers
in 6.12 soc-repo `include/uapi/linux/msm_geni_serial.h`).

Changed:
- 5.4 also accepted the legacy numbers `TIOCPMGET/PUT/ACT` 0x544D..0x544F on the UART; 6.12
  soc-repo only accepts 0x54ED..EF. The HAL binary logs "MSM_GENI_SERIAL_TIOCFAULT IOCTL not
  supported", which points at the new set, but which PM numbers it issues was not disassembled.
  If the UART clock vote fails on the phone, add the three legacy cases to msm_geni_serial.c.
- Device numbers: `/dev/btpower` major 489 and `/dev/btfmslim` major 482 on 5.4 are dynamic
  (`register_chrdev(0, ...)`), so they may differ; ueventd matches by name.
- SLIMbus device/ASoC component name: 5.4 DT node `qca6490` with compatible
  `qcom,btfmslim_slave`; on 6.12 the device is named `btfmslim` (`dev_set_name`) and matched as
  `slim217,221`. The audio machine driver's BT dai-link codec name must be `btfmslim` (audio
  agent: check `asoc-codec-names`/dai-link in the 6.12 audio DT).

Not verifiable offline: regulator ranges being accepted by 6.12 rpmh-regulator; the SLIMbus NGD
coming up (`qcom,wait_for_adsp_up` needs ADSP + audio SSR notifier); `qcom,ea-pc`; the HAL's
PM ioctl numbers; firmware download end to end.
