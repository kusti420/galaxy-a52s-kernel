# input_booster.ko: Samsung SEC input booster for the a52sxq 6.12 kernel line

This is a port of the Galaxy A52s 5.4 driver. It exposes the same `/sys/class/input_booster` tree
as 5.4 and gives a real CPU boost on every touch and key press. It has been tested offline in QEMU
only (`qemu-test/run.sh`: PASS). **It has never been loaded on a phone.**

Build: `EXTRA_SYMVERS="$PWD/drivers612/samsung-oneui/cpufreq_limit/Module.symvers"
drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/input_booster`, then
`drivers612/samsung-oneui/input_booster/check.sh`. The check confirms the vermagic, that the module has
no GOT relocations, and that every undefined symbol is a GKI export.

## 5.4 sources
`$ANDROID_TREE/kernel/samsung/sm7325/drivers/input/input_boost/{evdev_booster.c,input_booster.c,
input_booster_qc.c}` and `include/linux/input/input_booster.h`. The A52s 5.4 build used
`SEC_INPUT_BOOSTER=y`, `_QC=y`, with `_MODE` and `_HANDLER` off (from `lineage-a52sxq_defconfig`). The
5.4 driver was hooked into `evdev_events()` in evdev.c.

The boost table comes from the 5.4 DT node `input_booster` in
`arch/arm64/boot/dts/samsung/a52/a52sxq/a52sxq_kor_single_w00_r02.dts`. It is built into the module
because the 6.12 DT has no such node. The 5.4 A52s boot dmesg in
`research/blob-uapi-evidence/dmesg_boot.txt` confirms the touch row: `set_freq_limit: cflm: id(1)
freq(1324800)`, Tail_Time(300).

| label (type) | head ms | tail ms | CPU head/tail kHz | DDR | HMP | LPM |
|---|---|---|---|---|---|---|
| key (0) | 500 | 0 | 1324800 / 0 | 0/0 | 2/0 | 0/0 |
| touchkey (1) | 1 | 500 | 1324800 / 0 | 0/0 | 2/0 | 0/0 |
| touch (2) | 200 | 300 | 1324800 / 1056000 | 1017/1017 | 2/2 | 5/5 |
| multitouch (3) | 200 | 800 | 2035200 / 1324800 | 0/0 | 2/2 | 0/0 |
| keyboard (4) | 130 | 130 | 1324800 / 1324800 | 0/0 | 2/2 | 0/0 |
| MOUSE (5) | 200 | 300 | 1324800 / 489600 | 0/0 | 2/0 | 0/0 |
| mouse_wheel (6) | 200 | 0 | 1324800 / 0 | 0/0 | 2/0 | 0/0 |
| pen_hover (7) | 200 | 300 | 1324800 / 489600 | 0/0 | 2/0 | 0/0 |
| pen (8) | 200 | 600 | 1766400 / 1056000 | 0/0 | 2/2 | 5/5 |

Release values are `-1,0,-2,0` and allowed resources are `0,1,2,3` (CPU, DDR, HMP, LPM). The table
also has `cpu_cluster_policy "7,4,0"`, which 5.4 never used either.

## sysfs (names, modes and formats are the same as 5.4)
- `/sys/class/input_booster/enable_event`, `debug_level`, `sendevent`: 0644 root, `"%u\n"`
  (`sendevent` is `"%d\n"`). A write parses one integer. Only `debug_level` does anything: it turns
  on the per-event `[Input Booster]` messages. The other two are stored only, as on 5.4.
- `/sys/class/input_booster/ib_mode_state`: 0644, `"%u\n"`, stored only. **This node did not exist
  on the 5.4 A52s** (`research/blob-uapi-evidence/sysclass_detail.txt` does not list it). I added it
  because the ROM's `init.rc` chowns and chmods it and HYPER's `config_vendor.json` names it
  (`IB_MODE`). With one mode table, Samsung's MODE driver falls back to mode 0, so storing the value
  without acting on it is the same behaviour.
- `/sys/class/input_booster/<label>` is a symlink to `/sys/devices/virtual/input_booster/<label>/`,
  which holds `head`, `tail` and `level`, all 0644:
  - `head` and `tail` read as `"<time> <cpu> <ddr> <hmp> <lpm>\n"`, for example touch head is
    `200 1324800 1017 2 5`. A write must be exactly 1 + 4 integers. Anything shorter or longer is
    silently ignored (the write still returns count), as on 5.4.
  - `level` reads `"%d\n"`. One value is shared by every label, starting at 2. A write of 0..2 is
    stored and anything else is ignored. The value is never used, as on 5.4.
