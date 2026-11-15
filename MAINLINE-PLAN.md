# MAINLINE-PLAN: the third track (latest upstream kernel on the A52s)

Written 2026-11-15, offline. Nothing was run on a phone, nothing flashed. Track order (owner):
6.12 first (real-boots daily on phone 1), 6.18 second (real-boots on phone 2), mainline third.
This track gets no work that the 6.12/6.18 tracks need first.

What "mainline" means here: torvalds/stable plus the `sc7280-mainline` community patch stack,
upstream drivers and bindings, no Qualcomm downstream techpacks. The 6.12/6.18 tracks keep the
closed vendor blobs. This track starts with an open stack (Linux userspace first). Android on it
is a separate decision (section 5).

## 1. Newest upstream state (checked 2026-11-15 with `git ls-remote`, kernel.org `releases.json`, GitHub API)

| Tree | Branch / tag | Commit | Version | Note |
|---|---|---|---|---|
| torvalds | master | `23c62304dde2` | 7.4-rc2 (2026-11-09) | v7.4 final likely mid/late December 2026 |
| torvalds | tag v7.3 | `091b06388b11` | 7.3 | |
| stable | v7.3.4 | | 7.3.4 (2026-11-10) | newest stable |
| stable | v7.2.15 | | 7.2.15 (2026-11-01) | **EOL** (kernel.org `iseol`) |
| stable | v6.18.63 | | 6.18.63 LTS | |
| linux-next | next-20261113 | | | |
| **sc7280-mainline/linux** | **sc7280-7.3.y** | **`1cd0a2a93ac5`** (2026-11-13, tag `v7.3.0-sc7280`) | 7.3.0 base + patches | **newest community branch; the base for this track.** No 7.4 branch yet. |
| sc7280-mainline/linux | sc7280-7.2.y | `5016d406d3b9` | 7.2.y | our `linux/` checkout is older: `5b6560b07` (7.2.8) |
| sc7280-mainline/linux | sc7280-6.18.y-audio-fixups-clean-luca2 | `7401e10e0863` | 6.18 | audio WIP, worth reading for the q6afe card |
| android kernel/common | android18-7.3 | `8cb307d9ca5e` | 7.3.0 | ACK on the SAME base as sc7280-7.3.y (section 5) |
| android kernel/common | android-mainline | `f3a85265e02b` | Makefile says 7.3.0 | |
| android kernel/common | android17-6.18 | `7c083a341351` | 6.18 | our `ack/` is `00c8666046c2` (6.18.33) |
| qualcomm-linux/kernel | qcom-7.3 / qcom-next / qcom-6.18.y | `bda3031521c4` / `17bbb4b37bbc` / `a15b25c57f3c` | 7.3.0 / 7.3.0 / 6.18 | QCS6490 (RB3 Gen 2) fixes, AudioReach only |
| woa-a52s/linux | sc7280-6.15.y | `4de39531b11a` (pushed 2025-06-09) | 6.15 | **has `sm7325-samsung-a52sxq.dts` (1195 lines), `stmfts_fts5cu56a.c`, `sm5714-charger.c`, `sm5714-fg.c`.** the private project log only checked 6.14.y, which has none of these. Its dts has mistakes: a pmic-glink node and a placeholder panel `nothing,rm692e5-spacewar`. |
| korryasdlerto-lgtm/sc7280-mainline-linux-m52xq | master | `f19305c5ad05` (pushed 2026-11-05) | 7.1.x | Galaxy M52 (SM7325): `sm5714_charger.c`, `sm5714_fg.c`, `sm5714_typec.c`, `s2mpb03.c`, **`imx616.c`, `gc5035.c`** (two of our sensors), `s5kgw3.c`, `gc02m1b.c`, q6voice DT, wcd9385 + `qcom,sm8250-sndcard` |

Fetched for this plan: `linux/` now has `origin/sc7280-7.3.y` (depth 1, plus tag `v7.3.0-sc7280`). No other clones.

