# busdcvs: why DDR/L3/LLCC sat at max on 6.12, and the fix (2026-11-15, offline; NOT run yet)

Run ab-s76 (logs/ab-s76-{dmesg,busdcvs}.txt): bwmon bound, memlat deferred (-517) forever,
DDR 2092000 / L3 1516800 / LLCC 1066000 kHz (= max) even screen-off idle. Four causes:

1. **Boot boost never ended.** `qcom-dcvs` (dcvs.c, `qcom_dcvs_path_probe`) starts every slow
   path with `boost_freq = hw_max_freq` "for better boot perf", and `get_target_freq()` takes
   `max(votes, boost_freq)`. Only userspace lowers it (Qualcomm's 6.x post_boot:
   `cat hw_min_freq > boost_freq`). The ROM's post_boot is the 5.4 one (devfreq paths), so
   nothing ever did: all four `bus_dcvs/*/boost_freq` read hw max in the dump.
2. **Interconnect never left its boot floor.** yupik's keepalive BCMs (MC0 = DDR/ebi, SH0 =
   LLCC, ...) get `init_avg/init_peak = INT_MAX` (icc-rpmh.c `qcom_icc_bcm_init`), cleared by
   `icc_sync_state()` only once EVERY qnoc-yupik provider got sync_state. dmesg 25.85 s:
   providers 1500000, 1580000 (mc_virt, ebi), 16e0000, 1700000, 9100000 (gem_noc, qns_llcc),
   soc:interconnect "sync_state() pending due to" `8804000.sdhci` (no SD driver, on purpose),
   `1e00000.qcom,ipa` (no IPA in MODEM=0 runs), `a80000.i2c` (SE8 = SM5714 USB-PD: pins 32/33
   are in boarddt's `qcom,gpios-reserved`, "could not request pin 32"). So the hardware DDR/LLCC
   vote stays max whatever DCVS asks; `bus_dcvs/*/cur_freq` does not show this (only
   `/sys/kernel/debug/interconnect/interconnect_summary` does: ebi/qns_llcc peak 2147483647).
3. **bwmon at driver defaults** (io_percent 16, sample/window 50 ms, no mbps_zones): the DDR
   bwmon itself voted 2092000. 5.4's post_boot tuned the same monitors (68 %, 4 ms, zones).
4. **memlat + qcom-pmu-lib deferred forever.** Both call `get_qcom_scmi_device()`
   (qcom_scmi_client.c): -EPROBE_DEFER while an `arm,scmi` node has a child `reg = <0x80>` and
   no client probed. The client never probes: the phone's CPUCP (RIMPS) firmware is the 5.4
   one; the 6.12 SCMI core rejects its BASE protocol list ("No. Returned protocols > Total
   protocols", 5.4's base.c had no such check) -> "SCMI protocol 128/129 not implemented"; and
   its 0x80 is the 5.4 memlat-v1 protocol (memlat_vendor.c), not 6.12's qcom_scmi_vendor
   set_param protocol. No yupik memlat mon is `qcom,cpucp-enabled`, i.e. the 6.12 tree wants
   AP-side memlat (5.4 ran DDR/LLCC memlat on the AP too; L3 ran on RIMPS). Silent pmu-lib
   defer is why memlat said "reason unknown" (its event check also defers until pmu-lib is up).

## Fix (files here)
- `dt-fix.sh <dtb>`: removes `/soc/qcom,scmi/protocol@80` and `@81` -> the lookup returns
  -ENODEV, pmu-lib and memlat probe in AP mode. Called by `kexec/mkandroidtree.sh` and
  `drivers612/realboot/build-realboot.sh` at the same point. `out-ack/kx/android-r02.dtb` is
  regenerated (decompiled diff vs the old one = only the two nodes + 2 symbols; old one kept as
  `out-ack/kx/android-r02-pre-busdcvs.dtb`).
- `busdcvs.conf`: 56 sysfs writes = the ROM's 5.4 post_boot values on the 6.12 names (bwmon
  LLCC/DDR/L3, memlat L3/DDRQOS ceilings), then `boost_freq` 0 (clamped to hw min) x4, then
  `state_synced` 1 for the 12 interconnect providers. `check-conf.py <dtb> <conf>` proves every
  path belongs to a device of the tree and that no provider is missing.
- Kexec test: `post.sh` = stage `dcvs` post script (helper2.sh now runs `/a52/mods/<stage>.post`
  in the background after a non-@adsp stage; pack-kexec-rd.sh packs `<dir>/post.sh` and
  `<dir>/*.conf`). It waits for boot_completed + 30 s, logs, applies the conf in 3 steps
  (tunables, boost, icc) with a snapshot after each, then 12 idle samples (10 s), a 12 s memory
  load (4x dd), 6 more idle samples. `a52.busdcvs=0` = observe only, `=noicc` = no state_synced.
  `mkrd.sh [s76] [s77]` = s76 byte for byte + an appended cpio (helper2.sh, dcvs.post,
  busdcvs.conf), read back and diffed; out/stage-dcvs/ is the same stage for full packs.
- Real boot: build-realboot.sh REF=s76, stage dcvs in the first stage, the conf as `write`
  lines in the vendor rc on `sys.boot_completed` (vendor_init may write sysfs). rb14.

## Test (phone 2, key-free kexec; nothing flashed)
    A=drivers612/androidboot; PHONE=2 HARNESS_IMG=images/a52sxq-ack618-kexec9-p2-recovery.img \
    KEXEC_BASE=out-ack/kx/android-r02.dtb KEXEC_OVERLAY=none KX_HOLD=1 kexec/kx-cycle.sh ab-s77 \
    bsp612/out/dist/Image $A/out/s77-rd.cpio.gz gen "$(cat $A/out/android-cmdline.txt) log_buf_len=8M \
    a52.deadman=900 a52.mods=debug,secure,display,kgsl,dcvs,video,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,susp,audio@adsp,wlan@adsp"
Then `adb -s PHONE2 shell dmesg | grep -E 'a52sxq-busdcvs|memlat|qcom-pmu|scmi'` (or
/tmp/busdcvs.log over telnet). The post script needs ~5 min after boot_completed.

What to look at:
- memlat probes: no "Failure to probe memlat device: -517"; one "Error getting scmi_dev ret = -19"
  per pmu/memlat (expected); `/sys/devices/system/cpu/bus_dcvs/memlat_settings` and
  `bus_dcvs/{DDR,LLCC,L3,DDRQOS}/soc:qcom,memlat:*` exist; `/sys/devices/system/cpu/pmu_lib`.
- `boot:` line = state before any write: hw DDR=2092000 LLCC=1066000 L3=1516800 (boost),
  icc ebi/qns_llcc peak 2147483647 (floor). `tuned:` bwmon votes drop; `noboost:` hw cur_freq
  = max(bwmon, memlat) instead of max; `synced:` ebi/qns_llcc peak = real votes (the "icc ...
  already synced" lines name providers that had synced by themselves).
- idle (esp. once `bl=0`, screen off): expected DDR at or near 200000-547000, LLCC 150000-300000,
  L3 300000-ish (memlat follows CPU freq: cpu0 300 MHz -> lowest entries of the tables).
- `load1..5`: DDR/LLCC climb (bwmon: dd memset traffic), L3 follows cpu7/cpu4 freq; back down in
  `after-load`/`idle-b*`.
- Risk to watch: after `synced`, a consumer that relied on the INT_MAX floor without voting
  (display underruns "sde ... underrun", UFS/USB stalls). If so, rerun with `a52.busdcvs=noicc`.

## Not done / follow-ups
- Root fixes for sync_state: SE8 pins 32/33 in `qcom,gpios-reserved` (5.4 reserved only 56..59
  in C; 6.12 boarddt copied Qualcomm's base list) keep the SM5714 USB-PD I2C (a80000) from
  probing: power/boarddt owners decide; then only sdhci (and IPA without modem) remain.
- The ROM's power HAL boosts (powerhint.json) still point at 5.4 devfreq nodes (research/sepolicy/PATHS.md).
- 6.18: done 2026-11-15 (offline): mkdtb-618.sh takes the dt-fixed 6.12 tree, bsp618/android/mkrd-dcvs-618.sh
  builds ramdisk a10 (= a9 + GPU governors + stage dcvs + this post script), build-realboot.sh applies dt-fix,
  rc writes and check-conf on both kernels (rb618-5). Not run on 6.18 yet.
- L3 at 1.4-1.5 GHz on the real 6.12 boot: analysed in `L3-MEMLAT.md` (2026-11-15). dt-fix.sh now also
  moves the L3 vote to the EPSS shared register (0x90, was Qualcomm's OSM-style 0x920) and adds a
  300 MHz floor row to the gold/prime L3 tables (`A52_L3_VOTE_OFFSET=keep A52_L3_FLOOR=0` = old tree).
  Not run yet: regenerate android-r02.dtb (kexec/mkandroidtree.sh) and kexec-test before a real boot.
