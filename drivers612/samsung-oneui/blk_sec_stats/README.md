# blk_sec_stats.ko: Samsung 5.4 `/sys/kernel/blk_sec_stats/` on 6.12

Port of `$ANDROID_TREE/kernel/samsung/sm7325/block/blk-sec-stats.c` (Samsung GPL-2.0 header and
MODULE_AUTHOR kept; the stock ROM ships the same 5.4 build as `/vendor/lib/modules/blk-sec-stats.ko`,
its strings match the source). Built offline against bsp612, QEMU-tested only.
**Not loaded on a phone.**

## Nodes (names, modes, formats = 5.4)

| node | mode | format | 6.12 data |
|---|---|---|---|
| `diskios` | 0444 | `"ReadC":"%lu","ReadKB":"%lu","WriteC":"%lu","WriteKB":"%lu","DiscardC":"%lu","DiscardKB":"%lu","IOT":"%lu","Hours":"%ld"\n` | **real**: part_stat of the internal disk's whole-disk device, deltas since the previous read (first read = since boot), IOT = io_ticks seconds, Hours = rounded hours since the previous read |
| `pios` | 0444 | per tgid `"%d %llu %llu %s\n"` (tgid, read KB, write KB, comm), top 100 by read+2*write first when > 100 entries, lines while > 80 bytes of the page are left, then `99999 <r> <w> others` if non-zero; the read empties the table | **real** (block_bio_queue tracepoint) |
| `pios_enable` | 0644 | `%d\n`, default **0**; write `>=1` -> 1, else 0; every write clears the table | as 5.4 |
| `pios_duration_ms` | 0644 | `%u\n`, default 5000, capped at 10000 (negative -> huge -> 10000, as 5.4's `%d` into unsigned) | as 5.4 |

Accounting runs only while `pios_enable=1` and until `pios_duration_ms` after the last `pios` read
or `pios_enable` write (5.4 timeout semantics), so a reader polling `pios` keeps it alive.

## Differences from 5.4 (internal only)
- **Disk lookup**: `blk_lookup_devt`/`block_class` are not exported by the GKI. The disk is found
  via sysfs: `/sys/class/block/<name>` kernfs link -> device (type "disk") with `get_device()`.
  Candidates from module param `disks` (default `sda,mmcblk0`, the 5.4 order). 5.4 opened the bdev
  with `blkdev_get_by_dev()` and never closed it; this module holds only a device reference.
  Lookup at init, retried on every `diskios` read and `pios_enable=1` write (UFS scan may finish
  after insmod). No disk: `diskios` returns `-ENODEV` (5.4: -1 = EPERM) and logs once.
- **pios source**: 5.4 counted in its SSG I/O scheduler's `prepare_request` (first bio of each new
  request only, internal UFS only). 6.12 has no SSG; `__tracepoint_block_bio_queue` is exported
  (Module.symvers, GPL), so a probe counts every bio submitted to the internal disk or its
  partitions (bios merged into an existing request are counted too; 5.4 missed those), attributed
  to `current->group_leader` (tgid + start_boottime, comm) as on 5.4. Bios from non-task context
  go to "others".
- **Cost / locking**: a disabled or timed-out probe returns after two loads. Enabled: one
  irq-safe spinlock around an O(1) hash lookup (256 buckets by tgid; 5.4 walked a list of up to
  10000 nodes), `GFP_NOWAIT|__GFP_NOWARN` slab alloc, max 10000 nodes (~70 B each, ~0.7 MB worst
  case), overflow -> "others". No sleeping, no other lock taken inside. The reader swaps the
  whole table out under the lock and sorts/prints outside it. 5.4's unlocked `pio_cnt` race fixed.
- Init never fails: missing cache / probe / kobject is logged once and the rest loads.
  rmmod: sysfs removed, probe unregistered + `tracepoint_synchronize_unregister()`, nodes freed.
- Not provided: `hcgchist` (init.rc chowns it; not in the 5.4 source either) and
  `cpu_lpm_enable`/`cpufreq_min` (iod probes them and logs "cpu boost: not supported" when absent,
  as on 5.4).

## Users (OneUI 9 port work_dir)
- `vendor/bin/iod`: writes `pios_enable` and `pios_duration_ms`, reads `pios` (`%d %llu %llu %[^\n]`,
  "Write_top(KB)").
- `vendor/etc/hqm_device.xml` (hal_hqm): reads `diskios`, keys Hours/ReadC/ReadKB/WriteC/...
  (`clear="1"`: the node has no store on 5.4 either; a write fails the same way).
- rc: `system/etc/init/hw/init.rc` on boot (lines 1641-1642 and 1682-1683):
  `chown system system /sys/kernel/blk_sec_stats/diskios`, `chmod 0660 .../diskios`
  (+ `chown root system` / `chmod 0660 .../hcgchist`, absent). No rc for pios*: they stay root 0444/0644.
- SELinux (vendor_sepolicy.cil): `genfscon sysfs /kernel/blk_sec_stats/{diskios,pios,pios_enable,pios_duration_ms}`
  -> `u:object_r:vendor_sysfs_blksec:s0`; `vendor_iod` file rw, `hal_hqm_default` dir/file r + write.
  Nothing in the plat policy.

## Build / test
    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/blk_sec_stats
    drivers612/samsung-oneui/mm_boost/qemu-smoke/run.sh     # shared QEMU run for both modules

QEMU (2026-11-22, bsp612 Image, virt + 64 MiB virtio-blk `vda`): PASS, 0 WARN/BUG.
- default `disks` (no sda/mmcblk0 in QEMU): insmod rc 0, `diskios` read fails, rmmod clean;
- `disks=vda`: modes 0444/0444/0644/0644, defaults 0/5000;
- 8 MiB `dd` read -> `"ReadC":"9","ReadKB":"9216",...,"WriteC":"0"`; 4 MiB write + fsync ->
  next read `"ReadC":"0","ReadKB":"0","WriteC":"6","WriteKB":"4096"` (deltas);
- pios empty while disabled; after `pios_enable=1`, two parallel dd: `140 0 1024 busybox`,
  `138 3072 0 busybox` (busybox applets have comm busybox; read includes readahead); re-read empty;
- `pios_duration_ms` 20000 -> 10000, 100 -> 100; IO 1 s after the last enable -> pios empty;
- rmmod -> `/sys/kernel/blk_sec_stats` gone.

## On-phone check (not done)
    ls -lZ /sys/kernel/blk_sec_stats/   # diskios system system 0660 after boot; all vendor_sysfs_blksec
    cat /sys/kernel/blk_sec_stats/diskios; dd if=/dev/block/sda of=/dev/null bs=1M count=8 skip=100; cat /sys/kernel/blk_sec_stats/diskios
    cat /sys/kernel/blk_sec_stats/pios_enable /sys/kernel/blk_sec_stats/pios_duration_ms   # iod may already have set them
    echo 1 > /sys/kernel/blk_sec_stats/pios_enable; sleep 2; cat /sys/kernel/blk_sec_stats/pios
    dmesg | grep -E 'blk_sec_stats|avc.*blksec'     # expect "internal disk sda"
Load point: first stage after the UFS stack (first.load ~183-187, next to `ufs_sec_sysfs.ko`).
No module dependencies (`depends:` empty). Module name `blk_sec_stats` = the 5.4 name.
