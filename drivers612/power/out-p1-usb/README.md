# usb_notify_layer.ko out-p1-usb: lock-screen USB restriction behind the a52sxq switch (SPEC/05 P1-2)

Built 2026-11-24, QEMU load test only (module loads, unloads, 0 unresolved symbols, 0 WARN). The gated paths
were NOT exercised (no otg_notify registrant in QEMU). Not on a phone. Read "Risks" before a first boot.

## What changed

- Stock 5.4 compiles Samsung's "block USB connections while locked" in; LineageOS 5.4 sets
  `CONFIG_DISABLE_LOCKSCREEN_USB_RESTRICTION` and `drivers612/power/Kbuild` copied that (still does, for every
  other power module).
- In the three sources of `usb_notify_layer.ko` (`src/usb/notify/usb_notify.c`, `usb_notify_sysfs.c`,
  `dock_notify.c`) all 33 `#ifndef CONFIG_DISABLE_LOCKSCREEN_USB_RESTRICTION` blocks are now compiled in and
  selected at run time by `a52_usb_lockrestrict()` (`src/usb/notify/a52_usb_lockrestrict.h`) =
  `a52sxq_userspace_is_samsung()`, soft binding (`symbol_get`), evaluated at every site.
  The conversion is mechanical: statement blocks became `if (a52_usb_lockrestrict()) { stock } else { LineageOS }`;
  the two `set_notify_lock_state()` variants became `_restrict` / `_plain` behind a dispatcher; helper functions
  and locals are compiled in unconditionally. With the switch on `aosp` (or without `a52sxq.ko`) every site runs
  the statements the LineageOS configuration compiled. What differs under `aosp`: `init_waitqueue_head(&u_notify->init_delay)`
  and `mutex_init(&udev->lockscreen_enabled_lock)` now always run, three unused locals, and the kernel log
  prefix of the lock line (`set_notify_lock_state_plain` instead of `set_notify_lock_state`).
- Under `samsung` also (as stock): `usb_sl` accepts `0/1/2` besides the mode names (bone commit 5d4ab0b2b),
  `allowlist_for_mdm` accepts the `VPID:` list, `NOTIFY_EVENT_PD_USB_COMM_CAPABLE` is recorded.
- What `samsung` turns on: `usb_sl` state machine (`SUNNY_WORK_MODE` / `CLOUDY_WORK_MODE` / `RAINY_RESTRICT_MODE`,
  reads `SKY_DEFAULT` until the first write), host mode blocked from boot until the framework's first `usb_sl`
  write, first `RAINY` after boot blocks host + device, uevents on the usb_notify device
  `TYPE=usbrestrict STATE=ADD WORDS=timesecurerestrict|securerelease`, USB devices plugged while restricted are
  de-authorised unless on the allowlist.

## Not covered (stays the LineageOS variant on every ROM)

- `pdic_sm5714.ko` (`sm5714_pd.c`, `sm5714_policy.c`, `sm5714_typec.c`: alternate mode off while restricted, and the
  sender of `NOTIFY_EVENT_PD_USB_COMM_CAPABLE`) and `usb_typec_manager.ko` (3 sites: skip the enumeration check
  while the client is blocked). `struct sm5714_usbpd_data` gains a member with the option, so that part is a
  separate change. Effect: a charge-only PD charger plugged while locked can raise "USB restricted".
- The 5.4 dwc3-msm / USB core hooks (SPEC/03 U17): on 6.12 only the usb_notify side exists
  (`usb_check_allowlist_for_lockscreen_enabled_id` is called from `dock_notify.c`, not from the hub driver).
- Full boot-time behaviour needs the switch to be `samsung` BEFORE `usb_notify_layer.ko` initialises
  (`a52sxq.userspace=samsung` on the command line and `a52sxq.ko` earlier in `modules.load`). With the late
  `mask_brightness` hint the restriction works from the first `usb_sl` write on, without the boot-time host block.
- Switching the flavour at run time while a restriction is active is not handled (states are kept as they are).

## Build / ABI

- Built from a copy of the tree (HEAD + this change; `drivers612/power` itself and the shared bsp612 output are
  untouched), same make line as `drivers612/power/build.sh`, 0 errors, 0 warnings; `llvm-strip --strip-debug` +
  BTF sections removed. vermagic 6.12.81-4k-g8a69376da734. The .ko is not tracked (`*.ko` ignored): `SHA256SUMS`.
