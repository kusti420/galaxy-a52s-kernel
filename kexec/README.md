# kexec chain: experimental kernels are started FROM the 6.18 harness

Rule (the private project log, 2026-11-11 21:05): only the 6.18 harness sits on `recovery`. Every other
kernel is started from it by kexec with the hypervisor watchdog armed, so a crash, reset or
hang lands back in the harness, whose crash guard leaves for Download mode.

State 2026-11-11: everything below is BUILT and checked offline. NOTHING has run on a phone.

## What exists

| piece | where | state |
|---|---|---|
| kexec in the harness kernel | `ack/arch/arm64/configs/a52sxq_gki.fragment`: `CONFIG_KEXEC=y`, `CONFIG_KEXEC_FILE=y` | builds |
| alternative base FDT | patch on `ack/drivers/of/kexec.c` (copy: `kexec/0001-of-kexec-alternative-base-fdt.patch`) | builds |
| loader | `tools/kx.c` -> `/kx <Image> <initramfs or -> "<cmdline>"` (kexec_file_load, syscall 294) | error paths run under qemu-user |
| jump | `tools/rb.c`: `rb kexec` (sync, SIGSTOP all, reboot KEXEC; on refusal SIGCONT, exit 3) | disassembly checked; the `rb download` path is unchanged code |
| launcher + safety net | `ramdisk/kexec-run` -> `/kexec-run` | syntax-checked with the ramdisk's busybox |
| crash guard | `ramdisk/init`, `ramdisk/leave` | 8 log cases unit-tested with the ramdisk's busybox |
| dtb builder | `kexec/mkkexecdtb.py` | run on both live trees + both target trees |
| PC driver | `kexec/kexec-test.sh` | `bash -n` only, never run |
| image | `images/a52sxq-ack618-kexec1-recovery.img` (sha256 05a2370268dc9bb4...) | packed, NOT flashed |

Backups of what was changed: `tools/rb.prev-kexec` (old binary), `kexec/init.before-kexec`.

## Kernel side (read in this tree)

- ACK/GKI does not restrict kexec here: `CONFIG_SECURITY_LOCKDOWN_LSM` is off, `CONFIG_KEXEC_SIG`
  is off (no signature check on the Image), `kexec_load_disabled` defaults to 0, and
  `CONFIG_HOTPLUG_CPU=y` is already set. gki_defconfig simply does not enable KEXEC.
- EL1 is fine. `machine_kexec()` only uses HVC when `is_hyp_nvhe()` (kernel entered at EL2).
  At EL1 `cpu_soft_restart(0, ...)` turns the MMU off through SCTLR_EL1 and branches to the
  new Image; `arm64_relocate_new_kernel` needs nothing from EL2.
- Secondaries: `machine_shutdown()` -> `smp_shutdown_nonboot_cpus()` takes CPUs 1..7 down
  through PSCI CPU_OFF; `machine_kexec()` BUGs if a CPU stays online or is stuck. The next
  kernel brings them back with PSCI CPU_ON. Not tested under this hypervisor (risk 2).
- Before the jump `kernel_restart_prepare()` runs the reboot notifiers and every driver's
  `.shutdown`: arm-smmu writes sCR0 = CLIENTPD (translation off, streams bypass) and turns
  its clocks off; UFS and dwc3 are shut down and must be fully re-initialised by the next
  kernel (nothing is handed over); the nvmem reboot-mode notifier writes the "normal" reason.
  The simple-framebuffer has no shutdown: the bootloader's scanout keeps running as long as
  the clocks/power domains stay on (`clk_ignore_unused pd_ignore_unused` in the cmdline) and
  the next dtb describes the same framebuffer.
- kexec_file places Image, initramfs and dtb top-down in free memblock memory of the RUNNING
  kernel, so most likely in the bank above 4 GiB (0x1_0000_0000+). The bootloader always
  loads low. See risk 4.

### The patch (the only one): `/sys/firmware/kexec_fdt`

