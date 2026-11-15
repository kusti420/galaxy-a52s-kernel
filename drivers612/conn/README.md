# drivers612/conn: A52s connectivity on the Qualcomm 6.12 BSP

Modem plumbing, mobile data, Wi-Fi (WCN6750 on the WPSS) and Bluetooth for the a52sxq on
`bsp612` (GKI 6.12.81 + soc-repo r70), keeping the closed 5.4-era vendor daemons (Samsung
`rild`, `pm-service`, `rmt_storage`, `qrtr-ns`, `pd-mapper`, the QTI Bluetooth HAL, `macloader`).
Everything here is **compile-checked only**. Nothing was loaded, booted or flashed.

## What is here

| Dir / file | What | State |
|---|---|---|
| `data/` | dataipa + datarmnet + datarmnet-ext (`data-kernel.lnx.5.0.r30-rel`) as one external tree: `gsim ipam ipanetm rmnet_mem rmnet_ctl rmnet_core rmnet_offload rmnet_shs` + 5 more; `a52sxq-ipa.dtsi` | 13 `.ko`, depmod clean |
| `wlan/` | qcacld-3.0 + qca-wifi-host-cmn + fw-api + wlan-platform (icnss2) for `lahaina_gki_qca6750`; Samsung `/sys/wifi`; `icnss2-node.dtsi`; `DECISION.md` (qcacld, not ath11k) | 6 `.ko`, no unresolved symbols |
| `bt/` | the phone's 5.4 `btpower.c` on 6.12 (5.4 ioctl ABI), `bt_fm_slim.ko` from bt-kernel r6; `bt-node.dtsi`; `DECISION.md` (keep the closed HAL, not hci_qca) | 2 `.ko` |
| `subsys_compat/` | 5.4 PIL userspace face on remoteproc: `/dev/subsys_*`, `/sys/bus/msm_subsys` | 1 `.ko` |
| `rild/drb/` | Samsung `/dev/drb` (dev RIL bridge) from the 5.4 tree | 1 `.ko` |
| `rild/GAPS.md` | rild's kernel contact points (drb, rmnet ioctls, rmnet netlink, qrtr, pd-mapper, rmt_storage) mapped to 6.12, and the gap list | written |
| `a52sxq-conn.dtsi` | the DT fragment: includes the three sub-fragments, remoteproc firmware names, `smd4`, Samsung's SE5 radio UART | compiles on yupik.dtsi (`rild/dtcheck/check.sh`) |
| `tools/qrtrls` | static, libc-free QRTR service lister for the test ramdisk | built |
| `STATUS.md` | progress log; each part has its own `STATUS.md` with details | |

Decisions, with the evidence in the named files:
- **Wi-Fi: qcacld-3.0 + icnss2** (`wlan/DECISION.md`). GKI 6.12 + soc-repo ship no ath11k at all
  (only cfg80211/mac80211), the base DT has no upstream wifi node, and Samsung's `macloader`
  needs `/sys/wifi`, which lives in the downstream stack.
- **Bluetooth: btpower + the closed HAL on `/dev/ttyHS0`** (`bt/DECISION.md`). `hci_qca` would
  need a different HAL. Do not add a serdev child under the UART and do not load `hci_uart.ko`.
- **QRTR**: soc-repo's `qrtr.ko` is the same downstream implementation as 5.4 (in-kernel name
  server inside `qrtr.ko`, plus the vendor's userspace `qrtr-ns -f` next to it, as today). Not a
  new conflict. uapi `qrtr.h` is identical to 5.4's.
- **pd-mapper**: the in-kernel one (`qcom_pd_mapper.ko`) has no entry for root compatible
  `qcom,yupik`, so it stays inert and the vendor `pd-mapper` serves the `.jsn` domains as on
  5.4. Never add `"qcom,sc7280"` to the root compatible.
- **rmt_storage**: the downstream UIO driver is in soc-repo (`msm_sharedmem.ko`,
  `CONFIG_UIO_MSM_SHAREDMEM=m`) and yupik.dtsi 6.12 has the phone's node unchanged
  (`qcom,rmtfs_sharedmem@0`, `reg <0 0x280000>`, client-id 1, `qcom,vm-nav-path`; the phone
  does not use `qcom,guard-memory`). Nothing to port.

