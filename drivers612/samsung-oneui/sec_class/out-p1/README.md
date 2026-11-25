# a52sxq_sec_class.ko out-p1: flip cover (hall) switch code per userspace (SPEC/05 P1-4, SPEC/01 gap 7)

Built 2026-11-24, QEMU smoke test PASS (96 checks), not on a phone. Never tested with a magnet on any kernel.

## What it does

- `aosp` (LineageOS / IchthysOS, or no `a52sxq.ko`): nothing changes. The gpio-keys input `hall` (build option
  `HALL=1`) reports `SW_LID` (0). Those ROMs do not load `a52sxq_sec_class.ko` at all (samsung-oneui set only).
- `samsung` (`a52sxq.userspace=samsung`, sysfs write, or the `mask_brightness` hint about 23 s after boot): the
  module registers a second input device named `hall` (phys `a52sxq_sec_class/flip`) with `EV_SW` code 0x10 and
  re-reports the hall state there; the `SW_LID` events of the gpio-keys device are filtered away from evdev
  (the handler became an input filter; it returns false, i.e. passes the event, in every other case).
  `hall_detect`, `hall_count` and the `hall=open|close` uevent are unchanged. Switching back to `aosp` at run
  time: the flip input reads open and goes silent, `SW_LID` passes again.
- Soft binding as the other consumers: `symbol_get()` of the switch (notifier registered from a delayed work,
  every 2 s, 45 tries; the getter at event time). No `depends` entry, load order free.
- Module parameter `flip_code` (0444, default 0x10; 0 = never register the flip input).

## Why 0x10, and why the input must be called `hall` (evidence)

- Stock 5.4 reports 0x15: `~/git/kernel_a52sxq_bone/drivers/input/misc/hall/hall_ic.c:59` (`SW_FLIP 0x15`,
  `:381` `input_report_switch(hall->input, hall->event, state)`, state 1 = close) with the a52sxq DT
  `event = <0x15>` (`arch/arm64/boot/dts/samsung/a52/a52sxq/a52sxq_eur_open_w00_r02.dts:599-601`, gpio 0x65
  active low). Its uapi header has `SW_MAX 0x3f` (`include/uapi/linux/input-event-codes.h:823`).
- GKI 6.12 has `SW_MAX 0x10` (`bsp612/kernel/include/uapi/linux/input-event-codes.h`), so 0x15 cannot be
  registered. Samsung's own driver does the same for kernels >= 5.10: `hall_ic.c:54-57` (`SW_FLIP 0x10`) and
  `:644-645` (DT 0x15 -> 0x10).
- The One UI framework of the port (9.3.173, S26U base) still works with 0x15:
  `~/git/MonsterROM/out/target/a52sxq/apktool/system/framework/services.jar/smali_classes2/com/android/server/sepunion/cover/CoverManagerServiceImpl.smali:1964-1967`
  (`getSwitchState(-1, -0x100, 0x15)`) and `.../smali/com/android/server/input/InputManagerService.smali:20884`
  (`notifySwitch`: mask `0x200000` = 1 << 0x15 -> `notifyCoverSwitchStateChanged`; mask 0x10000 is not tested).
- The translation kernel 0x10 -> framework 0x15 is done by the native input reader per device NAME:
  `~/git/MonsterROM/out/target/a52sxq/work_dir/system/system/usr/idc/hall.idc`:
  `switch.codes = 0x0a:0x1f,0x0b:0x1b,0x0c:0x1e,0x0f:0x13,0x10:0x15` (`SwitchInputMapper` in
  `libinputflinger.so`, strings "switch code map", "ModifySwitchCodes"). Hence the flip input is named `hall`
  (also the 5.4 name, `hall_ic.c:499-500`). The parsing of `switch.codes` was not disassembled: that the idc is
  applied to our device is inferred, step 3 below proves or refutes it without hands.
- `SW_LID` (mask 1) on this framework is the plain AOSP lid path (`InputManagerCallback.notifyLidSwitchChanged`,
  `lid_behavior` default 0 = nothing); it never reaches the cover manager.

## Build / ABI

- Source: `../a52sxq_sec_class.c`, `../Kbuild` (+ include path of the switch header). Built from HEAD + this
  change only (a sibling copy), `drivers612/samsung-oneui/build.sh` method, vermagic 6.12.81-4k-g8a69376da734.
