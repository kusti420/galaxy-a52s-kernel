# a52sxq_mm_boost.ko: Samsung 5.4 `/sys/kernel/mm/vmscan/` nodes on 6.12

Built offline against bsp612 (vermagic `6.12.81-4k-g8a69376da734`), QEMU-tested only.
**Not loaded on a phone.**

## Nodes (5.4 `mm/vmscan.c` 2394-2552, group `vmscan` on `mm_kobj`)

| path | mode | format | accepted writes | 6.12 effect |
|---|---|---|---|---|
| `/sys/kernel/mm/vmscan/mem_boost_mode` | 0644 | `%d\n` | 0 NO_BOOST, 1 BOOST_MID, 2 BOOST_HIGH, 3 BOOST_KILL; anything else (or not decimal) -> `EINVAL`, value kept | **stored only** |
| `/sys/kernel/mm/vmscan/am_app_launch` | 0644 | `%d\n` | 0 or 1, else `EINVAL` | **stored only** |

5.4 timeout, kept: a read of `mem_boost_mode` more than 5 s (`MEM_BOOST_MAX_TIME`) after the last
write first resets it to 0 (so it reads 0 after 5 s; the boost was also only active inside that
window). `am_app_launch` has no timeout.

`am_app_launch` was not in the brief but is in the same 5.4 attribute group, `init.memory.rc`
chowns it and the hyper HAL writes it (`config_vendor.json` `KERNEL_APP_START_NOTIFY`
BoostPath), so it is created too.

## Why store-only (also in the source header)
5.4 effect of `mode >= BOOST_HIGH` inside the 5 s window (`need_memory_boosting()`):
- `get_scan_count()`: kswapd scans FILE pages only, unless file cache < 200-500 MB (by RAM size);
- end of `shrink_lruvec()`: skip the anon active-list rebalance;
- `__alloc_pages_direct_reclaim()`: skip `drain_all_pages()` on the retry;
- `wake_ion_rbin_heap_prereclaim()` (ION rbin; not on 6.12).
`am_app_launch` only fed an in-kernel notifier chain (no 6.12 listener).

All of that is static code in `mm/`. The 6.12 GKI runs MGLRU (`CONFIG_LRU_GEN_ENABLED=y`), where
kswapd never goes through `get_scan_count()`, and the only module-reachable knobs are GKI vendor
hooks (`android_vh_tune_swappiness`, `android_vh_drain_all_pages_bypass`,
`android_vh_tune_scan_type`, ...). Those are deliberately not registered here (out of scope; other
vendor modules may own them). A later hook module could read the stored value. No symbols are
exported (a duplicate export would make first-stage insmod fail).

## Implementation notes
- `mm_kobj` is not exported: the `/sys/kernel/mm` kobject is found from `kernel_kobj`'s kernfs
  node (`kernfs_find_and_get(kernel_kobj->sd, "mm")->priv`), the a52sxq_volkey trick.
- `/sys/kernel/mm/vmscan` absent (normal on 6.12): created as a named attribute group, exactly as
  5.4. Present (someone else made it): only the missing files are added with
  `sysfs_add_file_to_group` (no duplicate-name stack dump). `/sys/kernel/mm` missing: created.
- Init always returns 0, no sleeping beyond sysfs creation, one log line only on failure.
- Imports only: kernel_kobj, kernfs_find_and_get_ns/kernfs_put, kobject_*, sysfs_* , kstrtoint,
  jiffies, _printk. `depends:` empty.

## Who uses it (OneUI 9 port work_dir)
- Writers of `mem_boost_mode`: `system/bin/lmkd` (string `/sys/kernel/mm/vmscan/mem_boost_mode`;
  also `/sys/kernel/sec_mm/mem_boost_mode`, not provided), `vendor/lib{,64}/hw/com.qti.chi.override.so`
  (camera HAL). Writer of `am_app_launch`: hyper HAL (`vendor/etc/hyper/config_vendor.json`).
  No framework jar/odex references.
- rc: `system/etc/init/init.memory.rc` on boot:
  `chmod 0664 /sys/kernel/mm/vmscan/mem_boost_mode`, `chown cameraserver system ...mem_boost_mode`,
  `chmod 0664 .../am_app_launch`, `chown system system .../am_app_launch`
  (also sec_mm/ and rbin/ variants, absent here). `system/etc/init/hw/init.rc` on boot also
  touches `mem_boost_mode_kswapd` / `mem_boost_mode_system` (not in the 5.4 kernel, not provided).
  `vendor/ueventd.rc:702` `/sys/kernel/mm/vmscan mem_boost_mode 0664 cameraserver cameraserver`
  (ueventd sysfs rules fire on device uevents; this kobject has none, so the init.memory.rc line
  is the one that applies, as on 5.4).
- SELinux (vendor_sepolicy.cil): `genfscon sysfs /kernel/mm/vmscan/mem_boost_mode`,
  `/kernel/mm/vmscan/am_app_launch` (and `/kernel/mm/vmscan/disable_mem_boost`, not a 5.4 node)
  -> `u:object_r:sysfs_ski_memory_writable:s0`. rw allowed for lmkd, hal_camera_default,
  hal_hyper_default, system_server; read for heimdall. Nothing in the plat policy. genfscon is
  path based, so files created by this module get the label at creation.

## Build / test
    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/mm_boost
    drivers612/samsung-oneui/mm_boost/qemu-smoke/run.sh     # also tests blk_sec_stats.ko

QEMU (2026-11-22, bsp612 Image, virt + virtio-blk): 34/34 ok, PASS, 0 WARN/BUG. Load, 0644 modes,
initial 0, writes 2/3 read back, 4/-1/abc -> EINVAL with value kept, reset to 0 after 6 s,
am_app_launch 0/1 only, rmmod removes the directory.

## On-phone check (not done)
    ls -lZ /sys/kernel/mm/vmscan/        # cameraserver system 0664 / system system 0664, sysfs_ski_memory_writable
    cat /sys/kernel/mm/vmscan/mem_boost_mode; echo 2 > /sys/kernel/mm/vmscan/mem_boost_mode; cat ...; sleep 6; cat ...   # 0 2 0
    dmesg | grep -E 'a52sxq_mm_boost|avc.*mem_boost|avc.*am_app_launch'
Load point: first stage next to `ufs_sec_sysfs.ko` (first.load ~line 183-187); no dependencies.
