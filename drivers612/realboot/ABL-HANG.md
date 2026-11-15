# Why rb4..rb8 never started: the ABL crashes while merging our device tree

Offline analysis, 2026-11-15 (no phone touched, nothing flashed). Scope: phone 2 (PHONE2,
ABL A528BXXS2DWB5 = "bit 2"), direct boot from `boot` (v3) + `vendor_boot` (v3) + `dtbo`.

## Result

**The kernel was never entered. Phone 2's ABL takes a data abort (NULL pointer) inside its own
libufdt while it re-serialises the merged device tree, about 18.1 s after power-on. Then the
UEFI/XBL watchdog bites (~33 s later), and the cycle repeats.** The cause is the size of the
output buffer. The old libufdt allocates `out = totalsize(base dtb) + sum(totalsize(overlays))`
and rewrites the whole merged tree into it. Its string table keeps only exact-name duplicates
(dtc and libfdt also merge suffixes), so the same tree needs about 1.1 KB more strings. Stock
(466 KB base + 256 KB dtbo entry) has 65 KB to spare. Ours (661 KB base + a **507-byte** dtbo
entry + the hypervisor's 1272 bytes) is about 140 bytes short. When the struct block runs into
the strings, `_fdt_grab_space()` returns NULL, `prop->fdt_tag_ptr = NULL`, and
`ufdt_node_dict_add()` dereferences it.

Confidence: very high. A host build of the same libufdt source, given rb4/rb5's own dtb and
dtbo, crashes at the same property, with every header value the phone's crash dump shows
(table below). Stock, the 6.18 harness and phone 1's `first2` all fit in the same emulator.

**Fix:** give the dtbo entry free space (`dtc -@ -p 65536`). Emulated slack is then 65,399
bytes (stock: 66,651). Then gate every build with `tools/ufdt-host/check.sh`.

This invalidates the kernel-side conclusions of `kernel-diag/README.md`:
- "each kernel ran 35-49 s" is wrong. The failed boots never print `Shutting Down UEFI Boot
  Services`.
- The missing a52bc breadcrumbs (rb6), the `nokaslr` test (rb7) and the small ramdisk (rb8)
  tell us nothing about 6.12.
- The bite is not the hypervisor's VM watchdog.

## 1. Evidence on the phone (`logs/rb4-flash1-last_kmsg.txt`, `logs/rb5-last_kmsg.txt`)

The ABL keeps the start of every boot, including the exception dump that ends it. Every failed
boot (14 in the rb4 log, 7 in the rb5 log) ends like this:

```
{ 18076191 }[ ABL ] Hyp version: 1
{ 18076587 }[ ABL ] Memory Base Address: 0x80000000
{ 18087415 }[ ABL ] Override DTB: GetBlkIOHandles failed loading user_dtbo!
{ 18087781 }[ ABL ] EDTBO check fail
data fault: @ 14E18681 PC at 0x9CB3D1A0, FAR 0x0, iss 0x7
ESR 0x96000007: ec 0x25 ...          (data abort, same EL, level-3 translation fault at VA 0)
X1 2000  X2 1F05A416B  X10 A1D46  X23 4  X24 FFFF0186  X25 91EC8  X26 A1D86  X27 40  X28 13 ...
{ 51527310 }[ XBL ] WDog ALRT on 1, Cpu 0, Act 3 ...
** XBL(488, warm reset, valid magic) **      ... "Warm Reset by Watchdog Bite"
```

A good boot (LineageOS 5.4, same log, boot 502; the harness in `testdev-PHONE2/last_kmsg-p2-first.txt`)
continues after `EDTBO check fail` with `Apply Overlay total time: 334 ms` (harness: 46 ms),
`Final Dtb version`, ICCC/HDM, `sec_update_cmdline`, ..., `Shutting Down UEFI Boot Services`.
Our boots never print `Apply Overlay total time`. The failure is inside ApplyOverlay, which
runs before the kernel is even placed. The ABL's `dto_print()` prints nothing, so the libufdt
error line itself does not appear.

All 21 dumps have the same register values: X25 0x91ec8, X26 0xa1d86, X27 0x40, X10 0xa1d46,
X23 4, X24 0xffff0186. Only the load address changes (PC 0x9CB2A1A0 / 0x9CB391A0 / 0x9CB3D1A0 /
0x9CB3F1A0 / 0x9CB461A0: always `...1A0`, LR always `...FE0`). So the crash is deterministic
and does not depend on timing or the kernel.

## 2. Where in the ABL (bit-2 LinuxLoader, carved for this analysis)

`stock-firmware/fw-DWB5/` (the phone's own firmware, A528BXXS2DWB5): BL tar -> `abl.elf` ->
FV LZMA -> LinuxLoader PE (built "Feb 15 2023"), in `research/bl-scout/dwb5/` (gitignored;
regenerate with the `research/bl-scout/scripts` carve.py / pe.py / dis.py recipe of
`research/bootloader-acceptance.md`). The code is the same as the SAGYA2 ABL of that study,
about 0x50 bytes lower. The study's tables apply to phone 2.

PC ≡ 0x1A0 and LR ≡ 0xFE0 (mod 4 KiB) match exactly one bl/load pair in the image:

| RVA | code | source (`donors/abl-edk2/EmbeddedPkg/Library/LibUfdt`, same library) |
|---|---|---|
| 0x43b60-0x43bc4 | `_fdt_grab_space` inlined: `w25`=size_dt_struct, `w26`=totalsize, `w27`=off_dt_struct, `w0`=size_dt_strings; on overflow `str xzr,[x20]` | `fdt_internal.h` `fast_fdt_sw_property()`: `*prop_ptr = _fdt_grab_space(...)` = NULL |
| 0x43c88 | "Not enough space for the string space: %d" (silent) | `ufdt_node.c` `output_property_to_fdt()` |
| 0x43c98 | `bl ufdt_node_dict_add`, return address **0x43fe0**... | ... it is still called with the broken node |
| 0x44190/0x441a0 | `ldr x8,[x2]` (node->fdt_tag_ptr = 0), **`ldr w0,[x8]` = the fault** | `ufdt_node_dict.c` `_ufdt_node_dict_find_index_in_ht()` -> `tag_of(node)` |
| 0x3e180-0x3e22c | `dto_malloc(main + sum(overlays))`, then `ufdt_to_fdt(tree, out, that size)` | `ufdt_overlay.c` `ufdt_apply_multi_overlay()` (the only apply function in this ABL) |

Register decode: totalsize (X26) = **0xa1d86** = rb4/rb5 base 0xa1693 + dtbo entry 0x1fb +
**0x4f8 (1272 bytes) of hypervisor overlays**. off_dt_struct (X27) = 0x40, X10 = X26 − X27.
size_dt_struct at failure (X25) = 0x91ec8. Strings (X24 = −0xfe7a) = 0xfe7a. Property length
(X23) = 4. X1/X19 = 0x2000 = 8192-slot dict. X2 is an odd node pointer (bump allocator without
alignment).

## 3. Exact offline reproduction (`tools/ufdt-host/`)

`ufdt_host.c` + `sysdeps_host.c` compile the donor's libufdt unchanged, with the ABL's 5 MiB
bump allocator (`PRE_ALLOC_BUFFER_SZ`, no free, no alignment), and call
`ufdt_install_blob` + `ufdt_apply_multi_overlay` as ApplyOverlay does. A NULL dereference
becomes SIGSEGV and is reported as `ABL-CRASH`. `hyp-overlay-p2.dts` stands in for the
resource manager's overlays. It contains what phone 2's live 5.4 tree shows the RM added
(`/hypervisor` with its 3 children, wdt `status`, timer `always-on`) and is padded to the
measured 1272 bytes. For rb5 the host run stops at **struct 0x91ec8, strings 0xfe7a,
totalsize 0xa1d86, off_struct 0x40, len 4** (property
`/hypervisor/qcom,resource-manager-rpc/qcom,tx-message-size`). That is byte for byte the
phone's crash. `check.sh --selftest` checks this.

| Case (phone 2 hypervisor) | base | dtbo entry | out buffer | result |
|---|---|---|---|---|
| stock 5.4 yupik + r02 (boots) | 466,165 | 256,201 | 0xb0ab6 | fits, **66,651 B slack** |
| 6.18 harness, recovery (boots) | 170,986 | 860 | 0x2a43e | fits, **1,115 B slack** (thin!) |
| phone 1 `first2` 6.12 (booted on phone 1; here phone 2's hyp) | 345,882 | 7,936 | 0x56b12 | fits, 4,325 B |
| rb4 = rb5 (bites) | 661,139 | 507 | 0xa1d86 | **ABL-CRASH** at struct 0x91ec8 |
| rb6, rb7 = rb8 (bites) | 661,416 / 661,432 | 507 | | **ABL-CRASH** |
| rb618-2 (6.18 realboot, never flashed) | | 507 | | **ABL-CRASH** (would fail the same way) |
| rb7 tree + dtbo padded 128..136 B | | | | `ufdt_to_fdt` fails at `fdt_end_node` -> "ufdt apply overlay failed" -> Download mode |
| rb7 tree + dtbo padded 4 KiB / 16 KiB / **64 KiB** | | | | fits, 3,959 / 16,247 / **65,399 B**; pre-buffer 1.4 of 5 MiB |

Why our images are short:
- The buffer grows only by the overlays' totalsize. The stock dtbo entry is 256 KB and mostly
  redundant, so the stock buffer has room to spare. Ours is 507 bytes.
- libufdt re-emits prop names with exact-match dedup only: +1,096 bytes on our 3,533 names
  (dtc's suffix merging is undone).
- `build-realboot.sh:383` repacks the base with `dtc -I dtb -O dtb` "(fdtput leaves slack)".
  That removed the free space that would have counted towards the buffer.
- The hypervisor overlay appends `/hypervisor` (640 struct bytes) last, so the overflow hits
  its last properties.

## 4. The other suspects of the task, checked

| Item | Finding |
|---|---|
| Image header | flags 0xa in all four kernels (LE, 4K, bit 3 "anywhere"). text_offset 0 for 6.12 (rb*), 6.12 first2 and 6.18 harness, 0x80000 for 5.4. image_size 0x28b0000 (rb6-8 diag), 0x28a0000 (dist), 0x27e0000 (first2), 0x2be0000 (harness), 0x31b5000 (5.4). The ABL ignores text_offset (base + 0x80000 + N·0x8000) and checks only ARMd + image_size, which fits (REPORT: 0x381b000 of 0x517e000). Not the cause. |
| Compression | all raw Image (MZ/ARMd), the ROM too. The ABL only inflates gzip. Not the cause. |
| dtb selection | our single dtb has the stock base's `qcom,msm-id <0x1db 0x10000 0x203 0x10000>`, `qcom,board-id <0 0>`; dtbo `<0x22 2>`, rev 4 -> match. The ABL got past selection (it reached ApplyOverlay). Only `androidboot.dtb_idx` changes 36 -> 0. |
| /memory, hypervisor overlay on a non-stock tree | the hyp overlay itself applies (its target paths exist in our tree). The crash is in the re-serialisation that follows, i.e. "a malformed merged tree would be silent" in the form of a crash, not a bad tree. |
| v3 vs v4 | ours and the ROM's are both v3, same header values (control rebuild byte-identical). |
| AVB orange | the failed boots print the same "AUTHENTICATE fail but allow ... boot/dtbo/vendor_boot", "IsUnlocked : (1)", "Skipping boot verification" as stock. Not the cause. |
| x0 / FDT placement | never reached. The ABL copies the merged tree to DeviceTreeLoadAddr = ramdisk − 0x201000, inside the 0xA0000000 kernel region (< 4 GiB, page aligned), the same as for the harness. The 0x1_F05x_xxxx addresses in the dump (X0/X2/X20) are the ABL's pre-buffer heap, not the hand-over. |
| GKI 6.12 early code (PI, map_fdt, kaslr) | no information yet: no 6.12 instruction ever ran on these boots. |

## 5. Ranked causes

1. **ABL libufdt output-buffer overflow on our tree (rb4..rb8, rb618-2): proven.** Fix: pad
   the dtbo entry; gate with `check.sh`.
2. Residual risks of the first boot after the fix. Each is a guess, none is observed:
   a) 6.12 with an ABL `kaslr-seed` at the ABL's misaligned load address (every earlier ABL
      boot of a GKI kernel came from `recovery` without a seed; kexec boots are 2 MiB aligned);
   b) the hypervisor VM watchdog, if the ABL arms it on a normal boot (the old rank 2; no
      petter in our first stage);
   c) something in the ABL after ApplyOverlay (UpdateDeviceTree on our tree: `/memory`,
      `/chosen`, `/reserved-memory` exist and the harness trees pass; a fatal error there goes
      to Download mode, not bites);
   d) the 6.12 kernel stage itself on phone 2's firmware (cold, without the 6.18 harness
      having run first).
