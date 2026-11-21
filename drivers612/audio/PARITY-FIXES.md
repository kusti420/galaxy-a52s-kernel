# Audio parity fixes (2026-11-18)

Source: `drivers612/PARITY-2026-11-18.md` (P0 items 1 and 2, P1 items 3 and 4).
Everything here was done OFFLINE: compiled, not loaded on a phone. "Verified" below means
verified from source, preprocessed source or existing logs, never on hardware by this work.

Build: `drivers612/audio/build.sh` -> 32 modules, 0 compile errors, 0 modpost errors,
0 warnings; `machine_dlkm.ko` and `platform_dlkm.ko` vermagic `6.12.81-4k-g8a69376da734`.
Changed modules: **`asoc/platform_dlkm.ko`** (msm-dai-fe.c) and **`asoc/machine_dlkm.ko`**
(lahaina.c). No exported symbol or struct changed, so the two can be swapped into a ramdisk
independently of the other 30 audio modules.

Patches (a re-prepare keeps the changes; `patch -p1` in `audio-kernel/`, in this order, after
`a52-audit-2026-11-18.patch`; checked: applied to the pre-change files they reproduce the
tree byte for byte):
1. `patches/audio-kernel/a52-parity-fe-pcm-bt-slim.patch` (sections 1 and 2)
2. `patches/audio-kernel/a52-parity-mbhc-samsung-cfg.patch` (section 4)

