# Samsung USB gadget functions for the OneUI 9 port (6.12 line)

Built, offline-checked, **never loaded on a phone**.

## What
Two configfs USB function modules, so the stock OneUI vendor rc
(`vendor/etc/init/hw/init.qcom.usb.rc`, `on boot`) can run
`mkdir /config/usb_gadget/g1/functions/{ss_mon.mtp,ss_mon.ptp,conn_gadget.0}` and link them into
`configs/b.1` next to `ffs.mtp`/`ffs.ptp`, `ffs.adb` and `acm.0`:

| module (S26U vendor_dlkm name) | configfs function | node |
|---|---|---|
| `out/usb_f_ss_mon_gadget.ko` | `ss_mon` | `/dev/usb_mtp_gadget` (misc) + `/sys/class/misc/usb_mtp_gadget/guid` |
| `out/usb_f_ss_conn_gadget.ko` | `conn_gadget` | `/dev/android_ssusbcon` (misc) + `/sys/class/misc/android_ssusbcon/bInterfaceProtocol` |

Both depend only on GKI vmlinux exports (`modinfo -F depends` empty; every `llvm-nm -u` symbol is a
vmlinux entry in `bsp612/out/lahaina/Module.symvers`; libcomposite/configfs/f_fs are built in:
`CONFIG_USB_LIBCOMPOSITE=y CONFIG_USB_CONFIGFS=y CONFIG_USB_F_FS=y`). They export nothing.
Module init never fails (open-coded `DECLARE_USB_FUNCTION_INIT`: a `usb_function_register()` error
is only logged) and never blocks.

Build: `drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/usb_gadget` (0 warnings).

## Sources
- `f_ss_mon_gadget.c`: S26 6.12 `soc-repo/drivers/usb/gadget/function/f_ss_mon_gadget.c`
  (+ `include/linux/usb/f_ss_mon_gadget.h`), checked against the A52s 5.4 copy
  (`$ANDROID_TREE/kernel/samsung/sm7325/drivers/usb/gadget/function/`).
- `f_conn_gadget.c`, `f_conn_gadget.ioctl.h`: S26 6.12 copy (ioctl header identical to 5.4).

## Where Samsung hooks the core, and what is lost
The S26 GKI `common/` tree has no ss_mon/conn_gadget hooks. The hooks are in Samsung's
**soc-repo** `dwc3-msm-ops.c` (kretprobes) and `phy-msm-m31-eusb2.c`, which our bsp612 dwc3-msm does
not have:
- kretprobe on `configfs_composite_setup()` feeds EVERY ep0 request to `ss_mon->setup()`;
- `vbus_session_notify()` from the `dwc3_gadget_run_stop` kretprobe, `usb_reset_notify()` from
  `dwc3_gadget_reset_interrupt`, `make_suspend_current_event()` from the eUSB2 PHY.

On the 6.12 line ss_mon is a plain function. Kept:
- the Samsung MTP AVD class descriptor (0x24/0x80, DAU MTU) in the config descriptor;
- vendor request 0xA3 (PC GUID, OUT) via `req_match` -> stock `composite_setup()` routes it ->
  `/sys/class/misc/usb_mtp_gadget/guid` (40 bytes, cleared on disable);
- `/dev/usb_mtp_gadget`: open/release with single-open lock, nothing else (same as 5.4 and S26:
  no read/write/ioctl). No userspace in the port references it except init `chmod/chown`
  (MtpServer uses `/dev/usb-ffs/mtp`).

Dropped (no provider on this line, or only reachable through the dwc3 kretprobes):
- usb_notify layer: `store_usblog_notify` USB_STATE/usb_mode strings, `send_otg_notify`
  USBD_{CONFIGURED,UNCONFIGURED,SUSPENDED}, `send_usb_err_uevent(USB_ERR_ABNORMAL_RESET)`
  (AOA "3 resets within 1 s" detection);
- typec manager `set_usb_enumeration_state()` / `set_usb_enable_state()`;
- BC1.2 vbus current work: `POWER_SUPPLY_EXT_PROP_USB_CONFIGURE` to sec_battery "battery"
  (100/500/900 mA on unconfigured/HS/SS, suspended). Charging current on configure therefore stays
  with whatever the charger stack decides itself;
- AOA accessory-string / ACCESSORY_START accounting and GET_DESCRIPTOR/SET_CONFIGURATION logging
  (only reached through the kretprobe);
- `vbus_session_notify`, `usb_reset_notify`, `make_suspend_current_event` are neither implemented
  nor exported (a duplicate export by another module would fail the insmod).
- 0xA3 caveat: if the PC sends it with recipient = interface and wIndex = the MTP interface, f_fs
  claims it first (stock composite order, same as stock OneUI without the kretprobe).

