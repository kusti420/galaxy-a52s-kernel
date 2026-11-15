# kernel-diag: why rb4/rb5 died, and the instrumented rb6

> **SUPERSEDED 2026-11-15 by `../ABL-HANG.md`:** the kernel was never entered. Phone 2's ABL takes a
> data abort in its libufdt (merged-tree output buffer too small for our 661 KB tree + 507 B dtbo), then
> the XBL/UEFI watchdog bites. The hypotheses below (KASLR, vWDT, ...) are untested, not refuted.

Offline analysis of 2026-11-14 22:xx (no phone touched). Builds: `out/rb6` (observe only) and
`out/rb6w` (same + `a52bc.wdt=off`). NOT flashed.

## What happened (logs/rb4-flash1-last_kmsg.txt, logs/rb5-last_kmsg.txt, logs/rb5-flash-prev-console.txt)

- **rb4 behaved exactly like rb5**: 13 "Warm Reset by Watchdog Bite" from 19:20:53 to 19:32:52
  UTC, then a manual key reset and Download mode (the "first-stage mount failure" reading
  of rb4 was wrong: it never got that far). rb5: 5 more bites 19:38:00-19:43:05. Bite to bite
  54-68 s; the ABL reaches ExitBootServices at ~18.8 s, so each kernel ran **35-49 s** until
  the bite (not a fixed time).
- **Not one byte of 6.12 output reached ramoops in 18 boots.** rb5's ramoops layout is the
  harness's (0xf0b00000+0xe0000, record 0x20000: console zone at 0xf0b20000, read by the
  harness at the same place). The harness found the console zone of run **rh618c (21:01
  local, 6.18 kexec Android, audit lines, permissive)**, not a 5.4 log, bit-decayed but
  intact. A 6.12 that reached `ramoops_probe` (0.106-0.127 s in every earlier 6.12 boot,
  including the ABL-started first2 on phone 1) would have appended to it. So the kernel died
  (or never ran) before ~0.1 s, on all 18 boots.
- Side finding: the ABL keeps the first ~1500 lines of every previous boot in last_kmsg
  (XBL + ABL start), not the end: whether these boots reached "Exit EBS" is not recorded.
- Side finding: LineageOS's 5.4 ramoops has the 1 MiB layout (console at 0xf0b40000), so
  `cat /sys/fs/pstore/console-ramoops-0` **from LineageOS never shows a 6.x console**; read
  6.x logs from the harness (/tmp/prev-console.txt) only. (logs/rb4-flash1-pstore.txt is a
  decayed 5.4 log for that reason.)
- DRAM decays a little across "Hard Reset at XBL" / key resets (flipped bits in both pstore
  files): expect garbled characters in anything read back.

## Ranked hypotheses

1. **Early death on the ABL path only (< 0.1 s), most likely in head.S/PI/setup_arch.** Same
   Image + modules + tree boot by kexec, and 6.12 GKI was ABL-booted on phone 1 (first2), so
   it is something only this combination has:
   a) **KASLR with the ABL's seed at the ABL's misaligned load address.** A normal boot gets
      `/chosen/kaslr-seed` (phone 2's live tree has it, zeroed after use); every ABL boot of
      ours so far came from `recovery` without a seed ("KASLR disabled due to lack of seed"
      in first2, rd5, p2-first), the kexec boots had a seed but a 2 MiB aligned image. 6.12
      with a seed at 0xA008xxxx (+N*0x8000, "Kernel image misaligned") never ran.
   b) The ABL-merged tree itself (our 661 KB board tree through libufdt + the hypervisor
      overlay + ABL fixups, never seen by a kernel): an invalid blob makes
      `setup_machine_fdt()` spin in `while (true) cpu_relax();` with no console, i.e. busy.
   c) Placement of a 16 MB ramdisk (8x stock): budget fine (image 0x28a0000 + 0xf63000 in a
      256 MB region ending at 0xB0000000, stock initrd at 0xafe58000 proves the region; no
      reservation between 0xA0002000 and 0xB0100000). Low.
