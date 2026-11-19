# drivers612/audio — A52s audio on the Qualcomm 6.12 BSP

Legacy (Elite/APR) audio techpack `audio-kernel-legacy.lnx.6.12.r1-rel`, built with plain make
against `bsp612/out/lahaina`, with Samsung's A52s changes carried over from the phone's 5.4
kernel so that the closed `audio.primary.lahaina.so` sees the same card, PCM numbers and mixer
controls. Nothing here has run on hardware.

## What is here
| path | what |
|---|---|
| `audio-kernel/` | the build tree: donor copy + every change listed below |
| `build.sh` | builds all modules (reads bsp612, writes only here); log `build.log` |
| `load-order.sh` | prints the insmod order from the built modules' `depends` |
| `a52sxq-audio.dtsi` | the phone's audio DT for the 6.12 base (compiles: `dtcheck/check.sh`) |
| `dts/` | Qualcomm yupik audio dtsi (from redwood-6.12; the 6.12 yupik.dtb has NO audio nodes) |
| `dtcheck/` | DT compile check (yupik.dts + dts/ + a52sxq-audio.dtsi), not an image |
| `mixer/` | HAL controls vs 5.4 vs 6.12 (`MISMATCH.md`), dai-link tables (`dailinks.md`), scripts |
| `patches/soc-repo-needed/` | two redwood pd-mapper patches the BSP still needs (yupik domains, aux-device id) |
| `samsung/` | (standalone copies; the built copies are in audio-kernel/asoc/codecs/{tas256x,sec_audio}) Samsung diff (`SAMSUNG-DIFF.md`), TAS256x + sec_audio_sysfs ports with notes, the patches (`patches/0001`, `0002`, `adaptation/0003` + `NOTES.md`) |
| `patches/a52sxq-audio-kernel.diff` | everything changed against the pristine donor, one diff |

## Build
    ./build.sh               # about 10 s; prints modules / compile errors / modpost errors
Uses the brief's `M=` pattern with `KBUILD_EXTRA_SYMBOLS` = soc-repo + mm-drivers
(`msm_ext_display`) Module.symvers. Result: see STATUS.md.

## Changes to the donor (reason for each)
Plain-make fixes:
1. `Kbuild` (new, top level): the donor only builds with Kleaf. Lists soc, ipc, dsp, asoc and the
   codec sub-directories (asoc/codecs/Kbuild only descends for in-tree builds).
