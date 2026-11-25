# a52sxq_vrr_state.ko: `/sys/class/lcd/panel/vrr_state` + `panel_vcom_type` for the OneUI 9 port on 6.12

Built and QEMU-tested only. It has not been loaded on a phone.

## Node

`/sys/class/lcd/panel/vrr_state`. The real path on 6.12 is `/sys/devices/virtual/lcd/panel/vrr_state`:
`ss_create_sysfs()` calls `lcd_device_register("panel", NULL, vdd, NULL)`, with no parent, in class
`lcd` (lcd.ko). 5.4 used the same call, so the path is the same. The node is read-only (0444, show
only, no store). It always reads exactly 1 byte: `"\n"`.

## Who reads it (OneUI 9 port, stock A528BXXU5FWK4 vendor + framework)

I searched `work_dir/{system,vendor,product,odm}` with `rg -a`, and also looked inside every
compressed jar/apk/apex entry. Three files contain the string:
- `/system/bin/bootanimation`. This is the only reader. It reads the property
  `persist.sys.sf.hs_mode`, opens the node and reads up to 92 bytes. Then it strips trailing `\n`:
  - If nothing is left, or the open fails, it keeps the default display projection.
  - Otherwise it parses `<w>X<h>:<mode>` (copy up to `X`, then up to `:`, then the rest; the
    scan for `X` and `:` has no bound). It logs `VRR HSMode %d - %s`, swaps w/h if w > h, and sets
    a `{0,0,w,h}` layer-stack projection.

  A string without `X`/`:` would make it scan past its buffer, so the node must hold either nothing
  or a well-formed string.
- `/vendor/etc/init/hw/init.samsung.display.rc`, `on init`: `chown system system` and `chmod 0440`.
  bootanim runs as `user graphics, group graphics system`, so 0440 system:system is still readable
  for it.
- `vendor/lib/modules/5.4-gki/msm_drm.ko`: the stock driver itself.

`USERSPACE-CONTRACT.md` says "no reader". That was true for the LineageOS tree, but on OneUI
bootanimation reads the node. Today, when the node is missing, the only effect is the extra log
line `Could not open '/sys/class/lcd/panel/vrr_state'`: the projection path is the same as for `"\n"`.

## 5.4 format

The Lineage source (`techpack/display/msm/samsung/ss_dsi_panel_sysfs.c:4746`) works like this:
- If no timing has `sot_hs_mode`, it shows `"\n"`.
- Otherwise, with `CONFIG_SEC_PARAM`, it shows the `param` partition's `VrrStatus` string. If that
  string is empty, it first writes `"%dX%d:NOR"` back into the param partition from inside `show()`.

The stock vendor `msm_drm.ko` differs. I disassembled `vrr_state_show` in it:
- It has no `sec_get_param` import, so it is built without SEC_PARAM.
- Both 16-byte buffers are zeroed (`stp xzr` ×2).
- Both branches end in `snprintf(buf, 16, "%s\n", "")`.

So on the stock A528BXXU5FWK4 kernel the node always reads `"\n"`. The only reader treats that as
"keep the default projection". This module shows the same `"\n"`. It does not copy the
param-partition read/write.

The 5.4 mode was `S_IRUGO|S_IWUSR|S_IWGRP` with a NULL store, so writes failed with -EIO, and init
set 0440 anyway. Here the mode is 0444 with no store, for two reasons:
- 6.12's `device_create_file()` WARNs on a write bit without a store.
- kernfs refuses write opens on a file with no write bit, even for root (QEMU: `echo 1 >` fails).

## Data source / how it attaches

The node needs no msm_drm data, so the module has no msm_drm or lcd symbol dependency
(`depends=` empty). The S23 framework on 6.12 has no `vrr_state`. Its `vrr` node (`"%d %d\n"`,
refresh rate + HS mode) is a different thing, and the stock 5.4 `vrr_state` never showed that
data either.

Neither `lcd_class` (static in lcd.ko) nor the vdd is exported. The device is found the way
`a52sxq_volkey.c` finds `/sys/power`:
1. Walk from the kernfs root to `class/lcd/panel`, a symlink, and take its target dir.
2. That dir's `kernfs_node::priv` is the device's kobject. Take `get_device()` on it.
3. Check `class->name == "lcd"` and the name `panel`.
4. `device_create_file()`.

If the panel already has a `vrr_state`, the module leaves it alone, so there is no sysfs duplicate
warning.

`module_init` only schedules a delayed work and returns 0. The lookup retries every `retry_ms`
(default 250) up to `max_tries` (default 2400 = 10 min), then gives up quietly. Both are 0444
module params.

On exit it cancels the work, removes the file only if the panel kobject is still in sysfs, and
calls `put_device`.

