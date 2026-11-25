# cpufreq_limit (Samsung 5.4 CPU_FREQ_LIMIT as a 6.12 module)

Source: Samsung A52s 5.4 `drivers/cpufreq/cpufreq_limit.c` + `include/linux/cpufreq_limit.h`
(`$ANDROID_TREE/kernel/samsung/sm7325`), structure cross-checked with the S26 6.12 donor
(`donors/samsung-s26-6.12/.../soc-repo/drivers/cpufreq/cpufreq_limit.c`, which moved the nodes to
`/sys/devices/system/cpu/cpufreq_limit` and uses a DT virtual table: NOT what the A52s OneUI vendor
reads). Build: `EXTRA_SYMVERS=<sched-walt symvers> drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/cpufreq_limit`
(the symvers comes from `ko2symvers.py OUT sched-walt.ko` of the ramdisk). Depends: sched-walt.

## Nodes (5.4-identical names, modes, formats)
| Node | Mode | Read | Write |
|---|---|---|---|
| /sys/power/cpufreq_table | 0444 | unified virtual table, `%u ` each, last blank replaced by `\n` | - |
| /sys/power/cpufreq_min_limit | 0644 | last value written (`-1` initially) | kHz in the virtual table, -1 = release |
| /sys/power/cpufreq_max_limit | 0644 | same | same |
| /sys/power/over_limit | 0644 | `%d` | kHz |
| /sys/power/limit_stat | 0644 (no store, as 5.4) | 4 lines `min_ms max_ms over_ms` (USERSPACE, TOUCH, FINGER, ARGOS) | - |
| /sys/devices/system/cpu/cflm/info | 0444 | real/virt ranges, params, requested min/max per id | - |
| /sys/devices/system/cpu/cflm/{silver_min_lock,sched_boost_type} | 0644 | `%u` | int |

Exported for in-kernel users (input_booster): `int set_freq_limit(unsigned int id, unsigned int freq)`
(EXPORT_SYMBOL as on 5.4; ids in cpufreq_limit.h; freq -1 releases).

Expected table on this phone (from the 6.12 policies, which read the same EPSS LUT as 5.4):
`2400000 2380800 2208000 2035200 1862400 1766400 1516800 1324800 1056000 902400 825600 758400 662400 576000 470400 403200 345600 150000`
= prime table above ltl_max (1804800/2 = 902400), then the silver table / 2. Not compared with a live 5.4 read
(no 5.4 phone may be touched today).

## Logic (= 5.4)
min > 902400: silver min 1152000 (silver_min_lock), gold/prime min = value; else silver min = value*2.
max >= 1056000: gold/prime max = value (silver free); max < 1056000: silver max = min(1804800, value*2),
gold max = 691200 (g_fmin_up) if value == 902400 else gold fmin, prime max = prime fmin. over_limit and the
userspace/touch interplay unchanged. WALT CONSERVATIVE sched boost while the prime cluster's QoS min > its fmin
(sched_set_boost(2) / (-2), refcounted, as 5.4).

## Differences from 5.4 (module on GKI)
- /sys/power kobject from kernfs (power_kobj is not exported), as a52sxq_volkey.
- Tables from policy->freq_table of cpu0/cpu7 (5.4: hook in qcom-cpufreq-hw).
- One freq QoS request per cluster policy and id (5.4: one per CPU; only the first CPU of a cluster ever got a
  non-default value, so the aggregated limits are identical).
- Init never fails; missing policies -> nodes exist at once, a delayed work attaches (500 ms, 240 tries) and
  replays recorded writes.
- `store_one` (silver_min_lock, sched_boost_type) returns the count (5.4 set the value and returned -EINVAL).
- The per-decision pr_info lines of 5.4 are pr_debug (they fired several times per touch).

## SELinux / init (OneUI 9 port, stock A528B vendor)
vendor_sepolicy.cil genfscon already labels them by path: cpufreq_min_limit, cpufreq_max_limit, cpufreq_table,
over_limit = sysfs_power; limit_stat = sysfs_ski_power_readable. init.samsung.rc:229-238 chowns them radio:system
and sets 664/444/664/664. No OneUI-side change needed. /sys/devices/system/cpu/cflm has no genfscon (sysfs_devices_system_cpu;
5.4 had none either).

## Load position
After qcom-cpufreq-hw and sched-walt (first stage lines 33/34); appended to the ramdisk stage `vibrator`
(drivers612/samsung-oneui/rd-add-ko.py), i.e. ~line 182 of the real first stage. Check on a phone: check.sh.
