# L3 at 1.4-1.5 GHz on 6.12: causes and fix (2026-11-15, offline; nothing run on a phone)

Observation (rb15/rb16, the private project log 13:45): `bus_dcvs/L3/cur_freq` 1401600-1516800 under light load
and screen-off idle, boost already released (rh618p2 dmesg: `L3=300000/1516800/1401600`).
`cur_freq` is the **software** aggregate of the AP's votes (dcvs.c `show_cur_freq` = max of
`path->cur_freq.ib`), not the hardware clock.

## Ranked causes

1. **The AP's L3 votes go to the wrong register (high confidence on the code, effect unmeasured).**
   yupik.dtsi:1655 `qcom,shared-offset = <0x0920>`; dcvs_epss.c:132 writes the level index to
   `l3-base (0x18590000) + 0x920`. 0x920 is the **OSM** PERF_STATE offset (5.4
   drivers/cpufreq/qcom-cpufreq-hw.c:97, osm-l3.c:26; 6.12 sm8150.dtsi uses it for OSM). yupik's L3
   is **EPSS**: the phone's own 5.4 kernel voted the AP's shared L3 vote at base + 0x90
   (5.4 interconnect/qcom/epss-l3.c:31 REG_L3_VOTE, :117 SHARED = domain 0 cpu 0, :187; consumers
   downstream-dt/a52sxq-r02.dts:3227 snoop-l3-bw, :3320 cpu7 l3 latfloor, :26205 kgsl, all
   `<... 0x48 0x09>` = SLAVE_EPSS_L3_SHARED). Every other EPSS target in the 6.12 BSP uses
   `<0x0090>` (waipio.dtsi:2872, pineapple, chora, ...) and dcvs_epss.c:34 itself defines
   `L3_VOTING_OFFSET 0x90`. lahaina.dtsi:2337 carries the same 0x920 (copied from sm8150). So on
   6.12 neither memlat, bwmon-l3 nor kgsl controls the L3 clock; it runs at whatever the other EPSS
   voters (per-CPU regs, the RIMPS register 0x340 that 5.4's rimps_memlat.c:1463 initialised "to max
   until RIMPS takes over") hold. The 1.4-1.5 GHz number says nothing about the real L3 clock.
2. **The software vote is computed only in busy moments and then held (structural, medium).**
   memlat re-evaluates only from `android_vh_jiffies_update` (memlat.c:1182-1195 -> hrtimer ->
   memlat_update_work :1121), and that hook fires only from the timekeeping CPU's **tick**
   (bsp612/kernel/kernel/time/tick-sched.c:232-235; IRQ-entry/idle-exit jiffies updates do not call
   it). With NO_HZ_IDLE + HZ=250 a mostly idle system recomputes only when some CPU stays busy for a
   full tick, so every computed window contains a burst (gold/prime effective freq >= 1.65/1.77 GHz
   -> 1401600/1516800), and the vote then stays latched through the following tickless idle. There
   is no idle/suspend reset in memlat.c. An `adb shell cat cur_freq` is itself such a burst
   (observer bias). 5.4 did not have this: L3 memlat ran on RIMPS (CPUCP) with its own 3 ms timer
   (post_boot-yupik.sh:235-258, rimps_memlat.c configure_rimps), independent of AP ticks. LLCC
   806-933 at "idle" (gold LLCC rows 1228800-2400000) fits the same bias. Not fixed here (driver
   change or the RIMPS route, see below); measure first.
3. **Idle floor 556.8 MHz instead of 300 MHz (certain, small).** `cpufreq_to_memfreq()`
   (memlat.c:853-869) returns the FIRST row when no CPU qualifies (max_cpufreq 0, :1044), and the
   yupik gold/prime L3 tables start at `<940800 556800>` / `<1056000 556800>` (yupik.dtsi:1862-1879).
   5.4 governor_memlat.c:314 voted 0 there (-> min_freq 300 MHz). Qualcomm's 6.12 lahaina tables
   start with `<300000 300000>` (lahaina.dtsi:2536, :2551).
4. **L3 write-back path inert (no idle effect).** 5.4 gold/prime RIMPS mons had `qcom,wb-ev 0x18`,
   `qcom,access-ev 0x2b` (a52sxq-r02.dts:3517-3548); the 6.12 l3 group only has `qcom,miss-ev 0x17`
   (yupik.dtsi:1841), so `wb_pct` is always 0 and busdcvs.conf's `wb_pct_thres`/`wb_filter_ipm`
   lines do nothing. Only lowers L3 under write-heavy load; adding them needs 0x18/0x2b in
   `qcom,pmu-events-tbl` (PMU counter budget). Left as is.

## Ruled out (same as 5.4)
- cpu -> L3 tables: 6.12 silver/gold/prime/prime-compute rows (yupik.dtsi:1843-1891) = the 5.4
  RIMPS core-dev-tables decoded (a52sxq-r02.dts:3502, :3525, :3548; cpu7_l3_computemon :3449).
- ipm_ceil 400/4000/20000, l2wb 60/25000: busdcvs.conf = 5.4 ratio_ceil/l2wb (post_boot :239-258).
  Miss event 0x17 on both. compute (prime-compute) and memlat groups exist on both.
- sample_ms: 5.4 RIMPS 3 ms; 6.12 one global 8 ms (MIN 4, tick-granular at HZ=250): not a raise.
- OPP floor: the L3 table read from l3tbl-base 0x18590100 starts at 300000
  (logs/ab-s76-busdcvs.txt); dt-fix.sh's SCMI removal never touched an L3 path (yupik 6.12 has
  only the EPSS sp path, no cpucp L3 path).
