# Samsung rild: kernel contact points on 6.12, and the gap list

Scope: what the closed Samsung `rild` + `libsec-ril.so` (and `pm-service`, `rmt_storage`,
`tftp_server`, `qrtr-ns`, `pd-mapper`) touch in the kernel per
`research/blob-uapi-inventory.md` section 6, mapped to the 6.12 BSP + the modules in
`drivers612/conn/`. "5.4" = `$ANDROID_TREE/kernel/samsung/sm7325`. Nothing here was run on a phone.

## 1. `/dev/drb` (Samsung "dev RIL bridge")

- 5.4 driver: `drivers/misc/drb/dev_ril_bridge.c` (`CONFIG_DEV_RIL_BRIDGE=y`), header
  `include/linux/dev_ril_bridge.h`. A misc device named `drb` (dynamic minor; 120 on the phone,
  owner system:radio from ueventd). No ioctls. `read` returns one queued message
  (`struct sipc_fmt_hdr` + payload; waits up to 100 ms, returns 0 when empty), `poll` = POLLIN
  when the queue is non-empty, `write` takes `sipc_fmt_hdr{main_cmd 0x27, cmd_type 0x03}` +
  payload and calls the in-kernel notifier chain with `struct dev_ril_bridge_msg`.
- Not in the 6.12 BSP (Samsung-only). **Ported:** `rild/drb/` builds `dev_ril_bridge.ko` from the
  5.4 source; one change (module unload path, `0001-drb-module-unload.patch`). UAPI and the
  in-kernel API (`dev_ril_bridge_send_msg`, `register/unregister_dev_ril_bridge_event_notifier`)
  are byte-identical.
- In-kernel users on 5.4 (both only listen for `IPC_SYSTEM_CP_CHANNEL_INFO` 0x01 from rild):
  - `techpack/display/msm/samsung/ss_dsi_panel_common.c` (dynamic MIPI clock: moves the DSI
    clock away from the active RF band),
  - `techpack/camera/drivers/cam_sensor_module/cam_sensor/cam_sensor_mipi.c` (adaptive MIPI).
  Nobody in the A52s 5.4 tree calls `dev_ril_bridge_send_msg` (kernel -> rild), so rild only
  ever reads an empty queue here. The display and camera ports must be built with
  `-I conn/rild/drb/include -DCONFIG_DEV_RIL_BRIDGE_MODULE=1` and
  `KBUILD_EXTRA_SYMBOLS=conn/rild/drb/Module.symvers`, or they get the header's empty stubs.
- Gap: none in the driver. Load `dev_ril_bridge.ko` before rild starts (rild keeps the fd).
  Unverified: whether rild treats a missing `/dev/drb` as fatal.

## 2. rmnet `SIOCDEVPRIVATE` ioctls (`rmnet_ioctl_extended_s`)

- Who handles them: the IPA WAN netdev `rmnet_ipa0`, `ipa3_wwan_ioctl()` in
  `dataipa/drivers/platform/msm/ipa/ipa_v3/rmnet_ipa.c` (5.4: `.ndo_do_ioctl`). The rmnet
  virtual devices (`rmnet_data*`, datarmnet `rmnet_vnd.c`) have no private ioctls on either
  kernel. UAPI: `include/uapi/linux/msm_rmnet.h`.
- 6.12: since 5.15 the core no longer routes `SIOCDEVPRIVATE..+15` to `ndo_do_ioctl`; the donor
  (`data-kernel.lnx.5.0.r30`) sets **`.ndo_siocdevprivate = ipa3_wwan_ioctl`** as well, so the
  ioctls arrive. Built in `conn/data` (`ipanetm.ko`).
- Numbers: `RMNET_IOCTL_EXTENDED` 0x89FD and `RMNET_IOCTL_EXTENDED_V2` 0x89FE, the legacy
  0x89F2..0x89FC set and all extended sub-commands 0x0000..0x0022 are identical in both
  headers.