Offline check already done: `patches/ack-6.18/sm7325-samsung-a52sxq.dts` (the 6.18 harness board
file, upstream bindings) **compiles unchanged against sc7280-7.3.y** (`sm7325.dtsi` -> `kodiak.dtsi`
after the 7.x rename; cpp + `dtc -@`, 181 KB dtb, `__symbols__` present). Its 31 reserved-memory
regions do not overlap, and rmtfs is at `0x9c900000-0x9cb80000` (from `kodiak.dtsi`).

## 2. Inventory per block

Columns: **Upstream** = where the driver/binding exists (the `ack/` 6.18.33 tree, community 7.2.8 `linux/`,
community 7.3.0). "≤6.18" means it is already in the 6.18 tree; the first version was not bisected.
**Proven on 6.12/6.18** = hardware facts from our ports that a mainline dts can reuse.

| Block | Upstream | Missing for A52s | Proven facts to reuse (refs) |
|---|---|---|---|
| SoC basics (gcc, tlmm, rpmh, icc, llcc, smmu, tsens, cpufreq-epss, epss-l3) | ≤6.18; 7.x renames `sc7280.dtsi` -> `kodiak.dtsi`, `soc@0` | nothing; board values only | `&gcc protected-clocks` (touching one resets the phone); secure TLMM 56..59 in `gpio-reserved-ranges`; regulators pinned min == max to downstream `qcom,init-voltage` (regulator core programs the DT minimum, the private project log 2026-10-03); full table `downstream-dt/regulators-r02.txt`; DDR is LPDDR4X (`ddr_type 7`, drivers612/hwbringup/HARDWARE-LOG.md:136). L3: 5.4 votes at EPSS `+0x90` (drivers612/busdcvs/L3-MEMLAT.md); mainline `osm-l3.c` uses `EPSS_REG_PERF_STATE 0x320` for `qcom,sc7280-epss-l3`, so measure it with `l3measure.sh` |
| Hypervisor / watchdog | `gunyah_wdt.c` in 7.2+ (not in 6.18), registered by `qcom_scm` when the Gunyah UUID answers and `watchdog@17c10000` is `reserved` (it is, in kodiak.dtsi) | confirm the UUID check passes on this Haven build; otherwise build `modules/hhwdt` for 7.3 | same SMC IDs 5..8 as `modules/hhwdt`, **ms units**, max 32 s upstream; the counter stops in idle power collapse (the private project log 2026-11-12). The upstream probe stops the watchdog, which also stops one the ABL armed (good for real boots) |
| UFS | ≤6.18 | – | harness: L7B 2.952 V, L9B 1.2 V, L10C 0.88 V, L6B 1.2 V, reset TLMM 175; ICE upstream is enough (`inlinecrypt_optimized`, no wrapped keys) |
| USB | dwc3-qcom, snps HS, QMP combo ≤6.18 | Type-C/role from SM5714 (no driver); force `dr_mode=peripheral` until then | harness USB 2.0 gadget (NCM+ACM, 1209:a528) |
| microSD | sdhci-msm ≤6.18 | – | phone 1's card must never be written: keep `sdhc_2` disabled or mount read-only |
| Display DSI + S6E3FC3 (AMS646YD01) | MDSS/DPU/DSI 7nm + DSC ≤6.18 (spacewar runs DSC on sm7325); `panel-samsung-s6e3fc2x01.c` is in 7.2+ and does not match this panel | **new `drm_panel` driver**. The downstream DT has the on/off command arrays, DSC 1.1, 540x40 slices, 8 bpp, 1080x2400, 60/120 Hz (`downstream-dt/a52sxq-r02.dts:17546-17760`), so a lmdpdg-style generator applies. HBM, finger mask and AOD come later | rails L13C 3.0 V (vci), L8C 1.8 V (vddi); GPIO reset 44, TE 80, UB con-det 47, ESD irq 3 (drivers612/display/README.md); fb `0xe1000000`/`0x2300000`. UBWC: the 6.12 garbage-image bug was a UBWC version mismatch. Mainline takes UBWC from the root compatible `qcom,sm7325` -> `ubwc_3_1_hbb14`. hbb 14 matches the downstream LP4X entry; downstream SDE was 3.0: **verify 3.0 vs 3.1 with a UBWC test on hardware** |
| Touch ST FTS5CU56A | `stmfts` (older FingerTip protocol: wrong) | FTS5 driver: **port woa-a52s `stmfts_fts5cu56a.c` (6.15)** | I2C SE13 `i2c@a94000`, addr 0x49, IRQ TLMM 81 level-low, no reset line, AVDD L7C 3.0 V boot-on, fw `tsp_stm/fts5cu56a_a52sxq.bin` (drivers612/touch/README.md) |
| Keys / hall | gpio-keys, pmk8350 pwrkey/resin ≤6.18 | – | vol-up PM7325 GPIO 6 (in harness dts); hall TLMM 101 active-low; downstream sends Samsung's code 0x15, so map it to `SW_LID` (or `SW_MACHINE_COVER`) |
| SM5714 MFD / charger / FG / USB-PD / flash LED | none | **4 drivers.** Donors: woa 6.15 (charger, fg) and M52 7.1 (charger, fg, typec). The flash LED driver is new; logic from `leds-sm5714-fled` (drivers612/camera/FLASH.md: re-arm FLASH_BOOST at fire) | SE3 (TLMM 12/13): MFD 0x49, PCA9468 0x57, fled shares 0x49, so it must NOT be a separate i2c node (camera-overlay incident 2026-11-14); SE8 (32/33): usbpd 0x33; no supply properties; **pmic-glink is not used on this phone: do not copy it** (woa 6.15 dts has it) |
| PCA9468 direct charger | none (newest 5.15) | new power_supply driver, optional (25 W only) | SE3 0x57 |
| S2MPB03 camera PMIC | none | **M52 `s2mpb03.c`** | SE0 (TLMM 0/1) 0x56, 7 LDOs min == max (drivers612/power/DT-VALUES.md) |
| Audio WCD938x + TAS256x | q6afe/q6asm APR (the FP5 card uses `q6afedai` like us), lpass rx/tx/va/wsa macros, soundwire, `wcd938x`, `tas2562` (TAS2562/2564) all ≤6.18; AudioReach (`qcs6490-audioreach.dtsi`) does NOT fit the phone's Elite ADSP | board DT + machine card + UCM; voice needs q6voice (not upstream; M52 DT shows the out-of-tree route) | TAS on QUIN_MI2S, I2C 0x4c (`ti,right-channel`; 0x4d listed as left), irq TLMM 55, reset 63; WCD reset TLMM 83, rails L18B/L17B/BOB (drivers612/audio/README.md); ADSP firmware is Elite/APR. Read the chip ID before choosing `ti,tas2562` vs `ti,tas2564` |
| ADSP / CDSP / WPSS / MPSS remoteprocs | `qcom,sc7280-*-pas` ≤6.18; fastrpc ≤6.18 | firmware-name = **each phone's own** split `.mdt` from apnhlos/modem (read-only mount) | CDSP compute-cb SIDs `0x11ab..0x11ae`: kodiak.dtsi already matches (a wrong SID = silent SoC reset, the private project log 2026-11-13 21:50); pd-mapper `qcom,sm7325` domains are in-kernel upstream; phone 2 apnhlos = rollback-5 set (incident 2026-11-13) |
| Wi-Fi WCN6750 | ath11k ahb `qcom,wcn6750-wifi` ≤6.18 | ath11k board data (`board-2.bin`) built from the phone's own bdwlan; **never run on this phone** (both our tracks use qcacld) | WPSS boots from the phone's own image on 6.12/6.18; downstream SMMU window `0xa0000000/0x10000000` |
| Bluetooth | hci_qca `qcom,wcn6750-bt` ≤6.18 (serdev + PMU) | DT only | BT reset TLMM 85, sw-ctrl 86, WL reset 84 (`a52sxq-r02.dts:2807`) |
| Modem | mpss-pas, IPA `qcom,sc7280-ipa`, rmnet, qrtr ≤6.18 (7.3.y head: qrtr HELLO fix) | userspace: linux-msm rmtfs + tqftpserv + ModemManager (QMI over qrtr) | 6.12: rmtfs **RAM-only** (EFS copies in tmpfs) + static tqftpserv brought the modem fully up (the private project log 2026-11-13 19:29); the IPA must be up before the modem goes online; rmtfs carveout must be no-map |
| Sensors (SSC on ADSP) | fastrpc ≤6.18 | Linux: hexagonrpcd + libssc (pmOS) with the phone's sensor registry; Android HAL needs downstream `/dev/adsprpc-smd` (different UAPI) | 32 sensors on 6.12/6.18 through the ADSP sensors PD with the phone's own adsp |
| Grip SX9360 | IIO `sx9360` ≤6.18 | DT on `i2c-gpio`, addr 0x28 | |
| Cameras (CAMSS + IMX682 / S5KGW1P / IMX616 / S5KGD2 / GC5035) | CAMSS + CCI `qcom,sc7280-*` ≤6.18 (7.4-rc2 adds rb3gen2 imx219 overlays) | sensor drivers: **IMX616 + GC5035 from M52**; IMX682, S5KGW1P, S5KGD2 new (s5kgw3 as template); libcamera soft-ISP; S2MPB03 rails; flash = SM5714 fled | 6.12 camera DT `drivers612/camera/a52sxq-camera.dtsi` (CCI buses, sensor addresses, rails, EEPROM); 5 cameras enumerated |
| GPU | drm/msm `qcom,adreno-635.0` (chip 0x06030500), Turnip/freedreno; sm7325 boards use the kodiak node | zap = the phone's own `a660_zap` | 6.12 KGSL reports Adreno642Lv1 (a 635-class part; check the speed-bin fuse against the OPPs) |
| Video | venus `qcom,sc7280-venus` ≤6.18; **iris sc7280 in 7.2+** (same compatible) | the phone's own `vpu20_1v` | msm-vidc v1 works with it on 6.12/6.18 |
| Fingerprint ET713 (optical) | none | TZ-owned SPI (SE14, TLMM 56..59): the kernel only powers it (L3C 3.3 V, reset TLMM 35). Needs a QSEE trustlet (no upstream qseecom char dev; qcomtee is smcinvoke-style) plus HBM finger mask in the panel driver | drivers612/fingerprint/README.md, FOD.md |
| NFC S3NRN4V | `s3fwrn5` (S3FWRN5/S3FWRN82) ≤6.18 | try the s3fwrn5 NCI binding (the M52 fork uses `samsung,s3fwrn5-i2c` and reports NFC working; unverified for RN4V) | SE9 0x27, ven TLMM 38, firm 40, irq 41 |
| Vibrator | gpio-vibrator ≤6.18 | DT only | coin DC motor, enable TLMM 62 |
| Thermal / ADC | tsens, spmi-adc7/adc-tm5 ≤6.18 | thermistor channel DT | PM7325 gpio1/gpio4 (pa/wf thermistors) belong to the modem EE: writes are refused, and readings are only valid with the modem running (drivers612/power/THERMISTOR-ADC.md) |
| Suspend | s2idle, PSCI domain idle states (kodiak) | prove under Haven; deep sleep needs the owner's OK (a missed wake needs the keys) | s2idle shallow + RTC wake works on 6.12/6.18 with Wi-Fi/BT |

