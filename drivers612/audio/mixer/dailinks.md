# dai-link tables: 5.4 Samsung lahaina.c vs 6.12 donor lahaina.c

Tools: dailinks.py (dumps each array: dl54.txt, dl612.txt), dailinks-table.txt = the card as
composed for the phone's DT (wsa-max-devs 0 -> bolero_fe_stub; no qcom,tdm-audio-intf;
mi2s-audio-intf 1; CONFIG_AUXPCM_DISABLE; ext-disp-audio-rx 0; wcn-bt 1; afe-rxtx-lb 0; no
wcn-btfm) with the a52s config (SEC_SND_PRIMARY, SEC_SND_ADAPTATION, TAS256x). PCM/compress
device number = link index. Parser note: "FE" in the 6.12 column for a LPASS_BE_* link means the
entry has no `.no_pcm`.

Order of concatenation is identical: common(0-37) + bolero_fe_stub(38) + misc_fe(39-45[,46]) +
common_be + rx_tx_cdc_dma_be + va_cdc_dma_be + mi2s_be [+ wcn_be].

## Front ends (what the HAL addresses by number; audio_platform_info pcm ids in hal-pcm-ids.txt)
Index 0..45 are the same links with the same stream names, EXCEPT:

| idx | 5.4 a52s | 6.12 donor | fix |
|---|---|---|---|
| 24 | "MultiMedia11", cpu MultiMedia11, platform **msm-pcm-dsp.0** (PCM playback; `#ifdef CONFIG_SEC_SND_PRIMARY` in lahaina.c 7484 and msm_dailink.h 138) | "Compress4", platform msm-compress-dsp (compress device) | take the SEC_SND_PRIMARY variant: stream_name "MultiMedia11", COMP_PLATFORM("msm-pcm-dsp.0"). XML still lists OFFLOAD4 id=24 but the HAL routes `* Audio Mixer MultiMedia11` as PCM. |
| 46 | "Audio ADAPTATION Hostless" (no_pcm, cpu snd-soc-dummy-dai, platform **q6audio-adaptation**, `CONFIG_SEC_SND_ADAPTATION`), appended to msm_common_misc_fe_dai_links | absent (46 is first BE) | add with the sec adaptation port; it creates no PCM node but registers the Samsung controls. |

Link `.name` differs everywhere (5.4: `MSM_DAILINK_NAME(Media1)` = "<CHIPSET> Media1"; 6.12:
"MultiMedia1"); the pcm name shown in /proc/asound/pcm comes from stream_name, which is equal.
Key ids from the XML that depend on this table: 9 low latency (MultiMedia5), 7/11/43/24-28
offload, 2/15 voice, 12 voip, 13 ULL, 29 mmap, 36 A2DP ABR, 37 compress capture, 5/6/42 AFE
proxy, 23 incall music, 30/32/33 hostless — all at the same index in both trees except 24.

## Back ends (no PCM node; order irrelevant, presence matters)
- 6.12 folds the TDM links (PRI..SEN_TDM_RX/TX_0) into msm_common_be_dai_links unconditionally
  and adds LPASS_BE_AFE_PCM_RX1; 5.4 keeps msm_tdm_be_dai_links behind qcom,tdm-audio-intf
  (unset on the phone). Harmless as long as the msm-dai-q6-tdm cpu dais exist in the DT; else
  drop them (redwood dropped AUXPCM the same way) or the card will defer.
- QUIN_MI2S_RX/TX: 5.4 a52s codec = `tas256x.18-004c` / `tas256x ASI1`, `.init =
  lahaina_tas256x_init` (register_tas25xx_bigdata_cb); 6.12 = msm-stub-codec.1. Port.
- msm_wcn_be_dai_links (SLIMBUS_7_RX/TX, codec btfmslim_slave): present on the phone (wcn-bt=1);
  `#if 0` + commented property read in 6.12 -> BT SCO/A2DP backend missing. Restore.
- stream_name of CDC DMA BEs changed ("RX CDC DMA0 Playback" -> "LPASS_BE_RX_CDC_DMA_RX_0"),
  no userspace impact.
- 6.12 lost `.no_pcm = 1` (+dpcm_playback/capture) on RX_CDC_DMA_RX_1/2/3/5/6 (and
  WSA_CDC_DMA_RX_1/TX_1, unused here): they would be created as extra PCM devices 70-74. Restore
  `.no_pcm = 1`.
- CONFIG_AUXPCM_DISABLE must stay defined (phone DT has auxpcm-audio-intf = 1 but 5.4 a52s
  compiles the links out).
- ext_disp: 5.4 under CONFIG_AUDIO_QGKI, phone DT value 0 -> not added in either.