2. **The bite is the hypervisor's virtual watchdog, enabled for the HLOS before the kernel.**
   5.4 binds `/hypervisor/qcom,hh-watchdog` (added by the hypervisor's own overlay) with the
   built-in hh_virt_wdt at 0.43 s. On 6.12 nothing pets it: `gh_virt_wdt` (binds
   `qcom,hh-watchdog`) and `qcom_wdt_core` are modules and blocklisted, `hhwdt` was dropped;
   `/soc/qcom,wdt@17c10000` (qcom,msm-watchdog) is in the tree and the hypervisor overlay sets
   it disabled, as on 5.4. Gunyah's VM watchdog only stops counting when the VM suspends
   (donors/gunyah-hyp watchdog.c: freeze on vpm_system_suspend), and enabling it without
   SET_TIME uses WATCHDOG_TIMEOUT_MAX_TICKS: an ABL-booted harness idling in PSCI deep idle
   would never trip that, so "the harness survived busy transfers" does NOT prove "not
   armed". Early boot has no cpuidle (WFI only) = counted. This explains the BITE, not the
   missing ramoops: it is the reset layered on 1 (or the cause if 1 turns out to be wrong).
3. ABL never jumps (hang in the ABL after the logo, a boot watchdog bites). Weak: UEFI pets
   its watchdog from a timer; no evidence either way (last_kmsg keeps only boot starts).
4. A firmware call of an early built-in (PSCI OSI, SMCCC TRNG, FF-A, gunyah) stalls CPU0 in
   EL3 on phone 2's bit-2 TZ; with one CPU online the hypervisor cannot service its own
   watchdog bark and bites (Gunyah's UEFITZT comment). 6.12 never ran cold on phone 2's
   firmware (only after 6.18 by kexec). Low.

Checked and ruled out: DT/dtbo selection (one dtb with the stock msm-id/board-id, dtbo
`<0x22 2>` hw_rev 2..0x20; a mismatch ends in Download mode, not bites; the user_dtbo/EDTBO
lines are on stock boots too), COMMAND_LINE_SIZE (4096, 3395 B predicted, the rehearsals used
the predicted ABL part), ramoops layout mismatch (identical to the harness), a stall with idle
CPUs in first stage (ramoops would have the log).

## rb6: what is different from rb5 (nothing else)

| | rb6 |
|---|---|
| kernel | `bsp612/out/diag/Image` = the dist kernel (same release 6.12.81-4k-g8a69376da734, all 19062 export CRCs identical, so all 190+33 tested modules load) + `a52bc.c` built in (`build-diag-kernel.sh`, separate build dir, source tree restored) |
| tree | + `/reserved-memory/a52ram@f0be0000` (compatible `a52,ramcon`, no-map, 128 KiB): the range the 6.18 harness already reserves and prints as `/proc/a52ram` |
| DT bootargs | + `keep_bootcon initcall_debug ignore_loglevel softlockup_panic=1` (softlockup_panic was on in every kexec test via helper2.sh) |
| rb6w only | + `a52bc.wdt=off`: disables the hypervisor watchdog at the param stage (logged before/after) |

`a52bc.c` writes into 0xf0be0000 (survives warm resets; the ABL uses 0xf0c00000, not this):
- breadcrumb page (0xf0bff000), one ASCII line per stage: `A52BC1 attempt=N` (N = boots that
  reached setup_arch, carried across resets), `entry` (setup_arch after the fixmap: EL,
  physical _text, KASLR offset, FDT address) + **hypervisor watchdog STATUS** (a1 bit 0 =
  enabled, a2 = time since the last pet), `fdt` (FDT valid, size, whether our node survived the
  ABL, cmdline length), `param` (+ starts the RAM console), `paging` (DRAM range, initrd,
  memstart), `setup_end` (+ STATUS), one `ic:<level>` line per initcall level with STATUS, then
  a **heartbeat** rewritten every second: uptime, STATUS, number of modules, newest and
  still-initialising module, pid 1 comm. The watchdog is only READ in rb6.
- RAM console `a52ram0` (started by the kernel itself, no `earlycon=` for the ABL to strip): the
  first 64 KiB of printk linear, then the last 60 KiB circular (keep_bootcon keeps it after
  the real consoles register).
- Offline proof: `qemu-test.sh` (run by `DIAG=1 build-realboot.sh`) boots the same Image in QEMU
  and checks every line, the console head/tail, attempt=2 after a warm reset (RAM kept), the
  watchdog-off path, and that a tree without the node stops after the `fdt` line.

## Reading the result after a failed rb6 (phone 2)

1. By hand: Vol-down + Power ~7 s (restart; this is the key reset that lets DRAM decay a little),
   then at once Vol-up + Power with USB connected = recovery = the 6.18 harness (black screen,
   172.16.43.1; it leaves for Download mode by itself after 300 s without a login).
2. PC, before anything else (each later boot of LineageOS or the harness keeps the area, but a
   new rb6 attempt overwrites it):

       export TSH_IP=172.16.43.1
       tools/tsh.py -t 25 'cat /proc/a52ram' > logs/rb6-a52ram.txt
       tools/tsh.py -t 25 'cat /tmp/prev-console.txt' > logs/rb6-ramoops-console.txt
       tools/tsh.py 'ls -l /sys/fs/pstore; cat /sys/fs/pstore/dmesg-ramoops-0' > logs/rb6-ramoops-dmesg.txt
       python3 -I drivers612/realboot/tools/a52ram-decode.py logs/rb6-a52ram.txt -o logs/rb6-a52ram-decoded.txt

   then the rollback of README section 3 b) (dd the /cache/a52rb-rollback images, /leave),
   and in LineageOS `adb -s PHONE2 shell su -c cat /proc/last_kmsg > logs/rb6-last_kmsg.txt`
   (reset reasons: bites, or "panic" if softlockup_panic fired).
3. Verdict, from the decoded file:

| What is there | Meaning | Next |
|---|---|---|
| no `A52BC1` page (decoder: "no a52bc breadcrumb page") | kernel never reached setup_arch: ABL did not jump (3) or died in head.S/PI (1a) | rb7 = rb6 + `nokaslr` (`DIAG_BOOTARGS="... nokaslr"`) |
| `entry` but no `fdt` | died in setup_machine_fdt: the ABL-merged FDT is invalid for 6.12 (1b); `fdt=` gives its address | dump/compare the merged tree (size, alignment, 2 MiB limit) |
| `fdt ... ramcon=0` | the ABL dropped our reservation node: its DT processing rewrites /reserved-memory | lead on 1b |
| `wdt? entry a0=0 a1=0x..1` (bit 0 set) | vWDT already ARMED at kernel entry (2) | flash rb6w; for daily use load gh_virt_wdt + qcom_wdt_core in the first stage (or a built-in petter) |
| `wdt? entry` ending without `a0=` | the STATUS call itself hung | drop the call |
| `param`/`paging`/`setup_end`/`ic:*` | the last line = the stage reached; the console head/tail has the printk text up to the end (initcall_debug names the initcall) | follow the log |
| heartbeat `hb#N up=...` | kernel alive until `up`; `mods=/newest=/coming=` first-stage progress; `wdt=1/<rising>` nobody pets | 2 if wdt armed |
| ramoops console = a 6.12 log | the kernel passed 0.1 s on this boot: 1 is wrong, read it | |

`attempt=N` vs the number of bites in last_kmsg tells whether every boot got as far.