Bootloader (ABL) facts for any real boot. The kexec path does not need them.
- base dtb with `/__symbols__` (`-@`); a dtbo with `__fixups__`, padded with `dtc -p 65536`, and ≥16 KiB libufdt slack (`drivers612/realboot/tools/ufdt-host/check.sh`, drivers612/realboot/ABL-HANG.md).
- the hypervisor overlay needs placeholder `/soc { qcom,wdt@17c10000; tz-log; timer }` plus the labels `aliases`, `firmware`, `reserved_memory` (already in the harness dts; research/bootloader-acceptance.md).
- `COMMAND_LINE_SIZE` 4096; the ABL appends about 3 KB.
- AVB footer on recovery (`mkimage-ack.sh` checks); image + ramdisk ≤ 81 MiB.
- `mode-download = <0x15>` in /reboot-mode.

## 3. Boot and test strategy (key-free)

**Vehicle: the existing kexec harness. Nothing new goes on `recovery`.** The 6.18 harness
(`images/a52sxq-ack618-kexec9{,-p2}-recovery.img`) starts the mainline Image by
`kexec/kx-cycle.sh`. The payload sits on the unencrypted `/cache/a52kx` (~450 MB free). A reset,
panic or busy hang lands back in the harness, whose crash guard leaves for Download mode and then
Android with no keys (proven many times, the private project log 2026-11-11/12).