## Build

Each part builds alone against `bsp612/out/lahaina` (read-only use of `bsp612/`):

    data/build.sh            # ~40 s
    wlan/build.sh all        # ~2 min; `prepare` recreates work/ from donors/ + patches/; `check`
    bt/build.sh
    subsys_compat/build.sh
    rild/drb/build.sh
    tools/build.sh
    rild/dtcheck/check.sh    # cpp + dtc of a52sxq-conn.dtsi over yupik.dtsi + yupik-idp.dtsi

(The DT check uses `yupik-idp.dtsi` only to get regulator labels; the real overlay must provide
`S1B S7B S8B S1C L19B L11C` with the phone's own voltages.)

Donor changes are patches with reasons: `data/patches/`, `wlan/patches/`, `bt/patches/`,
`rild/drb/0001-drb-module-unload.patch`.

## Load order and dependencies

soc-repo/GKI modules first (already in the BSP module set):
`qcom_ipc_logging smem smp2p qcom-ipcc qcom_aoss qcom_glink qcom_glink_smem glink_probe qmi_helpers
qrtr qrtr-smd mdt_loader rproc_qcom_common qcom_sysmon qcom_q6v5 qcom_q6v5_pas pdr_interface
qcom_pdr_msg glink_pkt msm_sharedmem rfkill cfg80211 tipc msm_geni_serial slimbus
slim-qcom-ngd-ctrl` (+ their own dependencies; take the order from `modules.dep`).

Then ours:

1. `subsys_compat.ko` (needs `rproc_qcom_common`), `dev_ril_bridge.ko`
2. `rmnet_mem gsim ipam ipanetm` (IPA; `ipam` needs `usb_f_gsi`), then `rmnet_ctl rmnet_core
   rmnet_offload rmnet_shs`. **IPA before the modem is started.**
3. `btpower` (after `rfkill`), `bt_fm_slim` (after slimbus + ASoC)
4. `cnss_nl cnss_prealloc cnss_utils wlan_firmware_service icnss2`, then `wlan.ko` (the ROM
   modprobes it as `qca_cld3_wlan`)

Android init must do, before any remoteproc boots (see GAPS G1):
`write /proc/sys/kernel/firmware_config/force_sysfs_fallback 1` so that firmware requests reach
ueventd's `firmware_directories` (`/vendor/firmware_mnt/image`, `/vendor/firmware-modem/image`,
`/vendor/firmware`), as the 5.4 sysfs fallback did.

## subsys_compat: the contract

- `/sys/bus/msm_subsys/devices/subsysN` with `name state crash_count restart_level
  firmware_name system_debug`; values and error codes as 5.4 `msm_subsystem_restart.c`
  (`OFFLINING/OFFLINE/ONLINE`, `SYSTEM/RELATED`, `-EPERM` on a bad write, `sysfs_notify` on
  `state`).
- Numbering and names from the phone: 0 `yupik_ipa_fws`, 1 `a660_zap`, 2 `wpss`, 3 `modem`,
  4 `adsp`, 5 `cdsp`, 6 `venus`; `/dev/subsys_<name>` with minor = N, class `subsys`.
- Devices sit under `/sys/devices/platform/soc/<5.4 PIL node>/subsysN`
  (`4080000.qcom,mss/subsys3`, `soc:qcom,wpss@8a00000/subsys2`, `3700000.qcom,lpass/subsys4`,
  `a300000.qcom,turing/subsys5`, ...), the paths the vendor `genfs_contexts` labels.
- open = `rproc_boot()`, close = `rproc_shutdown()`: one remoteproc power reference per open
  file, which is exactly `subsystem_get/put`. pm-service holding `/dev/subsys_modem` keeps the
  modem up; in-kernel holders (icnss2 for the WPSS) compose.
