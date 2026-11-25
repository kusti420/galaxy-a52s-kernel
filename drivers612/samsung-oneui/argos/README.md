# sec_argos.ko: Samsung ARGOS (network-throughput boost) for the a52sxq 6.12 kernel line

Port of the Galaxy A52s 5.4 `drivers/samsung/misc/sec_argos.c` (+ `include/linux/samsung/sec_argos.h`
and the `PM_QOS_NETWORK_THROUGHPUT` class of `kernel/power/qos.c`, CONFIG_ARGOS) from
`$ANDROID_TREE/kernel/samsung/sm7325`, as one module. Offline only: built, QEMU-tested, **never
loaded on a phone**.

## Why the stock argosd exits on 6.12 (offline analysis of /vendor/bin/argosd)
`argos.rc`: `service argos-daemon /vendor/bin/argosd` (class main, user system, groups system radio,
not oneshot), started on `sys.boot_completed=1 && ro.product.system.brand=samsung`; `on post-fs-data
chown system system /dev/network_throughput`. argosd (11968 bytes, disassembled) does, in order:

1. `opendir("/proc/device-tree/soc/argos")` -> **fails on 6.12 (no such DT node)** -> prints
   `opendir failed, ...` to stderr, logs `argos: (ERR! main) ...: Fail to run traffic monitor with(-19)`
   (log buffer **radio**, tag `ARGOS`) and `return 0`. init restarts it every ~5 s = "exits repeatedly".
2. counts the entries containing `@` (n), `malloc(n * 320)`.
3. `open("/dev/network_throughput", O_RDWR)` -> **also absent on 6.12** -> `Device doesn't support qos`
   + the same -19 line, exit 0. (Reached only once step 1 is fixed.)
4. for N = 1..n reads, as text, `/proc/device-tree/soc/argos/boot_device@N/` `net_boost,node`,
   `net_boost,label`, and `net_boost,interval_idx` (optional, big-endian u32: 2 = 250 ms, 1 = 500 ms,
   else/absent = 1000 ms).
5. loop forever: `/proc/net/dev` (exit -2 if it cannot be opened), per device sum the rx/tx bytes of the
   interfaces in `net_boost,node` (space separated; label ending "TX" = tx only, "RX" = rx only, else
   both); when `node` is empty it reads the decimal counter at the path in `net_boost,sysnode`
   instead. Mbps = delta_bytes * 8 / 1e6 per interval; if Mbps != 0 (or was != 0 last time) it
   writes `"0x%x%x\n"` (Mbps, N) **including the trailing NUL** (count = strlen + 1) to the one fd.
   So the kernel value is `Mbps << 4 | N`, N = 1..7.

Nothing else: no netlink, no /dev/argos*, no other sysfs (imports are libc file I/O + liblog only).
Both missing pieces must exist: the DT node (argos.dtsi below, board tree) and the misc device (this
module).

## What the module provides
- `/dev/network_throughput` (misc, dynamic minor, 0600 root:root from ueventd, chowned by argos.rc),
  5.4 pm_qos misc semantics: each `open()` adds a request (default 0), `write()` = raw s32 when
  count == 4, otherwise base-16 text (`0x` prefix, trailing newline/NUL, <= 22 chars, as
  `kstrtos32_from_user`), `-1` = default; aggregate = PM_QOS_MAX over the open requests; `read()`
  returns the aggregate s32; a change of the aggregate runs the 5.4 argos handler.
- The 5.4 argos logic unchanged: type = (value & 0xf) - 1, speed = value >> 4, level = highest table
  row whose threshold <= speed (or unlock), per-resource max over all devices (check_update_freq),
  notifier chains per label.
- CPU (real): `set_freq_limit(CFLM_ARGOS = 3, max(BIG_MIN, LITTLE_MIN))`, `-1` on unlock, through
  `cpufreq_limit.ko` (weak link like input_booster: modinfo depends=cpufreq_limit, but it also loads
  without it and then does not boost).
- DDR (real only with the DT node): `icc_set_bw(path, 0, MHz * 1000 * 4)` like 5.4. 5.4 used
  `icc_get(dev, 2, 512)`, not exported on GKI 6.12, so the path comes from `of_icc_get()` on the DT
  node's `interconnects` (platform driver "samsung,argos"; probe only takes the path). Without the
  node: no DDR vote (status shows `ddr: none`).
- Task/IRQ affinity, hmp boost: 5.4 code kept (`set_cpus_allowed_ptr`, `irq_set_affinity`, both
  exported). The 5.4 A52s DT has **no IRQ names**; the lists are filled only by kernel drivers calling
  `argos_{task,irq}_affinity_setup_label()`, which nothing in the 5.4 tree did, so they are empty:
  no-op exactly as on 5.4. Exported (GPL) here so a 6.12 driver can opt in. hmp boost is a flag only
  (as 5.4). No irq_to_desc name walk was added: there are no names to look up.