```
PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img \
KEXEC_BASE=<7.3 a52sxq dtb> KEXEC_OVERLAY=none KX_HOLD=1 \
kexec/kx-cycle.sh ml73-a <7.3 Image> <ramdisk> gen \
 "loglevel=7 printk.devkmsg=on clk_ignore_unused pd_ignore_unused regulator_ignore_unused \
  earlycon=a52ram,0xf0be0000 panic=10 softlockup_panic=1 a52.deadman=300 a52.net=43 a52.wdt=30"
```

- `kexec/mkkexecdtb.py` already knows the mainline paths (`/soc@0/watchdog@17c10000`, `/timer`). It copies the live memory reg, `/hypervisor`, `uh_*` regions and rmtfs; rmtfs is in kodiak.dtsi anyway.
- The ramoops layout must equal the harness (`0xe0000`, record `0x20000`). Using the same dts gives that for free.
- Port `patches/ack-6.18/files/a52ram.c` (RAM earlycon) so the harness can read `/proc/a52ram` after an early death.
- Userspace 1: **our `ramdisk/`** (`mkramdisk.sh`, NET=43 for phone 2). It is kernel-agnostic: needs DEVTMPFS, configfs NCM/ACM, PSTORE_RAM. Swap `hhwdt.ko` for `gunyah_wdt.ko` (`=m`, so the watchdog that kexec-run armed stays armed until the ramdisk takes over; `init` lines 58-76).
- Userspace 2: a postmarketOS/Alpine rootfs as squashfs on `/cache`, switch_root from our ramdisk. It brings Mesa/kmscube, ALSA UCM, ModemManager, rmtfs, tqftpserv, hexagonrpcd + libssc and libcamera.
  - The pmOS initramfs itself never opened a shell here.
  - NFS/nbd root is out for now: the phone cannot reach the PC (VPN, the private project log 2026-11-11 21:40).