- Differences (diff of the two `msm_rmnet.h`):
  - The Samsung 5.4 header is *newer* than soc-repo 6.12's: it also has
    `RMNET_IOCTL_SET_ETH_VLAN` 0x23, `ADD_MUX_CHANNEL_v2` 0x24, `GET_EPID_ETH` 0x25,
    `GET_EP_PAIR_ETH` 0x26, `RMNET_IOCTL_FEAT_ETH_PDU`, `*_FORMAT_IP_ROUTE`,
    `RMNET_EGRESS_ETH_DATA`. But the 5.4 **driver** does not implement them (`rmnet_ipa.c` on
    5.4 handles 36 cases, none of the ETH ones), so rild cannot depend on them. No gap.
  - `struct rmnet_ioctl_extended_s`: 6.12 lacks the `ADD_MUX_CHANNEL_v2` union member
    (mux_id + name + 6-byte MAC, the largest one). The 6.12 struct is therefore the same size
    or smaller; the kernel copies fewer bytes in and out of rild's buffer. Safe direction.
  - The 6.12 donor driver handles **more** than 5.4: `RMNET_IOCTL_EXTENDED_V2`,
    `GET_EPID_LL`, `GET_EP_PAIR_LL`, `SET_{EGRESS,INGRESS}_DATA_FORMAT_V2`. `libsec-ril.so`
    has the string `ReadRmnetIoctlExtendedV2`: on 5.4 that call fails (unhandled ->
    `-EINVAL`) and rild evidently falls back to V1. **On 6.12 the V2 call will succeed**, so
    rild takes a path it never took on this phone. GAP/RISK R1: if data-format negotiation
    goes wrong on the first data call, make `ipa3_wwan_ioctl` return `-EINVAL` for
    `RMNET_IOCTL_EXTENDED_V2` (one-line patch in `conn/data`) to restore the 5.4 behaviour.
  - 32-bit callers: `ndo_siocdevprivate` gets the already-translated `data` pointer but the
    donor still reads `ifr->ifr_ifru.ifru_data`. Fine for a 64-bit caller:
    `/vendor/bin/hw/rild` is an aarch64 ELF and `libsec-ril.so` exists only in `lib64`
    (checked in the blob tree).
- `/dev/wwan_ioctl` (`rmnet_ipa_fd_ioctl.h`): `WAN_IOCTL_NOTIFY_NAT_MOVE_RES` moved 21 -> 22
  and `SET_DATA_QUOTA_WARNING` took 21. No process on the phone opens `/dev/wwan_ioctl`
  (no ipacm/netmgrd), so this does not matter here.

## 3. rmnet netlink (rtnetlink, protocol 0; rild via the open `librmnetctl.so`)

- `RTM_NEWLINK`/`RTM_SETLINK`/`RTM_DELLINK` with `IFLA_INFO_KIND "rmnet"` are handled by
  datarmnet `core/rmnet_config.c` (`rmnet_core.ko`), **not** by the upstream
  `drivers/net/ethernet/qualcomm/rmnet` (GKI 6.12 has `# CONFIG_RMNET is not set`, so there is
  no clash over the "rmnet" link kind).
- Attributes: `IFLA_RMNET_MUX_ID` 1, `IFLA_RMNET_FLAGS` 2 (uapi `if_link.h`, unchanged), then
  the downstream private ones in `rmnet_config.c`: `IFLA_RMNET_DFC_QOS` 3,
  `IFLA_RMNET_UL_AGG_PARAMS` 4 on both; 6.12 appends `IFLA_RMNET_UL_AGG_STATE_ID` 5 and
  `IFLA_RMNET_QUEUE` 6. Additive, existing numbers unchanged. `struct rmnet_egress_agg_params`
  (u16 agg_size, u8 agg_count, u8 agg_features, u32 agg_time) is identical in both
  `rmnet_config.h`; `IFLA_RMNET_DFC_QOS` carries a plain `struct tcmsg` (uapi, unchanged).
