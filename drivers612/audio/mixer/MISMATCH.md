# Mixer controls: HAL vs 5.4 (Samsung) vs 6.12 legacy donor

Inputs
- HAL XMLs (as shipped by the ROM): `device/samsung/a52sxq/configs/audio/mixer_paths.xml`
  (-> /vendor/etc/mixer_paths.xml, the only mixer_paths; card name in DT is
  `lahaina-yupikidp-snd-card`), `sm7325-common/audio/configs/sound_trigger_mixer_paths.xml`.
  325 unique `<ctl name>` in mixer_paths (hal-controls.txt), 79 in sound trigger
  (hal-controls-soundtrigger.txt).
- Hard-coded names inside the closed blobs: every string of the audio-related vendor blobs that
  equals a 5.4 kcontrol name (blob-hardcoded-controls.txt, 119 names, col 2 = OK / MISSING-6.12).
- Kernel sets: `kctl.py` (regex) over the whole 5.4 techpack (k54.tsv) and the 6.12 donor
  (k612.tsv). `k54-only.tsv` = every name 5.4 has and 6.12 lacks, by defining file.
- Limits of kctl.py: #ifdef ignored (superset: a name counted "present" may be config'd out);
  run-time built names (snprintf) invisible; enum VALUE texts are not compared (a control may
  exist with a changed value list); no name_prefix handling (lahaina.c sets none for
  bolero/wcd938x; swr-dmic gets "SWR_MICn" but the phone has swr-dmic-max-devs = 0).

Result: mixer_paths 325 = 299 present in both, 20 only in 5.4, 6 in neither. Nothing was renamed
by Qualcomm between 5.4 and 6.12 for the controls this phone uses; every miss is a Samsung
addition that has to be ported.

## A. In HAL XML, in 5.4, missing in 6.12 (20)

### asoc/codecs/tas256x/** (Samsung/TI addition, whole driver absent in 6.12) — 13
TAS256X AMP OUTPUT LVL LEFT/RIGHT, TAS256X ASI Left Switch / ASI Right Switch,
TAS256X ASI1 SEL LEFT/RIGHT, TAS256X BOOST CURRENT LEFT/RIGHT, TAS256X BOP ENABLE LEFT/RIGHT,
TAS256X DAC Mute, TAS256X PLAYBACK VOLUME LEFT/RIGHT, TAS256X RECEIVER ENABLE LEFT.
(tas256x-codec.c: DAPM/codec controls; tas256x-regmap.c: 53 more; algo/tas25xx-algo-common.c: 3
calibration controls. Full list: `grep tas256x k54-only.tsv`.)
Fix: port asoc/codecs/tas256x unchanged in names; codec device must be `tas256x.18-004c` with DAI
`tas256x ASI1` on QUIN_MI2S_RX/TX (msm_dailink.h, CONFIG_SND_SOC_TAS256x) and
`.init = lahaina_tas256x_init` on LPASS_BE_QUIN_MI2S_RX.

### asoc/codecs/bolero/rx-macro.c (Samsung, #ifdef CONFIG_SND_SOC_IMPED_SENSING) — 2
RX_RX0 HPH Digital Volume, RX_RX1 HPH Digital Volume (SOC_SINGLE_RANGE_EXT_TLV on
BOLERO_CDC_RX_RXn_RX_VOL_CTL with wcd_impedance_vol_get/put). Nearest 6.12: "RX_RX0 Digital
Volume" (plain). Fix: port the IMPED_SENSING block (rx-macro.c 411/769/852/1652/3234,
bolero-cdc.[ch], wcd-mbhc-v2.c, wcd938x internal.h/wcd938x.c/wcd938x-mbhc.c,
include/asoc/{wcd-mbhc-v2.h,bolero-slave-internal.h}); minimal fix = add the two controls as
aliases of the plain volume.

### asoc/msm-pcm-routing-v2.c (Samsung, no ifdef) — 2
- `PROXY_RX_Voice Mixer Voip`: add SOC_DOUBLE_EXT("Voip", MSM_BACKEND_DAI_PROXY_RX,
  MSM_FRONTEND_DAI_VOIP, msm_routing_get/put_voice_mixer) to proxy_rx_voice_mixer_controls[]
  and route {"PROXY_RX_Voice Mixer","Voip","VOIP_DL"}.
- `USB_AUDIO_RX Port Mixer TX_CDC_DMA_TX_3`: add SOC_DOUBLE_EXT("TX_CDC_DMA_TX_3",
  MSM_BACKEND_DAI_USB_RX, MSM_BACKEND_DAI_TX_CDC_DMA_TX_3, port_mixer) to
  usb_rx_port_mixer_controls[] + route {"USB_AUDIO_RX Port Mixer","TX_CDC_DMA_TX_3",
  "TX_CDC_DMA_TX_3"} (5.4 also has "SLIM_8_TX" there; not used by the XML).