- Risky drivers are `=m` and loaded from the ramdisk (`EXTRA=`, `ramdisk/extra/`), never built in. A built-in that kills every boot before the ramdisk is the one case that needs the keys.
- Phone 2 (bit 2) goes first for each new stage, then phone 1. Mute the phone after each kexec'd Android boot. Use each phone's own firmware only. Mount EFS/modem read-only, and run rmtfs RAM-only.

## 4. Android on mainline

| Option | dm-default-key / FBE | Blobs | Verdict |
|---|---|---|---|
| A. Test Android = phone 2's own LineageOS, `/data`+`/metadata` on zram (the kexec test mode used on 6.12/6.18) | not needed | the closed HALs fail on upstream UAPIs (no kgsl/SDE/ion/qseecom/legacy adsprpc) | only useful together with B or C |
| B. **`android18-7.3` ACK** (`8cb307d9ca5e`, same 7.3.0 base as sc7280-7.3.y) + the community board patches + our dts ("GKI-like mainline") | dm-default-key, Rust ashmem, binder, incfs all present | the 6.18 vendor modules (bsp618) carried 6.18 -> 7.3 with the same port method | **recommended Android vehicle.** It is the "next ACK branch" the 2026-11-08 direction names, and it already exists. Choosing it is the owner's call: the private project log says the target stays 6.18 unless he says |
| C. Pure 7.3/7.4 + carry ACK's dm-default-key (+ fscrypt/blk-crypto hooks) | patched in (M) | open HALs: Mesa freedreno/Turnip + drm_hwcomposer + minigbm, AOSP audio HAL on the upstream card, libcamera HAL, ModemManager-less RIL (none ready) | long; needs a ROM-side build (`$ANDROID_TREE`: only if the owner asks) |
| D. Fresh `/data` without metadata encryption on a test phone | none | as C | needs a test-phone data wipe: owner decision |

