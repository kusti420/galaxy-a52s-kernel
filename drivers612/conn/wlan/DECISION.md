# Wi-Fi on the 6.12 BSP: qcacld-3.0 (chosen) vs upstream ath11k

Decision: **downstream qcacld-3.0 + wlan-platform (icnss2)**. Built, see STATUS.md.

## Evidence

| Question | Finding | Where |
|---|---|---|
| Does GKI 6.12 ship ath11k? | No. `gki_defconfig`: `# CONFIG_CFG80211 is not set`, `# CONFIG_WLAN_VENDOR_ATH is not set`. No ath* in `modules-gki.list`. | `bsp612/out/gki/.config`, `bsp612/out/dist/modules-gki.list` |
| Does soc-repo ship it? | No. soc-repo builds `cfg80211.ko` and `mac80211.ko` as vendor modules (`CONFIG_CFG80211=m`, `CONFIG_MAC80211=m` in the lahaina config) and nothing from `drivers/net/wireless/ath`. No "ath11k" string in `soc-repo/build/` or `configs/lahaina_perf.bzl`. | `bsp612/out/lahaina/.config`, `out/dist/modules-soc.list` |
| Is the source there? | Yes, in the ACK tree: `drivers/net/wireless/ath/ath11k/ahb.c` has `qcom,wcn6750-wifi`, hw entry "wcn6750 hw1.0" (dir `WCN6750/hw1.0`). It could be built as one more external module against soc-repo's mac80211. Not tried. | `bsp612/kernel` |
| What else would ath11k need? | (1) An upstream-style `wifi@17a10040` node (`qcom,wcn6750-wifi`, `qcom,rproc`, `wifi-firmware` iommu sub-node, `qcom,smem-states`); the 6.12 downstream yupik.dtsi has none and its WPSS remoteproc is Qualcomm's `qcom,yupik-wpss-pas`, not upstream `qcom,sc7280-wpss-pas`. (2) Someone to hold the three RF rails (S7B/S1B/S8B) that icnss2 votes for; ath11k_ahb has no regulator code. (3) Firmware: `ath11k/WCN6750/hw1.0/board-2.bin` or `board.bin` (the phone's `qca6750/bdwlan.elf` works as `board.bin`: ath11k detects ELF board files, qmi.c:2442), `regdb.bin` (vendor has it), and the same `wpss.mdt/.b0x` through remoteproc. No m3 file. Whether Samsung's 2021-2023 WPSS build speaks the QMI subset ath11k expects is unknown. | ath11k `core.c`, `qmi.c`, `hw.h` |
| Is the ROM driver-agnostic? | Partly. `wpa_supplicant`/`hostapd` are nl80211 with the qcwcn private lib; the Wi-Fi HAL is the open `android.hardware.wifi-service` with **`libwifi-hal-qcom`**, which speaks QCA vendor nl80211 commands (OUI 00:13:74) that ath11k does not implement. `WIFI_DRIVER_STATE_CTRL_PARAM := "/dev/wlan"` (qcacld's state device). | `device/samsung/sm7325-common/{BoardConfigCommon.mk:240-259,common.mk:449-494}` |
| Closed consumers | `macloader` writes `/sys/wifi/{mac_addr,ant,pm}` (the MAC lives in `/mnt/vendor/efs/wifi/.mac.info`, the DT has no `use-nv-mac`); the antenna value selects `bdwlan.elf{,1,2,10}`. `cnss-daemon`, `lowi-server` use the ICNSS genl family and QCA vendor commands. With ath11k all of that is lost or has to be redone in userspace. | 5.4 `drivers/soc/qcom/icnss2/main.c` (CONFIG_SEC_SS_CNSS_FEATURE_SYSFS), `research/blob-uapi-inventory.md` section 7 |
| Prior art on this exact BSP | redwood-6.12 (same SoC, same chip, 5.4-era vendor) has WPSS booting, `wlan.ko` loaded and scanning with exactly this qcacld stack. No ath11k report on a 5.4-era vendor image. | `donors/redwood-6.12/STATUS.md` |
| Build cost | The whole qcacld stack builds here in under 2 minutes with 3 small donor patches. | `build.sh`, `out-*.log` |

## Why not ath11k now
It would need a new DT binding next to the downstream one, a regulator holder, a different HAL
(`libwifi-hal` generic instead of qcom), a macloader replacement and firmware compatibility that
nobody has shown. It stays the right choice for the second hop (ACK 6.18 with upstream sc7280
DT), where `qcom,wcn6750-wifi` is already described. For the 6.12 hop the contract with the
vendor image is the point, and qcacld keeps it.

## What ath11k would need from the vendor image (for the 6.18 hop)
- `/vendor/firmware/wpss.mdt`, `wpss.b00..b07` (per bootloader revision: `wlan/a528b/revN`).
- `qca6750/bdwlan.elf` (or `.elf1/.elf2/.elf10` by antenna setting) as
  `ath11k/WCN6750/hw1.0/board.bin`; `qca6750/regdb.bin` as `ath11k/WCN6750/hw1.0/regdb.bin`.
- `Data.msc` is firmware-log metadata for cnss-daemon; ath11k does not use it.