| What | State |
|---|---|
| hw:24 PCM (P0-2) | fixed, compiled, not on a phone |
| hw:43 PCM as on 5.4 | fixed, compiled, not on a phone |
| BT back ends SLIMBUS_7_RX/TX (P0-1, audio side) | machine driver done, compiled; DT + load order in `BT-SLIM-HANDOFF.md` (rb44 already has both) |
| BT codec name | no change needed: `btfmslim_slave` is correct (the parity report's rename to `btfmslim` would break it) |
| 10 run-time BT controls + 26 routing controls | no source change needed: they appear once the back end is in the card |
| `AFE Dynamic Bitrate`, `SBM Delay` (Samsung, A2DP offload only) | ported 2026-11-21, on the phone in rbich30 / ramdisk s97b (section 2) |
| USB audio offload (P1-3) | no audio-tree change needed; load-list item (section 3) |
| MBHC (P1-4) | button thresholds + 2 config values ported; impedance table, slow detect, moisture, sysfs NOT ported (section 4) |

## 1. P0-2: front-end PCM ids (done)

Method: `lahaina.c` and `msm-dai-fe.c` of both trees preprocessed with their real kbuild
command (`clang -E`), the front-end link arrays parsed in card order
(`msm_common_dai_links`, `msm_bolero_fe_stub_dai_links` because `qcom,wsa-max-devs = <0>`,
`msm_common_misc_fe_dai_links`). A link becomes a compress node when its cpu DAI has
`.compress_new` (5.4: `snd_soc_dai_driver.compress_new`; 6.12: `ops->compress_new`, i.e.
`msm_fe_compress_dai_ops`). 5.4 = `$ANDROID_TREE/kernel/samsung/sm7325/techpack/audio` (the
tree the ROM builds; `~/git/kernel_a52sxq_bone` has the same two hunks).

Two mismatches, both fixed:

| idx | 5.4 | 6.12 before | 6.12 after | Change |
|---|---|---|---|---|
| 24 | PCM, MultiMedia11 on msm-pcm-dsp.0 (`CONFIG_SEC_SND_PRIMARY`) | compress node (FE DAI MultiMedia11 had `msm_fe_compress_dai_ops`; the link was already msm-pcm-dsp.0) | PCM | `asoc/msm-dai-fe.c`: `.ops = &msm_fe_Multimedia_dai_ops` |
| 43 | PCM, link "Compress3" = MultiMedia10 on msm-pcm-dsp.1 | compress node, MultiMedia20 on msm-compress-dsp | PCM, MultiMedia10 on msm-pcm-dsp.1 | `asoc/lahaina.c` link 43: `.id = MSM_FRONTEND_DAI_MULTIMEDIA10`, `SND_SOC_DAILINK_REG(multimedia10)` |

Which ids the HAL opens: `device/samsung/sm7325-common/audio/configs/audio_platform_info.xml`
(`<pcm_ids>`, column 2 below; `audio_platform_info_diff.xml` has no pcm ids) plus the table
built into the blob `vendor/lib/hw/audio.primary.lahaina.so` (found at file offset 0xadc04 by
scanning for the int pairs; entry 1 = `primary-playback` = 24/24, which matches
`logs/rb16-call-audio.txt:35-38` "usecase(1: primary-playback)" / "cannot open device 24").
The blob table also names ids 47-49, 54, 55: those are not front ends on either kernel (same
on 5.4), so no gap.

Full table (front ends 0-46; back ends have no device node, so their order does not matter):

| idx | HAL use (audio_platform_info.xml) | 5.4 link / cpu DAI / platform | 5.4 type | 6.12 before | 6.12 after | match |
|---|---|---|---|---|---|---|
| 0 | - | LAHAINA Media1 / MultiMedia1 / msm-pcm-dsp.0 | PCM | PCM | PCM | yes |
| 1 | - | LAHAINA Media2 / MultiMedia2 / msm-pcm-dsp.0 | PCM | PCM | PCM | yes |
| 2 | VoiceMMode1 call | VoiceMMode1 / VoiceMMode1 / msm-pcm-voice | PCM | PCM | PCM | yes |
| 3 | - | MSM VoIP / VoIP / msm-voip-dsp | PCM | PCM | PCM | yes |
| 4 | - | LAHAINA ULL / MultiMedia3 / msm-pcm-dsp.2 | PCM | PCM | PCM | yes |
| 5 | AFE proxy out | MSM AFE-PCM RX / msm-dai-q6-dev.241 / msm-pcm-afe | PCM | PCM | PCM | yes |
| 6 | AFE proxy in | MSM AFE-PCM TX / msm-dai-q6-dev.240 / msm-pcm-afe | PCM | PCM | PCM | yes |
| 7 | offload | LAHAINA Compress1 / MultiMedia4 / msm-compress-dsp | compress | compress | compress | yes |
| 8 | - | AUXPCM Hostless / AUXPCM_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 9 | low-latency | LAHAINA LowLatency / MultiMedia5 / msm-pcm-dsp.1 | PCM | PCM | PCM | yes |
| 10 | - | Listen 1 Audio Service / LSM1 / msm-lsm-client | PCM | PCM | PCM | yes |
| 11 | offload2 | LAHAINA Compress2 / MultiMedia7 / msm-compress-dsp | compress | compress | compress | yes |
| 12 | VoIP | LAHAINA MultiMedia10 / MultiMedia10 / msm-pcm-dsp.1 | PCM | PCM | PCM | yes |
| 13 | ULL / low-latency rec | LAHAINA ULL_NOIRQ / MultiMedia8 / msm-pcm-dsp-noirq | PCM | PCM | PCM | yes |
| 14 | - | HDMI_RX_HOSTLESS / HDMI_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 15 | VoiceMMode2 call | VoiceMMode2 / VoiceMMode2 / msm-pcm-voice | PCM | PCM | PCM | yes |
| 16 | - | Listen 2 Audio Service / LSM2 / msm-lsm-client | PCM | PCM | PCM | yes |
| 17 | - | Listen 3 Audio Service / LSM3 / msm-lsm-client | PCM | PCM | PCM | yes |
| 18 | - | Listen 4 Audio Service / LSM4 / msm-lsm-client | PCM | PCM | PCM | yes |
| 19 | - | Listen 5 Audio Service / LSM5 / msm-lsm-client | PCM | PCM | PCM | yes |
| 20 | - | Listen 6 Audio Service / LSM6 / msm-lsm-client | PCM | PCM | PCM | yes |
| 21 | - | Listen 7 Audio Service / LSM7 / msm-lsm-client | PCM | PCM | PCM | yes |
| 22 | - | Listen 8 Audio Service / LSM8 / msm-lsm-client | PCM | PCM | PCM | yes |
| 23 | silence / incall music / incall rec | LAHAINA Media9 / MultiMedia9 / msm-pcm-dsp.0 | PCM | PCM | PCM | yes |
| 24 | primary-playback (blob) / offload4 (xml) | LAHAINA Media11 / MultiMedia11 / msm-pcm-dsp.0 | PCM | compress | PCM | yes (was wrong) |
| 25 | offload5 | LAHAINA Compress5 / MultiMedia12 / msm-compress-dsp | compress | compress | compress | yes |
| 26 | offload6 | LAHAINA Compress6 / MultiMedia13 / msm-compress-dsp | compress | compress | compress | yes |
| 27 | offload7 | LAHAINA Compress7 / MultiMedia14 / msm-compress-dsp | compress | compress | compress | yes |
| 28 | offload8 | LAHAINA Compress8 / MultiMedia15 / msm-compress-dsp | compress | compress | compress | yes |
| 29 | MMAP | LAHAINA ULL_NOIRQ_2 / MultiMedia16 / msm-pcm-dsp-noirq | PCM | PCM | PCM | yes |
| 30 | FM / spkr calib RX | CDC_DMA Hostless / CDC_DMA_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 31 | - | TX3_CDC_DMA Hostless / TX3_CDC_DMA_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 32 | FM in | Tertiary MI2S TX_Hostless / TERT_MI2S_TX_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 33 | spkr calib TX | WSA_CDC_DMA_TX_0 / msm-dai-cdc-dma-dev.45057 / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 34 | - | LAHAINA ASM Loopback / MultiMedia6 / msm-pcm-loopback | PCM | PCM | PCM | yes |
| 35 | - | USB Audio Hostless / USBAUDIO_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 36 | A2DP ABR feedback | SLIMBUS_7 Hostless / SLIMBUS7_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 37 | compress record | Compress Capture / MultiMedia17 / msm-compress-dsp | compress | compress | compress | yes |
| 38 | - | SLIMBUS_8 Hostless / SLIMBUS8_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 39 | - | TX_CDC_DMA_TX_5 / msm-dai-cdc-dma-dev.45115 / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 40 | - | LAHAINA Media31 / MultiMedia31 / msm-pcm-dsp.0 | PCM | PCM | PCM | yes |
| 41 | - | LAHAINA Media32 / MultiMedia32 / msm-pcm-dsp.0 | PCM | PCM | PCM | yes |
| 42 | AFE proxy2 in | MSM AFE-PCM TX1 / msm-dai-q6-dev.242 / msm-pcm-afe | PCM | PCM | PCM | yes |
| 43 | offload3 | LAHAINA Compress3 / MultiMedia10 / msm-pcm-dsp.1 | PCM | compress (MultiMedia20 on msm-compress-dsp) | PCM | yes (was wrong) |
| 44 | - | Secondary MI2S_TX Hostless / SEC_MI2S_TX_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 45 | - | DISPLAY_PORT_RX_HOSTLESS / DISPLAY_PORT_HOSTLESS / msm-pcm-hostless | PCM | PCM | PCM | yes |
| 46 | - | Audio ADAPTATION Hostless / snd-soc-dummy-dai / q6audio-adaptation | no_pcm (no node) | no_pcm (no node) | no_pcm (no node) | yes |

Not changed, cosmetic only: 5.4 names some links "LAHAINA Media1" etc. (`MSM_DAILINK_NAME`),
6.12 "MultiMedia1" etc. This shows in `/proc/asound/pcm` only; the HAL opens by number.

Note on 43: on 5.4 two links (12 and 43) share the FE DAI MultiMedia10 / FE id 10; the port now
does the same. Per-device controls are named by PCM device number, so no duplicate names
(checked in `asoc/msm-pcm-q6-v2.c`); `pdata->pcm_device[10]` ends up pointing at device 43 as on
5.4. 6.12 soc-core with one cpu DAI in two dynamic links is not exercised anywhere else in this
card: phone check below.

### Phone verification (P0-2)
1. `adb -s <test phone> shell cat /proc/asound/pcm | grep -E '^00-(24|43):'` -> both lines
   present with `playback 1` (before: no `00-24` line, `/dev/snd/comprC0D24` instead).
   `ls /dev/snd | wc -l` stays 66 (two compress nodes become two PCM nodes).
2. `dmesg | grep -c 'msm_compr_new: Could not add Compr'` -> 0. The 6 lines in the rb44 boot
   (`logs/verify-rb44-boot1-205242/dmesg.txt`, 14.67 s) come from link 24: a compress DAI on
   the PCM platform msm-pcm-dsp.0.
3. Card still registers: `cat /proc/asound/cards`, `dmesg | grep -i 'snd_soc_register_card\|ASoC:.*error'`.
4. Play a ringtone / notification (not music): logcat `audio_hw_primary` must show
   `usecase(1: primary-playback)` and no `cannot open device 24`.
5. New controls exist: `tinymix | grep -E "Playback 24 Volume|Playback Channel Map24|Playback 24 App Type Cfg"`.

## 2. P0-1: Bluetooth over SLIMbus, audio side (machine driver done)

### Findings
- **Codec name: keep `btfmslim_slave`.** `drivers612/conn/bt/btfmslim/Kbuild` builds with
  `-DCONFIG_BTFM_SLIM`, so `IS_ENABLED(CONFIG_BTFM_SLIM)` is true and `btfm_slim.h:32-33` sets
  `BTFMSLIM_DEV_NAME "btfmslim_slave"`; `btfm_slim_probe` renames the slim device to that
  before `snd_soc_register_component`, so the component name is `btfmslim_slave`. Evidence
  from the other agent's boot: `logs/verify-rb44-boot1-205242/dmesg.txt` 4.163 s
  `btfm_slim_probe: name = 217:221:1:0` -> `name = btfmslim_slave`. The parity report (and
  `conn/bt/STATUS.md`) say `btfmslim`: that is the `#else` branch, not what is built.
  `asoc/msm_dailink.h:906-919` is therefore unchanged. DAI names match too:
  `btfm_bt_sco_a2dp_slim_rx`, `btfm_bt_sco_slim_tx`, `btfm_fm_slim_tx`
  (`btfm_slim_codec.c:396-440`).
- 5.4 adds the BT back ends for `qcom,wcn-bt = <1>`: table `msm_wcn_be_dai_links`
  (SLIMBUS_7_RX + SLIMBUS_7_TX, `msm_wcn_init` rx {157,158} tx {159,160}, `msm_wcn_ops`).
  The 6.12 port had that table, its init and its ops under `#if 0` and only knew
  `qcom,wcn-btfm = <u32>` -> Qualcomm's 3-link table (adds SLIMBUS_8_TX = FM, tx {159,160,161}).
- The routing side needed nothing: the BT-related names (`SLIM_7`, `SLIMBUS_7`, `BT SampleRate`,
  `BT SampleRate RX/TX`, ...) in the preprocessed `lahaina.c` and `msm-pcm-routing-v2.c` are
  the same set on both kernels (0 names 5.4-only); `MSM_BACKEND_DAI_SLIMBUS_7` handling in
  `lahaina.c` is the same (50 references each). `MultiMedia16 Mixer SLIM_7_TX` is in the
  array on both; `RX_CDC_DMA_RX_0 Port Mixer SLIM_7_TX` is in neither (no gap).
- The 10 run-time controls (`AFE Input Channels`, `SLIM_7_RX Encoder Config`,
  `AFE Input Bit Format`, `AFE Scrambler Mode`, `TWS Channel Mode`,
  `SLIM_7_RX APTX_AD Enc Cfg`, `LC3 Channel Mode`, `SLIMBUS_7_RX DRIFT`,
  `SLIM_7_TX Decoder Config`, `AFE Output Channels SLIM7`) are added by
  `msm_dai_q6_dai_probe` when SLIMBUS_7_RX/TX is in a dai-link: they come back with the
  back end, no source change.

### Change (`asoc/lahaina.c`, in `a52-parity-fe-pcm-bt-slim.patch`)
- `msm_wcn_hw_params`, `msm_wcn_ops`, `msm_wcn_init`, `msm_wcn_be_dai_links` compiled again
  (were `#if 0` / commented out), table counted in `msm_lahaina_dai_links[]`.
- `populate_snd_card_dailinks`: `qcom,wcn-btfm` handling:

| Sound node property | Back ends added |
|---|---|
| absent | none (as before; `dev_info` instead of `dev_err`) |
| `qcom,wcn-btfm;` or `qcom,wcn-btfm = <1>;` | 5.4 set: SLIMBUS_7_RX, SLIMBUS_7_TX |
| `qcom,wcn-btfm = <2>;` | Qualcomm 6.12 set: SLIMBUS_7_RX, SLIMBUS_7_TX, SLIMBUS_8_TX |
| `qcom,wcn-btfm = <0>;` | none |
| `qcom,wcn-bt = <1>` (already in the board tree) | still ignored, on purpose |

  dmesg marker: `populate_snd_card_dailinks: wcn btfm back ends: mode N`.
  Behaviour change for the tree rb44 was built from (`qcom,wcn-btfm = <1>`): before this
  change `<1>` selected the 3-link table, now the 5.4 2-link table.
- Why `qcom,wcn-bt` stays ignored: a dai-link whose codec component does not exist keeps
  `snd_soc_register_card` deferring for ever, i.e. **no sound card at all**. The board tree
  has always carried `qcom,wcn-bt = <1>`; honouring it would break every build that does not
  load the four BT/SLIMbus modules.

### Done 2026-11-21: `AFE Dynamic Bitrate` and `SBM Delay` (ramdisk s97b)
Samsung's two A2DP-offload run-time controls of SLIMBUS_7_RX, ported from the ROM's 5.4 kernel
(`asoc/msm-dai-q6-v2.c:3860-3905, 4170-4210, 4362-4373`, `dsp/q6afe.c:2044-2098, 2287-2345`,
`apr_audio-v2.h:6627`): patch `patches/audio-kernel/a52-parity-a2dp-dynbitrate-sbm.patch`
(4 files: the two controls as `afe_enc_config_controls[7]` / `[8]` at 5.4's positions,
`afe_q6_slimbus_update_dyn_bitrate` / `afe_q6_slimbus_update_sbm` in q6afe.c through one helper,
`struct asm_sbm_param_t`, `struct asm_bitrate_param_t`, `AVS_MEDIA_ID_SBM_ID`,
`AVS_ENCODER_PARAM_ID_ENC_BITRATE`). Only `q6_dlkm.ko` and `platform_dlkm.ko` change; Module.symvers
= before + the two new exports (every existing CRC unchanged, so no dependent module is rebuilt).
Ramdisk `drivers612/androidboot/out/s97b-rd.cpio.gz` = s97 with those two modules (rd-swap-ko).
Phone (broken screen, IchthysOS, rbich30 = rbich29 on s97b): both controls exist, read back what
was written (`AFE Dynamic Bitrate` 328000, `SBM Delay` 16 bytes), the puts reach
`afe_q6_slimbus_update_*` with the same tinymix exit codes as 5.4 (0 / 2); `tools/abyss-cycle/
mixcheck.py`: the BT / A2DP-offload control line is now identical to 5.4's, and the names of the
ROM's `mixer_paths.xml` that do not exist are the same 24 on both kernels (stale names in the
xml, e.g. `RX_CDC_DMA_RX_0 Audio Mixer MultiMedia10`, `MultiMedia16 Mixer SLIM_7_TX`).
Neither abyssd (`a2dp_dsp.rs`) nor `mixer_paths.xml` uses the two controls; only
`liba2dpoffload.so` does.
Opening the back end without a headset (SLIMBUS_7_RX added to a running silent playback):
`btfm_slim_hw_init: failed to get slimbus logical address: -6` on 6.12 AND on 5.4 (the ADSP's
slimbus manager does not know the BT chip's address until the BT firmware starts an audio link),
same -6 up the DPCM chain, no WARN. So an AFE SLIMBUS_7_RX open still needs a real headset.
Logs: `logs/ichthys-1121/1c-slim7-open-{54,rbich30}.txt`, `logs/ichthys-1121/audio/`.

### Not done
- `AUDIO_REF_EC_UL* MUX` / `AFE_LOOPBACK_TX Port` enum values `SLIM_7_TX` etc. (parity P2).

### Phone verification (BT)
Needs the DT + modules of `BT-SLIM-HANDOFF.md` and this `machine_dlkm.ko`.
1. `dmesg | grep -E 'btfm_slim_probe|wcn btfm back ends|snd-card'` -> `name = btfmslim_slave`,
   `mode 1`, card registered; `cat /sys/kernel/debug/devices_deferred` empty (if the sound
   node is listed there, the codec is missing: remove `qcom,wcn-btfm` or fix the load order).
2. `tinymix | grep -cE 'SLIM_7|SLIMBUS_7'` and each of the 10 control names above with
   `tinymix '<name>'`; logcat has no `Control 'AFE Input Channels' doesn't exist`.
3. Pair a headset, make a call (HFP): audio both ways. `dmesg | grep -iE 'btfm|slim'` during
   the call: no `btfm_slim_hw_init` / `slim_stream` errors. `tinymix 'BT SampleRate'`.
4. Media to the headset (A2DP): per the parity report this does not use SLIMbus on this ROM;
   check it still plays.
5. Speaker playback + mic recording still work (card regression check).

## 3. P1-3: USB audio offload (`snd-usb-audio-qmi`): nothing to change in the audio tree

- Module: `bsp612/soc-repo-staging/sound/usb/snd-usb-audio-qmi.ko` (also in `bsp612/out/dist`),
  vermagic `6.12.81-4k-g8a69376da734`, `depends: qmi_helpers,qcom_ipc_logging,dwc3-msm`.
  All 71 undefined symbols resolve in GKI + lahaina + soc-repo Module.symvers
  (`snd_usb_register_platform_ops`, `xhci_sideband_*`: `CONFIG_USB_XHCI_SIDEBAND=y`).
- DT node `/soc/usb_audio_qmi_dev` is present with the 5.4 values (`iommus = <&apps_smmu
  0x180f 0>`, `qcom,iommu-dma = "disabled"`, `qcom,usb-audio-stream-id = <0xf>`,
  `qcom,usb-audio-intr-num = <2>`).
- Audio tree: the USB back ends (`USB_AUDIO_RX/TX`, `msm-dai-q6-dev.28672/28673`), their
  routing controls and `USB_AUDIO_RX/TX SampleRate/Format/Channels` are present with equal
  enum texts (parity report 3b). Nothing to patch.
- Needed (owner of the load list): add `snd-usb-audio-qmi.ko` after `dwc3-msm.ko`,
  `qmi_helpers.ko`, `qcom_ipc_logging.ko`. Not in rb44's `first-stage.modules.load`.
- Phone check: `dmesg | grep -iE 'uaudio|usb_audio_qmi'` after loading (probe, QMI service
  registered); plug a USB-C headset: `cat /proc/asound/cards` shows the USB card, play audio,
  `dmesg | grep -iE 'uaudio|xhci.*sideband|interrupter'`. Risk to look at: the secondary xHCI
  interrupter (`qcom,usb-audio-intr-num = <2>`) must be available on the dwc3 host
  (`xhci_sideband_create_interrupter` failing = no offload). Compare with 5.4:
  `tinymix 'USB_AUDIO_RX Audio Mixer MultiMedia1'` path and the same headset.
- P2, not done: `.dynamic_be = 1` on USB_AUDIO_RX (5.4 QGKI only; compiled out on 6.12 because
  `CONFIG_AUDIO_QGKI` is off).

## 4. P1-4: Samsung MBHC (partly done)

5.4 vs 6.12 (`asoc/lahaina.c` `wcd_mbhc_cfg` + `def_wcd_mbhc_cal`, DT `wcd938x-codec` node;
the 6.12 board tree carries the same `mbhc-button-thres` and `imp-table` as 5.4):

| Item | 5.4 (Samsung) | 6.12 before | 6.12 now |
|---|---|---|---|
| button thresholds `btn_high[0..7]` | DT `mbhc-button-thres`, first cell: 13, 88, 138, 225, 450, 450, 450, 450 | Qualcomm defaults 75, 150, 237, 500, 500, 500, 500, 500 (property unread) | from DT, as 5.4 |
| `detect_extn_cable` | false | true | false |
| `linein_th` | 59000 | 5000 | 59000 |
| `moisture_en` | true | false | false (NOT changed) |
| `gnd_det_en` | false | false (default) | same |
| `mbhc_spl_headset` | false | field not in the 6.12 struct | - |
| impedance table (`imp-table`, 8 rows min/max/gain) + digital gain offset | `CONFIG_SND_SOC_IMPED_SENSING`: `wcd938x.c:4201`, `wcd938x-mbhc.c:594`, event `SEC_WCD_BOLERO_EVT_IMPED_TRUE` to bolero / rx-macro | absent | NOT ported |
| slow insertion detect | `CONFIG_SND_SOC_WCD_MBHC_SLOW_DET` in `wcd-mbhc-v2.h/.c`, `wcd938x_disable_bcs_before_slow_insert` | absent | NOT ported |
| surge protection fields `WCD_MBHC_EN_SURGE_PROTECTION_HPHL/R` | register fields | done differently on 6.12 (surge off/on around Z-det in `wcd938x-mbhc.c`) | - |
| `HS_VREF_MIN_VAL` | 1300 | 1400 | not changed (shared header; needs a headset to judge) |
| `WCD938X_ZDET_NUM_MEASUREMENTS` | 250 | 900 | not changed |
| `sec_wcd_sysfs_cb.c` (`/sys/class/audio/earjack`) | present | absent | NOT ported |

Change: `a52-parity-mbhc-samsung-cfg.patch` (lahaina.c only): `def_wcd_mbhc_cal(component)`
parses `mbhc-button-thres` with `#list-det-cells` exactly as 5.4 (first cell because
`CONFIG_SEC_FACTORY` is not set in the ROM kernel config); the two config values.
Effect of the thresholds: with the Qualcomm defaults a Samsung headset's buttons land in the
wrong bins (button 0 reached up to 75 instead of 13).

Why `moisture_en` was left: enabling it changes the insertion flow (`wcd-mbhc-v2.c:908,
1073, 1419`, `wcd-mbhc-adc.c`), and 5.4 runs it together with the Samsung slow-detect /
pull-up hunks that are not ported. Not something to switch on without a headset on the bench.

What the rest needs (not a small change): Samsung hunks in `asoc/codecs/wcd-mbhc-v2.c`,
`wcd-mbhc-adc.c`, `include/asoc/wcd-mbhc-v2.h` (`impedance_offset`, `slow_insertion`,
`pullup_enable`), `codecs/wcd938x/{wcd938x.c,wcd938x-mbhc.c,internal.h}` (imp_table pdata),
`codecs/bolero` + `rx-macro` (`SEC_WCD_BOLERO_EVT_IMPED_TRUE` gain offset),
`asoc/sec_wcd_sysfs_cb.c`. All pure audio-tree, estimated M.

### Phone verification (MBHC)
1. `dmesg | grep def_wcd_mbhc_cal` -> 8 lines `btn_high[i] = 13/88/138/225/450... (modified)`.
2. Plug a 4-pole headset: `getevent -l` shows `SW_HEADPHONE_INSERT` + `SW_MICROPHONE_INSERT`;
   press each button: `KEY_MEDIA`, `KEY_VOICECOMMAND`, `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN` as on 5.4.
3. Plug 3-pole headphones and a line-out cable (aux to a speaker): reported as headphone
   (`SW_HEADPHONE_INSERT`), not `SW_LINEOUT_INSERT` (the `linein_th` / `detect_extn_cable` change).
