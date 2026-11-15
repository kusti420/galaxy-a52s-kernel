# Samsung hunks to carry into the 6.12 machine driver / platform (line refs = Samsung 5.4 tree,
# `$ANDROID_TREE/kernel/samsung/sm7325/techpack/audio`)

Ready patches (p1 against the 6.12 audio-kernel root, made from `donors/audio-kernel`):
- `patches/0001-dsp-q6afe-TAS25xx-smart-amp-algo-hooks.patch` — compile-checked (q6afe.o, exports present).
- `patches/0002-asoc-lahaina-TAS256x-on-QUIN-MI2S.patch` — NOT compile-checked (written against the donor
  text; uses `snd_soc_rtd_to_codec(rtd, 0)` instead of 5.4's `rtd->codec_dai`; declares
  `register_tas25xx_bigdata_cb()` inline instead of including the out-of-tree header).
Both need in `config/lahainaauto.conf` / `lahainaautoconf.h`:
`CONFIG_SND_SOC_TAS256x`, `CONFIG_TAS25XX_ALGO` (and for parity with lahaina_a52s.conf:
`CONFIG_AUXPCM_DISABLE`, WSA_MACRO/WCD937X/WSA883X/SWR_HAPTICS off).
machine_dlkm then imports `register_tas25xx_bigdata_cb` from tas256x_dlkm (as on 5.4): add
`samsung/tas256x/Module.symvers` to its KBUILD_EXTRA_SYMBOLS.
Load order: sec_audio_sysfs -> q6_dlkm (patched) -> tas256x_dlkm -> machine_dlkm.

## asoc/lahaina.c
| 5.4 lines | Hunk | Carry? |
|---|---|---|
| 44-52 | includes: `sec_wcd_sysfs_cb.h`, `codecs/tas256x/bigdata_tas_sysfs_cb.h` | yes (0002 covers TAS) |
| 1142 | `wcd_mbhc_cfg.mbhc_spl_headset = false` (Samsung value; check donor default) | yes |
| 7047-7056 | `lahaina_tas256x_init()` -> `register_tas25xx_bigdata_cb()` | 0002 |
| 7100-7155 | `def_wcd_mbhc_cal()`: defaults btn_high = 75,150,237,500,500,500,500,500, then overridden per button from the `mbhc-button-thres` phandle list of the wcd938x codec node (`component->dev->of_node`, i.e. `bolero-cdc/wcd938x-codec`) (`#list-det-cells = <2>` on `det_zones`; cell 0 normal, cell 1 factory). a52sxq r02 values: <&det_zones 13 63>, <.. 88 138>, <.. 138 138>, <.. 225 225>, <.. 450 450>, <.. 450 620> x3 -> btn_high = 13, 88, 138, 225, 450, 450, 450, 450 | yes (jack buttons wrong otherwise); donor signature is `def_wcd_mbhc_cal(void)`; change it to take the codec component as on 5.4 (5.4 line 8993) |
| 7484-7505 | hw:x,24 is `MultiMedia11` PCM playback (platform `msm-pcm-dsp.0`, id MSM_FRONTEND_DAI_MULTIMEDIA11) instead of Qualcomm's `Compress4`; with `msm_dailink.h:135-142` and `msm-dai-fe.c:2417` (no `.compress_new` for MultiMedia11) — CONFIG_SEC_SND_PRIMARY | yes: changes device 24 from compress to PCM; HAL's audio_platform_info pcm ids depend on it |
| 7795-7804 | hw:x,46 "Audio ADAPTATION Hostless" (cpu snd-soc-dummy-dai, platform `q6audio-adaptation`, no_pcm) appended to msm_common_misc_fe_dai_links; `msm_dailink.h:1220-1225` | only together with sec_audio_adaptation (platform must exist or the card defers forever) |
| 8285-8287 | `.init = &lahaina_tas256x_init` on LPASS_BE_QUIN_MI2S_RX | 0002 |
| 9007-9009 | `register_mbhc_jack_cb(component)` at the end of `msm_snd_card_codec_late_probe`/mbhc init (after wcd938x/937x_mbhc_hs_detect) | yes, with sec_wcd_sysfs_cb.c in MACHINE_OBJS (`asoc/Kbuild:206-209`) |
| 547-672 | `sec_tdm_dev_config`, SEC/QUIN TDM tables — vintage/Qualcomm, plus Cirrus-only parts | no (a52sxq amp is on MI2S, not TDM) |
| 1038, 6897, 8005-8057 | CONFIG_SEC_SND_HYBRID_CIRRUS_AMP_QUIN_TDM / CIRRUS | no |

## asoc/msm_dailink.h
- 1002-1011 quin_mi2s_rx/tx codec = `tas256x.18-004c` / `tas256x ASI1` (0002).
- 135-142 multimedia11 platform (above). 1220-1225 q6audio_adaptation link defs.

## Adaptation layer (only if sec_audio_adaptation is ported)
`asoc/Kbuild:260-263` (PLATFORM_OBJS += sec_audio_adaptation.o sec_voice_adaptation.o), `dsp/Kbuild:183-185`
(Q6_OBJS += q6voice_adaptation.o), `asoc/platform_init.c:30-41` + `platform_init.h`, `dsp/q6_init.c:28-40` + `.h`,
`dsp/q6asm.c:183-189`, `dsp/q6adm.c:24-26, 3517-3527`, `dsp/q6voice.c:29-31, 163-168, 7136-7138, 7605-7607`
+ `include/dsp/q6voice.h`, `dsp/q6afe.c:33-35, 306-, 1074-, 1239-1243, 8328-` + `include/dsp/q6afe-v2.h`,
`asoc/msm-pcm-routing-v2.c:32687-32808` + `.h`, `asoc/msm-pcm-voice-v2.c:24, 770`, `include/dsp/q6asm-v2.h`.

## Jack / MBHC
`include/asoc/wcd-mbhc-v2.h:629-640`, `asoc/codecs/wcd-mbhc-v2.c` (31-36, 736, 1853, 1921-1930),
`wcd-mbhc-adc.c` (26-40, 613-717, 777-860): CONFIG_SND_SOC_WCD_MBHC_SLOW_DET + IMPED_SENSING.
Impedance gain offset: `wcd938x-mbhc.c:513,594`, `wcd938x.c:4156,4201`, `bolero/rx-macro.c:411,769,852-,1652,3234`,
`bolero/bolero-cdc.c:259`. Not ported; detection works without them (stock Qualcomm MBHC), slow-insert
robustness and impedance-based gain are lost until carried.
Sound-node DT props used by MBHC on the phone: `qcom,msm-mbhc-hphl-swh = <1>`, `qcom,msm-mbhc-gnd-swh = <1>`,
`qcom,msm-mbhc-hs-mic-max-threshold-mv = <9999>`, `-min- = <640>`, `qcom,msm-mbhc-gnd-det = <1>`; `mbhc-button-thres` sits in the wcd938x-codec node, next to Samsung's `imp_list` (impedance table) under bolero-cdc.