3. Watch the harness: its tree has only 1,115 bytes of slack. Growing the harness dtb by
   about 1 KB (or a bigger hypervisor overlay after a firmware change) would break `recovery`
   the same way and lock out the rollback path. Pad its recovery dtbo too.

## 6. Proposal

### Build change (not applied here)
- `build-realboot.sh:406`: `dtc -q -@ -p 65536 -I dts -O dtb -o "$W/realboot.dtbo" ...`
  (mkdtboimg records the padded totalsize as the entry size, which `ufdt_apply_multi_overlay`
  requires). The kernel sees the 64 KiB only as free space at the end of its FDT. Merged size
  0xb1eab is far below the ABL's 0x201000 limit.
- After it: `tools/ufdt-host/check.sh "$W/vendor_boot.dtb" "$W/realboot.dtbo" 16384 || fail`
  (selftest once per build).
- `mkimage-ack.sh:20`: same `-p` for the harness overlay, and the same check (min 1024 there
  until padded).

### Testing, honestly
- **Key-free, now:** `check.sh` runs the exact ABL code that crashed (same source, same
  allocator, crash reproduced byte-exact). This proves the overlay step of a padded rb9 offline.
  It cannot prove anything after ApplyOverlay.
- **Key-free, harness running (normal kx-cycle entry, read-only):** dump `/sys/firmware/fdt`
  of the harness. It is the ABL's real merge of the harness dtb + recovery dtbo + the
  hypervisor's overlays (totalsize = out buffer + 2048 + strlen(cmdline), from UpdateDeviceTree's
  `fdt_open_into`). Use it to (1) confirm the 1272-byte hypervisor list, (2) diff against
  `ufdt-host` output for the same inputs (outside /chosen, /memory, uh_* and ddr props),
  validating the emulator on a real successful merge too.
