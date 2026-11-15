Galaxy A52s 5G (SM-A528B, a52sxq) - Linux 6.12 kernel for LineageOS 24 - @NAME@, recovery zips
==========================================================================================

FOR ENTHUSIASTS ONLY. This replaces the phone's 5.4 kernel with Qualcomm's 6.12 BSP kernel
(GKI 6.12.81 + forward-ported Qualcomm/Samsung drivers). It runs the ROM and vendor blobs
unchanged. Source: https://github.com/a52sxq-kernel/galaxy-a52s-kernel (GPL-2.0).

These two zips do the same as the Odin package (a52s-k612-@NAME@.zip), from the phone's
recovery instead of a PC:
  a52s-k612-@NAME@-twrp.zip           installs the 6.12 kernel + its /vendor add-on
  a52s-lineage-stock-restore-twrp.zip  puts the stock LineageOS @STOCK@ kernel back

REQUIREMENTS
- SM-A528B with an unlocked bootloader.
- LineageOS 24.0 (Android 17), tested with lineage-24.0-@STOCK@-nightly. Other 24.x builds: the
  zip warns and continues. Other ROMs: the zip refuses to install.
- TWRP or LineageOS recovery for the A52s 5G. Both run these zips (TWRP: Install; LineageOS
  recovery: Apply update -> Apply from ADB, then `adb sideload <zip>`).
- Mobile network (modem) needs the bootloader-bit-5 firmware (A528BXXU5...). On older firmware
  the phone boots fine, but the TrustZone refuses the modem (no cellular).
- For the bootloop rescue only: a PC with Odin (or odin4 on Linux) and the Odin package.

INSTALL
1. Back up anything you care about.
2. Boot into recovery (power off, then Vol-up + Power with USB plugged in).
3. Flash a52s-k612-@NAME@-twrp.zip. It checks the phone and the ROM first and stops before
   writing anything if one check fails. It then
   - saves the current boot/vendor_boot/dtbo to /sdcard/a52s-k612-backup/<time>/ (needs
     600 MB free and readable internal storage, else it warns and goes on without a backup),
   - installs the add-on into /vendor (/vendor/lib/modules/6.12, the 6.12 Wi-Fi driver in
     /vendor/lib/modules/5.4-gki, /vendor/etc/init/a52sxq-k612.rc; the 5.4 kernel ignores all
     of it) and verifies every file,
   - writes boot, vendor_boot and dtbo and verifies them (sha256).
4. Reboot to system. The first boot takes ~25 s to the lock screen. `adb shell uname -r`
   shows 6.12.81-....
The recovery's log of the install is in /tmp/a52s-k612.log (and in the backup directory).

ROLL BACK (to the stock LineageOS @STOCK@ kernel)
- Recovery: flash a52s-lineage-stock-restore-twrp.zip, reboot. It writes the stock
  boot/vendor_boot/dtbo and removes /vendor/lib/modules/6.12 and
  /vendor/etc/init/a52sxq-k612.rc. /vendor/lib/modules/5.4-gki is left as it is (the 5.4
  kernel loads its Wi-Fi driver from /vendor/lib/modules, not from there). If you run a
  different LineageOS build, flash that build's own boot.img/vendor_boot.img/dtbo.img instead
  (TWRP: Install -> Install Image), or your ROM zip.
- The backup from step 3 holds your previous boot/vendor_boot/dtbo (TWRP: Install Image).
- If it bootloops: hold Vol-down + Power ~7 s to restart, then immediately Vol-down + Vol-up with
  USB plugged for Download mode, and flash a52s-lineage-20261028-stock-AP.tar from the Odin
  package (Odin AP slot). Or hold Vol-up + Power instead to reach recovery and flash the
  restore zip.

KNOWN ISSUES
- No VoLTE / VoWiFi (this LineageOS build has no IMS stack; same on the stock kernel).
- L3 cache clock idles at ~1.19 GHz (firmware-side vote not configured yet): battery impact
  still being measured. Battery/standby numbers are not final.
- The first Wi-Fi connection attempt sometimes fails; the retry works.
- Night light also tints the fingerprint circle.

SAFETY
- Never flash official firmware with a higher bootloader bit than your phone has (no way back).
- Never load firmware images from another phone or firmware version: TrustZone raises its
  anti-rollback counter and the old images stop working.
- The zips write only the boot, vendor_boot and dtbo partitions, the add-on files in /vendor and
  the backup directory on internal storage. They never format anything and never touch the
  microSD card.

FILES / CHECKSUMS: see SHA256SUMS next to the zips.
