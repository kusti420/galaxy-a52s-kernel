# What the firmware outside the kernel assumes about the kernel (5.4 -> 6.12)

Offline, read-only audit, 2026-11-22. No phone was touched. Question: after PROCA, where else does firmware
outside the kernel (TZ/QSEE TAs, Gunyah/Haven, ABL/XBL, modem and DSP firmware, Samsung's secure TAs, the
bootloader's sec_debug handling) depend on something the 5.4 kernel did and our 6.12 does differently?

Evidence tags used below:

- `[SRC]` read in source (path given), `[LOG]` a saved log in this repo, `[DISASM]` read in the disassembly of a
  TA, `[STR]` a string in a firmware image, `[INF]` inference, not proven. Nothing here was verified on a phone
  today: every "fix" is a proposal and every "check" is still to run.

Inputs: 5.4 trees `~/git/kernel_a52sxq_bone` (its `out/.config` is the bone-machine kernel that the phones
actually run as "5.4") and `$ANDROID_TREE/kernel/samsung/sm7325`; 6.12 = `bsp612/kernel` (ACK, git clean) +
`bsp612/soc-repo` + `drivers612`; DTs `downstream-dt/a52sxq-r02.dts`, the live 5.4 tree
`testdev-PHONE1/oneui9-9.3.160/live.dtb`, the 6.12 tree `drivers612/realboot/out/rbou4/vendor_boot.dtb` +
`realboot.dtbo` (static merge; the dtbo-partition overlays the ABL adds are only visible in boot logs); firmware =
stock FWK4 `BL_*.tar` (abl, xbl, tz, hypvm, devcfg, km41, tz_iccc, tz_hdm, tz_kg, vaultkeeper, ...) and the
`apnhlos` TA set from `testdev-PHONE2/backup-2026-11-13-incident/apnhlos.img`, unpacked to scratch,
`strings` plus capstone on `proca.b02`.

## 0. The baseline rule that shrinks the problem

The "5.4" every comparison uses is the bone-machine kernel. Its `.config` has **none** of the Samsung security
or debug exports: `PROCA`, `FIVE`, `GAF`, `DEFEX`, `DSMS`, `UH`, `RKP`, `KDP`, `HDM`, `ICD`, `TZIC`,
`SEC_DEBUG*`, `SEC_LOG_BUF`, `SEC_SMEM`, `QCOM_MINIDUMP`, `QCOM_MEMORY_DUMP_V2` are all off `[SRC]`
(`~/git/kernel_a52sxq_bone/out/.config`). Vaultkeeper works on it. So none of those exports is required for the
behaviour we compare against, and porting them is not needed for parity. What remains are (a) things the
5.4 Qualcomm code does toward TZ/hyp/bootloader that 6.12 does differently and (b) arm64 layout changes.

## 1. Headline: today's PROCA conclusion needs three corrections

1. **The Image header is still reserved on our 6.12.** `bsp612/kernel/arch/arm64/mm/init.c:323` is
   `memblock_reserve(__pa_symbol(_text), _end - _text)`, `setup.c:216` starts "Kernel code" at `_text`, and
   `mmu.c:700` maps `[_text,_stext)` read-only `[SRC]`. The v5.11 change that freed it is not in this tree.
2. **The PROCA TA accepts 0 at header offset 0x28 exactly like `0xecefecef`.** `ConfigLoadFromKernel`
   (`proca.b02` 0x1ac0): read 4 bytes at base+0x38, compare with "ARMd"; read 8 bytes at base+0x28; if the value
   is `0xecefecef` **or 0** return 0x120000 (the "no PROCA config" result); only otherwise load a 0x64c-byte
   config `[DISASM]` (0x1c0c-0x1c3c, read by hand, not only by the helper). Our 6.12 Image has 0 there, the
   5.4 images have `0xecefecef` `[SRC]` (headers dumped from `testdev-*/boot.img` and
   `drivers612/realboot/out/rbou4/boot.img`).
3. **What fails is the TA's attempt to map HLOS memory at all.** The only saved log that still has the first
   PROCA lines of a 6.12 boot (kexec rehearsals `logs/kx-rhou1b-p1-152501/prev-console.txt`,
   `logs/kx-rhou1c-p1-153031/prev-console.txt`) shows, once, before the endless
   "Config is not initialized in SWD":

       [PA_TZ_DRV] [ERR] [PlatformSysMap:79] IHlosRegionFinder_getRegion return error.
       [PA_TZ_DRV] [ERR] [PhysicalGetBytes:61] Can not map paddr to read.
       [PA_TZ_DRV] [ERR] [ConfigLoadFromKernel:200] Can not read kernel magic.
       [PA_TZ_DRV] [ERR] [ConfigInit:294] Can not load configuration structure

   `[LOG]`. On 5.4 the same TA logs only "PlatformIsDeviceCompromised: Device is compromized" (13x in
   `logs/selftest/PHONE1-20261122-172724/kmsg.txt`), i.e. its config init succeeded as "not supported".
   The real 6.12 boots (rbou3/rbou4) only kept the wrapped tail of the log, so the four lines above are not yet
   seen on a real boot.

**Most likely cause `[INF]`: the TZ shared-memory bridge.** The 5.4 kernel never turns it on:
`drivers/firmware/qtee_shmbridge.c:419-420` in both 5.4 trees is
`/* temporarily disable shm bridge mechanism */ ret = qtee_shmbridge_enable(false);` and the 5.4 boot log says
"shmbridge isn't enabled" `[SRC][LOG]`. Our 6.12 turns it on: `CONFIG_QCOM_TZMEM_MODE_SHMBRIDGE=y`
(`bsp612/out/lahaina/.config`), `qcom_tzmem_init()` calls `qcom_scm_shm_bridge_enable()`
(`bsp612/soc-repo/drivers/firmware/qcom/qcom_tzmem.c:155`, again at `:506` on PM restore) `[SRC]`. With the
bridge enabled TZ lets a TA map HLOS memory only through a registered bridge; nobody registers one for the
kernel image, so a TA that reads kernel RAM by physical address gets "cannot map". That fits the error text
(an HLOS region lookup fails before any content is read) but the link between `IHlosRegionFinder` and the
bridge list is my reading, not something a string states.

Side facts that matter for testing:

- The TA's address is fixed: 0xA0080000 + the offset the ABL stored in a TZ OEM buffer (magic `0xcdefcdef`,
  written through bksecapp `kaslr_write_bl_data`) `[DISASM][STR]`. The Samsung ABL loads the kernel at
  0xA0080000 + k * 0x8000, k = 0..63, whatever `text_offset` says: about 400 saved `/proc/iomem` samples of the
  6.18 harness (`text_offset` 0) all start "Kernel code" in 0xa0080000..0xa0278000 `[LOG]`. So the header of a
  normally booted 6.12 sits where the TA looks. A kexec'd kernel does not: there the TA reads whatever the
  harness left at that address.