- **Key-free with the crash guard (kexec):** risk 2a can be rehearsed. Use `kexec_load` (not
  `kexec_file_load`, which aligns the Image to 2 MiB; `tools/kx.c` would need a
  segment-list mode). Put the 6.12 diag Image at an ABL-like address (2 MiB boundary
  + 0x80000 + N·0x8000) and the `ufdt-host`-merged tree with an ABL-style `/chosen`
  (kaslr-seed, rng-seed, initrd, the full predicted cmdline) at ramdisk − 0x201000.
  The armed hypervisor watchdog + crash guard bring a hang back to the harness. It still differs
  from the ABL hand-over in device state and secondaries (PSCI off vs never on).
- **The direct ABL -> kernel jump from `boot` has no key-free test.** There is no A/B and no
  boot-count fallback: 13 consecutive bites were seen without any fallback. A failed recovery
  image would loop the same way. rb9 (= rb6 DIAG kernel + a52ram + padded dtbo, KASLR on
  unless the kexec rehearsal fails) therefore still needs the owner's window with the keys
  ready, as the rule requires. What changes is the odds: the known blocker is fixed and
  verified offline, and the breadcrumbs would now actually be reached if the kernel starts.

## Files
| File | What |
|---|---|
| `tools/ufdt-host/check.sh` | builds the host libufdt from `donors/abl-edk2`, runs a base + dtbo through it with the hypervisor stand-in; `--selftest` |
| `tools/ufdt-host/ufdt_host.c`, `sysdeps_host.c`, `fdt_entry_node.h` | the host harness (ABL allocator semantics, `fdt_entry_node` layout from the binary) |
| `tools/ufdt-host/hyp-overlay-p2.dts` | stand-in for phone 2's hypervisor overlays (content from the live 5.4 tree, size from the crash registers) |
| `tools/ufdt-host/main.c` (repo root) | the 2026-11-11 harness idea for the same check, never run; superseded by the above |
| `research/bl-scout/dwb5/` (gitignored) | bit-2 `abl.elf`/`hypvm.mbn`/`xbl_config.elf`, carved LinuxLoader + disassembly |
