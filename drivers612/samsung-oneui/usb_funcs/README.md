# OneUI gadget functions missing on 6.12 (parity `usb.functions`)

Offline only. Nothing here was loaded on a phone. No new module was ported; this directory holds
the analysis and a QEMU smoke test of existing soc-repo dist modules.

Missing on 6.12 vs the port's 5.4: `audio_source.gs3 ccid.ccid cser.dun.0 cser.dun.2 cser.nmea.1
diag.diag diag.diag_mdm diag.diag_mdm2 qdss.qdss qdss.qdss_mdm`. The OneUI vendor
`init.qcom.usb.rc` `on boot` mkdirs all of them; a failed mkdir/symlink/write only logs an init
error, and the UDC is bound with the remaining functions.

## (a) Who uses them (vendor init.qcom.usb.rc; system init.usb*.rc link none of them)
Normal user modes (`sec_charging`, `mtp`, `mtp,adb`, `mtp,conn_gadget[,adb]`, `mtp,categories*`,
`ptp[,adb]`, `rndis[,adb]` (tethering), `midi[,adb]`, `ncm`, `accessory[,adb]`) use **none** of
them. They are linked only by:
- `audio_source.gs3`: `audio_source[,adb]`, `accessory,audio_source[,adb]` (AOA 2.0 audio).
  Nothing in the framework sets these modes. AOSP `UsbManager` does not allow audio_source in
  setCurrentFunctions (SETTABLE_FUNCTIONS = MTP|PTP|RNDIS|MIDI|NCM|UVC), Samsung `services.jar`
  has no `audio_source` string and does not read `f_audio_source/pcm`. Reachable only by a root
  `setprop sys.usb.config`.
- `cser.dun.0`: every `*serial_cdev*` mode: Qualcomm DM/factory compositions (`diag,serial_cdev*`,
  `rndis,serial_cdev*`, `diag,diag_mdm,qdss,...`). `cser.nmea.1`: only
  `diag,serial_cdev,serial_cdev_nmea,adb`. `cser.dun.2`: only the `...,serial_cdev_mdm,...` modes.
- `qdss.qdss` / `qdss.qdss_mdm` (`vendor.usb.qdss.inst.name=qdss_mdm` from init.target.rc): the
  `diag,...,qdss...` DM modes.
- `ccid.ccid`: `ccid[,adb]`, `ccid,diag[,adb]`, `diag,serial_cdev,rmnet,ccid[,adb]`,
  `diag,diag_mdm[,adb],ccid`.
- `diag.diag*`: **never linked**. `vendor/build.prop` sets `vendor.usb.diag.func.name=ffs`, so
  every DM mode links `ffs.diag`/`ffs.diag_mdm`/`ffs.diag_mdm2` (FunctionFS served by
  `/vendor/bin/diag-router`, `vendor.qti.diag.rc`). The rc only writes `diag.diag/serial` and
  `diag.diag/pid`: on 5.4 that fed f_diag's dload IMEM cookie (USB PID and serial for Qualcomm
  emergency download). Samsung uses its own upload mode, so the cookie is not used.
The DM modes are what the Samsung service menu offers (`USBSettings.apk`: "DM_QDSS",
"RMNET_DM_MODEM_ADPL_QDSS", `rndis,acm,diag`, `acm,diag[,rmnet][,adb]`, ...).

## (b) What exists for 6.12
GKI 6.12.81 (`bsp612/out/gki/.config`) has none of them built in: the CONFIGFS functions are
F_FS, ACM, SERIAL, NCM, ECM, EEM, MASS_STORAGE, UAC2, MIDI, HID, UVC, ANDROID F_ACC. The soc-repo
r70 builds three of the missing ones as dist modules that our builds do not load:

| function | dist module (bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734/...) | size | sha256 | depends |
|---|---|---|---|---|
| `cser` | `drivers/usb/gadget/function/usb_f_cdev.ko` | 80048 | `fd6b4b038b259c4d673dceddcbdc9593354b271d74fad5696fef6f7c6c253dd8` | (none) |
| `ccid` | `drivers/usb/gadget/function/usb_f_ccid.ko` | 60080 | `4c8e2baac2de0bd89bdc2d6dca0d00b21d0809ec27b671f39cdfab46a601d859` | (none) |
| `qdss` | `drivers/usb/gadget/function/usb_f_qdss.ko` | 67176 | `83df1e420201087b8c869eab256e68363492cd714883a331917380000352f12c` | qcom_ipc_logging, dwc3-msm |

(They are already stripped. Their vermagic is 6.12.81-4k-g8a69376da734.)
- `diag`: r70 has no kernel f_diag or diag char driver at all; diag is the userspace diag-router
  on GKI's f_fs. Nothing to load. `diag.diag*` stays missing; the only effect is the init errors
  on the mkdir and the pid/serial writes.
- `audio_source`: not in GKI 6.12 or soc-repo; 5.4 had it built in (`CONFIG_USB_CONFIGFS_F_AUDIO_SRC=y`).
  **Not ported**: it would need its own ALSA card for nothing, since no 6.12-era framework path uses
  it (see (a)). If a root setprop picks an `audio_source` mode, the symlink fails and the gadget
  binds with accessory (+adb) only.

## Load list (recommended: all three, harmless while unlinked)
First stage (`drivers612/realboot/out/rbich45/work/plan/first.load`), directly after line 185
`usb_f_ss_conn_gadget.ko`:
```
usb_f_cdev.ko
usb_f_ccid.ko
usb_f_qdss.ko
```
`usb_f_qdss` needs `qcom_ipc_logging` (line 22) and `dwc3-msm` (line 83). Its full transitive
modules.dep chain is dwc3-msm's, already loaded by then. Offline insmod simulation of rbich45 plus
these three (`drivers612/realboot/tools/loadsim.py`, real boot order, CRCs and duplicate exports):
**272 ok, 0 FAIL**. usb_f_qdss exports `usb_qdss_*`; no other loaded module exports them. The only
consumer, coresight-tmc's USB sink, is not loaded.

Effects when unused, i.e. normal modes:
- Module init only registers the function. The two DECLARE_USB_FUNCTION_INIT inits fail only on
  a duplicate name; qdss also creates a 10-page ipc_log context.
- The OneUI rc's `on boot` mkdirs then create:
  - cser: class `msm_usb_bridge`, `/dev/at_usb0` (dun.0), `/dev/at_usb1` (nmea.1),
    `/dev/at_usb2` (dun.2), one single-thread workqueue and a debugfs dir per port.
  - ccid: class `ccid_usb` with `/dev/ccid_ctrl` and `/dev/ccid_bulk`.
  - qdss: two channel entries.
- No USB descriptor change, because nothing is linked in normal modes. Same set as on 5.4.

Labels: vendor `ueventd.rc` has `/dev/at_usb0 0640 radio radio` only. No file_contexts entry for
`at_usb*` or `ccid_*` (default `device` label), and the vendor has no consumer: no port-bridge
binary, no ccid daemon. 5.4 was the same.

## What the DM (diag) modes expose
Qualcomm DIAG through `ffs.diag` + diag-router: QXDM/QPST modem/ADSP log and event streams, NV
item read/write, EFS file access, DM commands. Add qdss (hardware trace, only with a coresight
USB sink), cser DUN (AT port; nothing bridges it to the modem in this vendor) and gsi rmnet/dpl
(modem data and its packet log). These modes are off unless the service menu or root sets
`sys.usb.config`. Loading the three modules does not enable or expose any of that by itself; it
only lets those modes enumerate their full interface list as on 5.4. DM modes on 6.12 are
untested (diag-router itself not checked).

## QEMU smoke
`drivers612/samsung-oneui/usb_funcs/qemu-smoke/run.sh` (bsp612 GKI Image, QEMU virt):
- usb_f_cdev and usb_f_ccid load.
- mkdir `cser.dun.0`, `cser.nmea.1`, `cser.dun.2`, `ccid.ccid` all succeed; at_usb0..2 (505:0..2)
  and ccid_ctrl/ccid_bulk appear.
- symlink into b.1, rmdir (nodes gone) and rmmod all succeed.
- Phase 2: the whole 26-module qdss chain incl. dwc3-msm loads in QEMU; mkdir/symlink/rmdir of
  qdss.qdss and qdss.qdss_mdm, and rmmod, succeed.
- PASS, no WARN/BUG/oops.
Binding to a real UDC was not tested (QEMU has none).