- Exports: `sec_argos_{register,unregister}_notifier` (EXPORT_SYMBOL, as 5.4),
  `argos_{task,irq}_affinity_setup_label`, `argos_block_enable` (GPL, new). Header `sec_argos.h`.
- `/sys/class/misc/network_throughput/argos_status` (0444, new, for checks): table source, aggregate,
  request count, CPU/DDR backend and max, per device: level and votes.
- `/sys/module/sec_argos/parameters/debug` (0644, default 0): the 5.4 pr_info lines. Silent by default
  (0 lines at load or per write; only errors).

Differences from 5.4 (all deliberate): last close of the device releases all locks (5.4 kept the last
level when argosd died); index check `>= ndevice` (5.4 `>`: out of bounds); no `tables[-1]` on unlock;
devices with an empty table skipped; DT devices indexed by the unit address N (= what argosd sends),
5.4 used the DT child order (the 5.4 phone's merged tree lists boot_device@7..@1, i.e. reversed by the
overlay apply: if the 5.4 kernel saw that order too, its WIFI TX boost was dead and only UFS (middle,
index 4) worked: not verified on hardware); init never fails (on error the module stays loaded without
the node, one pr_err).

## Table (source: 5.4 `arch/arm64/boot/dts/samsung/a52/a52sxq/a52sxq_kor_single_w00_r02.dts`
fragment@84 `argos`; r00/r01 identical; = `downstream-dt/a52sxq-r02.dts` values)
Row = THRESHOLD Mbps, BIG_MIN, BIG_MAX, LITTLE_MIN, LITTLE_MAX (kHz in cpufreq_limit's virtual table),
DDR MHz, RESERVED, TASK_AFF, IRQ_AFF, SCHED_BOOST.

| N | label | node | rows |
|---|---|---|---|
| 1 | WIFI TX | wlan0 | `20 0 0 576000 0 1017 0 0 0 0`, `200 2131200 0 1804800 0 5161 0 1 1 1` |
| 2 | WIFI RX | wlan0 | all 0 (unused) |
| 3 | SWLAN | swlan0 | all 0 |
| 4 | UFS | "" (sysnode `/sys/class/sec/ufs/transferred_cnt`) | `800 0 0 902400 0 0 0 0 0 0` |
| 5 | P2P | p2p-wlan0-0 | all 0 |
| 6 | NAN | aware_data0 | all 0 |
| 7 | IPC | rmnet_mhi0 | all 0 |

Built into the module (6.12 has no node today); if the running tree has a `samsung,argos` node it is
parsed instead (status `source: dt`). Effective boosts: Wi-Fi TX >= 20 Mbps -> CFLM_ARGOS min 576000
(silver 1152 MHz) + DDR 1017 MHz; >= 200 Mbps -> 2131200 (gold/prime min, silver_min_lock) + DDR
5161 MHz. UFS: inert on 6.12 because `ufs_sec_sysfs` reports `transferred_cnt` = 0 always (6.12 ufs-qcom
has no byte counter).

## DT fragment (needed for argosd): `argos.dtsi`
`&soc { argos { compatible = "samsung,argos"; #address-cells = <1>; interconnects = <&gem_noc 2
&mc_virt 512>; boot_device@1..@7 {...}; }; };`, the 5.4 node in source order + `interconnects`
(MASTER_APPSS_PROC -> SLAVE_EBI1, same IDs in soc-repo `qcom,yupik.h`, labels in yupik.dtb
`__symbols__`). A module cannot create it: `CONFIG_OF_OVERLAY` and `CONFIG_OF_DYNAMIC` are off in
bsp612 (`of_changeset_apply`, `of_overlay_fdt_apply`, `of_attach_node` absent from Module.symvers; only
`of_add_property` exists, which cannot add nodes). Checked offline: `fdtoverlay` of the fragment onto
`bsp612/out/dist/dtb/yupik.dtb` gives `/soc/argos` with all 7 children equal (fdtget) to the 5.4 tree.
Must stay `/soc/argos/boot_device@N` (argosd builds the paths). **For the kernel-line agent:** add it to
the board overlay in the same build that adds sec_argos.ko to the first stage. With `interconnects`
the node is an icc consumer: if the DT has it but the module is not loaded, the gem_noc/mc_virt
sync_state waits for it (until fw_devlink.sync_state=timeout) -> drop that line if the module is not
shipped.

## Labels / init (OneUI vendor policy, read from MonsterROM work_dir/vendor)
- `vendor_file_contexts:1558 /dev/network_throughput u:object_r:sec_radio_device:s0` (present).
- `vendor_sepolicy.cil`: `argosd` domain allowed `sec_radio_device chr_file rw`, `sysfs` dir/file read
  (covers `/sys/firmware/devicetree/base/soc/argos/*` and `/sys/devices/virtual/sec/ufs/transferred_cnt`,
  no genfscon for either = `sysfs`), `proc_net` read; plat: `domain proc lnk_file read` (the
  `/proc/device-tree` symlink), `domain sysfs lnk_file read`. **No policy change needed.**
- ueventd: no line for the node (default 0600 root); `argos.rc` chowns it to system at post-fs-data,
  argosd runs as system -> O_RDWR works. The module must be loaded before post-fs-data (first stage:
  yes). Optional hardening, not required: `/dev/network_throughput 0660 system system` in a ueventd rc.
- Nothing to add for `argos_status` / `debug` (checks only).

## Build, checks, load position
    EXTRA_SYMVERS="$PWD/drivers612/samsung-oneui/cpufreq_limit/Module.symvers" \
      drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/argos
    drivers612/samsung-oneui/argos/check.sh   # vermagic, no GOT relocs, every undef exported or weak
Output `out/sec_argos.ko` (stripped, 57264 bytes, sha256 3cf2ff644f90564d...), depends
`cpufreq_limit` (weak), vermagic `6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions aarch64`.
0 warnings (also with W=1). Load: first stage after cpufreq_limit (182), i.e. as line 187 of
`drivers612/realboot/out/rbich45/work/plan/first.load` (after `input_booster.ko` at 186); for a test
ramdisk `rd-add-ko.py IN OUT vibrator out/sec_argos.ko` (stage of cpufreq_limit/input_booster).
`Module.symvers` here is for 6.12 drivers that want the notifier/affinity API.

## QEMU proof (`qemu-test/run.sh`, bsp612 dist Image, QEMU virt): PASS, 72 checks, 0 WARN/BUG/oops
Two boots: plain virt dtb (built-in table) and virt + `/soc/argos` from argos.dtsi (minus
interconnects: no provider in QEMU; `/proc/device-tree/soc/argos` then shows 7 `@` entries, node
"wlan0", label "WIFI TX", sysnode as argosd reads them; the platform driver binds soc:argos).
`qemu-test/nttest.c` writes exactly like argosd (one O_RDWR fd, "0x%x%x\n" + NUL) and prints
cflm `info` "[3]" after each step:
start 0 -> WIFI TX 20 Mbps 576000 -> 199 same -> 200 2131200 -> UFS 800 unchanged (902400 < max) ->
WIFI TX 5 (unlock) 902400 (UFS still holds) -> WIFI RX 900 ignored -> index 9 ignored -> UFS 0 -> -1
-> raw 4-byte s32 576000 -> read = 321 (0x141) -> second fd 0xc81: 2131200 (PM_QOS_MAX) -> fd2 closed:
576000 -> "zz" -EINVAL -> last close: -1. Also: loads/works/unloads without cpufreq_limit (weak link,
`cpu: none`), rmmod clean, cpufreq_limit rmmod after it OK, silent with debug=0, 5.4 lines with debug=1.
QEMU has no cpufreq and no interconnect: only the recorded CFLM requests are checked, not real clocks.

## On-phone checks (nothing of this has run)
    lsmod | grep sec_argos; ls -lZ /dev/network_throughput      # system system u:object_r:sec_radio_device:s0
    cat /sys/class/misc/network_throughput/argos_status          # source dt|builtin, cpu: cpufreq_limit, ddr: icc|none
    ls /proc/device-tree/soc/argos                               # boot_device@1..@7 (needs argos.dtsi)
    pidof argosd; logcat -b radio -d -s ARGOS                    # "Argos Daemon Boot", NODE:/LABEL:/INTERVAL: lines, no ERR!
    # Wi-Fi upload > 20 Mbps (e.g. iperf3 -c <pc> on wlan0), then:
    cat /sys/class/misc/network_throughput/argos_status          # [1] WIFI TX level 0/1
    grep '\[3\]' /sys/devices/system/cpu/cflm/info               # min(576000) / min(2131200)
    echo 1 > /sys/module/sec_argos/parameters/debug; dmesg | grep sec_argos
Expected failure modes: argosd still exits -> `logcat -b radio -s ARGOS` says which step (opendir =
DT node missing; "Device doesn't support qos" = module/node missing or not chowned); `requests: 0`
while argosd runs = it opened nothing; `cpu: none` = cpufreq_limit not loaded before sec_argos.

## Files
`sec_argos.c`, `sec_argos.h`, `Kbuild`, `check.sh`, `argos.dtsi`, `qemu-test/{run.sh,init.sh,nttest.c}`,
`out/sec_argos.ko`, `Module.symvers`, `STATUS.md`.