- 5.4 also registered two placeholder devices with no files, `/sys/devices/evdev_booster_dev` and
  `/sys/devices/input_booster` (the ICC device). Nothing references them, so they are left out.

## What really boosts and what is a no-op
- **CPU (real):** `set_freq_limit(CFLM_TOUCH=1, kHz)` on press, and `(unsigned)-1` on release. This
  comes from `cpufreq_limit.ko`. It is a *weak* link: modinfo depends=cpufreq_limit, but the module
  also loads and runs without it, and then it does not boost. The address is taken only in a data
  initialiser (ABS64 relocation). Testing a weak symbol's address in code makes clang emit
  `R_AARCH64_ADR_GOT_PAGE`, and the 6.12 arm64 module loader rejects that ("unsupported RELA
  relocation: 311", found in QEMU), which would be a first-stage bootloop. `check.sh` guards against
  it. `symbol_get()` cannot be used because set_freq_limit is `EXPORT_SYMBOL`, and since 6.5
  `__symbol_get` refuses non-GPL exports.
- **HMP (real):** `sched_set_boost(2)` = CONSERVATIVE_BOOST on press and `sched_set_boost(-2)` on
  release. This uses the 5.4 `set_hmp()` level tracking and comes from `sched-walt.ko` (first.load
  line 34), looked up lazily with `symbol_get()` because the export is GPL. On 6.12, WALT conservative
  boost also feeds `should_boost_bus_dcvs()`, which gives an indirect DDR/bus vote.
- **DDR (no-op):** 5.4 used `icc_get(dev, MASTER_APPSS_PROC, SLAVE_EBI1)`. GKI 6.12 exports only
  `of_icc_get()`, which needs a DT `interconnects` property on a device. The value stays in sysfs.
- **LPM bias (no-op):** `PM_QOS_BIAS_HYST` was a Qualcomm 5.4 pm_qos class and does not exist on
  6.12.
- **Timing and aggregation (same as 5.4):** head values for head_time. Then the tail values, held
  until tail_time after release, or a 60 s safety timer while the finger stays down. With tail 0 the
  boost ends at head end. Across all active instances, each resource gets the maximum value. A
  resource is released only when no instance holds it. Device types and key ids come from the same
  decoder as 5.4: TRACKING_ID slot counting gives touch/multitouch, VOL/POWER is key, BACK/HOME is
  touchkey, MSC_SCAN+KEY is keyboard or mouse, BTN_TOUCH+ABS_PRESSURE is pen, BTN_TOOL_PEN is hover.

## Port changes (behaviour kept, mechanics changed)
- **Input handler instead of the evdev.c patch, so GKI is unchanged.** The handler uses Samsung's own
  `_HANDLER` id table (MT touchscreen, touchpad, any EV_KEY device). It uses `.events` only and
  always returns `count`, so it never consumes an event. The event path copies only packets that can
  produce a device type into a 64-entry ring and queues a work item. Packets over 100 events are
  dropped, as 5.4 did with "Exceed max event number".
- **Piggyback open.** The handle is opened only after `dev->users > 0`, meaning Android's EventHub
  already opened the device, and it is closed again when it is the last user. A deferrable poll checks
  this (1 s, then 5 s), so the handler never calls a driver's open() or close() itself. This matters
  because the 6.12 stm touch driver's `open()` is a no-op before `probe_done`, and an open at
  connect time would leave it disabled. Screen off still works: Samsung's `enabled` sysfs calls
  `dev->close()` directly. Consequence: boosts start up to about 1 s after Android opens a device, and
  stop while a process holds an EVIOCGRAB on it (5.4 had the same limitation).
- **One ordered high-priority workqueue under one mutex.** 5.4 used an unbound workqueue with
  RCU-list races.
- **Two 5.4 hangs removed.** 5.4 spun forever with 100 live instances (no free uniq id) and with
  packets over 100 events (cur_idx never advanced).
- **Module init never fails and never blocks.** Every step is optional and init always returns 0.
  Without memory it runs sysfs only.
- **Silent by default.** Messages appear only with `debug_level=1`. The 5.4 "IB Trigger Press" and
  similar pr_info lines were unconditional.

## SELinux and rc expectations (from the OneUI vendor and system in MonsterROM work_dir)
The paths are the same as 5.4 (`/sys/devices/virtual/input_booster/<label>`), so the labels come
out as on stock:
- `vendor_sepolicy.cil` genfscon: `/devices/virtual/input_booster/touch/{level,head,tail}` gets
  `sysfs_ski_temp_writable`.
- `vendor_file_contexts`: `/sys/class/input_booster(/.*)?` and
  `/sys/devices/virtual/input_booster/touchkey(/.*)?` get `sysfs_input_booster`. Every other node
  defaults to `sysfs`.
- allow rules:
  - `hal_hyper_default` may read and write files labelled `sysfs_input_booster` or
    `sysfs_ski_temp_writable` (and use `sysfs_ski_temp_writable` dirs).
  - `system_app` has the same access.
  - `system_server` may read and write `sysfs_input_booster` files.
- `system/etc/init/hw/init.rc` "System Performance - Permissions for input_booster": `chown system
  system` and `chmod 0664` on touch/{level,head,tail}, multitouch/{head,tail,level} and ib_mode_state.
  No vendor rc or ueventd line mentions input_booster.
- Who writes what: HYPER's `config_vendor.json` "Sysfs" table names `/sys/class/input_booster/
  touch/head` (0x00201000), `touch/tail` (0x00201100), `touch/level` (0x00201200) and
  `ib_mode_state` (0x00203100). No vendor binary or framework jar contains the path.
  SamsungDeviceHealthManagerService reads `touch/head`.

## On-phone test recipe (coordinator, root shell; nothing here touches the screen)
```sh
# 1. tree, modes, labels
ls -lZ /sys/class/input_booster/ /sys/devices/virtual/input_booster/touch/
grep sec_input_booster /proc/bus/input/handlers        # handler registered
for f in enable_event debug_level sendevent ib_mode_state; do echo $f=$(cat /sys/class/input_booster/$f); done
for d in key touchkey touch multitouch keyboard MOUSE mouse_wheel pen_hover pen; do
  echo "$d head=[$(cat /sys/class/input_booster/$d/head)] tail=[$(cat /sys/class/input_booster/$d/tail)] level=$(cat /sys/class/input_booster/$d/level)"; done
# expect touch head=[200 1324800 1017 2 5] tail=[300 1056000 1017 2 5] level=2 (unless HYPER rewrote them)
# 2. store semantics (save and restore what HYPER may have written)
H=$(cat /sys/class/input_booster/pen/head); echo "250 1400000 0 2 0" > /sys/class/input_booster/pen/head
cat /sys/class/input_booster/pen/head; echo "1 2" > /sys/class/input_booster/pen/head; cat /sys/class/input_booster/pen/head   # unchanged
echo "$H" > /sys/class/input_booster/pen/head
# 3. touch boost without touching the screen: SCREEN OFF first (Android drops touches while not
#    interactive; with the screen on an injected touch would land at a stale position).
#    Inject a contact on the real touchscreen's highest slot with sendevent (no uinput needed):
D=$(for e in /sys/class/input/event*; do grep -qi stm $e/device/name && echo /dev/input/${e##*/}; done | head -1)
echo 1 > /sys/class/input_booster/debug_level
sendevent $D 3 47 9; sendevent $D 3 57 4242; sendevent $D 0 0 0          # SLOT 9, TRACKING_ID, SYN
cat /sys/devices/system/cpu/cflm/info | grep '\[1\]'                       # requested: [1] min(1324800)
cat /sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq              # raised while boosted
sendevent $D 3 47 9; sendevent $D 3 57 -1; sendevent $D 0 0 0             # release
sleep 1; cat /sys/devices/system/cpu/cflm/info | grep '\[1\]'             # back to min(-1)
dmesg | grep 'Input Booster' | tail -20; cat /proc/sys/walt/sched_boost   # 2 during, 0 after
echo 0 > /sys/class/input_booster/debug_level
```
Notes:
- `sendevent` writes to the evdev node, which goes through `input_inject_event` and reaches every
  open handle, ours included. Without debug_level the only trace is the cflm `[1]` line.
- If `sendevent` will not take `-1`, use `4294967295`.
- Alternative that works with the screen on: Android's `uinput` shell tool with a keyboard device
  that declares MSC_SCAN and KEY_F24. MSC_SCAN followed by a key triggers the keyboard booster
  (130/130 ms), and F24 has no keycode mapping, so Android ignores it.
- Load order: cpufreq_limit.ko must load before input_booster.ko. If it loads later the weak link
  stays NULL and nothing boosts. sched-walt.ko already loads early.
- Rebuild input_booster.ko whenever set_freq_limit's prototype or CRC changes. A CRC mismatch on a
  *resolved* weak symbol fails insmod.

## Files
- `input_booster.c`, `input_booster.h`, `Kbuild`: the module.
- `check.sh`: offline checks.
- `qemu-test/`:
  - `run.sh`: the QEMU test on `bsp612/out/dist/Image`.
  - `ibtest.c`: freestanding aarch64 uinput driver.
  - `init.sh`: initramfs `/init`.
  - `fakewalt/`: a sched_set_boost stand-in with the same CRC.