- bwmon-l3: capped by busdcvs.conf `max_freq 300000` (bwmon.c:836). Boost: released (300000).
- kgsl: votes hw max 1516800 only for a context with an L3 constraint and clears it on slumber
  (adreno.c:983, kgsl_pwrctrl.c:2621-2636); 5.4 had the same max (l3-pwrlevels 1516.8 MHz).
  Not a screen-off cause; it also only takes effect once cause 1 is fixed.

## Fix prepared (DT, in dt-fix.sh)
`drivers612/busdcvs/dt-fix.sh` now also (env switches, default on):
- `A52_L3_VOTE_OFFSET` (default `0x90`, `keep` = Qualcomm's 0x920): `/soc/qcom,dcvs/l3/sp
  qcom,shared-offset` -> 0x90 (cause 1).
- `A52_L3_FLOOR` (default 1): prepends `300000 300000` to `/soc/qcom,memlat/l3/{gold,prime}`
  (cause 3). Idempotent.
Tested offline on a copy of rb16's vendor_boot.dtb: decompiled diff = exactly those 3 lines;
`A52_L3_VOTE_OFFSET=keep A52_L3_FLOOR=0` gives a byte-identical dtb. busdcvs.conf unchanged.

Who picks it up (nothing rebuilt here):
1. `kexec/mkandroidtree.sh` (regenerates `out-ack/kx/android-r02.dtb`) -> a key-free kexec run on
   phone 2 (README.md test command, ramdisk s77) first.
2. Then `DIAG=1 MODEM=1 SDCARD=1 drivers612/realboot/build-realboot.sh rbNN`. It will **fail** the
   "tree differs from the tested" check until step 1 regenerated android-r02.dtb (by design).
3. 6.18: `bsp618/android/mkdtb-618.sh` after step 1, then `KERNEL=618 ... build-realboot.sh`.

Risk: with votes reaching the hardware, L3 now really follows memlat (down to 300 MHz idle, up to
1516.8 MHz on load), as on 5.4. If 0x90 were not the AP voter, nothing changes vs today.

## Measure before/after (the open question is the REAL L3 clock)
- Hardware L3: `insmod debugcc-sc7280.ko` (bsp612/out/dist, not in the module plan; DT node
  yupik.dtsi:1134 exists) in a kexec session first, then
  `cat /sys/kernel/debug/clk/measure_only_apcs_l3_post_acd_clk/clk_measure`. Same file on 5.4 =
  baseline; 5.4 also shows the RIMPS-desired level in
  `/sys/devices/system/cpu/memlat/c{0,4,7}_memlat/cpu*-cpu-l3-lat/cur_freq` (perf-base readback).
- Unbiased software trace: enable `events/dcvs/memlat_dev_update` + `events/dcvs/qcom_dcvs_update` (tracefs),
  screen off 60 s with no polling, then read the buffer: per-mon max_cpu/inst/miss/cpufreq/memfreq
  shows which mon votes and from which windows.

## Next (not done)
- Cause 2 + 3 in the driver: done offline as soc-repo patch 0010, see the next section. The
  RIMPS route (memlat_vendor SCMI protocol v1) is not needed for it.

## Fix for causes 2 and 3: soc-repo patch 0010 (2026-11-15, offline; nothing run on a phone)
Measured first (logs/l3measure-*.txt): with dt-fix `A52_L3_VOTE_OFFSET=0x90` the hw L3 follows
the vote (1.51 GHz = 1516800), and at screen-off idle the vote stays at 1.19-1.52 GHz (real rb16),
DDR 1.55-1.7 GHz, LLCC 806-933 MHz. So the wiring fix alone would raise L3 power.

`bsp612/patches/soc-repo/0010-memlat-drop-the-sampling-votes-when-the-CPUs-go-idle.patch`
(only `drivers/soc/qcom/dcvs/memlat.c`; applied in bsp612/soc-repo and soc-repo-staging like
0007/0009; `assemble.sh` applies it from now on). Line numbers = patched soc-repo memlat.c.

### Options weighed
- (a) **timer-based sampling that keeps running while the system is idle: CHOSEN, as a
  one-shot "idle decay" hrtimer.** A deferrable timer would not help (it never fires while every
  CPU idles, which is exactly the failing case); a free-running timer would wake the SoC
  forever. The one-shot only exists while some vote is above its idle level and is pushed back
  by every regular sample, so busy behaviour is unchanged and steady idle has zero extra
  wakeups.
- (b) cpuidle / PM QoS hook zeroing a group's vote when all its CPUs enter idle: rejected. The
  idle-entry path runs with IRQs off, but the yupik DDR/LLCC/L3 sampling paths are all
  `qcom,dcvs-path-type = <0>` (slow path: icc_set_bw / mutex, yupik.dtsi:1623-1667), so the
  vote would need a work item, i.e. a wakeup anyway. And it changes busy behaviour: a CPU that
  idles for 100 us between bursts (normal interactive load) would lose its vote at every idle
  entry and get it back only at the next tick sample (up to 8+ ms), so L3/DDR would dip in
  the middle of busy periods.
- (c) cpu_pm cluster notifier: rejected, dead on 6.12: nothing in bsp612 (ACK or soc-repo)
  calls `cpu_cluster_pm_enter()` (cluster idle is the PSCI OSI power domain), so
  CPU_CLUSTER_PM_ENTER never arrives. Same busy-dip objection as (b).

### What the patch does
1. **Idle decay** (cause 2). `memlat_arm_idle_decay()` (memlat.c:1163) runs at the end of every
   sampling update (`memlat_update_work`, memlat.c:1253). If any sampling mon's `cur_freq` is
   above `memlat_mon_idle_freq(mon)` (what an all-idle window votes, memlat.c:893), it (re)arms
   `idle_timer` (new hrtimer, CLOCK_MONOTONIC, not pinned) for `max(idle_decay_ms, 2 x
   sample_ms)` = 32 ms with 50 % slack (so it can share another wakeup); otherwise it cancels
   it. Regular samples come every sample_ms = 8 ms while any CPU ticks, each one pushes the
   timer back: it never fires under load. When it fires (memlat.c:1270) and no regular sample
   ran in the last sample_ms, it starts the existing sampling timer immediately on the waking
   CPU (`hrtimer_start(&timer, 0, PINNED)`, so all samples stay serialised through one timer)
   and sets `last_jiffy_ts`, so the tick path keeps its 8 ms spacing. Idle CPUs are counted
   from their idle-entry PMU snapshot (`memlat_pmu_idle_cb`, already there, called from
   `android_vh_cpu_idle_enter` on every idle entry, pmu_lib.c:541-574), with the time since the
   last update as window. So after a burst: 1st decay sample = the burst's tail spread over
   >= 32 ms (low), 2nd = no cycles at all -> idle level; then nothing is armed. Expected: votes
   at their idle level within ~0.1 s after the last CPU goes idle.
2. **Idle vote** (cause 3). `calculate_mon_sampling_freq()` (memlat.c:1046-1083) notes whether
   any CPU of the mon ran (`stats->freq_mhz != 0`). Only if none did, the mon votes
   `memlat_mon_idle_freq()` = its `min_freq` (= hw min unless userspace raised it) instead of
   `cpufreq_to_memfreq(mon, 0)` = table row 0. Any window in which a CPU of the mon ran is
   computed exactly as before (also row 0 for busy CPUs that do not qualify by ipm), so busy
   behaviour is identical.
3. Module parameters (0644, `/sys/module/memlat/parameters/`, or cmdline
   `memlat.idle_decay_ms=0 memlat.idle_min_vote=0`): `idle_decay_ms` (default 32, 0 = off),
   `idle_min_vote` (default Y). Both off = Qualcomm behaviour bit for bit (with
   idle_min_vote=N the idle path returns cpufreq_to_memfreq(mon, 0), the old value), for A/B
   on the same boot.

### DDR and LLCC: the floor fix belongs there too (5.4 did the same)
6.12 tables: every DDR mon starts at 451000 (yupik.dtsi silver/gold/silver-compute/
gold-compute/prime-compute), LLCC silver/gold at 300000, gold-compute 150000; hw minima DDR
200000, LLCC 150000, L3 300000, DDRQOS 1 (logs/ab-s76-busdcvs.txt). The compute mons vote row 0
for *any* window, so on 6.12 DDR can never go below 451 MHz from memlat, even fully idle.
5.4 (the phone's own kernel, read-only):
- DDR/LLCC memlat ran on the AP: `governor_memlat.c:264-329` skips cores with freq 0
  (`:293`), converts only a non-zero max (`:314`) and returns `*freq = 0` otherwise (`:328`);
  this holds for the `compute` latfloor governors too (same get_target_freq, `:447-451`).
  freq = cycles / window (`arm-memlat-mon.c:212`), so an idle window gives 0.
- devfreq clamps 0 to min_freq, and the ROM sets every memlat/latfloor min_freq to the first
  available frequency (`init.kernel.post_boot-yupik.sh:315-341`, `cat available_frequencies |
  cut -f1 > min_freq`). Lowest OPPs: DDR `opp-200` (762 MB/s, opp-supported-hw 0x180 = both
  DDR types), LLCC `opp-150` (a52sxq-r02.dts:3064-3150). The 5.4 tables' first rows equal
  6.12's (0x6b8 = 451 MHz for DDR lat + latfloor, 0x11e1 = 300 MHz / 0x8f0 = 150 MHz LLCC,
  a52sxq-r02.dts:3340-3480).
- So 5.4 voted DDR 200 MHz / LLCC 150 MHz from memlat for every window without CPU cycles,
  and patch 0010 lowers exactly that and nothing else (busy CPUs keep row 0 = 451 MHz DDR from
  the compute mons, as on 5.4, whose latfloor tables start at the same 451 MHz).
- Display/modem/GPU/bwmon are unaffected: memlat's DDR vote is one CPU-side ICC path
  (`ddr_dcvs_sp`: MASTER_LLCC -> SLAVE_EBI1, the same path as 5.4's cpu*-llcc-ddr-lat
  `<0x20 0x03 0x20 0x200>`); MDSS, modem, GPU and bwmon-ddr have their own ICC/RPMh votes and
  the interconnect framework/BCMs aggregate with max. 5.4's own memlat polling was a deferrable
  work (arm-memlat-mon.c:600, 8 ms): it re-evaluated at the next wakeup of that CPU, so 5.4
  also dropped these votes during idle; the 6.12 decay is at least as eager.
- L3: row 0 of gold/prime (556800) = the 5.4 RIMPS core-dev tables, so 0010 does not change
  busy-but-slow gold/prime CPUs; fully idle ones vote 300000 (hw min). dt-fix `A52_L3_FLOOR=1`
  (an extra `<300000 300000>` row from Qualcomm's lahaina tables) is therefore NOT needed for
  idle and goes below 5.4's tables for slow busy gold/prime CPUs: keep it 0 unless a 5.4
  baseline says otherwise.

### Build (bsp612, `./build.sh soc`)
Incremental: only memlat.o rebuilt, 0 warnings (out/soc.log), all other 271 soc-repo .ko
byte-identical, `soc-repo-staging/build/Module.symvers` unchanged (sha256 2940aee6...; memlat
exports nothing), vermagic `6.12.81-4k-g8a69376da734 SMP preempt mod_unload modversions
aarch64`, depends unchanged (qcom_scmi_client,qcom-dcvs,qcom-pmu-lib). New imports
hrtimer_init/hrtimer_start_range_ns/hrtimer_try_to_cancel are in the GKI Module.symvers
(TRIM_UNUSED_KSYMS off). bsp612/kernel untouched (no -dirty). out/dist not re-collected.
- unstripped: `bsp612/soc-repo-staging/drivers/soc/qcom/dcvs/memlat.ko` sha256 2c02171f44b3...
- stripped (llvm-strip --strip-debug = dist's INSTALL_MOD_STRIP; reproduces the old dist hash
  8a78ac58... from the old .ko): `drivers612/busdcvs/out/memlat.ko` sha256
  8a2e3c8144d759f8f8a12786926fb8b16a10c92bdaa014ae0333b49fa917ee5f, 115912 bytes.
- 6.18 not done: bsp618/src carries its own copy of memlat.c (apply 0010 there, as 0009 was).

### Test (kexec, phone 2, key-free; nothing flashed)
Ramdisk = s79 with only memlat.ko replaced (already built, sha256 277a8888...):

    python3 -I drivers612/realboot/tools/rd-swap-ko.py drivers612/androidboot/out/s79-rd.cpio.gz \
      drivers612/androidboot/out/s79m-rd.cpio.gz drivers612/busdcvs/out/memlat.ko
    # -> replaced a52/mods/dcvs/memlat.ko (113680 -> 115912 bytes)

Tree with the wiring fix and NO extra floor row (built, sha256 ce44309b...; decompiled diff vs
android-r02.dtb = only `qcom,shared-offset = <0x90>`):

    cp out-ack/kx/android-r02.dtb out-ack/kx/android-r02-L3drv.dtb
    A52_L3_VOTE_OFFSET=0x90 A52_L3_FLOOR=0 drivers612/busdcvs/dt-fix.sh out-ack/kx/android-r02-L3drv.dtb

Run (kexec 6.12 Android, as l3fix), then measure after boot_completed + the post script:

    A=drivers612/androidboot; PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img \
    KEXEC_BASE=out-ack/kx/android-r02-L3drv.dtb KEXEC_OVERLAY=none KX_HOLD=1 kexec/kx-cycle.sh l3drv \
    bsp612/out/dist/Image $A/out/s79m-rd.cpio.gz gen "$(cat $A/out/android-cmdline.txt) log_buf_len=8M \
    a52.deadman=900 a52.mods=debug,secure,display,kgsl,dcvs,video,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,susp,audio@adsp,wlan@adsp"
    PHONE=2 AB=1 drivers612/busdcvs/l3measure.sh l3drv-612

l3measure.sh now reads with the shell's builtin `read` right after each `sleep 3` (no fork
before the hardware read), prints the memlat parameters, and with AB=1 repeats the 10 samples
with both parameters 0 on the same boot. Expected with 0010 (screen off, 60 s idle):
`hw_l3` ~300 MHz (ring oscillator ~2.9-3.1e8; was 1.18e9 old DT / 1.51e9 with 0x90),
`sw_l3=300000`, DDR memlat share 200000 (bus_dcvs/DDR/cur_freq is the max over all voters, so
it may sit higher if bwmon votes), LLCC 150000; in the B half (0010 off) the old 1.19-1.52 GHz.
Unbiased cross-check: tracefs `events/dcvs/memlat_dev_update` during 60 s without polling: after
the last burst, two updates <= ~100 ms apart ending at the min freqs, then silence (no periodic
decay samples). Watch for: any change in UI smoothness with the screen on (busy path should be
unchanged), DDR-related display underruns (`sde ... underrun`) at idle, which 5.4 never needed.
Only after that: `A52_L3_VOTE_OFFSET=0x90` + memlat 0010 together into a real-boot build
(build-realboot.sh REF=<the tested ramdisk>), never the offset alone.

## Who holds the L3 at 1190.4 MHz on 6.12 (2026-11-15, offline; nothing run on a phone)
Measured (the private project log 17:00, logs/l3measure-rh612p1l3.txt): AP vote 556.8 MHz, hw L3 1189-1190.4 MHz
in 20 of 20 samples, 0010 on and off. 1190400 = L3 LUT index 7 exactly (LUT logs/ab-s76-busdcvs.txt:
300000 556800 652800 768000 844800 940800 1056000 **1190400** 1305600 1401600 1516800). With the AP
at idx 10 the hw read 1516.8 (l3fix run), with the AP at idx 1 it reads 1190.4: the EPSS takes the
max over its ports and one port sits at a **constant** idx 7 (a running governor would move).

### (1) The voter, ranked
1. **CPUCP (RIMPS) L3 vote port 0x18590340, stale at idx 7 since boot (high, not yet read back).**
   - 5.4: all three RIMPS L3 mons have `perf-base` = 0x18590340 (a52sxq-r02.dts:3500/3523/3546).
     rimps_memlat.c:1461-1464 writes `l3_pstates` (= max idx 10) there at each mon probe "until RIMPS
     takes over"; RIMPS takes over when scmi_memlat_probe (memlat_scmi.c:15-24) -> rimps_memlat_init
     (rimps_memlat.c:1175) -> configure_rimps (:1022-1145) has sent SET_CPU_GROUP..START_MONITOR
     (5.4 boot: arm-scmi at 0.70 s, logs/rb5-last_kmsg.txt:342). From then on the firmware owns the
     register; `cur_freq` of the 5.4 mon is a readback of it (:338-350, mask 0x3f).
   - CPUCP firmware (phone 1's own, FWK4 BL tar `cpucp.elf`, RISC-V, disassembled with
     llvm-objdump --triple=riscv32; SAGYA2 copy in research/bl-scout/fw identical in this respect):
     the ONLY store to 0x18590340 is `sw a5,0x340(a4)` at 0x3bde in the L3 aggregator (0x3b36: max
     over the configured mons' votes -> LUT index -> write if changed). It is called from the sample
     loop (0x3fe4) and from the SET_MIN/SET_MAX handlers only when the mon state is 2 = started
     (0x4614-0x4626). The other EPSS store (0x54c4: `0x18590340 + (d << 12)`) is called only with
     d = 1..3 (CPU domains: PLH perf-lock, protocol 0x81). So with no HLOS configuration (6.12: we
     removed protocol@80, and its messages would not parse anyway) CPUCP never writes the L3 port,
     and nobody else does: whatever boot left there (idx 7) stays forever.
   - 6.12 writers into 0x18590000-0x18593fff, all checked: dcvs_epss.c:132 (shared offset only;
     yupik has no percpu path, yupik.dtsi:1645-1657), qcom-cpufreq-hw.c:208-212/279-283 (0x320
     + 4n of domains 1-3), qcom_cpucp.c:68-70 (irq status/clear 0x30c/0x308), nothing at 0x340.
     The qcom-dcvs boot boost goes through the same 0x90 commit and is released (busdcvs.conf).
     Who writes idx 7 at boot is unknown: no literal 0x18590000/0x18590340 (nor a movz of 0x1859)
     in xbl.elf, xbl_config.elf, abl.elf; reset default or XBL table-driven.
2. Per-CPU L3 vote registers 0x1090-0x109c / 0x2090-0x2098 / 0x3090 (5.4 epss-l3.c:36-39,
   :109-116) left by boot (low): no 6.12 writer, 5.4 had nodes but no DT consumer.
3. A port outside the 16 KiB EPSS block (other EE, e.g. hypervisor/TZ) (low): only if the dump
   shows no register at idx 7.
The read-only dump below decides between them in one run.

### Read-only register dump module (built, not loaded anywhere)
`drivers612/debug/epssdump/epssdump.c` (+ Kbuild). ioremap only (no request_mem_region), readl
only. Prints at load (`samples` x `interval_ms`, default 3 x 200 ms) and on every read of
`/proc/epssdump`: the four LUTs decoded; per domain 0..3 (L3, silver, gold, prime) ENABLE 0x000,
DBG_STATUS 0x01c, PSTATE_STATUS 0x020 (bits 7:0 = running L-val; x 19.2 MHz = the real clock, a
second hw measurement next to debugcc; cpufreq-hw reg_domain_state), VOTE0-3 0x090-0x09c,
DCVS_CTRL 0x0b0, DBG_SRB 0x0bc, IRQ_STATUS 0x30c, PERF_STATE 0x320, CPUCP_VOTE 0x340, CYCLE_CNTR
0x3c4 (index registers decoded to kHz), domain 0 +0x920 (the old DT's write target), a 1 ms
cycle-counter delta; with `sram=1` (default) the SCMI shmem 0x18509400 (last SCMI message),
the 5.4 PMU cache 0x185098e0 and the CPUCP log 0x18509c00 (all in the one AP-accessible page the
6.12 SCMI/cpucp_log nodes already map). `full=1` (opt-in) adds every word of 0x000-0x3fc per domain
and 0x900-0x9fc of domain 0 (unnamed offsets). CPUCP's private RAM (0x1850b000+) is NOT read
(XPU risk).
- built against bsp612/out/lahaina, 0 warnings, vermagic `6.12.81-4k-g8a69376da734 SMP preempt
  mod_unload modversions aarch64`, depends none.
- stripped (llvm-strip --strip-debug): `drivers612/debug/epssdump/out/epssdump.ko` 36616 B, sha256
  a6a64ac652f954dcfc4373b3152a120fa57227453cdf18210066180edbc6bd7c (unstripped
  `drivers612/debug/epssdump/epssdump.ko` 9b2e09bc5cde95da59ab1fc9df5df17d2c83666f1c3afca803b054f5fbbe4b68).
- For step 2 of the test plan only (WRITES one register): `drivers612/debug/epssvote/epssvote.c`,
  `insmod epssvote.ko off=0x340 idx=0`; offsets limited to 0x340 and the per-CPU L3 votes, idx <
  LUT length, rmmod writes the original value back (`keep=1` = no restore). Stripped
  `drivers612/debug/epssvote/out/epssvote.ko` sha256
  d3a227232fda5d149d491c1a177a77358700f0ac984dd5f1b764cbbe2bd7a48a. Same vermagic.

### (3) Fixes, ranked
A. **Release the CPUCP L3 port from the AP once (cheapest; recommended if the dump shows
   0x340 = 7).** The inverse of 5.4's "init to max until RIMPS takes over" (rimps_memlat.c:1464):
   on 6.12 RIMPS never takes over, so the AP writes the lowest index (0) to 0x18590340 and the AP's
   own 0x90 vote (memlat + 0010, kgsl, bwmon) becomes the only one. Proposed implementation: soc-repo
   patch 0011 in dcvs_epss.c `setup_epss_l3_device()` (shared path, after init_epss_data): if the
   sp node has `qcom,cpucp-l3-release-offset = <0x340>`, `writel_relaxed(0, l3_base + off)` + one
   pr_info; dt-fix.sh switch `A52_L3_CPUCP_RELEASE=1` adds the property (default off until step 2
   passed). If step 3 shows the value comes back after suspend, also rewrite it from a PM resume
   notifier. Effect: idle L3 556.8 MHz (row 0 of gold/prime with 0x90 + 0010) or 300 MHz, as 5.4's
   RIMPS (min_freq = l3_freqs[0], post_boot-yupik.sh:236-258). Under light load the L3 goes below
   today's 1.19 GHz floor: that is 5.4 behaviour, check UI smoothness.
B. **SCMI-only cheap fix: none exists.** No single message lowers the floor: SET_MIN_FREQ/
   SET_MAX_FREQ only re-run the aggregator for a started mon (firmware 0x4614-0x4626), and starting
   one mon without PMU maps would vote from garbage counters.
C. **(2) Port the 5.4 memlat-v1 SCMI client so RIMPS runs L3 memlat with 5.4's tables (full
   parity; only if A fails or for the 3 ms tick-independent sampling).** Messages, protocol 0x80
   (memlat_vendor.c:16-34): 0x03 SET_LOG_LEVEL; 0x10 SET_CPU_GROUP and 0x11 SET_MONITOR {cpumask
   (MPIDR aff1 bits), mon_type 1/2}; 0x12 COMMON_PMU_MAP and 0x13 MON_PMU_MAP {cpumask, type, nr,
   u32 hw counter idx[24]} (inst 0x08/cyc 0x11/stall; miss 0x17/wb 0x18/access 0x2b); 0x14
   RATIO_CEIL, 0x15 STALL_FLOOR, 0x16 L2WB_PCT, 0x17 IPM_FILTER, 0x18 SAMPLE_MS, 0x1a MIN_FREQ,
   0x1b MAX_FREQ {cpumask, type, val; freqs in Hz}; 0x19 FREQ_MAP {cpumask, type, nr, {cpu MHz,
   L3 Hz}[14]} (= core-dev-tables a52sxq-r02.dts:3502/3525/3548); 0x1c START / 0x1d STOP; 0xff
   GET_DATA (debug). Boot sequence = 3 groups x ~12 messages (configure_rimps).
   Size and obstacles: (i) GKI built-in SCMI: base.c:208-212 aborts the protocol list because this
   firmware's BASE attributes report fewer protocols than it lists, and driver.c:2291 only searches
   `num_protocols` entries -> every protocol "not implemented" (logs/ab-s76-dmesg.txt:951-954; 5.4
   base.c/driver.c:629 never trusted num_protocols). Needs a ~10-line kernel patch (raise
   num_protocols to the listed count, allocate prot_imp for the max) = vmlinux change
   (assume-unchanged trick for the release string); 6.18 has the same code (ack base.c:210,
   driver.c:2326). (ii) qcom_scmi_client defers memlat/pmu-lib forever while a reg 0x80 child
   exists (README cause 4) and would bind the 6.12 vendor ops to our protocol: soc-repo patch
   (ignore a 0x80 node marked legacy). (iii) New protocol module (as qcom_scmi_vendor.c, ~250
   lines) + client (rimps_memlat.c minus 5.4 sysfs, ~800 lines: per-CPU pinned perf events,
   hw.idx -> PMU maps, cpu_pm enter/exit and hotplug saving counters into the 0x185098e0 cache
   with the valid flag, rimps_memlat.c:630-885). (iv) PMU budget: pmu_lib already holds inst/cyc/
   0x17/0x2A per CPU (yupik.dtsi:1554-1559); gold/prime would need 0x18 + 0x2b too: own events
   exceed the 6 programmable counters, so the client must reuse pmu_lib's events (hook/export
   of hw idx). Then drop the AP l3 memlat group or keep both (max). Estimate 1-2 days, three
   trees (GKI, soc-repo, new modules) and again for 6.18. Not started.

### Test plan (next phone session; phone 1 on rb19, real 6.12, adb root; key-free, no flash)
1. **Read.** Push `epssdump/out/epssdump.ko`; screen off 60 s (as l3measure.sh), then
   `insmod epssdump.ko samples=10 interval_ms=500; dmesg | grep epssdump` and one
   `cat /proc/epssdump` with the screen on. Expect d0 PSTATE_STATUS L-val 62 (1190.4 MHz),
   d0 VOTE0 (0x90) idx 1. The register at idx 7 is the voter: d0 CPUCP_VOTE -> step 2 with
   off=0x340; a per-CPU VOTEn -> step 2 with that offset; none -> rank 3, stop (fix C or more
   digging). Also note the CPU domains' CPUCP_VOTE (0x1340/0x2340/0x3340: stale perf-lock floors
   would pin cluster clocks too) and the cpucp-log text.
2. **A/B on the same boot.** `insmod epssvote.ko off=<from 1> idx=0`, then
   `PHONE=1 drivers612/busdcvs/l3measure.sh l3cpucp-612` (screen off 60 s, 10 samples) + `cat
   /proc/epssdump`: expect hw_l3 = the AP vote (556.8 MHz, L-val 29) instead of 1190.4; a short CPU
   load must still raise it (AP votes reach the L3 since rb19). `rmmod epssvote` -> back to 1190.4
   (proves causality).
3. **Persistence.** `insmod epssvote.ko off=<from 1> idx=0 keep=1`, 10 min screen-off idle and
   one real suspend, then `cat /proc/epssdump`: the port must still read 0. On the real boot the
   phone cannot suspend with USB attached (dwc3 -EBUSY, no a52susp in rb19): either `adb tcpip`
   + owner unplugs the cable for ~5 min, or a kexec session with stage `susp` and
   `PHONE=1 drivers612/suspend/run-level.sh s2idle-shallow` (drivers612/suspend). Pass -> implement fix A (soc-repo 0011 + dt-fix switch) in the next
   rb, rehearse, flash; port reverted after resume -> fix A plus a resume rewrite. Reboot clears
   all test writes.