The real `/data` also needs KeyMint through QSEE, i.e. `/dev/qseecom`, which upstream does not
have. Pure mainline therefore needs the out-of-tree qseecom module (`drivers612/secure`, already
built for 6.18) to unlock CE keys. Two more 7.x gotchas, already solved on 6.18:
- the SELinux `system:firmware_load` check (6.14+) needs `bsp618/port/patches/ack-0002-selinux-no-firmware_load-check-on-direct-reads.patch`-style handling or a vendor policy change;
- `ro.bpf.kver_override`.

## 5. Phases (agent-days, rough; one phase at a time, after the 6.12/6.18 work they depend on)

| # | Phase | Effort | Exit test |
|---|---|---|---|
| M0 | 7.3 tree + config + dts port + a52ram + build (offline) | 0.5-1 d | Image + dtb build; `__symbols__`, no reserved overlaps, mkkexecdtb dry run |
| M1 | kexec to our ramdisk: harness parity (8 CPUs, UFS ro, USB NCM shell, simple-fb, ramoops, tsens, gunyah_wdt) | 1-2 d | `a52.kexeced` in cmdline, dmesg collected, clean `/leave` on both phones |
| M2 | board base: all regulators (pinned), PMIC/ADC/thermal, cpufreq + L3 measure, keys, hall, vibrator, remoteprocs ADSP/CDSP (own fw), fastrpc, SD read-only | 3-5 d | thermal zones sane, ADSP/CDSP running, no SoC reset |
| M3 | display (new S6E3FC3 panel driver + DSC) + touch (FTS5 port) + GPU (own zap, kmscube/Turnip) | 1.5-3 wk | image on the panel, touch events, UBWC test clean |
| M4 | Wi-Fi ath11k (board-2.bin from own bdwlan), BT hci_qca, modem (IPA/rmnet/qrtr, RAM-only rmtfs, ModemManager) | 1-2 wk | scan/join, BT scan, LTE registered + data ping |
| M5 | SM5714 fg -> charger -> typec/role switch -> fled; S2MPB03; PCA9468 last | 2-3 wk | battery %, charging with the owner present, USB role switch |
| M6 | audio (q6afe card, wcd938x, TAS, UCM), then voice (q6voice) | 2-4 wk | speaker/mic/jack; a call with the owner listening |
| M7 | sensors (hexagonrpcd + libssc), NFC (s3fwrn5 try), grip | 1-2 wk | accel events, NFC poll |
| M8 | cameras (CAMSS/CCI + IMX616, GC5035 from M52, then IMX682/S5KGW1P/S5KGD2) + video (iris) | 4-8 wk | libcamera raw/soft-ISP frames, iris decode |
| M9 | suspend under Haven (s2idle, then deep with owner OK) | 1-2 wk | RTC wake loop |
| M10 | Android: decide B/C; test Android on zram first | 4-12+ wk | boot_completed on the test Android |
| M11 | real ABL boot of a mainline kernel (owner window; rehearse with the ABL facts in section 2) | 2-4 d | boots from `boot`, way back ready |
| — | upstreaming dts + new drivers (panel, FTS5, SM5714, S2MPB03, sensors) | continuous | |