## SELinux labels

The OneUI vendor policy (`work_dir/vendor/etc/selinux/vendor_sepolicy.cil:742`) has
`genfscon sysfs /devices/virtual/lcd/panel` -> `sysfs_lcd_writable`. That is a prefix rule, so
the new file gets this label with no per-file rule. There is no `vrr_state` genfscon. The other
`/devices/platform/panel_drv*` entries are Exynos paths.

The label is the same as on 5.4, because the device path is the same. `vendor_file_contexts:1049`
labels the same path for restorecon. Policy allows `bootanim_30_0 sysfs_lcd_writable` file
`read open getattr`, and the dir `search` (`vendor_sepolicy.cil:5245-5246`). No policy change is
needed.

## Second node: `panel_vcom_type` (added 2026-11-22, same module)

It is a parity item: `drivers612/ONEUI9-PARITY.md`, `display.panel_attrs`, lists it as missing
on 6.12.

**Readers: none.** I ran `rg -a` over `work_dir/{system,vendor,product,odm}` and also looked inside
every compressed jar/apk/apex entry. The only hit is the stock `msm_drm.ko`. There is no init
chown and no `research/` or `logs/oneui-mods` evidence of it.

**5.4 source** (`ss_dsi_panel_sysfs.c:255`, `DEVICE_ATTR(panel_vcom_type, S_IRUGO, show, NULL)`):
it shows `"%d\n"`, 1 if `vdd->panel_func.samsung_cmd_log_read(vdd)` returns non-zero, else 0. The
comment says "Vcom register check for M44 model"; it logs "vom read result 120hz?". No panel in
the 5.4 tree sets that callback.

**Stock FWK4 `msm_drm.ko`** (disassembled): `panel_vcom_type_show` calls the pointer at `vdd+0x1f8`
under a CFI check, then `snprintf(buf, 128, "%d\n", ret != 0)`.
- No instruction in the whole module stores to `+0x1f8` of a vdd. The only two `str ..., #0x1f8`
  are in `_sde_sspp_setup_vigs`, and there is no `stp` at `+0x1f0`.
- `S6E3FC3_AMS646YD01_LO_FHD_init` fills many `panel_func` slots, but not `0x1f8`.
- No `*cmd_log_read*` or `*vcom*` function exists.

So on the A52s the node always reads `"0\n"` (2 bytes). This module shows the same constant, mode
0444, no store. It needs no panel data and has no symbol dependency.

**Label:** same as `vrr_state`. The genfscon prefix `/devices/virtual/lcd/panel` gives
`sysfs_lcd_writable`, and there is no per-file rule.

On-phone check: `cat /sys/class/lcd/panel/panel_vcom_type | od -c` -> `0  \n`, and
`ls -lZ` -> `-r--r--r-- root root u:object_r:sysfs_lcd_writable:s0`.

Each node is added only if the panel does not already have one of that name, and it is removed
on rmmod only if this module added it.

## Build / test

    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/vrr_state      # -> out/a52sxq_vrr_state.ko
    drivers612/samsung-oneui/vrr_state/qemu-smoke/run.sh                      # PASS/FAIL

The QEMU run (bsp612 GKI Image, virt) uses the phone's `lcd.ko` from the rbich45 plan plus
`qemu-smoke/fakepanel` (`lcd_device_register("panel")`). It checks:
- load with no lcd class (init 0, retry)
- late attach
- 0444, `"\n"` only, write refused
- `panel_vcom_type` 0444, `"0\n"`, write refused
- init-like chown/chmod
- rmmod while attached
- panel unregistered first
- an existing `vrr_state` kept while `panel_vcom_type` is still added
- give-up after `max_tries`, then rmmod while retrying
- lcd.ko unloads (no leaked reference)
- no WARN/BUG/duplicate in dmesg

Result: PASS, 27/27.

Load point: first stage after `msm_drm.ko`, e.g. near line 187 of `first.load` (msm_drm is line 119
there). It is not added to any load list or build yet.

## On-phone read-only check (when it is on a phone)

    ls -lZ /sys/class/lcd/panel/vrr_state            # -r--r----- system system u:object_r:sysfs_lcd_writable:s0
                                                      # (0444 root root if the panel came up after init's "on init" chmod)
    cat /sys/class/lcd/panel/vrr_state | od -c        # 0000000  \n
    readlink -f /sys/class/lcd/panel                  # /sys/devices/virtual/lcd/panel
    dmesg | grep a52sxq_vrr_state                     # "added ... (after N lookups)"
    logcat -b all -d | grep -E "BootAnimation.*(vrr_state|VRR)"   # no "Could not open" line any more

Do not write to the node, or to anything under `/sys/class/lcd/panel/`.
