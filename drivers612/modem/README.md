# drivers612/modem: cellular (calls + mobile data) on the 6.12 BSP

State 2026-11-14 16:30: **M1 passed on hardware** (phone 1, run `kx-m1b`, log
`logs/kx-m1b-p1-p1-160146/`): MPSS boots on 6.12, IPA FW loads, SSR recovery and a deliberate
SSR both work, no panic. The four problems that run showed are analysed and fixed or explained
in section 9 (built and checked offline; **not rerun yet**: "Next on hardware" there). The
Android-level cellular test is still **blocked on a firmware decision by the owner** (section 6).
19:30: **M2-K prepared** (kernel only, phone 1, open rmtfs + tqftpserv on RAM copies of the EFS
partitions; section 10). 19:29: **M2-K PASSED on 6.12** (run `kx-m2k-p1-p1-192337`: modem fully
up, no DOG stall, 45 modem QRTR services, EFS verify unchanged). 19:50: **M2-K for 6.18 prepared**
(`build-618.sh` + `run-m2-618.sh`, section 11). Built and checked offline, not run yet.

## 1. What is here

| Path | What |
|---|---|
| `build.sh` | builds `a52_modem_guard.ko` + `dev_ril_bridge.ko` against `bsp612/out/lahaina`, resolves all module dependencies with depmod, assembles the stages, the kernel-only test pack and the modem DT. Reads bsp612/, conn/, androidboot/ only; writes only `out/` and `stages/modem/resolved*.list` |
| `guard/a52_modem_guard.c` | NEW test-only module: a modem crash ends in SSR, never in a panic (section 4) |
| `stages/modem/targets.txt` | the synchronous stage `modem` (load before Android): guard, msm_sharedmem, memshare, glink_pkt, IPA, rmnet |
| `stages/modem/resolved.list` | the resolved load order (14 modules) as packed in `out/stage-modem/` |
| `stages/radio/{load.list,pre.sh}` | stage `radio@adsp`: `pre.sh` = rollback guard + force_sysfs_fallback + **EFS in RAM**; then `dev_ril_bridge.ko` |
| `dt/mkmodemtree.sh` | `out-ack/kx/android-r02.dtb` -> `out/android-modem-r02.dtb` (= `MODEM=1 kexec/mkandroidtree.sh` + memshare fix + checks) |
| `kpack/{m1.sh,all.sh,common.sh}` | kernel-only test M1 (busybox, no Android), packed as `out/pack-modem.tgz` |
| `run-m1.sh` | the kx-cycle command for M1 on phone 1 |
| `build-618.sh`, `run-m2-618.sh` | M2-K on the 6.18 kernel (section 11): pack, modem tree and cmdline in `out-618/`; the kx-cycle command for phone 1 |
| `check-load-kernelonly.py` | offline insmod simulation of the kernel-only order (init first stage, escape chain, dsp, modem, therm), per-module checks from `bsp618/android/check-load.py` |
| `tools/mbnver.py` | prints sw_id + anti-rollback version of a split image (`.mdt`/`.b01`), offline |
| `userspace/` | M2-K userspace (section 10): upstream linux-msm `qrtr`, `rmtfs`, `tqftpserv` (unmodified in `src/`, with their BSD-3-Clause LICENSE files), our patches in `patches/`, our `efsdump/`, and `build.sh` (static aarch64 musl, called by `../build.sh`) |
| `userspace/qmi-nas/` | ours: QMI client over AF_QIPCRTR (DMS/NAS/UIM read-only/WDS/WDA, rmnet_ipa0 ioctls, rmnet links), host unit test in `test/` (section 12) |
| `kpack/dataup.sh` | run by `qmi-nas data --run` in the `data` step: address, route and ping on `rmnet_data0` (section 12) |

Build: `drivers612/modem/build.sh` (~30 s). Outputs: `out/stage-modem/`, `out/stage-radio/`,
`out/pack-modem.tgz`, `out/android-modem-r02.dtb`. Every packed `.ko` is vermagic-checked
(`6.12.81-4k-g8a69376da734`), depmod over GKI + soc-repo + conn/data + ours reports nothing
unresolved, and the build refuses any `.mdt/.bNN/.mbn` in a stage or pack.

## 2. The 5.4 modem stack on this phone and its 6.12 counterpart

