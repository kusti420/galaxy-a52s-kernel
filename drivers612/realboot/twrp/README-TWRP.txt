Galaxy A52s 5G (SM-A528B, a52sxq) - Linux 6.12 kernel @NAME@, recovery zip (LineageOS 24)
==========================================================================================

FOR ENTHUSIASTS ONLY. Qualcomm's 6.12 BSP kernel (GKI 6.12.81 + forward-ported Qualcomm/Samsung
drivers). Runs the ROM and vendor blobs unchanged. This older zip format carries prebuilt
images and a /vendor add-on made for LineageOS 24, so it installs on LineageOS 24 only; the
newer kernel-only zips install over any ROM of this phone.
Source: https://github.com/a52sxq-kernel/galaxy-a52s-kernel (GPL-2.0).

INSTALL
Flash a52s-k612-@NAME@-twrp.zip in TWRP or LineageOS recovery (Apply update -> adb sideload),
reboot. The zip checks the phone and ROM first, saves your current boot/vendor_boot/dtbo to
/sdcard/a52s-k612-backup/<time>/ when internal storage is readable, installs the 6.12 add-on into
/vendor and writes boot, vendor_boot and dtbo (all verified). First boot ~25 s.
Install log: /tmp/a52s-k612.log.

ROLL BACK
Flash your ROM's own boot.img, vendor_boot.img and dtbo.img (or the backup above).

Never flash firmware with a higher bootloader bit than your phone has. Never load firmware
images from another phone or firmware version.
