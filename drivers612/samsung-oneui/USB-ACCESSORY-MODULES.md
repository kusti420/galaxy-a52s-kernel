# USB accessories on the OneUI 9 6.12 builds: what exists, what is missing, proposed optional set (2026-11-22, offline)

Sources: GKI config bsp612/out/gki/.config (= out/lahaina/.config for these symbols), bsp612/out/dist/lib/modules/
6.12.81-4k-g8a69376da734 (383 .ko, modules.builtin 641), load list drivers612/realboot/out/rbou5d/first-stage.modules.load
(279). Sizes = stripped (debug + BTF removed, as build-realboot does). Nothing here ran on a phone.

## 1. Already in the GKI Image (built in): nothing to do
usb-storage, uas, usbhid, hid-generic, hid-apple, hid-microsoft, hid-logitech (+dj, hidpp), hid-sony, hid-playstation,
hid-nintendo, hid-steam, hid-multitouch, hid-magicmouse, hid-wacom, hid-elecom, hid-roccat, hid-uclogic, hid-wiimote,
xpad (JOYSTICK_XPAD=y), uvcvideo, snd-usb-audio, exfat, uhid (Bluetooth HID through the Android stack), USB_CONFIGFS_F_HID.
So gamepads (Xbox, DualShock/DualSense, Switch Pro), mice, standard keyboards, USB sticks, webcams work without modules.
`INPUT_JOYDEV` is off (no /dev/input/js*): Android uses evdev, not a loss.

## 2. Built as GKI modules in dist but NOT in the ramdisk (load=0 in rbou5d)
| module | bytes | depends | what |
|---|---|---|---|
| mii | 20376 | - | MII helper |
| usbnet | 80184 | mii | USB network core |
| cdc_ether | 33160 | usbnet | CDC ECM adapters, many docks |
| cdc_ncm | 62480 | usbnet, cdc_ether | CDC NCM (newer docks, phone tethering as NCM) |
| r8152 | 234992 | mii | Realtek RTL8152/8153/8156 = most USB-C Ethernet adapters and docks |
| ax88179_178a | 73480 | usbnet, mii | ASIX gigabit |
| asix | 96032 | usbnet, mii (phylib built in) | ASIX AX8817x/AX88772 100 Mbit |
| aqc111 | 44728 | usbnet | Aquantia 5G |
| rtl8150 | 37864 | - | old Realtek 10/100 |
| r8153_ecm | 15528 | cdc_ether, usbnet, r8152 | RTL8153 in ECM mode |
| cdc_eem | 16544 | usbnet | CDC EEM |
| cdc-acm | 77616 | - | USB serial modems / Arduino |
| usbserial, ftdi_sio | 84488, 157976 | usbserial | FTDI serial |
| hidp, rfcomm, bluetooth | 64320, 127664, 1165912 | bluetooth | kernel BT stack: NOT needed (Android BT is userspace) |
5.4 had all of the Ethernet ones built in (ONEUI9-KERNEL-INVENTORY.md row 9).

## 3. Not built at all
- `hid-samsung` (HID_SAMSUNG=n in GKI): Samsung keyboards/book covers work as plain keyboards through hid-generic but
  lose the Samsung keys (apps, DeX, language, brightness rows). NOW BUILT as an external module from the unmodified
  6.12 source: drivers612/samsung-oneui/hid_samsung/ (hid-samsung.c + hid-ids.h copied from bsp612/kernel/drivers/hid),
  out/hid-samsung.ko 26560 bytes, 8 imports all GKI exports (no KMI change), 7 HID aliases.
- Not built and not attempted: `rndis_host` (USB tethering FROM another Android phone), `cdc_mbim`/`qmi_wwan`
  (LTE sticks), `smsc75xx/95xx`, `lan78xx` (config says m but no .ko in dist), `cp210x/pl2303/ch341` serial, `usblp`,
  `joydev`, `hid-nvidia-shield`. rndis_host is the one a user may notice; it could be built like hid-samsung (untested).

## 4. Can they load on demand? No.
- OneUI's fstab (testdev-PHONE1/oneui9-9.3.160/fstab.qcom) has system/vendor/product/odm as EROFS logical
  partitions and NO vendor_dlkm / system_dlkm. /vendor/lib/modules holds the 5.4 set (98 entries,
  vendor_modules_ls.txt) and is read-only, and the ROM is one image for both kernels.
- The vendor ramdisk's /lib/modules is gone after first stage (switch_root), and Android has no kernel modprobe helper
  unless ueventd.rc sets `modalias_handling enabled` (not checked in this ROM's ueventd.rc: UNVERIFIED; even then it
  needs a readable module dir for 6.12).
- So: either (a) in the vendor_boot ramdisk and on modules.load = loaded at every boot (what all 279 do), or
  (b) ROM-side: the ROM ships a 6.12 module dir (e.g. /vendor/lib/modules/6.12/) and an init rc that insmods it in 6.x
  mode. (b) couples the ROM image to one kernel build (vermagic + CRCs), so (a) is the proposal.
- Cost of (a): RAM for the loaded modules (about the file size, < 1 MiB for the set below) and ramdisk bytes;
  vendor ramdisk today 26180800 bytes of a 100663296-byte vendor_boot (rbou5d REPORT.txt:124).

## 5. Proposed optional set (build option name proposal: `USBACC=1`, default off; NOT implemented, script not touched)
Order (dependency order, append after the last USB stage with the existing `xmod` helper, build-realboot.sh:496):
`mii usbnet cdc_ether cdc_ncm r8152 ax88179_178a asix` = the 7 from the inventory, 600704 bytes;
`+ aqc111 rtl8150 r8153_ecm cdc_eem` = 715368 bytes; `+ hid-samsung` (samsung-oneui/hid_samsung/out) = 741928 bytes, 12 modules.
Left out on purpose: cdc-acm/ftdi (no OneUI consumer without an app), kernel bluetooth.
ROM side to check when it runs on a phone (UNVERIFIED): OneUI's EthernetService brings up `eth0` (config_ethernet_iface_regex),
netd/ethernet SELinux for the usbnet netdev, Samsung keyboard special keys reaching the framework (key layout files
for vendor 04e8 exist in /system/usr/keylayout?), DeX is not a target on A52s.

## 6. QEMU test (drivers612/samsung-oneui/usb_accessory/qemu-test/run.sh): PASS 27/27
bsp612 GKI Image on QEMU virt with `-device qemu-xhci -device usb-net -device usb-kbd`: all 12 modules insmod rc=0,
QEMU's USB network device (0525:a4a2) is bound by cdc_ether, the interface comes up and pings the user-net gateway,
the keyboard binds built-in usbhid, `/sys/bus/hid/drivers/samsung` registered, 8 rmmods rc=0, no WARN/BUG.
Not covered: the real adapters' drivers binding hardware (r8152, ax88179, asix: insmod only), dwc3 host mode on the
phone, hid-samsung with a real Samsung keyboard.