Changed vs S26 (bugs): misc device refcounted across ss_mon.mtp/ss_mon.ptp (S26 deregistered it when
the first instance was removed); `guid` created via `miscdevice.groups` (before the uevent);
descriptors via `usb_assign_descriptors`/`usb_free_all_descriptors` (S26 leaked a copy per bind);
`guid_store` returns `size`. Node lifetime follows S26 (created at mkdir); 5.4 created it at bind
and removed it at unbind.

conn_gadget: bulk IN/OUT interface (class 0xFF/0x40/proto 3), `/dev/android_ssusbcon`
read/write/poll/ioctl/flush unchanged. ioctl ABI verified against the port's
`/system/bin/ss_conn_daemon2` (64-bit): it issues 0x80087300 (SUPPORT_LIST), 0x80047301
(BIND_WAIT_NOTIFY), 0x80047302 (BIND_GET_STATUS) and reads the status as 8 bytes, which is what
the driver copies (kept). Lost: `/sys/class/android_usb/android0/f_conn_gadget/` (GKI 6.12 has no
`android_create_function_device()`; S26's `#else` path returned an uninitialised value). The daemon
reads `.../f_conn_gadget/{usb_buffer_size,in_max_packet_size,out_max_packet_size}`, which the A52s
5.4 kernel never built either (`CONFIG_F_CONN_GADGET_DEBUGFS` not set) and logs "unknown" ->
defaults. Fixed: a second `conn_gadget.N` returns -EBUSY (S26 clobbered the live device pointer),
the embedded usb_function is handed out once at a time, internal helpers static.

## Load order
Any time before init's `on boot` (the mkdir trigger); no module dependencies. In the first stage
append both after line ~182 of `drivers612/realboot/out/rbich43/work/plan/first.load` (dwc3-msm at
83 is not required by them, the UDC is only needed at the `UDC` write). Loading them under
LineageOS/IchthysOS is inert (nothing mkdirs the functions).

## SELinux / ueventd (OneUI work_dir)
- `vendor/etc/selinux/vendor_file_contexts`:
  `/dev/usb_mtp_gadget.*  u:object_r:mtp_device:s0` (l.779),
  `/dev/android_ssusbcon(/.*)?  u:object_r:usb_device:s0` (l.874),
  `/sys/devices/virtual/misc/usb_mtp_gadget(/.*)?  u:object_r:sysfs_usb:s0` (l.1223).
- `vendor_sepolicy.cil`: `(genfscon sysfs /devices/virtual/misc/usb_mtp_gadget/ (u object_r sysfs_usb ...))`;
  `allow ss_conn_daemon_30_0 usb_device_30_0 (chr_file (ioctl read write open))`;
  `allow {priv_app,system_app}_30_0 mtp_device_30_0 (chr_file ...)`.
  `/sys/devices/virtual/misc/android_ssusbcon/bInterfaceProtocol` has no label (default sysfs; no
  userspace uses it).
- `vendor/ueventd.rc` l.72-73: `/dev/usb_mtp_gadget 0660 system mtp`,
  `/dev/android_ssusbcon 0660 system system`. init.rc (system) post-fs-data and init.qcom.usb.rc
  repeat the chown/chmod. No ueventd.rc in `vendor/etc/`.

## Test recipe (coordinator, as root)
Non-disruptive (does not touch the UDC or b.1; adb keeps working):
```
insmod /path/usb_f_ss_mon_gadget.ko; insmod /path/usb_f_ss_conn_gadget.ko
dmesg | tail
mkdir /config/usb_gadget/g1/functions/ss_mon.mtp
ls -lZ /dev/usb_mtp_gadget; cat /sys/class/misc/usb_mtp_gadget/guid | xxd | head -2
mkdir /config/usb_gadget/g1/functions/conn_gadget.0
ls -lZ /dev/android_ssusbcon
rmdir /config/usb_gadget/g1/functions/conn_gadget.0
rmdir /config/usb_gadget/g1/functions/ss_mon.mtp
ls /dev/usb_mtp_gadget /dev/android_ssusbcon   # both gone
```
(If the ROM already created these instances, skip the mkdir/rmdir and only `ls -lZ`.)

**DISRUPTIVE (re-binds the only UDC: adb drops for a few seconds; have a way back, e.g. a
`(sleep 120; reboot) &` dead-man, and never do it on a phone whose only access is adb):**
```
cd /config/usb_gadget/g1
echo none > UDC
ln -s functions/ss_mon.mtp configs/b.1/f9     # next to ffs.mtp/ffs.adb already linked
echo a600000.dwc3 > UDC
dmesg | grep -i 'ss_mon\|conn_gadget'          # "ss_mon.mtp bind"
# on the PC: lsusb -v -d 04e8: shows the 0x24/0x80 class descriptor
# undo: echo none > UDC; rm configs/b.1/f9; echo a600000.dwc3 > UDC
```
For conn_gadget the same with `functions/conn_gadget.0` (adds a bulk interface; userspace
`ss_conn_daemon2` / `sys.usb.config=mtp,conn_gadget,adb` exercises it).