5.4 = the phone's QGKI kernel, everything below built in except the four rmnet modules.
Nodes from `downstream-dt/a52sxq-r02.dts`. "stage" = where the 6.12 module is loaded in the
Android test (`dsp` = drivers612/androidboot's stage, `modem`/`radio` = this directory).

| 5.4 node / driver | 6.12 module (source) | stage | state |
|---|---|---|---|
| `qcom,mss@4080000` pil-tz-generic, pas-id 4, ssctl 0x12, smem 421 | `qcom_q6v5_pas` (+`qcom_q6v5`, `rproc_qcom_common`, `mdt_loader`, `qcom_pil_info`), node `remoteproc-mss@4080000` "qcom,yupik-modem-pas" (same pas/ssctl/smem ids) | dsp | loads; MPSS **booted** in run ab-s18 (TZ accepted phone 2's then-valid image) |
| `msm_subsystem_restart`: `/dev/subsys_*`, `/sys/bus/msm_subsys` | `subsys_compat.ko` (drivers612/conn) | dsp | works: pm-service booted the modem through `/dev/subsys_modem` in ab-s18; restart_level RELATED by default |
| `qcom,smp2p-modem` (master/slave-kernel, ipa in/out) | `smp2p.ko`, base yupik.dtsi node | dsp | in tree |
| glink edge `modem` (IPCRTR, DS, glink_ssr) | `qcom_glink_smem`, edge under modem_pas (IPCRTR, DS; glink_ssr binds by channel name) | dsp | in tree |
| QRTR (`CONFIG_QRTR_NODE_ID=1`, userspace `qrtr-ns -f`) | `qrtr.ko` (first stage) + `qrtr-smd.ko`; same downstream ns + uapi | first/dsp | works (ADSP/CDSP services seen) |
| sysmon / SSCTL | `qcom_sysmon.ko` | dsp | loads; ADSP answers modem SSR events with "response result: 1, Retrying legacy EVENT_REQ" (seen in ab-s18, also for wpss) |
| PDR / service locator | `pdr_interface`, `qcom_pdr_msg`, **`qcom_pd_mapper_a52`** (kernel locator, sc7280 domains incl. `msm/modem/root_pd` gps/tms) + the vendor `pd-mapper` | dsp | both locators run (risk R3) |
| `qcom,rmtfs_sharedmem@0` UIO, client 1, vm-nav-path | `msm_sharedmem.ko`, same node in base (driver source identical to 5.4 except `hyp_assign_phys` -> `qcom_scm_assign_mem`) | **modem** | M1: `uio0` name `rmtfs`, 1.0, 0x280000 at a dynamic address, assign OK; no server yet (section 9, item 4) |
| `qcom,memshare` clients 0/1/2 + Samsung client_4 (id 3) | `msm_memshare.ko` + `heap_mem_ext_v01.ko`; client_4 disabled (DT fix, = what 5.4 ends up with) | **modem** | M1: probes, QMI service up; client-3 WARN fixed 11-14 (section 9, item 2) |
| `qcom,ipa@1e00000` v4.11, `qcom,ipa_fws` PIL, `qcom,msm_gsi`, `qcom,rmnet-ipa` | `gsim`, `ipam`, `ipanetm`, `rmnet_mem` (+`usb_f_gsi`) from conn/data (dataipa r30); IPA fw loaded by the driver itself (pas-id 0xf, region 0x8b710000) | **modem** | M1: `IPA FW loaded successfully`, `IPA driver initialization was successful`, `rmnet_ipa0`; two harmless messages (section 9, item 3) |
| datarmnet `rmnet_core`, `rmnet_ctl`, `rmnet_offload`, `rmnet_shs` (the only 5.4 modules) | same names from conn/data | **modem** | M1: `rmnet_core` FAILED (built against the IPA stubs), offload/shs unresolved; fixed 11-14 in conn/data (section 9, item 1), not rerun |
| `qcom,glinkpkt` (smd4 glink_bridge, smd7/8/11, smdcntl8, at_mdm0, apr_apps2) | `glink_pkt.ko` | **modem** | M1: loads |
| `drivers/misc/drb` `/dev/drb` | `dev_ril_bridge.ko` (conn/rild/drb source, rebuilt here) | **radio** | built |
| `qmi-tmd-devices/modem` (PA, skin, mmw mitigation), `qmi-ts-sensors` | `qti_qmi_cdev.ko`, `qti_qmi_sensor.ko` | not staged | needed by thermal-engine for modem throttling: add before long data runs |
| modem minidump / ramdump | `qcom_va_minidump`, `qcom_ramdump`; coredump off by the guard | display/dsp | - |
| `qrtr-haven`, `rdbg_modem`, ESOC/MHI | not needed (integrated modem; ESOC/MHI absent on 5.4 too) | - | - |
| ADSP / CDSP interplay | ADSP must run before audio; voice calls use the ADSP voice path (audio stack); CDSP not involved | dsp/audio | ADSP+CDSP up in Android runs |

## 3. What the vendor radio userspace expects (LineageOS + Samsung blobs, sm7325-common rc)

- `vendor.per_mgr` (pm-service) + `vendor.per_proxy`: `/dev/subsys_modem` open = modem up;
  `libmdmdetect` scans `/sys/bus/msm_subsys/devices/subsysN/name` (rild says "There's no valid
  ESOC node" when it finds nothing). -> subsys_compat.
- `vendor.rmt_storage`: `/sys/class/uio/uio*/{name=rmtfs,version,maps/map0/{addr,size}}`, mmap
  of `/dev/uioN`, read-write block devices `/dev/block/bootdevice/by-name/{modemst1,modemst2,fsg,fsc}`.
  -> msm_sharedmem + (test only) the EFS RAM shim, because testguard keeps those four read-only.
- `vendor.tftp_server`, `vendor.qrtr-ns -f`, `vendor.pd_mapper`, `time_daemon`, gnss HAL,
  `xtra-daemon`, `thermal-engine`, `cnss-daemon`: AF_QIPCRTR sockets (uapi identical to 5.4).
- `ipa_fws.rc`: `on early-boot write /dev/ipa 1` (triggers the IPA firmware load). `/dev/ipa`
  must exist before that line runs, or init creates a plain file there (ab-s18 avc
  "create ... name=ipa"). -> IPA in the synchronous `modem` stage.
- `netmgrd.rc`: `modprobe -d /vendor/lib/modules rmnet_ctl rmnet_core` (the ROM's 5.4 .ko; ab-s18
  shows "this_module section size must match"). With ours loaded first, modprobe finds them.
- Samsung `ril-daemon` (`/vendor/bin/hw/rild`, class main; the QC `vendor.ril-daemon*` are
  `rild-dummy`): `/dev/drb`, ~120 QRTR QMI sockets, rtnetlink "rmnet" links on `rmnet_ipa0`,
  `SIOCDEVPRIVATE` extended ioctls on `rmnet_ipa0` (`ipa3_wwan_ioctl`, `.ndo_siocdevprivate`
  wired in dataipa r30), `/sys/class/power_supply/battery/voltage_now`,
  `/sys/class/lcd/panel/mipi_switch`, `/sys/class/nfc_sec/nfc_support`, `/efs`, `/mnt/vendor/efs`.
  Details and the remaining uapi deltas: `../conn/rild/GAPS.md` (G3: `RMNET_IOCTL_EXTENDED_V2`
  now succeeds; G5: Samsung procfs knobs absent).
- IMS/VoLTE: no extra kernel interface (an IMS PDN is one more `rmnet_data` link + QMI IMS
  services over QRTR). Whether the LineageOS userspace on phone 2 does VoLTE at all is a
  userspace question; without it, calls fall back to 2G CSFB.

## 4. Run ab-s18 (2026-11-13 19:15): what really happened, and the crash/recovery config

Log: `logs/kxfin-ab-s18-p2-191459/prev-console.txt` (console filtered to error level after
~19 s: Android lowers the console loglevel, so dev_info/dev_warn lines are missing after that).

1. 3.8 s: dsp stage, subsys_compat: `qcom rproc: 4080000.remoteproc-mss: recovery enabled`.
2. 19.3 s: rmt_storage starts: `Mmap Failed for rmts (-1)...pausing execution!` (no
   msm_sharedmem -> no `/dev/uio0`). No IPA modules, no memshare, no glink_pkt were loaded;
   `/dev/ipa` was created by init as a plain file.
3. 19.8 s: pm-service opens `/dev/subsys_modem`: TZ accepts phone 2's own modem (rollback 2,
   before the incident), MPSS runs (sysmon notifications go out).
4. 86.2 s (66 s later): `fatal error received: dog_hal_common.c:177:DOG detects stalled
   initialization` -> recovery #1 reloads the image (works) -> 152.1 s (66 s later) the same
   stall -> recovery #2: `request_firmware failed: -2` -> rproc_qcom_common's vendor hook
   `qcom_check_ssr_status()`: **"Kernel panic - Panicking, remoteproc 4080000.remoteproc-mss
   failed to recover!"**.

So "without IPA it crashed" (the private project log 19:15) is not what the log shows. The modem stalled in
its own initialisation, twice, 66 s after each start. Ranked causes: (a) no RMTFS server
(rmt_storage could not map the shared buffer, so the MPSS never got its EFS: NV items, RF
calibration, IMEI); (b) no IPA (the modem's IPA driver waits for the AP-side IPA QMI
handshake); (c) no memshare service. All three are now in the `modem` stage. In a test run,
rmt_storage also needs the EFS RAM shim (`radio` pre.sh), because testguard makes the real
partitions read-only and rmt_storage opens them read-write.

Why the second `request_firmware` returned -2 while the first one worked is **not explained**:
the loglevel hides the fallback lines. Things that make the test independent of it:
`pre.sh` sets `force_sysfs_fallback=1` (ueventd lists /vendor/firmware-modem/image), and the
guard boots the modem again after 20 s, up to 3 times, if a recovery leaves it offline.

**Crash/recovery configuration (what a modem crash does now):**

| Path in soc-repo r70 | Before | With `a52_modem_guard` (defaults) |
|---|---|---|
| modem crash with recovery enabled -> `rproc_crash_handler_work` -> recovery | SSR | SSR (same) |
| recovery fails -> `qcom_check_ssr_status` (vendor hook) | **panic** | WARN; guard retries the boot (`retries=3`, `retry_delay=20`) |
| SSR / sysmon / PDR notification timeouts | WARN (config off) | WARN |
| recovery disabled (restart_level SYSTEM via ssr_setup, sysfs `recovery`) -> `qcom_q6v5_crash_handler_work` | **panic** | cannot happen for the modem: the guard re-enables recovery (`keep_recovery=1`) |
| coredump of the 246 MiB MPSS region per crash | default (copy) | off (`coredump=0`) |
| TZ refuses the image at **init** (rollback too low, e.g. phone 2's own modem) | `error -22 initializing firmware`, no panic | same |
| TZ accepts init but refuses **auth_and_reset**; `pas_shutdown` fails | **panic** (unconditional in qcom_q6v5_pas) | still panic: not coverable without patching soc-repo. The kexec harness's crash guard brings the phone back (proven path) |

The guard flips rproc_qcom_common's exported `qcom_device_shutdown_in_progress`, which in r70
gates exactly the four SSR-related panics (qcom_common.c, qcom_sysmon.c, pdr_interface.c);
userspace equivalent `echo 1 > /sys/kernel/qcom_rproc/shutdown_in_progress`. It is test-only:
for a real ROM boot the same effect comes from restart_level RELATED for the modem
(subsys_compat default, or `persist.vendor.ssr.restart_level` via ssr_setup), coredump off and
that sysfs write in an init script; the retry logic is a test convenience.

## 5. Device tree for MODEM=1

`dt/mkmodemtree.sh` (run by build.sh) starts from the current Android tree
(`out-ack/kx/android-r02.dtb`, made by `kexec/mkandroidtree.sh`, which already contains conn's
IPA/rmnet/glinkpkt/icnss2 fragment) and changes only:
1. `modem_pas` status okay (what `MODEM=1` does);
2. memshare `qcom,client_4` (Samsung, client-id 3): `status = "disabled"`. 5.4 ends up
   without this client on both test phones: `androidboot.reserve_mem_region=0x0`, its
   `memory-region` (`modem_shared_mem@d0000000`) has reg size 0, so the reservation fails, the
   region gets no ops and 5.4's `memshare_child_probe()` fails in
   `of_reserved_mem_device_init()` (-EINVAL). Details: section 9, item 2. (Until 11-14 this
   step set `qcom,peripheral-size = 0` instead; that registered a 0-byte client and the
   6.12 driver then hit a page_alloc WARN, run kx-m1b.)

and checks: mpss region `0x8b800000 + 0xf600000`, IPA GSI fw region `0x8b710000 + 0xa000`,
`firmware-name = "modem.mdt"`, IPA/GSI/rmnet-ipa/rmtfs/glinkpkt/memshare nodes enabled,
`qcom,max_num_smmu_cb = 4` with 4 cb children, IPA smp2p entries, no upstream
`qcom,rmtfs-mem` node, no `qcom,sc7280` in the root compatible. The harness's live
`rmtfs@9c900000` (assigned to the modem by the 6.18 harness) is carried in as no-map by
`kexec/mkkexecdtb.py` at kexec time (fix of 2026-11-14 11:20), nothing to do here.
Diff against the base tree: exactly those 2 `status` properties. mkmodemtree.sh also checks
that memshare clients 1/2/3 (ids 0/2/1) are present and enabled.

## 6. The firmware question (owner decides; nothing here loads non-own firmware)

What the modem needs from TrustZone-authenticated images:

| Image | Where on the phone | pas-id / sw_id |
|---|---|---|
| `modem.mdt` + `modem.b00..b28` (MPSS) | partition `modem` (vfat), `/vendor/firmware-modem/image` | 4 / 0x2 |
| `yupik_ipa_fws.mdt/.b0x` (IPA GSI firmware) | partition `apnhlos`, `/vendor/firmware_mnt/image` | 0xf / 0x1d |

Not TZ-loaded but from the same `modem` partition: `modemr.jsn` (pd-mapper), `modem_pr/mcfg`
(carrier configs, served by tftp_server), `qdsp6m.qdb` (diag). Voice also needs the ADSP.

Anti-rollback versions, read offline with `tools/mbnver.py` (OEM metadata of the hash
segment; offset 0xa4 of `.b01` for these v6 headers):

| Image | Rollback | Note |
|---|---|---|
| phone 2's `modem` partition (backup `testdev-PHONE2/backup-2026-11-13-incident/modem.img`) | **2** | byte-identical `modem.mdt`/`.b01` to Samsung's official DWB5 CP: it is phone 2's own image |
| phone 2's TZ counter since the incident | **5** | `RP SWREV B2(2,5,...)`: one shared counter for all subsystem images -> its own modem is **refused** |
| phone 2's apnhlos `yupik_ipa_fws`, `adsp`, `cdsp`, ... | 5 | phone 1's copies, written by the owner on 2026-11-13 |
| official FWK4 CP (`stock-firmware/fw-FWK4`, phone 1's firmware version) | **5** | same MPSS build id string `MPSS.HI.4.1.1-00392` as DWB5 |
| official A528BXXSAGYA2 CP (`stock-firmware/fw`) | **10** | would raise any phone's counter to 10: then every rollback-5 image on it is refused. **Never.** |
| phone 1's own modem | not read (no phone access) | expected 5 (FWK4); `kpack/m1.sh` reads and checks it before booting |

Consequences:
- **Phone 1** (`PHONE1`, bit 5, its own modem): the kernel-only test M1 needs no decision.
  An Android-level test on phone 1 is not possible today: its One UI port is a user build, the
  test mode needs a permissive (userdebug) init (`drivers612/androidboot/README.md` item 5).
- **Phone 2** (`PHONE2`): its own modem cannot run (also not on its own LineageOS 5.4). An
  Android test there checks everything except the modem itself (A0 below).
- Cellular in Android on 6.12 therefore needs ONE of these, each only with the owner's explicit
  OK (listed for the decision, not proposed):
  1. a test device whose own modem its TZ accepts and that runs a userdebug Android (a third
     phone, or phone 1 with a different ROM);
  2. phone 2 with a rollback-5 modem image (the official FWK4 CP is the only one known with
     exactly 5: equal to its counter, so no further raise), either written to its `modem`
     partition (also restores cellular on its LineageOS; unknowns: Odin/bootloader checks of a
     bit-5 CP on a bit-2 bootloader, MPSS-vs-TZ/AOP compatibility across firmware versions) or
     loaded from RAM only for a test run (needs the firmware refusal in
     `androidboot/pack-kexec-rd.sh` lifted for that file set);
  3. Android test mode for user builds (labelled shims on a real filesystem; large).
- Whatever is chosen: no image with rollback > 5 on either phone; check every candidate with
  `tools/mbnver.py` first. `pre.sh` and `m1.sh` refuse to boot a modem whose rollback is above
  the phone's ADSP image's.

## 7. Hardware test plan

General: the main session runs these, on the named test phone only, via the kexec chain
(nothing flashed). Before any run: `drivers612/modem/build.sh`. Each run ends in Android by
itself (deadman, crash guard); `KX_HOLD=1` for interactive work, then `kexec/kx-finish.sh`.

### M1: kernel only, phone 1, its own modem (no decision needed)

Pre-check from phone 1's own Android (read only):

    adb -s PHONE1 shell su -c 'for f in /vendor/firmware-modem/image/modem.b01 /vendor/firmware_mnt/image/adsp.b01 /vendor/firmware_mnt/image/yupik_ipa_fws.b01; do echo "$f $(od -An -tu1 -j164 -N1 $f)"; done; cat /vendor/firmware-modem/verinfo/ver_info.txt'

Expected: all three 5 (FWK4). If the modem value is higher than adsp: STOP (m1.sh refuses too).

Run: `drivers612/modem/run-m1.sh m1a` (PHONE=1, harness kexec9, tree
`out/android-modem-r02.dtb`, pack `out/pack-modem.tgz`, `sh /p/all.sh 100`, deadman 420 s).
m1.sh: mounts the phone's own `modem` + `apnhlos` partitions read-only (vfat), symlinks only
`modem.*`, `modemr.jsn`, `yupik_ipa_fws.*` into `/lib/firmware`, prints the rollback values,
loads dsp + modem stages, checks uio/memshare/IPA nodes, `echo 1 > /dev/ipa`, lists QRTR,
opens `/dev/subsys_modem`, lists QRTR for 20 s, waits 100 s, triggers one deliberate SSR
(`echo 1 > /sys/kernel/debug/remoteproc/<mss>/crash`), closes the fd.
Optional `therm` argument (`M1_ARGS="100 therm"`): Test T1 of
`drivers612/power/THERMISTOR-ADC.md` (PMIC VADC + PM7325 gpio1..4 read-only samples with the
modem off / up / stopped; lines `T1 ...` at the end of kexeced-extra.txt).

Pass criteria, in order:
1. `a52_modem_guard: SSR panics off` and `guarding 4080000.remoteproc-mss (offline, recovery enabled, coredump off ...)`
2. `/sys/class/uio/uio0` name `rmtfs`, size 0x280000; memshare probes; `/dev/smd*` + `/dev/at_mdm0` exist
3. IPA: `IPA FW loaded successfully`, `IPA driver initialization was successful.`, `rmnet_ipa0` in `ip link`
4. `remote processor 4080000.remoteproc-mss is now up`; `subsys3/state` ONLINE
5. QRTR servers from the modem node (at least SSCTL 43, then more; RMTFS client activity has
   no server here); memshare alloc requests in dmesg
6. If the DOG stall comes (expected, no rmt_storage): `handling crash #1`, recovery, guard
   message, **no panic**; the deliberate SSR: stop + `Booting fw image modem.mdt` + up again
7. `exec 3<&-` -> OFFLINE. Run ends in Android without keys.

Failure table:

| Symptom | Meaning / next step |
|---|---|
| `error -22 initializing firmware modem.mdt` | TZ refused the image: rollback or wrong image. Do not try other images. |
| panic "auth and reset failed" | TZ refused auth_and_reset (not coverable by the guard): harness brings the phone back; compare `pil_mpss_mem` with the phone, pas-id 4 |
| `start timed out` | MSS did not signal ready: smp2p-modem interrupts, `qcom,smem-states` |
| ipam does not probe | `cat /sys/kernel/debug/devices_deferred`; usb_f_gsi/dwc3-msm, SMMU cbs (`max_num_smmu_cb`) |
| modem crashes within seconds of `up` with an IPA/`ipa_q6` message | IPA FW not loaded before the modem: check step 3 |
| SoC reset with nothing in the console | SMMU/XPU class (like the CDSP cb SID bug of 2026-11-13): check IPA SIDs 0x480..0x483 vs the phone |

### A0: Android, phone 2, modem tree, own modem refused (no decision needed)

Checks everything around the modem in Android. Phone 2's own modem is refused by TZ at init
(`-22`, no panic, the same thing its own LineageOS hits on every boot).

    A=drivers612/androidboot; M=drivers612/modem
    (cd $A && STAGES="$(for s in debug secure display kgsl i2c nfc touch fingerprint powerpd vibrator camera dsp wlanb wlan audio; do printf '%s:%s ' $s $PWD/out/stage-$s; done)modem:$PWD/../modem/out/stage-modem radio:$PWD/../modem/out/stage-radio" \
       BINDS="$PWD/shims/netd.rc:/system/etc/init/netd.rc" ./pack-kexec-rd.sh m0)
    PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img KEXEC_BASE=$M/out/android-modem-r02.dtb \
      KEXEC_OVERLAY=none KX_HOLD=1 kexec/kx-cycle.sh ab-m0 bsp612/out/dist/Image $A/out/m0-rd.cpio.gz gen \
      "$(cat $A/out/android-cmdline.txt) log_buf_len=4M a52.mods=debug,secure,display,kgsl,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,modem,wlanb,audio@adsp,wlan@adsp,radio@adsp"

Check (telnet `TSH_IP=172.16.43.1 tools/tsh.py`, or adb):
`dmesg | grep -E 'a52sxq-init: (radio|insmod FAILED)|a52_modem_guard|ipa|rmtfs|memshare|4080000'`,
`ls -l /dev/ipa /dev/uio0 /dev/drb /dev/smd4 /dev/subsys_modem` (in Android: `/dev/ipa` a char
device 0660 radio), `ip link | grep rmnet`, `cat /sys/bus/msm_subsys/devices/subsys3/state`,
`an 'logcat -d -b radio' | tail`, `an 'getprop | grep -E "ril|baseband|per_mgr"'`. Pass:
no module failures, `EFS shim: 4 of 4 partitions in RAM` and `default namespace: ... is the RAM
copy` x4, IPA ready after early-boot, pm-service's boot fails with -22 and no panic, rild
running without "no valid ESOC node". Then `TSH_IP=172.16.43.1 tools/tsh.py /leave; PHONE=2
kexec/kx-finish.sh ab-m0`.

### A1: Android cellular (blocked: section 6)

On a device/image combination the owner approved, same command as A0. Needs a SIM in the
phone (owner). Steps and pass criteria:
1. modem ONLINE, no crash for 5 min; QRTR servers (push `drivers612/conn/tools/qrtrls` with `tools/tput.py`):
   DMS 2, NAS 3, WDS 1, UIM 11, VOICE 9, WMS 5, WDA 26, PDC 36, IPA 49 (inst 2 modem, 1 apps),
   LOC 16, RMTFS 14 answered by rmt_storage, memshare.
2. `an 'dumpsys telephony.registry' | grep -E 'mServiceState|mSignalStrength'`: SIM detected,
   registered; IMEI shown (Settings > About phone), proving the EFS came through the RAM shim.
3. Mobile data (Wi-Fi off): `rmnet_data0` up with an address, `ping -I rmnet_data0 1.1.1.1`.
   If the data call fails in format negotiation: GAPS G3 (reject `RMNET_IOCTL_EXTENDED_V2`).
4. A voice call only with the owner (it uses his SIM and his time): MO call, audio both ways.
5. SSR under Android: `echo 1 > /sys/kernel/debug/remoteproc/<mss>/crash`: modem back,
   rild re-registers, no panic; repeat twice (the -2 question of section 4).

## 8. Open points / what is still missing

1. DOG stall: M1 had IPA up (FW loaded, AP QMI service 49 inst 1) and memshare up, and the
   stall still came at 80 s (65 s after `up`, as in ab-s18): the remaining candidates are the
   missing RMTFS server (first) and TFTP/pd-mapper (vendor userspace), so M2 (section 9) is
   the test that decides. The `request_firmware -2` of ab-s18's second recovery did not recur
   in M1 (both reloads worked; firmware from `/lib/firmware`), still unexplained under Android.
2. Firmware for an Android cellular test: owner's decision (section 6).
3. R3: two service locators (kernel `qcom_pd_mapper_a52` with `msm/modem/root_pd` =
   gps/gps_service + tms/pdr_enabled; vendor `pd-mapper` with modemr.jsn = tms/servreg +
   gps/gps_service). If GNSS or a modem PD lookup fails, check `qrtrls` for two servers of
   service 64 and drop one.
4. Modem thermal mitigation (`qti_qmi_cdev`, `qti_qmi_sensor`) not staged.
5. Unguarded panics: auth_and_reset refusal, `pas_shutdown` failure (section 4 table).
6. `msm_sharedmem`'s hypervisor assign (vm-nav-path) under Gunyah: unverified; a wrong assign
   shows up as a modem crash on its first RMTFS access.
7. conn GAPS G3..G6 (rmnet V2 ioctl, ttyHS8, Samsung procfs knobs, ipam -> usb_f_gsi).
8. The real boot path: DONE offline 2026-11-15 as `MODEM=1` (rb12, `drivers612/realboot/README.md`
   section 2e): the `modem` stage minus the guard + `dev_ril_bridge.ko` at the end of the FIRST
   stage (not vendor modules: /dev/ipa before ipa_fws.rc's early-boot write), the ROM's own
   rmt_storage on the real EFS (no testguard there); restart_level RELATED is subsys_compat's
   default and the rproc coredump is off by default, so no init script. The rehearsal
   (`rh612p1m`) serves the EFS from RAM like `radio/pre.sh` meant to (efsdump + loop + bind).
9. 6.18 (bsp618) not covered here.
9b. IPA SMMU IOVA windows: fixed 2026-11-15 (`dt/ipa-iova-fix.sh`, called by `dt/mkmodemtree.sh`;
    `IPA_IOVA_FIX=0` = the M1/M2 trees): the 2+2-cell iommu-addresses were read with /soc's 1+1
    cells ("Cannot reserve IOVA region of 0 size" in every run), the AP fastmap range was
    [0x40000000, 4 GiB) instead of the 5.4 pool 0x20000000 + 512 MiB. `out/android-modem-r02.dtb`
    predates the fix (rebuild with build.sh before the next kernel-only run).
10. IPA SRAM map of dataipa r30 for v4.11 differs from the 5.4 techpack (section 9, item 3):
    FnR stats region gone, quota/tethering/pdn moved up 0x800, and r30 sends the modem a
    `hw_filter_stats_info` TLV (start 0x27B0, 191 x 16 bytes) that 5.4 never sent. Watch in
    A1 data tests; candidate patch: 5.4's `ipa_4_11_mem_part` values.

## 9. M1 result (run kx-m1b, 2026-11-14) and the fixes of 16:30

Run: `logs/kx-m1b-p1-p1-160146/` (`kexeced-dmesg-after.txt`, `kexeced-extra.txt`; the earlier
`kx-m1a-p1-155837` crash is unrelated: no Qualcomm bootargs). Timeline: 13.9 s guard active;
14.13 `IPA FW loaded successfully` + `IPA driver initialization was successful`; 14.25 open
`/dev/subsys_modem`; 15.14 `4080000.remoteproc-mss is now up`; QRTR from the modem in 20 s:
only SSCTL 43 and the PDR notifier 66; 80.17 `DOG detects stalled initialization` -> recovery
#1 OK (80.75); deliberate SSR 143.2 -> up again 143.8; vote released 158 -> offline
(`timeout waiting for shutdown ack` WARN at 168.4, known, harmless); no panic.

### Item 1: rmnet_core.ko failed to insmod -> rmnet_offload / rmnet_shs unresolved

- Symptom: `FAIL rmnet_core.ko` with no kernel message (so not a symbol error: its init
  returned an error), and before it `rmnet_ctl_init: -1`. offload/shs then miss every
  rmnet_core export (`rmnet_get_port`, `rmnet_frag_*`, the `rmnet_shs_*` tracepoints).
- Cause: `-1` = `-EPERM` from the **stub** `ipa_register_ipa_ready_cb()` in dataipa's
  `include/linux/ipa.h` (the `#else /* IS_ENABLED(CONFIG_IPA3) */` branch). rmnet_ctl and
  rmnet_core were compiled with `CONFIG_IPA3` undefined: `modinfo` showed
  `depends: rmnet_mem,rmnet_ctl,qmi_helpers` (no `ipam`), `nm -u` showed no `ipa_*` import.
  rmnet_ctl ignores the error; rmnet_core's `rmnet_init()` -> `rmnet_ll_init()` ->
  `rmnet_ll_ipa_init()` returns it -> module init fails. In bazel, `rmnet_ctl`/`rmnet_core`
  depend on the `ipam` ddk_module, whose defconfig (`config/dataipa_GKI.conf`:
  `CONFIG_IPA3=m`) kleaf hands to its dependents; our single `M=` tree only force-includes
  `dataipa_vendor.h` for dataipa's own objects. Load order was right (ipam before rmnet_*).
- Fix: `drivers612/conn/data/src/Kbuild`: `LINUXINCLUDE += -DCONFIG_IPA3_MODULE=1` (what
  kleaf's propagation gives). dataipa itself is unaffected (it already had `CONFIG_IPA3`, no
  `IS_MODULE/IS_BUILTIN` users); datarmnet-ext does not include ipa.h. Rebuilt
  (`drivers612/conn/data/build.sh`: 13 modules, 0 warnings, depmod clean). Now
  `rmnet_core: depends ipam,rmnet_mem,rmnet_ctl,qmi_helpers`, imports
  `ipa_register_ipa_ready_cb`, `ipa_register_rmnet_ll_cb`, `ipa_rmnet_ll_xmit`, ...;
  `rmnet_ctl: depends qcom_ipc_logging,ipam`, imports `ipa_register_rmnet_ctl_cb`, ... At
  insmod time IPA is not ready yet (FW loads ~25 ms later), so both register a ready callback
  (return 0) and attach when IPA finishes, as on 5.4 (where IPA was built in).

### Item 2: memshare client id 3: 96 MiB then 32 MiB -> page_alloc WARN

- 5.4: client 3 (`qcom,client_4`, label modem, Samsung's CP RAM-log buffer:
  peripheral-size 32 MiB + reserved-size 64 MiB = 0x6000000 = the 96 MiB request, the 32 MiB
  retry = peripheral-size alone) is **never served** on these phones. Both bootloaders pass
  `androidboot.reserve_mem_region=0x0` and `androidboot.cp_reserved_mem=off`
  (`testdev-PHONE1/last_kmsg-*`); its `memory-region` `modem_shared_mem@d0000000`
  ("modem-removed-dma-pool", `reg` size 0, `non_gki_size` 0x6000000) is not reserved ("failed
  to reserve memory for node 'modem_shared_mem_region@d0000000' ... size 0 MiB"), so
  `fdt_init_reserved_mem()` -> `__reserved_mem_alloc_size()` fails (no `size` property) and the
  region never gets ops; `memshare_child_probe()` -> `of_reserved_mem_device_init()` ->
  -EINVAL -> child probe fails -> client 3 not registered. The modem's requests then hit
  `check_client()` -> "client not found" (5.4 sends no reply). With a non-zero
  reserve_mem_region Samsung's `CONFIG_CP_DYNAMIC_MEM_RESERVE` code would size it 32 or
  96 MiB from that region; it is not active here.
- 6.12 before: the kx-m1b tree kept the client with `peripheral-size 0` and no region:
  `init_size` 0 -> request clipped to 0 -> `dma_alloc_attrs(size 0)` -> `get_order(0)` = 52
  (x1/x19 = 0x34 in the WARN) -> `WARN_ON_ONCE(order > MAX_PAGE_ORDER)` in
  `__alloc_pages_noprof`, failure reply.
- Fix: `dt/mkmodemtree.sh` sets `qcom,client_4` `status = "disabled"` (and leaves its other
  properties as in the base): client 3 is not registered, as on 5.4; the 6.12 driver logs
  `memshare_alloc: client not found ... requested client: 3` and replies failure without
  allocating. Clients 0 (GPS, boot-time, size 0), 2 (DIAG) and 1 (FTM, 5 MiB on request from
  `memshare_region`, shared-dma-pool) unchanged and checked. Not serving the 96 MiB is the
  5.4 behaviour; serving it would also need a hyp assign of 96 MiB to MSS+HLOS that 5.4 never
  does on these phones.

### Item 3: IPA "Invalid source resource group, index #2" x5, "SRAM partition too small: 0 needed 512"

- Version/flavour: the same as 5.4. DT `qcom,ipa-hw-ver = <0x14>` (20 = `IPA_HW_v4_11`),
  `qcom,platform-type = <1>` (MSM), `qcom,ipa-hw-mode = <0>`, `qcom,ee = <0>`, same property
  set as `downstream-dt/a52sxq-r02.dts`; `ipa3_get_hw_type_index()` -> `IPA_4_11` (no
  MHI/APQ/auto variants for 4.11). No DT/config mismatch, nothing to change in the DT.
- Resource groups: **harmless, identical on 5.4.** `ipa3_set_resorce_groups_min_max_limits()`
  walks group pairs j = 0, 2 up to `IPA_v4_11_SRC_GROUP_MAX` (3); for 4.11 only group 0
  (UL_DL) exists on the source side, so j = 2 hits the `default:` of the 4.11 switch once per
  source resource type (5 types = 5 lines). The table entries for that pair are all {0,0}, so
  nothing is lost. The 5.4 techpack (`techpack/dataipa/.../ipa_utils.c`) has the same
  constants and the same switch (prints with `IPAERR` there).
- FnR stats: **harmless for bring-up, but a real r30-vs-5.4 difference.** r30's
  `ipa_4_11_mem_part` has `stats_fnr_size = 0x0` (5.4: `0x1FB0 + 0x800`), its NAT table is
  0x800 instead of 0x500, and pdn_config/quota/tethering moved up by 0x800 into the former FnR
  space (5.4
  0x1CA8/0x1D00/0x1D30/0x1D78 -> r30 0x24A8/0x2500/0x2530/0x2578; drop stats 0x27B0 and the
  modem region 0x27D8 + 0x800 unchanged). So `ipa_init_flt_rt_stats()` cannot place 512 bytes
  of FnR counters and returns -EPERM; `ipa3_post_init()` only logs it and finishes ("IPA driver
  initialization was successful"); only the FnR counter ioctls (per-rule statistics, ipacm)
  are unavailable. The quota/drop offsets the modem needs are sent to it in the QMI
  init_modem_driver request (`hw_stats_quota_base_addr`, `hw_drop_stats_base_addr`), so the
  moved layout stays consistent. What 5.4 never did: r30 also sends `hw_filter_stats_info`
  (start = `stats_fnr_ofst` 0x27B0, size `IPA_Q6_FNR_STATS_SIZE` = 191 x 16 = 0xBF0, indices
  64..254) and `per_stats_smem_info`/`smem_info`. With FnR size 0 that range overlaps the drop
  stats and the modem SRAM region and runs past `end_ofst` 0x3000. Unknown whether this
  MPSS (MPSS.HI.4.1.1) uses the TLV. Not changed here (donor source, and M1/M2 do not need
  it); if A1 shows data-path trouble, the candidate is patch 0002 setting r30's
  `ipa_4_11_mem_part` back to 5.4's values (same SRAM end 0x3000, FnR at 0x1FB0 + 0x800).

### Item 4: what M2 (modem with a working RMTFS server, no DOG stall) needs

The device-tree and kernel side is complete for the vendor `rmt_storage`; what is missing is
a test where it runs with a modem that TZ accepts.

| rmt_storage (sm7325-common blob, strings + vendor.qti.rmt_storage.rc) opens | 5.4 | 6.12 (M1) |
|---|---|---|
| `/sys/class/uio/uio%u/name` = `rmtfs`, `version` (it refuses unknown versions), `maps/map0/addr`, `maps/map0/size` | msm_sharedmem, node `qcom,rmtfs_sharedmem@0` (`reg <0 0x280000>`, reg-names `rmtfs`, client-id 1, `qcom,vm-nav-path`) | identical node and driver: `uio0` name `rmtfs` ver `1.0` size `0x280000`, addr dynamic (0xf2800000 in M1) |
| `/dev/uio%u` open + mmap | ueventd `/dev/uio0 0660 system system`; daemon runs as root (class core) | char 511:0 in M1 (dynamic major), same ueventd rule applies |
| buffer: `reg` base 0 -> `dma_alloc_coherent` 0x280000, `hyp_assign_phys` HLOS -> HLOS+MSS_MSA+NAV RW | yes | same via `qcom_scm_assign_mem`; no error in M1 |
| `/dev/block/bootdevice/by-name/{modemst1,modemst2,fsg,fsc}` read-write (fallback `/dev/block/platform/msm_sdcc.%d/by-name`, file names `/boot/modem_fs1/2/fsg/fsc`) | real partitions | real partitions are read-only under testguard -> RAM copies via `stages/radio/pre.sh` (EFS shim) |
| `/sys/power/wake_lock`, `wake_unlock` | yes | `CONFIG_PM_WAKELOCKS=y` |
| `ro.baseband` | `msm` | `androidboot.baseband=msm` in `androidboot/out/android-cmdline.txt` |
| libmdmdetect: `/sys/bus/msm_subsys/devices/subsys*/name` | msm_subsys | subsys_compat |
| QMI server RMTFS (service 14) over QRTR (libqmi_csi), `qrtr-ns` | yes | QRTR + ns as for the other daemons |

The modem learns the buffer address from rmt_storage over QMI, so a different address than
5.4's is fine. `rmtfs@9c900000` is the 6.18 harness's upstream `qcom,rmtfs-mem` region,
assigned to the modem by the harness's `qcom_rmtfs_mem` before kexec; it is not the 6.12
buffer and must stay no-map (kexec/mkkexecdtb.py step 3b does that; no change here). Do not
load upstream `qcom_rmtfs_mem` on 6.12, and do not make the 6.12 node point at 0x9c900000.

M2 therefore needs one of:
- **M2-A (Android, vendor rmt_storage, the intended test):** the A0 boot (section 7) on a phone
  whose own modem TZ accepts and that runs a userdebug (permissive) Android: blocked on the
  section-6 decision (phone 1 is a user build, phone 2's modem is refused). Everything else is
  in the stages: msm_sharedmem in `modem`, EFS shim in `radio` pre.sh, subsys_compat in `dsp`.
- **M2-K (kernel only, phone 1, no decision):** an RMTFS server in the busybox environment.
  **Prepared 2026-11-14 19:30: section 10.** (Original plan: it needs a static aarch64 RMTFS server (e.g. linaro `rmtfs` + `libqrtr`,
  UIO lookup by name `rmtfs`, storage = RAM copies of phone 1's four EFS partitions dd'd from
  the read-only block devices to `/tmp/efs/modem_fs1|modem_fs2|modem_fsg|modem_fsc`), fetched
  and built with the owner's OK.) TFTP is now served too (tqftpserv); the vendor pd-mapper is
  not (the kernel locator `qcom_pd_mapper_a52` is), so a stall that remains in M2-K does not
  fully clear the userspace side.

M2 pass: `rmt_storage` logs "Shared memory initialised successfully." and no "Mmap Failed for
rmts"; `qrtrls` shows service 14 on node 1 (AP) and the modem's own services appear (DMS 2,
NAS 3, WDS 1, UIM 11, IPA 49 inst 2 ...); no `DOG detects stalled initialization` for 5 min;
`ipa3_qmi` init_modem_driver exchange in dmesg; memshare: client 3 "client not found" only.

### Next on hardware (owner runs; nothing here was run on a phone)

1. Rebuild (offline, ~40 s): `drivers612/conn/data/build.sh && drivers612/modem/build.sh`
   (already done for this commit; repeat only after changes).
2. **M1c** (phone 1, kernel only, own modem; same safety as kx-m1b):
   `drivers612/modem/run-m1.sh m1c-p1`
   then check (log dir `logs/kx-m1c-p1-p1-*`):
   `grep -E "FAIL|rmnet_ctl_init|Unknown symbol" logs/kx-m1c-p1-p1-*/kexeced-dmesg-after.txt` -> nothing for rmnet_*;
   `grep -E "^rmnet_|^ipam|^msm_mem" logs/kx-m1c-p1-p1-*/kexeced-extra.txt` -> rmnet_ctl, rmnet_core, rmnet_offload, rmnet_shs listed (Live);
   `grep -E "memshare_alloc|page_alloc" logs/kx-m1c-p1-p1-*/kexeced-dmesg-after.txt` -> two "client not found ... requested client: 3", **no** page_alloc WARN;
   IPA lines unchanged (5 x resource group #2, FnR -1: expected, item 3); the rest as kx-m1b
   (DOG stall at ~80 s, recovery, deliberate SSR, clean release, no panic).
3. **M2-A**: only after the section-6 decision, on the approved phone: the A0 command of
   section 7 with that phone's `PHONE=`/`HARNESS_IMG=`, then the M2 pass checks above and A1.
4. **M2-K**: prepared, see section 10 for the command.

## 10. M2-K: kernel-only modem with an open RMTFS + TFTP server (phone 1; prepared 2026-11-14 19:30)

Why: in every M1 run (`kx-m1b`, `kx-m1c-p1-p1-162401`, `kx-m1t2-p1-p1-182948`) the MPSS boots,
publishes SSCTL 43 + PDR 66 and ~65 s later dies with `DOG detects stalled initialization`:
nothing serves its remote file system (RMTFS, QMI service 14) or its TFTP (service 4096). M2-K
runs the open linux-msm servers in the busybox environment, on **RAM copies** of the EFS.

### What is in the pack (`out/pack-modem.tgz`, `bin/`)

| Binary | Source | What |
|---|---|---|
| `rmtfs` | linux-msm/rmtfs b30a3eb + `userspace/patches/rmtfs-0001-a52sxq-ram-only-efs-uio-by-name.patch` | RMTFS server. Shared buffer = msm_sharedmem's UIO with name `rmtfs` (found in `/sys/class/uio/*/name`, `maps/map0/addr`/`size`, mmap of `/dev/uioN`; no udev). **RAM-only build**: `-P` (raw partitions) refused, `-o <dir>` required and must be tmpfs/ramfs, every storage file must be a regular file on tmpfs/ramfs (`O_RDONLY\|O_NOFOLLOW`, fstat + fstatfs checked), read once into a private buffer; modem writes stay in that buffer. No `O_RDWR`, `pwrite` or `fdatasync` left in `storage.c` (build.sh checks the object's imports); `storage.c` refuses to compile without `-DA52SXQ_RAM_EFS`. The upstream `qcom_rmtfs_mem` and `/dev/mem` fallbacks are compiled out (on this setup `reserved-memory/rmtfs*` is the 6.18 harness's region, stage-2 assigned to the modem). Also fixed two upstream bugs: `GET_DEV_ERROR` dereferenced NULL (inverted test), `-v` close log printed an int with `%s` |
| `tqftpserv` | linux-msm/tqftpserv eb4b9a0 + `patches/tqftpserv-0001-a52sxq-tmpfs-readwrite.patch` | TFTP over QRTR. `/readonly/firmware/image/<f>` -> `/lib/firmware/<f>` (links into the read-only vfat `modem` mount), `/readwrite/` -> `/tmp/tqftp-rw` (tmpfs; refused if it is not tmpfs/ramfs). No xz/zstd |
| `qrtr-lookup` | linux-msm/qrtr 29e36ae | lists QRTR services with names |
| `efsdump` | ours (`userspace/efsdump/efsdump.c`) | `copy <dir>`: modemst1/modemst2/fsg/fsc -> `<dir>/modem_fs1/modem_fs2/modem_fsg/modem_fsc`. Each partition found by `PARTNAME` (exactly one match), `/dev/<name>` must be a block device with the sysfs dev_t, opened **O_RDONLY** (the only block-device open in the program), then **BLKROSET** (kernel read-only flag for the rest of this boot: every later open for writing gets EACCES), BLKGETSIZE64, read. Output files are created `O_EXCL\|O_NOFOLLOW` in a directory checked to be tmpfs/ramfs. `verify <dir>`: re-reads the partitions and compares them with the copies |

Not built: `qrtr-ns` (6.12's `qrtr.ko` contains the in-kernel name service, `net/qrtr/ns.c`;
M1 already listed servers without any userspace ns) and `pd-mapper` (the dsp stage loads the
kernel locator `qcom_pd_mapper_a52`). Toolchain: AOSP clang r547379 + lld, musl `libc.a` from
`$ANDROID_TREE/prebuilts/build-tools/sysroots/aarch64-unknown-linux-musl`, compiler-rt builtins
of the same clang; all four are static aarch64 ELF without interpreter (checked by
`userspace/build.sh`). Smoke-tested offline under qemu-aarch64 (refusals: no `modemst1` on the PC,
non-tmpfs directory, `-P`; and the patched `storage.c` on the host: reads the copy, writes stay in
memory, the file stays byte-identical, a symlink to a block device and a non-tmpfs `-o` are
refused).

### Flow (`m1.sh` argument `m2`)

Same as M1 up to "QRTR before the modem" (firmware links from the read-only `modem`/`apnhlos`
mounts, rollback checks, dsp + modem stages, IPA FW), then, **before the vote**:
1. tmpfs on `/tmp/efs` and `/tmp/tqftp-rw`; `efsdump copy /tmp/efs` (prints size + fnv64 per
   partition and `ro=1` from sysfs); any failure: exit 5, the modem is not started.
2. links of the `modem` partition's non-image entries (`modem_pr/`, `*.jsn`, `qdsp6m.qdb`, ...)
   into `/lib/firmware` for TFTP; never `.mdt/.bNN/.mbn` (nothing is copied).
3. `rmtfs -v -o /tmp/efs` (log `/tmp/rmtfs.log`) and `tqftpserv -d` (`/tmp/tqftp.log`); rmtfs
   dead after 2 s: exit 6, modem not started. `qrtr-lookup`: 14 and 4096 on node 1.
4. vote (`/dev/subsys_modem`), QRTR 20 s, then the observe window with an `M2 obsNN` status line
   every 20 s (subsys3 state, DOG / crash / fatal counts, rmtfs opens/iovec/read/write counts,
   TFTP opens); with `therm`: a T1 sample every 20 s plus a 3-sample phase `up60` once the
   modem has been up 60 s.
5. after the window: `qrtr-lookup`, rmtfs/tftp logs, files the modem wrote to `/readwrite`;
   deliberate SSR as in M1 (shows whether rmtfs serves the restarted modem; `nocrash`
   skips it);
   vote released; rmtfs/tqftpserv stopped; `efsdump verify /tmp/efs`.

### Command (owner runs it; phone 1 = PHONE1, own modem, kexec harness as for M1)

    drivers612/modem/build.sh      # offline, ~5 s after the first build; already done for this commit
    M1_ARGS="120 m2 therm" drivers612/modem/run-m1.sh m2k-p1

Log: `logs/kx-m2k-p1-p1-*/kexeced-extra.txt` (sections `===== M2 ...`) and
`kexeced-dmesg-after.txt`. Run time ~230 s of 6.12 uptime (deadman 420 s, extra timeout 360 s).

### What success looks like

1. `efsdump: copy done: 4 of 4 partitions in RAM` and `m2: <part> /sys/class/block/sdaN/ro=1` x4.
2. rmtfs log: `[storage] RAM-only: serving copies in /tmp/efs`, `[RMTFS] shared memory:
   /dev/uio0 (uio name rmtfs) phys 0x... size 0x280000`; `qrtr-lookup` shows 14 and 4096 on node 1.
3. After the vote: `[storage] open /boot/modem_fs1 -> /tmp/efs/modem_fs1 (...)` (and fs2, fsg,
   fsc as the modem asks), `[RMTFS] alloc ...`, many `[RMTFS] iovec`/`read` lines; tqftp log
   `... opened for reading` (mcfg / server_check) and maybe writes under `/readwrite`.
4. **No `DOG detects stalled initialization`**: every `M2 obsNN` line `DOG=0 crashes=0`,
   `subsys3=ONLINE`, `rmtfs=alive`, through obs120 (~135 s after `is now up`).
5. `qrtr-lookup` at the end: many more modem (node 0) services than M1's two, e.g. DMS 2,
   NAS 3, WDS 1, UIM 11, VOICE 9, WMS 5, IPA 49 inst 2, LOC 16, PDC 36 (names printed).
   dmesg: the `ipa3_qmi` init_modem_driver exchange; memshare: client 3 "client not found" only.
6. T1 `up60` / `obs60+`: `pa=` and `wf=` near ambient (~30 C) instead of ~69-70 C, and the PM7325
   gpio1/gpio4 registers changed (the modem configured them: THERMISTOR-ADC.md).
7. Deliberate SSR: modem up again, rmtfs logs new opens after it (its socket loop restarts on
   ENETRESET). End: `efsdump verify ... identical` x4 and `all 4 partitions unchanged`.

Failure table:

| Symptom | Meaning / next step |
|---|---|
| `FAIL m2: efsdump copy` | partition name not found once / dev_t mismatch / BLKROSET refused: nothing was started; read the efsdump line |
| rmtfs: `no UIO device named rmtfs` | msm_sharedmem did not probe (modem stage; `uio0` check of M1) |
| rmtfs: `failed to mmap` | msm_sharedmem's mmap (`remap_pfn_range`, size 0x280000): compare `maps/map0/size` |
| modem crash right at the first iovec | the HLOS-side buffer permissions (msm_sharedmem's `qcom_scm_assign_mem` HLOS -> HLOS+MSS_MSA+NAV, open point 8.6) |
| DOG stall still at ~80 s with RMTFS opens/reads logged | RMTFS was not the only cause: check the TFTP log (rejected paths), then the pd-mapper data (R3: vendor modemr.jsn service list vs the kernel locator) |
| DOG stall, no RMTFS open at all | modem never looked the service up: `qrtr-lookup` must show 14 on node 1 before the vote; check `[RMTFS] packet` lines |
| `efsdump verify ... DIFFERENT` | must not happen (no write path exists): stop and report; the copies in `/tmp/efs` of that boot are the reference |

## 11. M2-K on the 6.18 kernel (phone 1; prepared 2026-11-14 19:50)

Same test as section 10 (kernel only, own modem, open rmtfs + tqftpserv on RAM copies of the EFS),
on ACK 6.18.33 + the forward-ported BSP (`bsp618/`). Everything except the kernel-version-bound
parts is the passing 6.12 run's material, byte for byte.

### What is used (`build-618.sh` -> `out-618/`, reads bsp618/ and `out/`, writes only `out-618/` and `stages/modem/resolved-kernelonly-618.list`)

| Part | 6.12 (`run-m1.sh`, kx-m2k-p1-p1-192337) | 6.18 (`run-m2-618.sh`) |
|---|---|---|
| Image | `bsp612/out/dist/Image` | `bsp618/android/out/dist/Image` (the a8 package's; byte-identical to `bsp618/out-survey/gki/arch/arm64/boot/Image`) |
| ramdisk | `bsp612/out/bringup/ramdisk-612.cpio.gz` | `bsp618/android/out/bringup/ramdisk-618.cpio.gz` (mkramdisk-618.sh: same `bsp612/ramdisk/init`, same 87-module first stage in the same order, 6.18 builds + 6.18 hhwdt/sec_core) |
| dsp list | `androidboot/out/stage-dsp` | `bsp618/android/stage-618/dsp` (mkstages-618.py); list identical to the 6.12 pack's `dsp.list` (checked) |
| modem/therm lists | `stages/{modem,therm}/targets.txt` resolved over the 6.12 modules.dep | the same targets resolved over the 6.18 modules.dep (dist + `bsp618/src/drivers612/conn/data` + guard): **same 15 modules in the same order** as `stages/modem/resolved-kernelonly.list` (written to `stages/modem/resolved-kernelonly-618.list`), therm = qcom-vadc-common + qcom-spmi-adc5 |
| conn/data | `drivers612/conn/data` (IPA3 fix) | 6.18 build of the same tree (19:23; has the `-DCONFIG_IPA3_MODULE=1` fix: `rmnet_core depends ipam,...`, imports `ipa_*`; patches 0040/0041 for rmnet_core/shs) |
| a52_modem_guard | built against `bsp612/out/lahaina` | built here against `bsp618/out-survey/lahaina` (clang r596125, soc Module.symvers of `bsp618/src`); 6.18 has both vendor hooks (`android_vh_rproc_recovery` in `rproc_crash_handler_work`, `android_vh_rproc_recovery_set` in sysfs), `struct rproc` keeps `recovery_disabled`/`dump_conf`/`power`/`crash_cnt`, the 6.18 `rproc_qcom_common` still exports `qcom_device_shutdown_in_progress` |
| userspace | `out/kpack/bin/*`, `qrtrls`, `mkdevs` | **the same files** (copied from `out/kpack`, sha256 in `out-618/userspace.sha256`): static aarch64, kernel-independent |
| scripts | `kpack/*.sh` | unchanged (build-618.sh fails if a packed script differs from the 6.12 pack's) |
| DT | `dt/mkmodemtree.sh out-ack/kx/android-r02.dtb` | `dt/mkmodemtree.sh bsp618/android/out/android-r02-618.dtb` -> `out-618/android-modem-r02-618.dtb`. Decompiled diff to the 6.12 modem tree: exactly the two `mkdtb-618.sh` edits (`/reserved-memory/a52ram@f0be0000` for earlycon, dwc3 `qcom,iommu-faults = "non-fatal"`), nothing removed (build fails otherwise) |
| cmdline | `loglevel=7 ... a52.deadman=420 a52.net=42` + `bsp612/qcom-bootargs.txt` | the same + `sched_proxy_exec=0 earlycon=a52ram,0xf0be0000 log_buf_len=4M` (= `bsp618/android/android-cmdline-618.txt` without `androidboot.*`, `a52.androidtest`, `firmware_class.path`, `loop.max_part`), 396 B, in `out-618/cmdline-m2-618.txt` |

### Offline checks (all in `build-618.sh`; it stops on the first failure)

- vermagic `6.18.33-4k-g00c8666046c2-dirty` on all 36 `.ko` of the pack; no GKI (signed) module
  in the modem/therm resolution; no `.mdt/.mbn/.bNN` anywhere in the pack.
- depmod over the 6.18 tree: 16 known warnings (coresight-*, mhi, mac80211; not loaded here),
  **none** for a module of the first stage, dsp, modem or therm lists.
- insmod simulation of the kernel-only order (`check-load-kernelonly.py`: hhwdt, escape chain +
  sec_core, first stage without the escape five, dsp without frpc-adsprpc, modem, therm; per
  module vermagic, symbol presence, modversion CRCs incl. 6.18 gendwarfksyms, duplicate exports):
  `127 ok, 0 FAIL` (`out-618/check-load.txt`). Cross-checks: the same simulator on the passing
  6.12 pack gives 127 ok / 0 FAIL; with the 6.12 guard swapped into the 6.18 pack it reports the
  vermagic and the `__tracepoint_android_vh_rproc_recovery` CRC mismatch.
- DT: `modem_pas` okay, memshare `client_4` (id 3) disabled, `/soc/qcom,rmtfs_sharedmem@0`
  `qcom,sharedmem-uio`, reg-names `rmtfs`, size 0x280000, client-id 1, enabled; plus every
  mkmodemtree.sh check (mpss/IPA GSI regions, IPA/rmnet/glinkpkt/memshare nodes, no upstream
  `qcom,rmtfs-mem`, no `qcom,sc7280` root compatible).
- EFS safety on 6.18 (source check of `ack/block`): `BLKROSET` still sets `BD_READ_ONLY` on the
  partition (`blkdev_roset`), writes to it return -EPERM (`blkdev_write_iter`), an open for
  writing by path gets -EACCES (`bdev_file_open_by_path`), sysfs `ro` shows the flag. efsdump
  (O_RDONLY, BLKROSET, copies in tmpfs, verify) and rmtfs (RAM-only build) are the 6.12 binaries.
- `out-618/inputs.sha256` fingerprints Image, ramdisk, pack, DT and cmdline; `run-m2-618.sh`
  refuses to run if any of them changed after these checks.

### Command (owner runs it; phone 1 = PHONE1, harness kexec9 on recovery, as for the 6.12 M2-K)

    drivers612/modem/build-618.sh      # offline, ~5 s; already done for this commit
    drivers612/modem/run-m2-618.sh m2k618-p1

(`M1_ARGS` defaults to `"120 m2 therm"`, the 6.12 run's arguments.) Log:
`logs/kx-m2k618-p1-p1-*/kexeced-extra.txt` and `kexeced-dmesg-after.txt`; the pass criteria
are section 10's "What success looks like" (compare line by line with
`logs/kx-m2k-p1-p1-192337/`).

### What is new on 6.18 (not covered by any earlier run)

- First IPA + MSS + rmnet run on 6.18 at all (the Android 6.18 runs never loaded the modem stage).
  The forked arm_smmu `BUG()`s on an unhandled context fault unless the client node says
  `qcom,iommu-faults = "non-fatal"`; only dwc3 has that. An IPA SMMU fault would therefore end in
  a panic: the harness recovers that like any 6.18 crash (ab618-a3 hung_task, phone 2). If it
  happens, the next step is the same test-safety edit on the IPA context-bank nodes
  (`/soc/qcom,ipa@1e00000/ipa_smmu_*`) so the fault is printed and the shell survives.
- First kernel-only boot of the bare `ramdisk-618` (the 6.18 runs so far used it as layer 2 of the
  Android ramdisk); the init and first stage are the ones those runs loaded without failures.
- Phone 1's previous 6.18 boot (ab618-p1s1, 15:22) died on the dwc3 SMMU write fault that
  bsp618 patch 0031 has fixed since (the a3-a8 runs on phone 2 have it).

## 12. Radio and data on the new kernels: `qmi-nas`, M2 steps `nas` and `data` (prepared 2026-11-14 20:15)

Goal: show that the modem's **radio** works on 6.12 and 6.18 (cell search, signal, a network
scan; no SIM needed), and, with the SIM the owner put into phone 1, a **data call** through
IPA + rmnet. Nothing here was run on a phone.

### The tool (`userspace/qmi-nas/`, static aarch64 musl, built and tested by `userspace/build.sh`)

QMI over `AF_QIPCRTR`. Our code; no glib, libqmi or libqrtr. The message layouts (ids, TLVs,
field order, enum values) come from libqmi's published `data/qmi-service-{dms,nas,uim,wds,wda}.json`
and `qmi-enums-*.h`. Services are found through the in-kernel QRTR name service
(`QRTR_TYPE_NEW_LOOKUP` on the control port, like `qrtr-lookup`). It prefers the modem's node
(0), and reports a service that is not registered. Every response prints its result TLV 0x02
(`result=success`, or `FAILURE error=0x.. (name)`). Every known TLV is decoded. Unknown TLVs,
and known ones whose length does not match the definition, are printed as hex (`-v`: hex for
every TLV and the requests).

| Command | QMI |
|---|---|
| `qmi-nas info` | DMS GET_OPERATING_MODE 0x2D, UIM GET_CARD_STATUS 0x2F, NAS GET_SIGNAL_INFO 0x4F, GET_SERVING_SYSTEM 0x24, GET_SYSTEM_INFO 0x4D, GET_RF_BAND_INFO 0x31 |
| `qmi-nas --online` / `--low-power` | DMS SET_OPERATING_MODE 0x2E to ONLINE (0) / LOW_POWER (1), then read back. ONLINE makes the radio transmit: cell search, attach attempts, emergency-only without a SIM (normal phone behaviour) |
| `qmi-nas -t 150 scan [gsm,umts,lte,tds,nr5g]` | NAS PERFORM_NETWORK_SCAN 0x21 (the modem answers when the scan is done; default timeout 180 s); one line per network: `net[i] mcc=... mnc=... rat=... status=0x.. available/current-serving/home/roaming/forbidden/...` (TLVs 0x10/0x11/0x12), `scan-result` (0x13) |
| `qmi-nas wait-registered 90` | polls GET_SERVING_SYSTEM every 3 s; prints only changes; rc 0 once registered (+ PS attached) |
| `qmi-nas card` | UIM GET_CARD_STATUS: card/app state, PIN1/PUK1 state + retries (read only; the tool sends nothing that changes the SIM) |
| `qmi-nas wda 2:5:5:32:16384 --ep 4:1` | WDA SET_DATA_FORMAT 0x20: raw IP, QMAP UL/DL, DL 32 datagrams / 16384 B, endpoint EMBEDDED(4) iface 1 |
| `qmi-nas ipa-setup rmnet_ipa0 16384 32 0x26 0` | `RMNET_IOCTL_EXTENDED` (0x89FD) on `rmnet_ipa0`: SET_EGRESS_DATA_FORMAT {6, 0}, SET_INGRESS_DATA_FORMAT {7, MAP\|DEAGG\|AGG_DATA, 16384, 32}, GET_EP_PAIR |
| `qmi-nas rmnet-add rmnet_ipa0 rmnet_data0 1 3` / `rmnet-del` | RTM_NEWLINK kind `rmnet` (IFLA_LINK, IFLA_RMNET_MUX_ID 1, IFLA_RMNET_FLAGS 3/0xffffffff = deagg + MAP commands); busybox `ip` cannot pass the rmnet attributes |
| `qmi-nas data --dpm ctl --ep 4:1 --ipa rmnet_ipa0 --rmnet rmnet_data0 --wda 2:5:5:32:16384 --mux 1 --ipfam [--apn A] [--apn-fallback internet] --run CMD` | all on ONE QMI client: DPM OPEN_PORT 0x20 (svc 0x2F), WDA SET_DATA_FORMAT, rmnet_ipa0 pipes + rmnet link + ADD_MUX_CHANNEL for the protocol the modem applied, WDS BIND_MUX_DATA_PORT 0xA2, SET_IP_FAMILY 0x4D, START_NETWORK 0x20 (IPv4; no APN = default profile, retried with `--apn-fallback` on call-failed), GET_CURRENT_SETTINGS 0x2D, GET_PACKET_SERVICE_STATUS 0x22; CMD runs with `QMI_IP QMI_GW QMI_PREFIX QMI_DNS1 QMI_DNS2 QMI_MTU QMI_MUX QMI_QMAP QMI_RMNET_FLAGS` set; then STOP_NETWORK 0x21 |
| `qmi-nas data-probe --ipa rmnet_ipa0 --rmnet rmnet_data0 [--wda 2:9:9:32:16384] [--budget 420] --run CMD` | the variants below, one per fresh QMI client, each logged, stops at the first call that comes up; `== data-probe summary:` lines list every stage result per attempt |
| `qmi-nas ipa-pair rmnet_ipa0` | GET_EP_PAIR + GET_EPID only |
| `qmi-nas decode <svc> <hex>` | offline: print a raw QMI message (`dpm` included) |

Exit codes: 0 ok, 1 QMI error result, 2 service missing / no response, 3 transport error,
4 not registered, 5 the `--run` command failed. A FAILURE response of any service but UIM is
printed with the raw bytes of every TLV (result TLV included) plus the request that failed;
UIM TLVs are never dumped raw (also not under `-v` or on a parse error).

Offline tests (`userspace/build.sh`, every build): host unit test `qmi-nas/test/test-qmi.c`,
81 checks, 0 failed (also clean under ASan/UBSan). It uses libqmi's canned NAS responses from
`src/libqmi-glib/test/test-generated.c` (network scan with 8 networks, serving system, system
info; the bytes after the QMUX header, which QRTR does not carry) and hand-made DMS, UIM, WDS,
signal, RF-band and error vectors (missing result TLV, failure result, malformed lengths, a
known TLV with a wrong length). Request encoding is checked byte for byte against libqmi's
expected requests. Then the aarch64 binary decodes the network-scan vector under
`qemu-aarch64`, identically. Static, no interpreter. It opens or writes no files (checked by
its imports).

### Data path, what it is based on (source reading of `conn/data/src`, not run)

`rmnet_ipa0` is registered by `ipam.ko` (rmnet_ipa.c) at IPA probe, and the QMI
`init_modem_driver` exchange is automatic (both are in the kx-m2k log). The APPS WAN pipes
exist only after the two ingress/egress ioctls; netmgrd sends these on Android. Ingress AGG_DATA
is required with our DT (NAPI + `qcom,wan-use-skb-page`). agg_size must be > 1500 and
<= 32 KB. With `qcom,modem-cfg-emb-pipe-flt` the modem owns the filter rules, so no IPACM is
needed for one IPv4 call. Qualcomm rmnet_core takes kind `rmnet`. IFLA_LINK is mandatory (its
newlink dereferences it unchecked). Flag bits 0/1 are deagg/MAP commands. Bits 4..6 are
Qualcomm-specific (COALESCE, CKSUMV5 in/out), not the upstream values.

Inferred and unverified: whether this MPSS installs its embedded-pipe rules without IPACM, and
the QMAPv5 path (ingress CHECKSUM + rmnet CKSUMV5 bits 5/6; qmi-nas picks them from the WDA
answer since 22:30). iface_id 1 for EMBEDDED is what rmnet_ipa's GET_EPID returns (constant).
The IPA pipes cannot be reconfigured once set (one setup per boot). An SSR tears all of this
down. The DPM prerequisite: see "Data call setup fix" below.

### Flow (`m1.sh` arguments `nas`, `data`; both need `m2`, else exit 7 before the modem starts)

After the modem has been up 30 s (from the vote), before the observe window:

- **nas**: `lookup`, `info` (mode as booted), `--online`, 20 s (`M2 nas-online20` status line),
  `info`, `scan` (150 s), `M2 nas-scan`, `--low-power`, `mode`.
- **data**:
  1. `card`. If the SIM application is not `ready`, the data step is skipped and the reason is
     printed. This includes PIN1 `enabled-not-verified`: the tool does not enter a PIN.
  2. `--online`, `wait-registered 90`, `info`.
  3. `ip link set rmnet_ipa0 up`, `ipa-pair`.
  4. ONE process: `data --dpm ctl --ep 4:1 --ipa rmnet_ipa0 --rmnet rmnet_data0 --wda
     2:Q:Q:32:16384 --mux 1 --ipfam --apn-fallback internet [--apn]` (Q = `qmap=` argument,
     default 5), or with the argument `probe` `data-probe` (variants below). DPM open_port,
     WDA, then the IPA pipes + `rmnet_data0` (mux 1) for what the modem applied, bind, ip
     family, start. dataup.sh runs while the call is up: `ip addr add
     $QMI_IP/32`, default route, `ping -c 5 -I rmnet_data0 1.1.1.1`, `ping` the DNS server,
     interface counters, IPA/rmnet dmesg, route and address removed. Then the call is stopped.
  5. `M2 data`, `rmnet-del`, `--low-power`.

  Output is in `/tmp/nas.out`, which `all.sh` prints in `===== NAS / DATA`. Before the vote is
  released, the mode is set to LOW_POWER once more.

Timeouts:

| Mode | a52.deadman | Extra timeout | Run time (worst case) |
|---|---|---|---|
| `nas` | 900 s | 840 s | ~8 min |
| `nas data` / `data probe` | 1500 s | 1440 s | ~13-20 min |

On 6.12, `run-m1.sh` picks these from `M1_ARGS`. On 6.18, `build-618.sh` writes
`cmdline-m2{nas,data}-618.txt` (fingerprinted in `inputs.sha256`) and `run-m2-618.sh` picks one
by `M1_ARGS`. `M1_DEADMAN` / `KX_EXTRA_TIMEOUT` override.

microSD (owner's HARD RULE, 2026-11-14: never wipe, format or write it):
- efsdump only considers UFS partitions named `sdXN`. It skips and refuses `mmcblk*`, both by
  sysfs name and by DEVNAME, before the open.
- `common.sh part()` looks only at `/sys/class/block/sd*`.
- The packed `mkdevs` makes no `mmcblk*` nodes.
- Both build scripts fail if any packed script or binary other than efsdump mentions `mmcblk`.

### Data call setup fix (2026-11-14 22:30, offline; run kx-m2data-p1-p1-215702 failed at setup)

That run registered on LTE (CS+PS attached) but WDA set_data_format answered invalid-operation
(0x46), WDS bind_mux_data_port internal (0x03), start_network invalid-operation, each with no
other TLV. The IPA side was fine: QMI_IPA_INIT_MODEM_DRIVER answered, the indication to the modem
was sent (no "not send indication (0)" error in dmesg), ingress/egress pipes set up, pair 2/16.
Missing piece: the **Data Port Mapper** (QMI service 0x2F, registered by this modem, port 69 in
that run). The ROM's own `netmgr_config.xml` (listitem `lahaina`) has `qmi_dpm_enabled 1`,
`single_qmux_ch_name DATA5_CNTL`, `phys_net_dev rmnet_ipa0`, `wda_data_format_enabled 1` and
QMAPv5 both ways: netmgrd opens the data port with DPM OPEN_PORT before WDA, and a modem without
that port rejects WDA/WDS for it. rmnet_ipa's GET_EPID is the constant 1 (rmnet_ipa.c `epid = 1`),
so embedded:1 was right; ModemManager also uses EMBEDDED/1 for "ipa". DPM OPEN_PORT layout
(TLV 0x10 control ports {string8 name, u32 ep type, u32 iface}, 0x11 hardware data ports
{u32 ep type, u32 iface, u32 rx ep, u32 tx ep}) and the WDA/WDS TLV ids were checked by feeding
our encoder's bytes to libqmi 1.38's own decoder on the host (vectors in test-qmi.c).

Also changed: everything runs in ONE qmi-nas process (the old flow set WDA from one process and
called from another; the modem keys QMI clients by QRTR port and drops a client's state when the
socket closes). The IPA pipes are set up only after WDA answered, for the protocol the modem
applied (qmap 5: ingress 0x26, egress 0, rmnet flags 3; qmapv5 9: ingress 0x36 = +CHECKSUM,
egress 0x10, rmnet flags 0x63 = + Qualcomm CKSUMV5 in/out); ADD_MUX_CHANNEL as netmgrd;
SET_IP_FAMILY ipv4 before the call; call-failed with the default profile retries with APN
`internet` (the local carriers).

`data-probe` variants (each on a fresh QMI client; phase 2 re-runs the ones that ran before the
IPA pipes existed, with the pipes set up first; budget 420 s):

| # | DPM | endpoint (WDA 0x17 / bind 0x10 / DPM) | QMAP | why |
|---|---|---|---|---|
| 1 | control `DATA5_CNTL` + hardware port rx 2 / tx 16 | embedded:1 | requested (5) | the netmgrd recipe (ROM config) |
| 2 | as 1 | embedded:1 | the other one (9) | the ROM asks QMAPv5 |
| 3 | hardware port only | embedded:1 | requested | libqmi's minimal open-port |
| 4 | as 1, rx/tx = producer/consumer | embedded:1 | requested | pipe order not documented |
| 5 | as 1 | embedded:<consumer pipe 2> | requested | iface = IPA pipe number |
| 6 | as 1 | embedded:0 | requested | |
| 7 | none | embedded:1 | requested | baseline = the failing request |
| 8 | none | no endpoint TLVs | requested | the modem's default port |

BAM-DMUX (type 5) is not tried: this SoC has no bam-dmux (IPA only). Offline checks
(`userspace/build.sh`): 109 codec checks, and the whole data / data-probe flow against
`test/fake-modem.c` (accepts only control+hw, only hw, or nothing; qmapv5 adaptation).
Not run on a phone.

### Commands (owner runs them; phone 1 = PHONE1, same harness and safety as sections 10/11)

    drivers612/modem/build.sh && drivers612/modem/build-618.sh     # offline, ~6 s; already done for this commit
    # radio, no data (works with or without a SIM):
    M1_ARGS="150 m2 nas" drivers612/modem/run-m1.sh m2nas-p1                 # 6.12
    M1_ARGS="150 m2 nas" drivers612/modem/run-m2-618.sh m2nas618-p1          # 6.18
    # radio + data call (SIM in phone 1; add apn=<name> if the default profile has none):
    M1_ARGS="200 m2 nas data" drivers612/modem/run-m1.sh m2data-p1           # 6.12
    M1_ARGS="200 m2 nas data" drivers612/modem/run-m2-618.sh m2data618-p1    # 6.18
    # data call setup probe (variants one at a time until a call comes up; nas left out: proven):
    M1_ARGS="200 m2 data probe" drivers612/modem/run-m1.sh m2probe-p1          # 6.12
    M1_ARGS="200 m2 data probe" drivers612/modem/run-m2-618.sh m2probe618-p1   # 6.18
    # m1.sh options: qmap=9 (request QMAPv5 first), apn=<APN>

Logs: `logs/kx-<name>-p1-*/kexeced-extra.txt` (sections `===== NAS / DATA` and `===== M2`),
`kexeced-dmesg-after.txt`.

### What success looks like

1. `qmi-nas: local node 1; DMS(2)=node 0 port ... NAS(3)=node 0 ...` (all five services found).
2. The first `info`: `DMS summary: operating mode N (...)` (whatever the modem booted into).
   After `--online`: `operating mode is now 0 (online)`.
3. After 20 s online: `get_signal_info` has `lte:`/`5g:`/`wcdma:`/`gsm:` lines with real values
   (rsrp around -80..-120 dBm), and `get_rf_band_info` shows an active band (e.g. `lte-b3`,
   `lte-b20`, `nr-n78`). Without a SIM, `get_serving_system` is `not-registered`/`searching`
   (limited service = camped for emergency calls is fine). **This is the radio proof.**
4. `scan`: `networks found: N` with N >= 1, several `net[i] mcc=<MCC> mnc=..` lines (local
   operators; `forbidden` without a SIM is normal), `scan-result: 0 (success)`.
5. `M2` status lines stay `DOG=0 crashes=0 subsys3=ONLINE` throughout.
6. data:
   - `UIM summary: card=present ... app=ready`
   - `NAS wait-registered: REGISTERED, PS attached`
   - `DPM open_port: ... result=success`, `WDA summary: the modem applied ... dl-agg=5` (or 9)
   - `ipa-setup: ... endpoint pair: consumer pipe 2 producer pipe 16`
   - `rmnet: add rmnet_data0 ... ok`
   - `WDS summary: data call UP`, then `IPv4 a.b.c.d gateway ... dns ...`
   - `dataup:` ping replies, `rmnet_data0` rx/tx counters > 0
   - `stop_network ok`

| Symptom | Meaning / next step |
|---|---|
| `NOT REGISTERED` for DMS/NAS | modem not fully up (check the M2 lines: DOG, rmtfs) |
| `set_operating_mode` FAILURE `invalid-transition`/`hardware-restricted` | read `offline-reason` / `hardware-restricted` in `get_operating_mode`; RF calibration / NV (EFS copy) issue |
| online, but no signal TLVs and no band after 20 s / scan finds 0 | radio front end not working: RF cal in EFS, the PM7325 RF GPIOs, `RFRPE`/SAR services; compare the thermistor lines (PA thermistor should read ambient) |
| scan `NO RESPONSE within 150 s` | scan longer than 150 s (rerun scan alone with `-t 240`) or blocked by registration attempts |
| data: `SIM application not ready` + `pin1=enabled-not-verified` | the SIM's PIN1 lock is on; this tool does not enter PINs: disable the PIN lock on the SIM in another phone, or handle it outside this test |
| `ipa-setup ... SET_INGRESS_DATA_FORMAT: Invalid argument` | agg_size/flags rejected (rmnet_ipa.c handle3_ingress_format); dmesg has the reason |
| call UP, ping 100 % loss, rmnet_data0 tx > 0 rx = 0 | downlink not reaching APPS_WAN_CONS: modem embedded-pipe rules / QMAP version (WDA response `dl-aggregation: 9 (qmapv5)` -> rerun with ingress CHECKSUM + rmnet bit 5) |
| `start_network` FAILURE `call-failed` + verbose reason type 6 (3gpp) | network refused the PDN: try `apn=<operator APN>` (the tool already retries with `internet`) |
| `DPM open_port` FAILURE on every variant | read its raw TLVs; compare `ipa-pair` pipes; the probe still tries WDA/WDS after a DPM failure |
| `== data-probe: NO variant brought a call up` | the summary lines show which stage failed per variant: send them back |