Root-only (0600) binary file. Write a complete dtb sequentially from offset 0 (`cat x.dtb >
/sys/firmware/kexec_fdt`), max 4 MiB. The next `kexec_file_load()` then builds the new
kernel's FDT from that blob instead of `initial_boot_params`; everything
`of_kexec_alloc_and_setup_fdt()` does to /chosen still happens (bootargs from the kx cmdline,
linux,initrd-start/end, kaslr-seed, rng-seed, old initrd/elfcorehdr properties removed).
Validation at load: header, totalsize <= bytes written, a full node walk, a memory node
(`fdt_check_full` is not part of the kernel's libfdt). An invalid blob FAILS the load, it
never falls back silently. Reading the file returns the blob. A write shorter than 8 bytes at
offset 0 clears it (back to the kernel's own FDT); a reboot clears it too.

## Device tree for the next kernel

- harness -> harness: dtb `-`. The running kernel's FDT already has this boot's bootloader and
  hypervisor patches.
- a different kernel: `mkkexecdtb.py --base <new kernel dtb> [--overlay <dtbo>] --live <tree
  with the runtime patches> -o out.dtb`. It copies exactly (details in the script header):
  1. memory node `reg` + `ddr_device_type` (target: root child with device_type "memory");
  2. `/hypervisor` whole node;
  3. `/reserved-memory/uh_guest_region`, `uh_heap_region`;
  4. `status` of the node `@17c10000` (`/soc/qcom,wdt@17c10000` or `/soc@0/watchdog@17c10000`);
  5. `always-on` on the `arm,armv8-timer` node (`/soc/timer` or `/timer`).
  /chosen is not copied: the kernel writes it at load.
- Which `--live`? The two dumped trees differ in `/hypervisor`: the resource-manager node is
  `...rpc@039acdf92ca175e3` on PHONE2 and `...rpc@326780cadcbdcc65` on PHONE1, and
  the RAM banks differ too. Whether those capability ids are fixed per phone or change per
  boot is NOT known. So `kexec-test.sh` has dtb mode `gen`: it fetches the harness's own
  `/sys/firmware/fdt` of the current boot (busybox-extras httpd on the phone, curl on the PC)
  and uses that as `--live`. Use `gen` for 6.12. The result is kept in `logs/kexec-<name>-last.dtb`.
  Offline check done: yupik.dtb + a52sxq-bringup.dtbo + either live.dtb gives a 351404-byte
  tree with all five items and the ramoops reservation at 0xf0b00000.

## Safety net (`/kexec-run`)

`/kexec-run <name> <Image> <initramfs|-> <dtb|-> <wdt seconds|0> "<cmdline|->"`, in this order:
1. refuses in safe mode (`/tmp/crashed`);
2. writes or clears `/sys/firmware/kexec_fdt` (readback sha256 compared);
3. `/kx` loads, with ` a52.kexeced=<name>` appended to the cmdline. A failed load stops here,
   nothing armed;
4. logs `a52sxq-init: kexec to <name> (watchdog Ns)` (and the same as `a52sxq-harness:`);
5. arms the hypervisor watchdog by the raw sequence only: `8 <N hex> ffff`, `8 ffff <N+5 hex>`,
   `5 3 0`, `7 0 0` into `/sys/module/hhwdt/parameters/raw` (N = 20..600 s, default 120).
   No hhwdt raw file = no jump;
6. `/rb kexec`. If the kernel refuses, userspace resumes, the watchdog is disabled (`5 2 0`)
   and the script exits 7.

What the next kernel must do: within N seconds either disable (`5 2 0`) or keep petting
(`7 0 0`) through the same SMC calls. The 6.18 harness does it itself: with `a52.kexeced=` in
its cmdline `init` loads hhwdt.ko and writes `5 2 0`. For 6.12 the module is
`bsp612/out/bringup/hhwdt/hhwdt.ko` (in its ramdisk as `/lib/modules/hhwdt.ko`, has the same
`raw` parameter): `insmod /lib/modules/hhwdt.ko; echo "5 2 0" > /sys/module/hhwdt/parameters/raw`.
The bsp612 init does NOT do this yet (not mine to edit). Wanted change there: when the cmdline
has `a52.kexeced=`, insmod hhwdt.ko first and either pet every 20 s while modules load or
write `5 2 0` once the shell is up. Its own `a52.wdt` path uses the busybox watchdog applet,
which resets the phone at once: always pass `a52.wdt=0`.

### Crash guard (ramdisk/init), new rule

The harness now logs every line twice: `a52sxq-init: ...` (PC scripts read these) and
`a52sxq-harness: ...` (unambiguous: the bsp612 ramdisk also logs `a52sxq-init:`).
Previous log (`/sys/fs/pstore/console-ramoops-0`) = crashed when it contains
`a52sxq-(init|harness): start` or `a52.kexeced=` (the kernel prints its command line, so any
kexec'd kernel's log is recognised even without our ramdisk) and has no `clean exit`.
Exception: this kernel was itself kexec'd (`a52.kexeced=` in its own cmdline) and the last
marker line of the previous log is `kexec to`: the expected hand-over.
Cases (all unit-tested): kexec target dies without logging -> ramoops still holds the
harness's own log ending in `kexec to` -> crashed. Target logs to ramoops and dies -> its log
has `a52.kexeced=` and no clean exit -> crashed. Target leaves through its own `/leave`
(`a52sxq-init: clean exit`) -> not crashed. Android/foreign log -> not crashed (as before).
ramoops survives the kexec because both trees reserve 0xf0b00000+0x100000 with the same
record sizes (checked in both dtbs; mkkexecdtb.py warns if a tree does not).

## Staging

No `nc` in this busybox (applets checked with strings; present: wget, sha256sum, tftp,
base64; httpd/telnetd in busybox-extras). So the PC runs `python3 -m http.server` bound to
its 172.16.<net>.x address and the phone fetches with `busybox wget` into /tmp (tmpfs),
sha256 compared for every file.

`kexec/kexec-test.sh <Image> <ramdisk|-> <dtb|-|gen> "<cmdline|->"`; env `TSH_IP`,
`KEXEC_NAME`, `KEXEC_WDT` (120), `KEXEC_WAIT`. Telnet only: no adb, no heimdall, no flashing.
Exit 0 = kexec'd kernel answered on telnet, 1 = not started, 3 = back in the harness from
flash, 4 = nothing answered.

## Test order (main session; needs the owner's go-ahead for the flash of kexec1)

Precondition: `images/a52sxq-ack618-kexec1-recovery.img` on `recovery` of the test phone by
the usual harness procedure, shell reachable (`python3 tools/tsh.py 'uname -r'`). The harness
dead-man timer (300 s) keeps running: start the test soon after boot.

### (a) harness -> harness

    KEXEC_NAME=h2h kexec/kexec-test.sh out-ack/arch/arm64/boot/Image out-ack/ramdisk-a52.cpio.gz - -

Expected, first kernel (`dmesg`, later in ramoops): `a52sxq-init: kexec to h2h (watchdog 120s)`,
four `hhwdt: fn 8/8/5/7 ... -> a0=0` lines, `a52sxq-harness: kexec to h2h: watchdog armed`,
`kexec_core: Starting new kernel`, `Bye!`.
Second kernel: `Kernel command line: ... a52.kexeced=h2h`, `a52sxq-init: start (previous test
boot crashed: 0, kexeced: 1)`, `kexec'd boot: inherited watchdog disabled`, `gadget on ...`.
Script prints `RESULT: the kexec'd kernel 'h2h' is up`. Then check by hand:
`python3 tools/tsh.py 'cat /proc/cmdline; grep -c processor /proc/cpuinfo; grep -c "sd[a-f]" /proc/partitions; cat /sys/module/hhwdt/parameters/status'`
(8 CPUs, UFS partitions present, watchdog not enabled), wait > 130 s (no bite), then
`python3 tools/tsh.py /leave` must reach Download mode. That proves kexec under the
hypervisor, USB re-enumeration, and the exit after a kexec.
Failures: `kx: kexec_file_load failed: errno N` (nothing armed, still in harness; 8 = ENOEXEC
image refused, 12 = no memory, 22 = bad dtb, 38 = no kexec in this kernel); exit 3 = the jump
or the second kernel died and the watchdog/reset brought the flash harness back in safe mode
(log saved in `logs/kexec-h2h-prev-console-*.txt`; it shows how far it got); exit 4 = second
kernel alive without USB (it then leaves by its own dead-man timer after 300 s) or hung with
no bite (then the watchdog does not survive kexec: owner keys needed. This is the one case
that cannot be excluded before the first run).

### (b) deliberate bad payload: proves the way back

    head -c 20000000 out-ack/arch/arm64/boot/Image > /tmp/trunc-Image
    KEXEC_NAME=bad KEXEC_WDT=60 kexec/kexec-test.sh /tmp/trunc-Image out-ack/ramdisk-a52.cpio.gz - -

The header is intact, so the load should succeed and the jump lands in a kernel without its
tail. Expected: silence for about 65 s, then the bite, the flash harness boots, logs
`a52sxq-init: start (previous test boot crashed: 1, kexeced: 0)`, script prints `RESULT: back
in the harness ... safe mode`, and the harness leaves for Download mode within 90 s.
If the load is refused instead (errno 8/22: image_size check), that only proves the loader's
check; then use a full-size Image with 1 MiB zeroed at offset 4 MiB
(`cp Image x; dd if=/dev/zero of=x bs=1M seek=4 count=1 conv=notrunc`).
Failure: no return within ~3 min = the watchdog does not reset a dead kexec'd kernel -> stop,
do not go on to (c).

### (c) 6.12 BSP

    KEXEC_NAME=bsp612 KEXEC_WDT=300 kexec/kexec-test.sh bsp612/out/dist/Image \
        bsp612/out/bringup/ramdisk-612.cpio.gz gen \
        "console=tty0 loglevel=7 clk_ignore_unused pd_ignore_unused a52.wdt=0 a52.deadman=300 a52.net=42"

(Check the cmdline against what the bsp612 image builder uses; `a52.wdt=0` is mandatory.)
Expected: `kexec_fdt: using the alternative base FDT (35xxxx bytes)` at load; after the jump
the 6.12 log in ramoops starts with `Linux version 6.12.81`, `Kernel command line: ...
a52.kexeced=bsp612`, then `a52sxq-init: start bsp612`. If its telnet comes up: disarm
(`insmod /lib/modules/hhwdt.ko; echo "5 2 0" > /sys/module/hhwdt/parameters/raw`), work,
then its `/leave`. If it does not come up or `reboot download` fails there (as in esc3): the
bite after 300 s returns to the harness, which saves the 6.12 log (that log is the first
retrievable evidence of why 6.12's exit fails) and leaves.

## Risks not closed by reading code

1. Whether the hypervisor watchdog keeps counting across a kexec and still bites when the
   guest is dead at EL1 with all secondaries off. Everything rests on it; test (b) is the proof.
   Until (b) passes, a failed (a) can need the owner's keys once.
2. PSCI CPU_OFF/CPU_ON of secondaries under Haven during kexec: never exercised here.
3. `device_shutdown()` of this driver set (dwc3, UFS, SMMU, geni) has never run on the phone;
   a hang there is covered by the watchdog (armed before), a reset there too.
4. Kernel loaded above 4 GiB instead of the bootloader's low address; and for 6.12 the load
   addresses are chosen from the harness's memory map, not checked against the 6.12 tree's
   static reservations (same Samsung map by construction, but not compared region by region).
5. SMMU left in bypass with clocks off, and whatever state the hypervisor's stage 2 / SCM
   keeps from the first kernel (e.g. qcom-scm, gh_dbl were the last modules logged before
   the 6.12 resets): the second kernel is not a cold boot.
6. hhwdt.ko was built before the config change (same vermagic, modversions): if a symbol CRC
   moved, insmod fails and `/kexec-run` refuses to jump (safe, visible). Rebuild modules/hhwdt
   against out-ack if so.
7. `/hypervisor` capability ids may be per boot: use dtb mode `gen`, not the dumped trees.
8. The crash guard cannot see a kexec'd kernel that used ramoops with another layout and
   corrupted the record: then the flash harness boots in normal mode (no loop either way: it
   never kexecs by itself and leaves after 300 s).
9. `kexec-test.sh` has never run: PC-side address detection, wget throughput over NCM and
   the busybox-extras httpd fetch are untested.
10. The 6.12 simple-framebuffer/USB depend on the bring-up overlay and its modules, same as in
    the direct-boot attempts; kexec does not make 6.12's `reboot download` work.