2. `dsp/Kbuild:238`: `EXTRA_CFLAGS += $(KERNEL_SRC)/drivers/pinctrl/` lacked `-I` (clang: "linker
   input unused", -Werror).
3. `ipc/Kbuild`: bare `export` (export-all) removed. With GNU make 4.4 it stops kbuild with
   "Makefile.lib:382: prerequisites cannot be defined in recipes". The `.conf` lines export
   themselves.
4. `asoc/Kbuild:239`: `msm-pcm-host-voice-v2.o` enabled (Kleaf's module list has it;
   `platform_init.c` calls `msm_voice_host_init`).
From redwood-6.12 (same SoC):
5. `0001 apr: add the child devices on the first ADSP up` (q6core + audio ION devices appear).
6. redwood `0002 lahaina: speaker amps on PRI_TDM_RX_0` is NOT applied (Awinic amps of their
   phone).
Samsung (from the phone's 5.4 techpack, names unchanged):
7. `asoc/codecs/tas256x/` → `tas256x_dlkm.ko` (TI smart amp; 13 HAL controls `TAS256X ...`,
   `/dev/tas256x`, `/dev/tas_calib`, `/sys/class/tas25xx`), `samsung/tas256x/PORTING-NOTES.md`.
8. `asoc/codecs/sec_audio/` → `sec_audio_sysfs.ko` (`/sys/class/audio/{earjack,codec,amp}`).
9. `dsp/q6afe.c` + `include/dsp/tas_qualcomm.h`: TI smart-amp AFE hooks (`afe_tas_smartamp_*`).
10. `asoc/lahaina.c`, `asoc/msm_dailink.h`: QUIN_MI2S_RX/TX codec = `tas256x.18-004c` /
    `tas256x ASI1`, `.init = lahaina_tas256x_init`.
11. `CONFIG_SEC_SND_ADAPTATION` (`samsung/adaptation/0003`): `sec_audio_adaptation.c`,
    `sec_voice_adaptation.[ch]`, `q6voice_adaptation.c` + hooks; 30 controls the HAL sets by
    hard-coded name; dai-link 46 "Audio ADAPTATION Hostless".
12. `asoc/lahaina.c` hw:24 = "MultiMedia11" PCM on `msm-pcm-dsp.0` (Samsung
    `CONFIG_SEC_SND_PRIMARY`; donor: Compress4).
13. `asoc/lahaina.c`: `.no_pcm = 1` + `.dpcm_playback` restored on RX_CDC_DMA_RX_1/2/3/5/6
    (the donor would create five extra PCM devices and shift nothing the HAL uses, but 5.4 has
    none).
14. `asoc/msm-pcm-routing-v2.c`: `PROXY_RX_Voice Mixer Voip`,
    `USB_AUDIO_RX Port Mixer TX_CDC_DMA_TX_3` (+ routes).
15. `asoc/msm-qti-pp-config.c`: `TX_CDC_DMA_TX_3 LOOPBACK Volume`, `USB_AUDIO_TX LOOPBACK Volume`.
16. `asoc/codecs/bolero/rx-macro.c`: `RX_RX0/RX_RX1 HPH Digital Volume` as plain aliases of the
    RX0/RX1 volume. Samsung's impedance offset (`CONFIG_SND_SOC_IMPED_SENSING`) is NOT ported.
17. `config/lahainaauto.conf`, `lahainaautoconf.h`: `CONFIG_SND_SOC_TAS256x`,
    `CONFIG_TAS25XX_ALGO`, `CONFIG_SEC_SND_ADAPTATION`.
Fixes found on hardware (one patch each in `patches/audio-kernel/`, applied in `audio-kernel/`):
- `a52-import-cma-map-fix.patch`, `a52-wcd938x-amic-direct-routes.patch`,
  `a52-fe-qos-vote-fix.patch` (see the project log).
- `a52-audit-2026-11-18.patch`: the audio fixes from the 2026-11-18 audit (list in the patch
  header; built, not yet tested on a phone).
- `a52-parity-fe-pcm-bt-slim.patch`, then `a52-parity-mbhc-samsung-cfg.patch` (2026-11-18, 5.4
  parity: hw:24 and hw:43 are PCMs, BT back ends for `qcom,wcn-btfm`, Samsung headset button
  thresholds; compiled only): see `PARITY-FIXES.md` and `BT-SLIM-HANDOFF.md`.
- `a52-voice-cal-assign-direction.patch` (2026-11-15, rb16 call with heavy far-end noise):
  the donor's hyp_assign_phys -> qcom_scm_assign_mem conversion put the RECLAIM vmids
  (source LPASS|ADSP_HEAP, dest HLOS) into the two LEND calls, `voice_get_cal()` (q6voice) and
  `send_adm_cal_type()` (q6adm). A CMA cal buffer is owned by HLOS, so TZ refused (-22), the
  VOCPROC cal (cal 2: ECNS/AGC/gains) was never registered and the call ran uncalibrated.
  Now HLOS -> LPASS + ADSP_HEAP RW as on 5.4. Same patch: `msm_audio_protect_memory_region()`
  passed VMID 3 instead of the bitmap BIT(3); `voice_set_cvp_param()` copies the trailing
  payload with unsafe_memcpy (FORTIFY "field-spanning write" WARN on every call).
  Only `q6_dlkm.ko` changes (vermagic, CRC and import sections identical).
- The real boot takes every module byte for byte from a tested kexec ramdisk (REF), so a fixed
  audio .ko gets there through `./mk-ref-audio.sh <ref-rd> <out-rd> <new.ko>...` (REF + an
  appended cpio with only those files, checked) and `REF=<out> build-realboot.sh`.

## Userspace contract (research/blob-uapi-inventory.md, audio)
Kept: card name `lahaina-yupikidp-snd-card` (DT `qcom,model`); front-end PCM/compress numbers
0..45 as on 5.4 (index 24 fixed, see 12); all 325 mixer_paths.xml controls except the four that
are dead on 5.4 too (`HPH_L/R Switch`, `DSD_L/R Switch` — this is what redwood "could not find";
WCD938x uses `HPHL_RDAC Switch`/`HPHR_RDAC Switch` in both kernels) and two more absent in both;
`/dev/msm_audio_cal`, `/dev/msm_rtac` (misc, dynamic minors as before), hwdep nodes, the
`/dev/msm_*` codec nodes (native_dlkm), `/dev/tas256x`, `/dev/tas_calib`, `/sys/class/tas25xx`,
`/sys/class/audio/*`.
Changed / missing:
- Bluetooth back end: 5.4 `qcom,wcn-bt` (SLIMBUS_7 + `btfmslim_slave`) is `#if 0` in the donor;
  it reads `qcom,wcn-btfm` instead (same SLIMBUS_7 links + SLIMBUS_8_TX). Not enabled in the DT
  until a btfmslim codec exists on 6.12 (`/dev/btfmslim` is a separate driver).
- Earjack sysfs: the class exists, but `sec_wcd_sysfs_cb.c` (feeds state/key/mic-adc from MBHC)
  and Samsung's MBHC changes (slow detect, `mbhc-button-thres`, `det_zones`, impedance table) are
  not ported: plain Qualcomm MBHC detection applies.
- Sound trigger: 16 `SWR_MICn` names of the sound-trigger XML need swr-dmic devices the phone
  does not have (same on 5.4).
Could not verify: enum value lists of controls (only names were compared), run-time built
control names, which `audio_platform_info*.xml` the HAL loads (`mixer/hal-pcm-ids.txt` has both).

## Audio ION (task 4)
- In-kernel buffers: `msm_audio_ion_alloc()` calls `dma_heap_find("qcom,system-uncached")`.
  That heap is created by soc-repo `qcom_dma_heaps.ko` (`qcom_dma_heap.c`), not by a DT node;
  nothing to add to the DT, the module must be loaded before q6_dlkm.
- SMMU: node `qcom,msm-audio-ion` needs `iommus = <&apps_smmu 0x1801 0x0>`,
  `qcom,smmu-sid-mask = /bits/ 64 <0xf>` and an IOVA window. 5.4 uses
  `qcom,iommu-dma-addr-pool = <0x10000000 0x10000000>`; redwood kept it on 6.12 ("works,
  deprecated"). If the device never gets an IOMMU domain (their Wi-Fi case), switch to
  `iommu-addresses` with a reserved-memory node.
- The CMA variant (`qcom,msm-audio-ion-cma`, heap "qcom,audio-ml", `audio_cma_mem`) is only used
  for the ML/voice-wakeup path; `yupik-dma-heaps.dtsi` already defines `qcom,audio-ml`.
- Userspace: the HAL and libacdbloader DO pass ION fds: the live inventory shows the audio HAL
  holding `/dev/ion` and the calibration ioctls (`/dev/msm_audio_cal`) carrying ION fds. The
  kernel side only does `dma_buf_get(fd)` (`msm_audio_ion_import`), so any dma-buf works:
  `modules/ioncompat` is the bridge (its heap 25 "system" is backed by the dma-heap "system",
  which on this BSP is Qualcomm's system heap). No 6.12 exporter implements `get_flags`, so
  `dma_buf_get_flags()` returns 0 with flags 0 and every imported buffer is attached with
  `DMA_ATTR_SKIP_CPU_SYNC` (no cache maintenance), whether its mapping is cached or not. The
  CMA cal heap (`qcom,audio_ml`) therefore has to be uncached in the board DT
  (`qcom,uncached-heap`, audit 2026-11-18; not done yet, board-DT change).

## Load order (first-stage shell, after the ADSP is up)
Needs from the BSP first (not built here): `qcom_dma_heaps`, `rproc_qcom_common` + the ADSP PAS
driver, `pdr_interface`, pd-mapper with the yupik (sc7280) domains bound to
`rproc_qcom_common.pd-mapper` (redwood patches/soc-repo 0003, 0004), `qcom_ipc_logging`,
`qti_regmap_debugfs`, `qcom_scm`, `pinctrl_msm`, `fsa4480_i2c` (mbhc links against it although
the switch is disabled on this phone), `msm_ext_display` (mm-drivers), and `modules/ioncompat`
for Android. Then the exact order is in `load-order.txt` / `insmod-audio.sh` (generated by
`./load-order.sh` from the modules' `depends`):

    snd_event_dlkm  q6_pdr_dlkm  q6_notifier_dlkm  apr_dlkm  adsp_loader_dlkm  q6_dlkm
    native_dlkm  pinctrl_lpi_dlkm  swr_dlkm  swr_ctrl_dlkm  platform_dlkm  stub_dlkm  hdmi_dlkm
    wcd_core_dlkm  wcd9xxx_dlkm  mbhc_dlkm  bolero_cdc_dlkm  va_macro_dlkm  rx_macro_dlkm
    tx_macro_dlkm  wcd938x_slave_dlkm  wcd938x_dlkm  sec_audio_sysfs  tas256x_dlkm
    wsa883x_dlkm  wcd937x_dlkm  (pinctrl_wcd, swr_dmic, swr_haptics, wcd937x_slave, wsa_macro)
    machine_dlkm
machine_dlkm imports symbols from wsa883x_dlkm, wcd937x_dlkm and tas256x_dlkm, so those must be
loaded although the phone has no WSA883x/WCD937x. The modules in brackets are optional here.

## First on-device test (busybox shell, ADSP running)
    cat /sys/class/remoteproc/remoteproc*/name /sys/class/remoteproc/remoteproc*/state  # adsp running
    cd /extra/audio && sh insmod-audio.sh      # flat copy of the 32 .ko + insmod-audio.sh
    echo 1 > /sys/kernel/boot_adsp/boot 2>/dev/null   # adsp_loader, only if the ADSP is not up
    cat /proc/asound/cards
Expected:
     0 [lahainayupikidp]: lahaina-yupikid - lahaina-yupikidp-snd-card
                          lahaina-yupikidp-snd-card
Then:
    cat /proc/asound/pcm | head -50        # 00-00 MultiMedia1 ... 00-24 MultiMedia11 ... 00-45
    ls /dev/snd | grep -c pcm; ls /dev/msm_audio_cal /dev/msm_rtac /dev/tas256x /sys/class/audio
    i2cdetect is not needed: dmesg | grep -i tas256      # both channels 0x4c/0x4d answer
    dmesg | grep -iE 'apr|q6core|swr|wcd938x|bolero|tas25|lahaina|asoc' | tail -80
Expected log lines: `apr_tal_rpmsg ... apr_audio_svc`/`Q6 Is Up`, `q6core ... AVCS ready`,
`swrm ... slave device 1 found` twice (rx, tx), `wcd938x_codec ... bind`, `tas256x 18-004c`
probe with chip id, `lahaina-asoc-snd ... Sound card lahaina-yupikidp-snd-card registered`.

Likely failure modes:
- Card never appears, `platform ... deferred`: `cat /sys/kernel/debug/devices_deferred`. Usual
  causes: i2c bus is not number 18 (alias missing → codec `tas256x.18-004c` not found); a cpu
  dai of the unconditional TDM links missing in the DT; the adaptation node missing; ADSP not
  up (apr children are only added on the first ADSP up); pd-mapper without the yupik domains
  (the `avs/audio` domain never reported up).
- `swrm: no slave found`: SoundWire bus numbers (aliases swr0..2), LPI pinctrl, or the codec
  rails (L18B, L17B, BOB) / reset TLMM 83.
- TX capture silent: `qcom,swr-tx-port-params` (new on 6.12, lahaina defaults).
- `afe_tas_smartamp` errors on speaker start: the TI modules 0x1000fc00/0x1000fd00 on
  QUIN MI2S (port 0x1016) answer only with the phone's ADSP image and ACDB loaded.
- `msm_audio_ion ... no IOMMU`: see Audio ION above.