- `restart_level`: `RELATED` -> remoteproc recovery on, `SYSTEM` -> off (qcom_q6v5 panics on a
  crash). Applied like a write to remoteproc's `recovery` file, including the Android vendor
  hook that qcom_q6v5_pas uses to copy the flag.
- Parameters: `default_related=1` (bring-up default: recover, do not panic; 5.4's default is
  SYSTEM), `keep_on_close=0`, `stubs=1` (list 0, 1, 6, which have no remoteproc: on 5.4 they are
  kernel-internal firmware loads nobody in userspace opens), `autoboot=` (e.g. `adsp,cdsp`).
- Changed vs 5.4: `firmware_name` shows the remoteproc firmware without extension and a write
  sets `<name>.mdt` (only while offline); the `wakeup/` sub-directories and PIL uevents are not
  reproduced; ramdump devices (`/dev/ramdump_*`) are not provided (soc-repo `qcom_ramdump`
  has its own).
- Could not verify without hardware: that libmdmdetect accepts the device symlink layout, and
  SELinux labels on the new sysfs nodes.

## First on-device test (busybox shell of the 6.12 test ramdisk)

Goal: start the MSS from the phone's own modem partition and see QRTR services, without Android.
Put into the ramdisk's `/extra`: `subsys_compat/subsys_compat.ko`, `tools/qrtrls`, and (step 4)
the data modules from `data/out/lib/modules/*/extra/` plus their soc-repo dependencies
(`usb_f_gsi`, `dwc3-msm`, `qcom_ramdump`, ...: see the table in `data/STATUS.md`).
The DT must carry `a52sxq-conn.dtsi` (at least `&modem_pas`); mpss/wpss/ipa reserved regions of
the 6.12 base equal the phone's (checked: `mpss@8b800000 0xf600000`, `wlan@9ae00000`,
`ipa_fw/ipa_gsi`). The ADSP region differs (phone `0x84700000 +0x4800000`, base `0x86700000
+0x2800000`): do not boot the ADSP before the memory-map fragment fixes it.

    # 1. firmware: one directory for firmware_class (GKI has no sysfs fallback by default)
    part() { for u in /sys/class/block/*/uevent; do grep -q "^PARTNAME=$1\$" $u && basename ${u%/uevent}; done; }
    mkdir -p /fw/modem /fw/apnhlos /lib/firmware
    mount -t vfat -o ro /dev/$(part modem)   /fw/modem
    mount -t vfat -o ro /dev/$(part apnhlos) /fw/apnhlos
    ln -s /fw/modem/image/* /fw/apnhlos/image/* /lib/firmware/ 2>/dev/null
    ls /lib/firmware/modem.mdt /lib/firmware/yupik_ipa_fws.mdt
    echo -n /lib/firmware > /sys/module/firmware_class/parameters/path

    # 2. PIL face; recovery ON before anything boots (a modem crash must not panic)
    insmod /extra/subsys_compat.ko
    cat /sys/bus/msm_subsys/devices/subsys3/name /sys/bus/msm_subsys/devices/subsys3/state   # modem OFFLINE
    cat /sys/bus/msm_subsys/devices/subsys3/restart_level                                    # RELATED
    cat /sys/class/remoteproc/remoteproc*/name; cat /sys/class/remoteproc/remoteproc*/recovery

    # 3. QRTR before the modem
    /extra/qrtrls            # "local node 1", 0 servers (or only kernel ones)

    # 4. IPA first (GAPS G2), then the modem. Open = boot; keep fd 3 open.
    for m in rmnet_mem gsim ipam ipanetm rmnet_ctl rmnet_core; do insmod /extra/$m.ko; done
    dmesg | grep -i -E "ipa|gsi" | tail -20
    exec 3</dev/subsys_modem
    cat /sys/bus/msm_subsys/devices/subsys3/state      # ONLINE
    dmesg | grep -i -E "remoteproc|mss|modem|sysmon|qrtr|glink" | tail -40
    /extra/qrtrls -w 20
    # 5. stop: close = shutdown (5.4 semantics)
    exec 3<&-; cat /sys/bus/msm_subsys/devices/subsys3/state   # OFFLINE

Expected log lines: `remoteproc remoteprocN: Booting fw image modem.mdt`, `... remote processor
4080000.remoteproc-mss is now up`, glink edge `mpss` channels (`IPCRTR`), `qcom_sysmon`/ssctl
connect. Expected QRTR servers on the modem node soon after start (no `rmt_storage` runs in the
ramdisk, so the modem stays in its early state): 43 SSCTL, 15 TEST, 66 service notifier, 24/23
thermal, then it asks for 14 RMTFS. With Android's `rmt_storage`, `tftp_server` and `pd-mapper`
running, the full set follows: 2 DMS, 3 NAS, 1 WDS, 11 UIM, 9 VOICE, 5 WMS, 26 WDA, 36 PDC, 49
IPA (instance 2 = modem; instance 1 = apps from `ipam.ko`), 16 LOC. (Which early services
Samsung's MPSS build registers before RMTFS is an expectation from other Qualcomm modems, not
measured on this phone.)

Likely failure modes:

| Symptom | Cause | What to do |
|---|---|---|
| `open /dev/subsys_modem`: ENODEV | `qcom_q6v5_pas` not probed (deferred on regulators/clocks/smp2p/aoss) | `cat /sys/kernel/debug/devices_deferred`; `&modem_pas` status |
| `-ENOENT` loading `modem.mdt` | firmware path | step 1; `dmesg | grep firmware` |
| **kernel panic "auth and reset failed for remoteproc"** | soc-repo `qcom_q6v5_pas` panics unconditionally when TZ rejects the image (wrong region, wrong/unsigned image) | the ramdisk's crash guard brings the phone back; compare `pil_mpss_mem` with the phone's tree |
| "start timed out", then recovery loops | modem did not signal ready (smp2p/ipcc wiring) | `restart_level` is RELATED, so no panic; check `qcom,smp2p-modem` interrupts |
| modem crashes ~seconds after ONLINE, log mentions `enl2`/IPA | IPA not up (GAPS G2) | fix the IPA probe first (`ipam` needs `usb_f_gsi`; context banks, `yupik_ipa_fws`) |
| `qrtrls`: "no AF_QIPCRTR socket" | `qrtr.ko` not loaded | insmod `qrtr.ko qrtr-smd.ko` |
| modem up but only a handful of services | no RMTFS/TFTP server in the ramdisk | expected here; continue under Android |

Then, in this order: Bluetooth power (`bt/STATUS.md`: rfkill, `/dev/btpower`, GPIO 85/86),
Wi-Fi (`wlan/STATUS.md`: WPSS boots through icnss2, `wlan0`), and under Android the data call
(`rild/GAPS.md`, G1..G6).

## Userspace contract summary

Kept identical to 5.4: `/dev/subsys_*` + msm_subsys sysfs (above), `/dev/drb`, `/dev/btpower`
ioctls 0xbfac..0xbfb1 + rfkill `extldo`, `/dev/btfmslim`, `/dev/ttyHS0`, `/dev/uio0` "rmtfs",
glink_pkt nodes incl. `smd4`, AF_QIPCRTR + uapi, rmnet link kind + `IFLA_RMNET_*` numbers and
flag bits, `SIOCDEVPRIVATE` rmnet ioctls on `rmnet_ipa0`, `/sys/wifi/*` (most), `/dev/wlan`,
`/sys/kernel/icnss/wpss_boot`, ini path `wlan/qca_cld/qca6750/WCNSS_qcom_cfg.ini`.

Changed: `RMNET_IOCTL_EXTENDED_V2` now succeeds (5.4 rejected it); `/dev/wwan_ioctl` numbers
21/22 moved (no user on this phone); UART PM ioctls 0x544D..0x544F are gone from
`msm_geni_serial` (BT HAL use unverified); `/sys/wifi/pm` override, `/sys/wifi/feature` not
ported; firmware fallback needs the sysctl; `/dev/ttyHS8` not enabled.

Not verifiable offline: everything at run time. See the risk lists in each `STATUS.md`.