- Flag bits in `IFLA_RMNET_FLAGS`: the trap is `RMNET_FLAGS_{INGRESS,EGRESS}_MAP_CKSUMV5`.
  5.4 datarmnet: COALESCE bit 4, CKSUMV5 ingress bit 5, egress bit 6. Upstream 6.12
  `if_link.h` defines CKSUMV5 as bits 4/5. The 6.12 datarmnet donor keeps the downstream
  layout under private names (`RMNET_PRIV_FLAGS_INGRESS_MAP_CKSUMV5` BIT(5),
  `..._EGRESS_...` BIT(6), `RMNET_FLAGS_INGRESS_COALESCE` BIT(4)). So the bits rild sends
  mean the same. No gap, as long as upstream rmnet is never used instead.
- Generic netlink: family `RMNET_CORE` (`rmnet_genl.c`, cmds PID_BPS_REQ 1, PID_BOOST_REQ 2;
  6.12 adds TETHER_INFO_REQ 3) and the `rmnet_shs` family in datarmnet-ext. Users are
  `shsusrd`-type daemons, which this phone does not run. No gap.
- `rmnet_ctl.ko` (QMAP control over the IPA `rmnet_ctl` pipe; DT `qcom,rmnet-ctl-enable` is in
  the IPA node) and `rmnet_core.ko` built in `conn/data`.

## 4. QRTR

- soc-repo builds its own `net/qrtr` (`qrtr.ko` = `af_qrtr.o` + `ns.o`, `qrtr-smd.ko`), the
  same downstream implementation family as 5.4 (`CONFIG_QRTR_NODE_ID=1`). The in-kernel
  name server is part of `qrtr.ko` on both kernels, and the phone already runs the closed
  userspace `qrtr-ns -f` next to it on 5.4. So "kernel ns vs userspace ns" is **not a new
  conflict**: same arrangement as today. Unverified: what the closed `qrtr-ns` does when its
  control-port bind returns `-EADDRINUSE` (on 5.4 it obviously survives).
- `include/uapi/linux/qrtr.h`: the 5.4 header and soc-repo 6.12's are identical (one blank
  line differs), including the downstream `QRTR_TYPE_DEL_PROC` 13 and the `proc` control
  member that plain ACK lacks. soc-repo's `af_qrtr.c` implements DEL_PROC like 5.4.
- Load order: `qrtr.ko`, `qrtr-smd.ko` before the remoteprocs start (glink edge "IPCRTR").

## 5. Service locator / pd-mapper

- 6.12 has the in-kernel pd-mapper (`qcom_pd_mapper.ko`, started by remoteproc through
  `qcom_add_pdm_subdev`). Its table is keyed on the root compatible; `qcom,yupik` is **not**
  in it ("PDM: no support for the platform, userspace daemon might be required") while
  `qcom,sc7280` is. With the BSP's root compatible the kernel mapper stays inert and the
  vendor's closed `pd-mapper` (reads `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `cdspr.jsn`,
  modem `.jsn` from the firmware partitions) serves the locator service exactly as on 5.4.
- RULE for the a52sxq dts: do not add `"qcom,sc7280"` to the root compatible, or the kernel
  mapper registers the locator service too and the vendor daemon's registration collides.
- `pdr_interface.ko`, `qcom_pdr_msg.ko` (kernel PDR clients: audio, sensors) are built.

## 6. Remote processor face (pm-service, libmdmdetect, ssr_setup, lib*dsprpc)

- `/dev/subsys_*` + `/sys/bus/msm_subsys/devices/subsysN/*`: `conn/subsys_compat/` (see its
  README section in `../README.md`). Kept: names, subsysN numbering, the six sysfs files,
  `sysfs_notify` on `state`, open/close = get/put, class `subsys`, the 5.4 sysfs device paths
  that `genfs_contexts` labels.
- Changed: the char major is dynamic on both; minors keep the 5.4 numbers. `/dev/subsys_*`
  for ipa_fws / a660_zap / venus exist but do not load anything (kernel-internal on 5.4).