### asoc/msm-qti-pp-config.c (Samsung, no ifdef) — 2
`TX_CDC_DMA_TX_3 LOOPBACK Volume`, `USB_AUDIO_TX LOOPBACK Volume`
(tx_cdc_dma_tx_3_lb_vol_mixer_controls / usb_audio_tx_vol_mixer_controls with
msm_qti_pp_{get,set}_cdc_tx_3_lb_vol_mixer / _usb_tx_lb_vol_mixer, 5.4 lines ~1745-1755 and their
registration in msm_qti_pp_add_controls). Handlers do not exist in 6.12: copy both.

### asoc/msm-pcm-routing-v2.c, same file, XML-used via MultiMedia11 being a PCM (see dailinks.md)
`AFE_PCM_RX/QUIN_MI2S_RX/RX_CDC_DMA_RX_0 Audio Mixer MultiMedia11` exist in 6.12 (OK);
5.4-only `Incall_Music Audio Mixer MultiMedia11`, `Incall_Music_2 Audio Mixer MultiMedia11`
are not in the XML (port anyway, cheap).

## B. Hard-coded in audio.primary.lahaina.so, missing in 6.12 (18) — never in the XML
All from Samsung's adaptation platform component ("q6audio-adaptation", compatible
`samsung,q6audio-adaptation`, CONFIG_SEC_SND_ADAPTATION; dai-link "Audio ADAPTATION Hostless"):
- asoc/sec_audio_adaptation.c (19 controls; HAL uses): LRSM data, Listenback Enable,
  Remote Mic Vol Index, SA LISTENBACK RX volume, SB FM RX Volume, SB RX Volume, SB enable,
  SB flatmotion, SB rotation, VSP data. (Others defined: Audio DHA data, DA data, MSP data,
  SA LISTENBACK RX data, SA data, UPSCALER, VM Energy, VM data, VoiceTrackInfo — the string
  matcher skips names of <= 6 chars / single words, so assume the HAL uses these too.)
- asoc/sec_voice_adaptation.c (11; HAL uses): DSP AEC Effect, Echo Ref Mute, Loopback Enable,
  NB Mode, Sec Set DHA data, Speaker Sensor Mode, Voice Device Info, Voice Isolation Mode.
  (Also: BT SCO Rx Volume, REF LCH MUTE, Receiver Sensor Mode.)
Fix: port sec_audio_adaptation.c, sec_voice_adaptation.[ch], dsp/q6voice_adaptation.c and the
CONFIG_SEC_SND_ADAPTATION hunks in dsp/q6afe.c (35), q6adm.c, q6asm.c, q6voice.c, q6_init.[ch],
platform_init.[ch], msm-pcm-routing-v2.[ch], msm-pcm-voice-v2.c, msm-dai-fe.c; DT node
`samsung,q6audio-adaptation` + the dai-link.

## C. Other 5.4-only controls (not referenced by XML or blob strings; port opportunistically)
tx-macro.c: `HPF cut off TX0..7`, `DMIC_RATE OVERRIDE`; wcd938x.c: `MIC BIAS1..4 Standalone`,
`DMIC8_MIXER Switch`; msm-dai-q6-v2.c: `SEC_MI2S_RX AFE ...`/`SBM Delay`/`AFE Dynamic Bitrate`
(A2DP-over-MI2S, not this phone); routing: `FNN STM Audio/Voice Tx *`, `QUAT/QUIN_TDM_RX_0_Voice
Mixer *`, `CDC_DMA_RX_n_VI_FB_MUX`, `MultiMedia6 Mixer SLIM_8_TX`; lahaina.c: `DAI Clocks`,
`DAI Mode`, `DAI Polarity`, `Force Frame32`, `Static MCLK Mode`, `Codec CLK Source` (Cirrus amp
variants, not a52s). Full list: k54-only.tsv.

## D. In HAL XML, in neither kernel (6) — already dead on 5.4, no action
`HPH_L Switch`, `HPH_R Switch`, `DSD_L Switch`, `DSD_R Switch` (old WCD934x names; WCD938x has
`HPHL_RDAC Switch`/`HPHR_RDAC Switch`, same in both trees — this is what redwood "could not
find": it is not a 6.12 rename), `MultiMedia5_RX QOS Vote`, `RX_CDC_DMA_RX_0 Port Mixer
SLIM_7_TX`. Sound-trigger XML: 16 `SWR_MICn ...` names need swr-dmic devices (the phone has
none); all `VA DMIC/SMIC MUXn` are present in both.

## E. Not name mismatches but they decide whether existing names work
- BT: 5.4 adds msm_wcn_be_dai_links (SLIMBUS_7_RX/TX, `qcom,wcn-bt = <1>` in the phone DT);
  the 6.12 donor has that array under `#if 0` and the property read commented out. The
  `SLIM_7_RX*/SLIM_7_TX` controls still register (routing) but have no backend. Restore.
- 6.12 lahaina.c drops `.no_pcm = 1`/`.dpcm_playback` on RX_CDC_DMA_RX_1,2,3,5,6 and
  WSA_CDC_DMA_RX_1/TX_1 (only RX_0 keeps it) — those BEs would become real PCM devices; restore.
- 6.12 has the wsa-max-devs DT read commented out (wsa_max_devs stays 0 = what the phone wants).