- The 6.18 harness is built with `QCOM_TZMEM_MODE_GENERIC` (`out-ack/.config`) and does not enable the bridge.
  The bridge is enabled by our `qcom-scm.ko` after kexec. So a rehearsal with a changed `qcom-scm.ko` shows the
  TZ-side difference key-free. Once enabled, the bridge stays on until the next reset.

## 2. Ranked list: checks to run on a phone, fixes to make

1. **Shm bridge: boot 6.12 without `SHM_BRIDGE_ENABLE` (5.4 parity).** Fix proposal: a switch in
   `qcom_tzmem.c` (module parameter or an entry in `qcom_tzmem_blacklist`; both call sites, `:155` and `:506`)
   so `qcom_tzmem_using_shm_bridge` stays false; only `qcom-scm.ko` changes, the pinned boot.img does not.
   Test order: rehearsal first (expect the four `PlatformSysMap / PhysicalGetBytes` lines to disappear and
   "Device is compromized" to appear as on 5.4), then a real boot with vaultkeeper (`TA ret = 0`, no -10032).
   Risk: every TZ client on 6.12 (qseecom, smcinvoke, ICE, keymaster, fingerprint, Widevine, RPMB listeners) has
   only run with the bridge on, so rerun the secure part of the OneUI sweep and the IchthysOS selftest; the
   non-bridge paths exist in soc-repo (`qtee_shmbridge_register` and `qcom_tzmem` return early when the bridge
   is off) `[SRC]` and are what 5.4 uses on this TZ.
   Alternative if the bridge must stay on: register a read-only bridge over the Image header page
   (`[_text, _text + 4K)`); the TA then reads "ARMd" and 0 and takes the "not supported" path. Smaller blast
   radius, but it only helps PROCA, not other raw-address readers.