- Not provided: `/sys/bus/esoc/devices`, `/dev/esoc-0` (external modem; absent on 5.4 too),
  the `wakeup` sub-directories that genfs_contexts mentions, uevents of the old PIL
  platform devices.

## 7. rmt_storage

- `/dev/uio0` + `/sys/class/uio/uio0/{name,version,maps/map0/{addr,size}}`: soc-repo has the
  downstream driver (`drivers/uio/msm_sharedmem`, `msm_sharedmem.ko`) and yupik.dtsi 6.12 has
  the phone's node unchanged. No gap expected. Unverified: the hypervisor assign call
  (`qcom,vm-nav-path`) on Samsung's firmware.
- Block devices `modemst1`, `modemst2`, `fsg`, `fsc`: UFS, generic.
- **Do not load upstream `qcom_rmtfs_mem`** for the same region; nothing in the BSP DT asks for it.

## 8. Other contact points

| Interface | 6.12 state | Gap |
|---|---|---|
| `/dev/smd7`, `smd8`, `smd11`, `smdcntl8`, `at_mdm0`, `apr_apps2` | `glink_pkt.ko` in soc-repo, nodes in yupik.dtsi with the phone's channel names | none |
| `/dev/smd4` (channel `glink_bridge`, Samsung) | added in `a52sxq-conn.dtsi` | none |
| `/dev/ttyHS8` (SE5 UART, root:radio) | node written, disabled (consumer unknown; SE5 is the debug console in the base) | G4 |
| Modem firmware through the sysfs fallback | GKI: `FW_LOADER_USER_HELPER=y`, `..._FALLBACK` off | G1 |
| `/proc/sys/net/ipv4/tcp_netpm*`, `/proc/sys/net/core/support_dropdump`, `/proc/sys/net/optr` | Samsung net patches, not in GKI | G5 (optional per inventory) |
| TIPC | GKI `tipc.ko` (redwood's qcrild needed it). Samsung's rild: no evidence it uses TIPC | load it anyway |
| `/dev/rtc0`, efs/sec_efs/param partitions | generic | none |
| `/sys/class/power_supply/battery/voltage_now`, `/sys/class/lcd/panel/mipi_switch`, `/sys/class/nfc_sec/nfc_support` | other fragments (charging, display, NFC) | owners elsewhere |

## Gap list (ordered by how likely they are to stop the first data call)

- **G1 firmware loading.** 5.4 loaded `modem.mdt` through the sysfs fallback served by
  ueventd (`firmware_directories /vendor/firmware_mnt/image/ /vendor/firmware-modem/image/`).
  GKI 6.12 has no automatic fallback. Fix in init: `write
  /proc/sys/kernel/firmware_config/force_sysfs_fallback 1` (exists because
  `FW_LOADER_USER_HELPER=y`), before the first remoteproc boot. Unverified on hardware.
- **G2 IPA must be up before the modem goes online** (redwood: modem crashes in `enl2_dl`
  otherwise). Module order `gsim ipam ipanetm` + IPA firmware `yupik_ipa_fws` (firmware
  partition) before `/dev/subsys_modem` is opened; keep `default_related=1` in
  `subsys_compat` so a crash is recovered instead of a panic.
- **G3 `RMNET_IOCTL_EXTENDED_V2` now succeeds** (R1 above).
- **G4 `/dev/ttyHS8`**: exists on the phone (511,8 root:radio) but no vendor blob contains the
  string `ttyHS8` (paths.tsv), so it is probably unused or factory-only. Left disabled; if a
  consumer shows up, enable the node and move the console off SE5.
- **G5 Samsung procfs knobs**: `tcp_netpm`, `support_dropdump`, `optr` do not exist; rild is
  expected to tolerate ENOENT (inference from the inventory, unverified).
- **G6 `ipam.ko` depends on `usb_f_gsi`/`dwc3-msm`** (from the data build): tethering glue; if
  the port's USB stack is different, `ipam` does not load and there is no data path.