- `Module.symvers` of the whole power stack: the 313 existing exports are identical (name, CRC, module); 2 new
  exports of usb_notify_layer: `check_usb_restrict_lock_state` 0x498242df,
  `usb_check_allowlist_for_lockscreen_enabled_id` 0x82306a14 (nobody imports them).
- `usb_notify_layer.ko` vs the shipped one (rb108 / rbou9 ramdisks, sha c5d6a6b2...): exports 63 -> 65,
  imports 107 -> 111 (107 identical CRCs; new: `__symbol_get`, `device_attach`, `kstrtoull`, `schedule`),
  `depends` empty before and after. No other module has to be rebuilt; swap this one file. Needs `a52sxq.ko` in the
  ramdisk to ever switch on.
- Byte identity of the unchanged base with the shipped file was not shown (the copy's path is embedded).

## Risks (why this must first boot on a test phone with a rollback staged)

- The file is in the USB debugging path of every ROM. The aosp side is unchanged by construction, not by a run.
- Under `samsung` with a secure lock and Settings "Block USB connections while locked" on, USB data INCLUDING the
  debug bridge is blocked while locked. That is the feature (same on 5.4), but it makes the test phone unreachable
  over USB while locked. OTHERPHONE has no passcode: the framework is not expected to send RAINY there.

## Test on a phone (all shell lines run on the phone, as root where a write is involved)

### No hands, LineageOS / IchthysOS (aosp)

1. `cat /sys/module/a52sxq/parameters/userspace` -> `aosp`. The debug shell answering at all = device mode works.
2. `cat /sys/class/usb_notify/usb_control/usb_sl` -> `SUNNY_WORK_MODE`; `cat .../disable` -> same text as on rb108.
3. `dmesg | grep -cE 'usb_notify: .*(after wait|first_restrict|timesecurerestrict)'` -> 0.
4. `verify-realboot.sh` 36/0 as rb108. `echo 2 > /sys/class/usb_notify/usb_control/usb_sl` -> write error
   (integers refused under aosp, as before). `echo RAINY_RESTRICT_MODE > .../usb_sl` -> stored, the shell stays
   up, `dmesg | tail` shows `set_notify_lock_state_plain lock`; write `SUNNY_WORK_MODE` back.

### No hands, One UI (samsung on the command line)

5. `cat /sys/module/a52sxq/parameters/userspace /sys/module/a52sxq/parameters/source` -> `samsung` / `cmdline`.
6. `dmesg | grep -E 'usb_notify: (reserve_state_check|usb_sl_store|set_notify_lock_state)'` ->
   `reserve_state_check after wait`, then `usb_sl_store before secure_lock = init first_restrict = ...` and
   `set_notify_lock_state_restrict lock_state=N` from system_server's first write (the `init` word and the
   `_restrict` name prove the stock path). `cat .../usb_sl` -> a mode name, not `SKY_DEFAULT`, once the framework
   wrote; the shell is still up while unlocked.
7. `logcat -d | grep -iE 'UsbHostRestrictor|ScrLck'` -> no "Failed to write" line.
8. `echo 1 > .../usb_sl; cat .../usb_sl` -> `CLOUDY_WORK_MODE` (integer accepted); write `SUNNY_WORK_MODE` back.
9. Compare steps 6 to 8 with the same phone on its 5.4 kernel.

### Needs hands

One UI on the broken screen phone, a PIN set for the test, Settings > Security > Auto Blocker / "Block USB
connections while locked" on. USB debugging drops by design while restricted: watch over the network transport,
or with a detached recorder on the phone (`dmesg -w > /data/local/tmp/usb.log`, started through `su -c setsid`).

10. Lock the screen, wait for the framework's timer (`usb_sl` -> `RAINY_RESTRICT_MODE`), then plug a USB stick
    with an OTG adapter: no mount, notification "USB connection blocked", log
    `send_usb_restrict_uevent: WORDS=timesecurerestrict`. Unlock: `WORDS=securerelease`, re-plug -> mounts.
11. Locked, plug into a PC: no MTP / debug enumeration, same uevent; unlock -> enumerates.
12. Locked, plug a plain charger and a PD charger: charging starts; note whether "USB restricted" shows for the
    PD charger (expected yes until pdic_sm5714 is done, see "Not covered").
13. Reboot while locked with a stick plugged: host stays off until the first unlock (stock: first_restrict).
14. LineageOS / IchthysOS: OTG stick and PC connection while locked work exactly as before.