- Exports: none before, none now (`Module.symvers` 0 bytes both). `depends` unchanged: `sec_core`.
- Imports 61 -> 74, all 61 old ones with identical CRCs, 13 new (all vmlinux GKI): `__symbol_get`,
  `__symbol_put`, `input_allocate_device`, `input_register_device`, `input_unregister_device`,
  `input_free_device`, `input_set_capability`, `input_event`, `queue_delayed_work_on`,
  `cancel_delayed_work_sync`, `delayed_work_timer_fn`, `param_ops_uint`, `_printk`.
- Shipped module (s99t..s99ou9): sha256 60dd1835...; HEAD rebuilt in the sibling directory: 65a66284... (differs
  only by the embedded source path string, imports identical); this build: see `SHA256SUMS`. Swap with
  `rd-swap-ko.py`; needs `a52sxq.ko` in the ramdisk (flavor set, sha 486acb4f) to do anything.
- QEMU: `../qemu-smoke/run.sh` (fakehall + a52sxq.ko): no switch / aosp = one hall input; samsung = second
  input with sw capability 10000, evdev of the SW_LID input gets nothing, the flip input gets
  `EV_SW 0x10 1` then `0`; back to aosp = SW_LID events pass; rmmod clean; 0 WARN.

## Test on a phone

Needs a build with `HALL=1` (the gpio-keys node) + this module + `a52sxq.ko`.

### No hands (One UI)

1. `cat /sys/module/a52sxq/parameters/userspace` -> `samsung`.
   `dmesg | grep a52sxq_hall` -> `bound to the userspace switch (try N)` and
   `flip switch 0x10 registered (userspace samsung)`.
2. `grep -A9 'N: Name="hall"' /proc/bus/input/devices | grep -E 'Name|Phys|B: SW'` -> two inputs:
   `B: SW=1` (gpio-keys) and `P: Phys=a52sxq_sec_class/flip` with `B: SW=10000`.
   `cat /sys/class/sec/hall_ic/hall_detect` -> `OPEN`.
3. The idc translation: `dumpsys input | grep -B3 -A25 'a52sxq_sec_class/flip'` -> the device has
   `ConfigurationFile: /system/usr/idc/hall.idc`, class SWITCH; `logcat -d | grep -iE 'switch code map|ModifySwitchCodes'`
   -> `0x10 -> 0x15`. If hall.idc is NOT picked up, the flip code reaches Java as bit 0x10000 and is ignored:
   report it, do not go on to the magnet test.
4. Control: `echo aosp > /sys/module/a52sxq/parameters/userspace` -> still two inputs (the flip one stays
   registered, silent); set back to `samsung`.

### No hands (LineageOS / IchthysOS)

5. `ls /sys/class/sec/hall_ic 2>&1` -> absent (module not in those ramdisks);
   `grep -c 'N: Name="hall"' /proc/bus/input/devices` -> 1 with `HALL=1`, `B: SW=1`. Unchanged from rb108.

### Needs hands: a magnet or a Samsung flip cover at the hall position (upper part of the back)

6. One UI: `getevent -lt` in one shell, then close / open the cover 5 times.
   Expected per close: on the flip input `EV_SW 0010 00000001` (getevent has no name for 0x10 on older tools:
   `SW_MACHINE_COVER` or `0010`), per open `00000000`; NOTHING on the gpio-keys `hall` input.
   `cat /sys/class/sec/hall_ic/hall_detect` -> `CLOSE` while closed; `hall_count` -> `"FCNT":"10"`.
   `logcat | grep -iE 'CoverManager|notifyCoverSwitchStateChanged'` shows the state change; with a flip
   cover the screen goes off on close and on at open (a bare magnet may only log: the cover type is unknown).
   Same steps on the 5.4 kernel of the same phone for comparison (there: code 0x15 on input `hall`).
7. LineageOS / IchthysOS: `getevent -lt` -> `EV_SW SW_LID 00000001` / `00000000` on `hall`, as before.

Known limits: the gpio-keys input still advertises `SW_LID` under One UI and its EVIOCGSW state bit is set
while the cover is closed (only the events are filtered), so a `getSwitchState(SW_LID)` poll sees "lid
closed"; with `lid_behavior` 0 that does nothing. No hall notifier (touch cover mode, grip recalibration).