Rebase rule: follow sc7280-mainline's per-release branches (`sc7280-7.4.y` after v7.4). Do not
chase rc's.

### First 3 concrete steps (all offline)
DONE 2026-11-15 18:00 (see the private project log status log). Deviations from the text below: worktree `linux-7.3/`
(not `linux73/`), output `out-ml/`, script `./build-mainline.sh` with the ACK clang r596125 pins, ramdisk
`out-ml/ramdisk-ml.cpio.gz`; the first-run line is `out-ml/FIRST-RUN.txt` (a52.wdt=0, not 30: see there).
1. `git -C linux worktree add ../linux73 origin/sc7280-7.3.y` (`linux73/` is new: add it to `.gitignore`). Put the following in `linux73/`:
   - `patches/ack-6.18/sm7325-samsung-a52sxq.dts` (compiles unchanged, see section 1) plus its Makefile line;
   - `a52ram.c` with its Makefile hook;
   - `COMMAND_LINE_SIZE 4096`.

   Store all of it in a new `patches/mainline-7.3/`, kept up to date like `sync-ack-patches.sh`.
2. Config `fp5_defconfig` + `a52sxq.config` + DEVTMPFS, USB configfs NCM/ACM, PSTORE_RAM, `GUNYAH_WATCHDOG=m`, everything non-boot as `=m`. Build with `make ARCH=arm64 LLVM=1 O=../out-ml73` (system clang works for upstream trees; the ACK pins are only for `ack/`). Write `build-ml.sh` with the offline checks (symbols, reserved overlaps, ramoops layout = harness, Image size).
3. Build an NET=43 ramdisk with `gunyah_wdt.ko` + `hhwdt.ko` (7.3 build). Generate the kexec dtb with `mkkexecdtb.py` against `testdev-PHONE2/live.dtb`, and write the exact `kx-cycle.sh` line for the M1 run on phone 2. That run is the first on-phone step, in a later session.

## 6. Risks: what could need the owner's keys, and how to avoid it

| Risk | Needs keys? | Avoidance |
|---|---|---|
| kexec'd kernel deadlocks with idle CPUs before the ramdisk (the VM watchdog counter stops in idle power collapse) | **yes** | risky code `=m` from the ramdisk. In early cmdlines `softlockup_panic=1 panic=10` + hung_task panic. Try `cpuidle.off=1` so the counter keeps running (untested idea: verify it with `tools/wdtmeasure.sh` first) |
| silent SoC reset (wrong SMMU SID, protected clock, XPU) | no (harness catches it) | copy SIDs and protected-clocks from the phone, never from another board |
| any real boot through the ABL (`boot`/`recovery`): rb4-rb8 all needed keys | **yes** | only after M1-M3 work by kexec. Check the ABL facts of section 2 offline (ufdt-host), keep the harness as the way back, owner window, phone 2 first |
| loading another phone's / another version's signed firmware (raises the TZ rollback counter: incident 2026-11-13) | can brick features | firmware-name only to the phone's own mounted images; no `linux-firmware` qcom blobs for TZ-verified images |
| wrong regulator voltage / charger setting (hardware damage) | – | pin min == max from `regulators-r02.txt`; SM5714: fuel gauge read-only first, charger with conservative limits and the owner present |
| EFS/modemst writes by rmtfs | – | RAM-only rmtfs (6.12 recipe); backups in `testdev-PHONE2/backup-2026-11-14-prerealboot/` |
| phone 1 microSD | – | `sdhc_2` disabled or read-only |
| `gunyah_wdt` not registering (UUID check fails on this Haven) | no | keep `hhwdt.ko` (same SMCs) |
| speaker damage from TAS without protection | – | low volume limits in UCM until the smart-amp setup is understood |
| bootloader bit | – | never flash official firmware above bit 5 (phone 1) / bit 2 (phone 2) |