2. **First confirm the failure on a real boot** (cheap, read-only): capture the first `[PA_TZ_DRV]` lines of an
   rbou boot before the ring wraps (pstore console of the next boot, or `dmesg -w` to a file from early init).
   Expected if the theory holds: the same four lines as in the rehearsal log. If instead it says "Kernel magic is
   incorrect", the load address is the problem, not the bridge.
3. **Do not port PROCA/FIVE for this bug.** The baseline has neither and the TA treats 0 as "no PROCA". If the
   Image is rebuilt anyway, put `.quad 0xecefecef` at header offset 0x28 for exact parity (one line in
   `head.S`); not worth a boot.img change on its own.
4. **Watchdog: every current build has `wdt=0`** (BUILDINFO of rbou4, rbou5i, rbich43, rbich44, rb104). The
   hypervisor watchdog is disarmed at kernel entry on bit 2 and bit 5, so a hard hang
   never resets and needs a manual key press. 5.4 pets it (`HH_VIRT_WATCHDOG=y`, bark 11 s, pet 9.36 s). WDT=1 is
   proven under load and idle on rb78; the open item is a real suspend. Make it default after that.
5. **Crash path differs.** 5.4: `POWER_RESET_QCOM_DOWNLOAD_MODE_DEFAULT=y` arms the dload cookie at boot and
   disarms it on a clean reboot. 6.12: `qcom-dload-mode.ko` is not loaded and `qcom_scm.download_mode` is off,
   so the cookie is whatever the ABL left; `sec_core` writes imem `restart_reason` 0 and the PON reason on clean
   reboots only. Check (read-only): `cat /sys/module/qcom_scm/parameters/download_mode`, and after the next
   unplanned 6.12 reset note what the bootloader did (normal boot vs upload screen). XBL classifies warm resets
   from these magics ("Warm Reset by Kernel Panic / Watchdog Bite", "not allow normal booting with warm_reset
   status!!!") `[STR]`.
6. **`/proc/tzdbg` resets the phone on 6.12** (11-22 gotcha). `tz_log` registers bridges for its encrypted-log
   buffers; with item 1 applied this path changes too. Retest only after item 1 and only with an explicit OK
   `[INF]`.
7. **KASLR: keep it seedless.** 6.12 logs "KASLR disabled due to lack of seed" (`logs/1122/rb99m-b1-dmesg.txt`);
   placement is randomised physically by the ABL, and the TA and the bootloader's dump code use the ABL's
   offset. Do not add a `kaslr-seed` or `rng-seed` based relocation: the virtual offset must stay equal to the
   physical misalignment. Check on a real 6.12 boot: `grep 'Kernel code' /proc/iomem` starts at
   0xA0080000 + k * 0x8000.
8. **Reserved-memory map on a real OneUI 6.12 boot.** Static and white-cable evidence says parity (table rows
   R1-R4); run one `ls /proc/device-tree/reserved-memory` + `dmesg | grep 'OF: reserved mem'` on rbou and diff
   against `testdev-PHONE1/oneui9-9.3.160/live.dtb`, looking at `uh_guest_region`, `uh_heap_region`,
   `cvp@8b200000`, `modem_shared_mem_region`.
9. **Samsung reboot commands on OneUI 6.12:** `reboot recovery`, `reboot download`, `reboot bootloader`
   through `sec_core` (CHECKLIST.md line 79 is still unticked for OneUI).
10. **Never judge vaultkeeper/PROCA from a kexec rehearsal alone** once item 1 is in: the TA reads the harness's
    stale header address. A pass there is encouraging, a real boot is the proof.

## 3. Table

Risk: HIGH = breaks a user-visible function now; MED = wrong behaviour in a failure case or a security
property; LOW = no known consumer in our baseline; NONE = parity with the bone 5.4 baseline.

### 3.1 TrustZone and TAs

| # | Assumption | Firmware consumer | 5.4 mechanism | 6.12 state | Risk | Fix or check |
|---|---|---|---|---|---|---|
| T1 | TAs may map any HLOS RAM by physical address (shm bridge off) | PROCA TA, and through its library vaultkeeper, tz_kg, skeymast, wsm `[STR]`; any other raw-address reader | `qtee_shmbridge_enable(false)`, "shmbridge isn't enabled" | bridge enabled by `qcom_tzmem_init()` | HIGH: vaultkeeper -10032 loop, cidmanager, CSC activation | list item 1 |
| T2 | arm64 Image header at 0xA0080000 + ABL offset, "ARMd" at +0x38, +0x28 = `0xecefecef`, 0, or offset of `g_proca_config` | PROCA TA | `head.S:83-87` writes the magic (PROCA off) | header present and reserved, +0x28 = 0, accepted `[DISASM]` | NONE once T1 is fixed | optional `0xecefecef` |
| T3 | If +0x28 is an offset: config v3, size 0x64c, magic `0xcd0436ea`, GAF >= 0x600 with checksum, `mm->mmap`/`mm_rb` VMA walk, own page-table walk | PROCA TA | off in the baseline | absent | NONE (not wanted; a 6.x maple tree would not fit this TA `[INF]`) | do not port |
| T4 | Kernel physical base and KASLR offset come from the ABL, not from the kernel | PROCA TA (`qsee_read_oem_buffer`, magic `0xcdefcdef`), bksecapp | kernel runs where the ABL put it | same on a normal boot; not under kexec | LOW | list items 7 and 10 |
| T5 | "Custom kernel" / device-compromised state | vaultkeeper, tz_kg, skeymast ("abnormal kernel status. boot/recovery"), esecomm, mldapta `[STR]` | set by the ABL through ICCC (`IcccBlDataToIccc`, `IcccKernToIccc`) and the warranty fuse, not read from kernel RAM | same inputs (same ABL, same signature state) | NONE vs baseline | none |
| T6 | ICCC "KERN" info pushed from HLOS (`tzbsp_oem_write_iccc_kern_info`, PKM text/RO, SELinux, dm-verity types) | tz_iccc | not pushed (no ICD/uH in the baseline) | not pushed | NONE vs baseline | none |
| T7 | RTIC: `TZ_RTIC_ENABLE_MEM_PROTECTION` SMC at early boot, MP blob (`qcom,rtic-id`, `MP_DATA`, `linux_banner`, vbar) | rtic TA / TZ, hypervisor report | SMC is made and **fails** ("scm_mem_protection_init_do: SCM call failed" in the 5.4 log); no MP in the DT | SMC not made, no MP | NONE | none |
| T8 | Keymaster root of trust, boot state, OS version / patch level | km41 | from the ABL (`KeyMasterSetRotAndBootState`, vbmeta properties) | same; build-realboot keeps patch level 2023-11 | NONE | none |
| T9 | RPMB / SFS / time listeners registered from HLOS, buffers "in HLOS range" | TZ, km41, vaultkeeper | qseecomd (userspace) | same; RPMB path proven identical 11-22 | NONE | none |
| T10 | HDM: uH app at EL2 answering over `hdm_region@9FB00000` | tz_hdm ("Hypervisor MAGIC is wrong") | no `CONFIG_HDM`; region reserved; `androidboot.hdm_status=NONE` | region reserved, no driver | NONE | none |
| T11 | TZ diag log readable by HLOS | tz_log driver | built in | module not loaded; reading resets the phone | MED (debug only) | list item 6 |
| T12 | SMC ABI: SMCCC v1.0, PSCI 1.1 with OSI, x18 preserved across SMC/HVC | TZ, hypervisor | no shadow call stack | dynamic SCS uses x18; days of uptime show the firmware preserves it `[LOG]` | NONE | none |
| T13 | `hyp_assign` of secure heaps and audio/modem shared buffers | TZ + hypervisor RM | `hyp_assign_phys` | `qcom_scm_assign_mem` (voice-cal fix 11-15) | LOW | covered by audio/camera tests |

### 3.2 Hypervisor (Gunyah "haven-71a16790" + Samsung Rust uH in devcfg)

| # | Assumption | Firmware consumer | 5.4 mechanism | 6.12 state | Risk | Fix or check |
|---|---|---|---|---|---|---|
| H1 | Kernel runs at EL1, hypervisor owns EL2 | Gunyah | "All CPU(s) started at EL1" | same; `kvm-arm.mode=protected` is ignored ("KVM is not available") | NONE | drop the word from the cmdline some day |
| H2 | `/hypervisor` nodes are added by the ABL from the RM overlay (`qcom,haven-hypervisor`, `qcom,hh-watchdog`, `qcom,resource-manager-rpc@...`), `/soc/qcom,wdt@17c10000` set disabled | Gunyah RM | `hh_*` drivers | `gh_*` drivers bound to the haven names (already handled) | NONE | none |
| H3 | Primary VM pets the virtual watchdog once it is armed | Gunyah ("WDT bite ... from VM") | `HH_VIRT_WATCHDOG=y` | not loaded by default (`wdt=0`); disarmed at entry | MED | list item 4 |
| H4 | `uh_heap_region` 0xb0200000 (2 MiB) and `uh_guest_region` 0xb0400000 (18 MiB) stay reserved | Samsung uH (HypX), added by the ABL to `/reserved-memory` | reserved (in the live 5.4 tree) | reserved on a real boot (`rb99m-b1-dmesg.txt`) | NONE | list item 8 |
| H5 | uH calls from the kernel: `smc` with x0 = `0xc300c000 | app` (RKP init with `_text`, `swapper_pg_dir`, ...; KDP; HDM) | Samsung uH | never made (UH/RKP/KDP off) | never made | NONE vs baseline | none; a kernel that made them would need the whole RKP ABI |
| H6 | `qcom,hyp-core-ctl` (reserve CPUs for a secondary VM) | Gunyah + trusted VM | `QCOM_HYP_CORE_CTL=y` | node and driver absent | LOW (no trusted VM in use) | none |
| H7 | Trusted VM memory `pil_trustedvm_region@d0800000`, `qrtr-shmem`, neuron blocks | Gunyah RM | reserved, loader built in | reserved, `gunyah_loader` loaded | LOW | none |
| H8 | PSCI system suspend only from the primary VM, OSI mode | Gunyah | OSI | OSI (`qcom_lpm`) | NONE | none |

### 3.3 Bootloader (ABL / XBL, Samsung sec code)

| # | Assumption | Firmware consumer | 5.4 mechanism | 6.12 state | Risk | Fix or check |
|---|---|---|---|---|---|---|
| B1 | Kernel is loaded at 0xA0080000 + k * 0x8000 (not 2 MiB aligned), `text_offset` ignored; XBL map names 0xA0000000 + 256 MiB "Kernel" | Samsung ABL | relocatable kernel absorbs the misalignment | same (6.12 boots there; 6.18 samples) | NONE | list item 7 |
| B2 | `/chosen` gets bootargs, initrd, `kaslr-seed` (0 on this phone) | ABL, hypervisor (`patch_chosen_node`) | no visible KASLR message | "KASLR disabled due to lack of seed" | LOW (security parity unknown: 5.4 prints nothing) | keep |
| B3 | DT + overlays re-serialised by the ABL's libufdt with little slack | ABL | stock dtbo entries ~256 KiB | fixed 11-15 (padded dtbo, `tools/ufdt-host/check.sh`) | NONE | keep the build gate |
| B4 | Cmdline: ABL appends ~2.7 KiB of Samsung words | ABL `sec_update_cmdline` | 2048+ | `COMMAND_LINE_SIZE` 4096, "lost 0 words" in the build report | NONE | keep the gate |
| B5 | `sec_log=0x200000@0xF0200000`, `sec_dbg=0x1FF000@0xF0000000`, `sec_dbg_ex_info=0x1000@0xF01FF000` inside `sec_debug_region@F0000000` (9 MiB, no-map; XBL map "SEC Debug") | bootloader upload/RDX code | not consumed (`SEC_DEBUG` off) | not consumed ("Unknown kernel command line parameters") ; region reserved | NONE vs baseline | none |
| B6 | `sec_debug_summary` in SMEM item 136 (kallsyms, `PHYS_OFFSET`, `VA_BITS`, `kimage_voffset`, `swapper_pg_dir`, task_struct offsets, magics `0x5ECDEB6`...) | XBL upload mode ("Summary Info is not valid", "Bootloader version is %x and Kernel version is %x") | not written (off) | not written | NONE vs baseline | none; only needed for Samsung ramdumps |
| B7 | Upload magic `0x776655ee` in imem 0x65c and upload cause in imem 0x66c (`0xCAFEBABE` at boot) | XBL reset classification | not written (off); Qualcomm values on reboot | `sec_core` writes 0 at load and on clean reboot; `upload_cause@66c` node absent | LOW | list item 5 |
| B8 | Download-mode cookie armed while the kernel runs | XBL / SDI | armed at boot (`DOWNLOAD_MODE_DEFAULT=y`), cleared on clean reboot | not armed (module not loaded, param off) | MED: a crash on 6.12 takes a different bootloader path than on 5.4 | list item 5 |
| B9 | PON/SDAM reason byte (7-bit cell at `sdam@7100` +0x48), Samsung codes 0x12-0x62 | ABL ("Current Reset Reason Value") | `qcom-reboot-reason` (+ Samsung table only with SEC_DEBUG) | `qcom-reboot-reason` + `sec_core` (recovery, download, nvbackup, ...) | LOW | list item 9 |
| B10 | imem `kaslr_offset@6d0` = `0xdead4ead` + offset | ramdump tools | `store_kaslr_offset()` | `qcom_cpu_vendor_hooks.c:129` | NONE | none |
| B11 | Minidump / memory-dump tables registered with TZ and SMEM | XBL ramdump, TZ ("S:Minidump disabled", `MinidumpTALoadingCfg = 0x0`) | both off | `minidump`, `qcom_va_minidump` loaded (SMEM item 602), `mem_dump` node without driver | LOW (firmware has minidump disabled) | none |
| B12 | `param` partition shared with the kernel (debug level, FMM lock, sapa, edtbo fiemap) | ABL | `SEC_PARAM=y` writes it | no kernel writer; userspace uses the `androidboot.*.param.offset` values on the block device | LOW | watch for features that changed debug level or sales code through the kernel |
| B13 | Partial-goods and display fixups by node name (`qcom,kgsl-3d0`, `qcom,vidc*`, `/reserved-memory/splash_region`, demura) | ABL | downstream names | our tree keeps the downstream names for these | LOW | keep the names |
| B14 | `debug` partition layout (`/sec_debug_partition` part-table, magic `0x41114729`) | XBL ("AP_Health Header") | not used (off) | node kept, no driver | NONE vs baseline | none |
| B15 | "Got Secure Check fail flag from Kernel!" | ABL | writer not found in the 5.4 sources | none | unknown `[STR]` only | none |

### 3.4 Memory map, modem and DSP firmware

| # | Assumption | Firmware consumer | 5.4 mechanism | 6.12 state | Risk | Fix or check |
|---|---|---|---|---|---|---|
| R1 | Fixed no-map carve-outs: hyp 0x80000000, xbl_aop, cmd_db 0x80860000, smem 0x80900000, fw, wlan_fw, cdsp_secure_heap, adsp 0x84700000 (72 MiB), cdsp, video 0x8ad00000, cvp 0x8b200000, ipa, gpu zap, mpss 0x8b800000, wlan 0x9ae00000, removed_region 0xc0000000, trustedvm | TZ PIL authentication, modem, DSPs, AOP | DT | identical addresses and sizes in the real-boot log | NONE | none |
| R2 | Samsung carve-outs: `kaslr_region@A0001000`, `tima_region@B0100000`, `hdm_region@9FB00000`, `sec_debug_region`, `ss_plog`, `dummy_mem` | bootloader, TZ, uH (no kernel user of `kaslr_region` or `tima_region` exists in the 5.4 sources) | reserved | reserved | NONE | none |
| R3 | `modem_shared_mem_region@d0000000` | modem (memshare client 4, CP debug memory) | reg size 0, `non_gki_size` 0x6000000 | 8 MiB no-map | LOW; unclear what 5.4 really reserves with `cp_reserved_mem=off` | list item 8 |
| R4 | Our additions: `a52ram@f0be0000` (128 KiB, taken from the ramoops megabyte), `debug_kinfo_region` (top of RAM), `va_md_mem_region`, `ramoops-region` | none | absent | present | LOW; ramoops is 0xe0000 instead of 0x100000, so a 5.4 boot cannot read a 6.12 console and vice versa (known) | none |
| R5 | SMEM: host items, `SMEM_ID_VENDOR0/1` read-only for the kernel, `ap_suspended` in VENDOR1 | modem / boot firmware | `SEC_SMEM` off in the baseline | `samsung,sec-smem` node, no driver | NONE vs baseline | none |
| R6 | cmd-db, RPMh, AOP QMP, sleep stats | AOP | built in | `cmd-db`, `qcom_rpmh`, `qcom_aoss`, `msm_qmp` loaded | NONE | none |
| R7 | Sysmon / SSCTL shutdown handshakes, PDR, memshare, rmtfs | modem, ADSP, CDSP, WPSS | subsystem-restart framework | remoteproc + `qcom_sysmon`, `subsys_compat`, `qcom_pd_mapper_a52` | LOW | covered by modem/Wi-Fi/audio tests |
| R8 | `msm_rtb` buffer, `qcom,msm-rtb` node | XBL dump code ("Kernel did not initialize RTB") | `QCOM_RTB=y`, `msm_rtb.enable=0` from the ABL | absent | NONE | none |

### 3.5 arm64 changes 5.4 -> 6.12 seen from the firmware

| Topic | 5.4 (bone) | 6.12 (ours) | Who could care | Verdict |
|---|---|---|---|---|
| Image header | `text_offset` 0x80000, flags 0xa, 0x28 = `0xecefecef` | `text_offset` 0, flags 0xa, 0x28 = 0 | PROCA TA, ABL | fine (T2, B1) |
| Header memory | reserved | reserved (`init.c:323`), mapped RO | PROCA TA | fine |
| Physical placement | 0xA0080000 + k * 32 KiB | same | TA, XBL map | fine |
| Virtual KASLR | seed-based code present, no message | disabled, no seed; offset = physical misalignment | PROCA config math, sec_debug summary | keep seedless |
| `VA_BITS` / page size / levels | 39 / 4K / 3 | 39 / 4K / 3 (`bsp612/out/gki-diag/.config`) | PROCA page-table walk, GAF, summary | parity; a 16K or 48-bit build would break any future use of T3/B6 |
| KPTI | `kpti=off` | `kpti=0`, "forced OFF" | TA page-table walks (not used) | parity |
| PAN | SW TTBR0 PAN | SW TTBR0 PAN + hardware PAN | none | fine |
| PAC / BTI / MTE / SVE / SME | CPU has none | compiled in, not detected on this CPU (`arm64.nosme`) | TZ return paths | no effect |
| Shadow call stack, CFI | none | dynamic SCS (x18), kCFI | SMC/HVC must preserve x18 | fine in practice (T12) |
| struct layouts (`task_struct`, `mm_struct` maple tree, `vm_area_struct`) | 5.4 | 6.12 | PROCA GAF, sec_debug summary | only matters if T3/B6 were ever enabled |
| `swapper_pg_dir`, `kimage_voffset`, linear map base | 5.4 values | 6.12 values (`PAGE_OFFSET` moved in 5.4+ already) | uH RKP init, summary | not exported in the baseline |
| Per-CPU areas, vmemmap | 5.4 | 6.12 | summary only | not exported |
| EL2 / KVM | no KVM | KVM built, "HYP mode not available" | Gunyah | fine (H1) |
| SMCCC / PSCI | SMCCC 1.0, PSCI 1.1 OSI | same | TZ, hypervisor | parity |
| FF-A | none | not used | none | fine |
| TZ shm bridge | **off** | **on** | every TA that reads HLOS RAM | T1 |

## 4. TAs and images checked for kernel-facing strings

- With kernel-facing behaviour: `proca` (reads kernel RAM: header, config, GAF, task list, page tables),
  `vaultkeeper`, `tz_kg`, `skeymast`, `wsm` (all through the PROCA TZ library: "KG PROCA does not work on custom
  kernel", "PA_TZ_PROCA_NOT_SUPPORTED", "This device does not support PROCA authentication"), `tz_iccc`
  (value store, expects pushed KERN data), `tz_hdm` (talks to the uH), `rtic` and the RTIC code inside `tz.mbn`
  (kernel banner, vbar, RO-section attestation; inert here, T7), `km41` (ABL-provided state only), `esecomm`
  and `mldapta` (ICCC / device state only).
- No kernel-facing strings: authhat, engmode, featenabler, hdcp1, hdcp2p2, hdcpsrm, loadalgota64, mst, prov,
  skm, skpm, soter64, sp_license, sshdcpapp, ssu, voicepri, widevine, winsecap, storsec, uefi_sec, sec.elf,
  apdp, aop, cpucp, shrm, xbl_config, qupv3fw, imagefv; dualfp, fingerpr and sec_fr only match image-processing
  "kernel".
- `devcfg.mbn` carries the Samsung Rust uH (`src/app/rkp/*.rs`, `src/app/kdp/*.rs`, `src/app/hdm/system_api.rs`,
  "RUSTUH_78637743"); its log strings are hashed, so its behaviour cannot be read from strings.
- `hypvm.mbn`: HypX plugin ("HYPX REGISTRATION SUCCESS / NOT ENABLED Reason: 0x%x", "Failed to map HLOS for
  HypX"), RM device-tree strings, watchdog, hyp-assign rules.

## 5. Limits of this audit

- Strings and one hand-read function; no TA was run, no SMC was traced. The bridge theory (T1) rests on one
  source difference and one error sequence from kexec rehearsals; item 2 of the list is the cheap confirmation.
- The Samsung stock kernel's real config (with PROCA, RKP, sec_debug on) is not in either 5.4 tree; the shipped
  open-source defconfig has them off. Everything is judged against the bone-machine baseline, which is the
  kernel the phones run.
- The 6.12 DT compared statically is the vendor_boot tree plus the realboot overlay; node lists from a live
  OneUI 6.12 boot were not available. The reserved-memory lines come from a white-cable real boot (rb99m).
- No 5.4 `/proc/iomem` sample exists in the logs, so "the 5.4 kernel is loaded at the same addresses" rests on
  the TA's hard-coded base and on the 6.18 samples.
- Modem, ADSP, CDSP and WPSS images were not searched beyond the memory map; their HLOS contracts (QMI, sysmon,
  memshare) are exercised by the existing functional tests.
