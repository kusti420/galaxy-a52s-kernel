Galaxy A52s 5G (SM-A528B, a52sxq) - Linux 6.12 kernel @NAME@ (@KREL@), recovery zip
==========================================================================================

FOR ENTHUSIASTS ONLY. Qualcomm's 6.12 BSP kernel (GKI 6.12.81 + forward-ported Qualcomm/Samsung
drivers) for Android 17 ROMs for the SM-A528B that use the stock-derived a52sxq vendor (tested:
LineageOS 24, IchthysOS, K4_UN1CA One UI 9 port). Runs the ROM and vendor blobs unchanged.
The zip is not tied to a ROM: it installs over any Android ROM of this phone and prints a
warning when the ROM or its Android version is one the kernel was not tested with.
Source: https://github.com/a52sxq-kernel/galaxy-a52s-kernel (GPL-2.0, bin/a52boot included).

INSTALL
Flash a52s-k612-@NAME@-twrp.zip in TWRP or LineageOS recovery (Apply update -> adb sideload),
reboot. The zip works with your ROM's own images: it reads the current boot, vendor_boot and
dtbo partitions and replaces only the kernel, the first-stage modules, the device tree, the
vendor command line and the dtbo. Your ROM's ramdisks, Android version and security patch
level stay. Before writing it backs the current images up:
  internal storage readable (data decrypted): /sdcard/a52s-k612-backup/<time>/ (plain images)
  otherwise: /cache/a52s-k612-backup/<time>/ (*.img.a52pack, zero blocks left out)
No place for a backup -> nothing is written (a zip named *-nobackup.zip installs without one).
It then writes boot, vendor_boot and dtbo (all verified with sha256). /vendor is left alone
(everything is in vendor_boot); only the add-on of an earlier install is removed. Older builds
that carry a /vendor add-on install it first and accept LineageOS 24 based ROMs only.
It refuses, before writing anything: another phone model, partitions that do not hold your
ROM's boot/vendor_boot/dtbo images, AVB verification enabled in vbmeta, a vendor ramdisk
without a first-stage fstab, and (builds with inline encryption in the hardware engine) ROMs
that use hardware-wrapped keys. First boot ~25 s. Log: /tmp/a52s-k612.log.

ROLL BACK
Flash a52s-k612-restore-twrp.zip: it finds the backup of the images this kernel was installed
over, checks that it belongs to them, writes it back (verified) and removes the add-on:
your ROM's own kernel is back.
After a ROM update, flash this zip again (the ROM update brings its own kernel back).

Never flash firmware with a higher bootloader bit than your phone has. Never load firmware
images from another phone or firmware version.
