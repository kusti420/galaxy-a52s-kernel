# Samsung's changes in the A52s 5.4 audio stack vs the 6.12 legacy audio-kernel donor

Compared: `$ANDROID_TREE/kernel/samsung/sm7325/techpack/audio` (+ `sound/soc/samsung/sec_audio_sysfs.c`,
`include/sound/samsung/`) against `donors/audio-kernel` (audio-kernel-legacy.lnx.6.12.r1-rel).
No Qualcomm 5.4 baseline of the same vintage is on disk, so Samsung's changes were isolated by
their markers (CONFIG_SEC_*, CONFIG_SND_SOC_TAS256x, CONFIG_TAS25XX_*, CONFIG_SND_SOC_IMPED_SENSING,
CONFIG_SND_SOC_WCD_MBHC_SLOW_DET, files that exist only on the Samsung side). A raw
`diff lahaina.c` is 2529 changed lines, mostly vintage drift (TDM/pr_info), not Samsung.

## What a52sxq enables
`techpack/audio/Makefile`: `CONFIG_SEC_A52SXQ_PROJECT=y` -> `config/lahaina_a52s.conf` + `lahaina_a52s.h`
(instead of lahainaauto.conf). Versus Qualcomm's lahainaauto.conf it:
- turns OFF: WSA_MACRO, WCD937X(+SLAVE), WSA883X, SND_SWR_HAPTICS
- turns ON: `CONFIG_AUXPCM_DISABLE`, `CONFIG_SEC_SND_PRIMARY` (header only), `CONFIG_SEC_SND_ADAPTATION`,
  `CONFIG_PLATFORM_QCOM`, `CONFIG_SND_SOC_TAS256x`, `CONFIG_TAS256X_{REGMAP,CODEC,MISC}`,
  `CONFIG_TAS25XX_ALGO`, `CONFIG_TAS25XX_CALIB_VAL_BIG`, `CONFIG_SND_SOC_WCD_MBHC_SLOW_DET`,
  `CONFIG_SND_SOC_IMPED_SENSING` (the last two in the .h only)
- defconfig (`lineage-a52sxq_defconfig`): `CONFIG_SND_SOC_SAMSUNG_AUDIO=m` (sec_audio_sysfs.ko).
NOT enabled for a52sxq (ignore): tfa9878, Cirrus cs35l41/45 (+ `bigdata_cirrus_sysfs_cb.h`),
`CONFIG_SEC_SND_HYBRID_CIRRUS_AMP_QUIN_TDM`, `CONFIG_SEC_SND_USB_HEADSET_ONLY`, `CONFIG_SEC_FACTORY`.

## Samsung-only files
| File | What | a52sxq needs | State here |
|---|---|---|---|
| `asoc/codecs/tas256x/**` (12k lines) | TI TAS2562/2564 smart amp: i2c/regmap, codec, misc dev, TI smart-amp algo controls + calibration/validation/bigdata sysfs | YES (speaker + earpiece amps) | ported, `tas256x/` -> `tas256x_dlkm.ko` |
| `include/dsp/tas_qualcomm.h` + hunks in `dsp/q6afe.c` | AFE get/set param for TI's CAPI module, DC-detect reset callback | YES (tas256x links against it) | `patches/0001-dsp-q6afe-...patch`, compile-checked |
| `sound/soc/samsung/sec_audio_sysfs.c`, `include/sound/samsung/sec_audio_sysfs.h` | class `audio`: earjack / codec / amp sysfs with callback registration | YES (closed thermal HAL reads `/sys/class/audio/amp/curr_temperature_1`; init scripts, factory) | ported, `sec_audio/` -> `sec_audio_sysfs.ko`, no unresolved symbols |
| `asoc/sec_wcd_sysfs_cb.[ch]` (114 lines, in machine_dlkm) | feeds earjack sysfs from wcd938x MBHC (`hph_status`, `buttons_pressed`, `zl`, `zr`) | YES for `/sys/class/audio/earjack/*` content | NOT ported (trivial; add to MACHINE_OBJS; uses wcd938x internal.h/wcd938x-mbhc.h, check struct names on 6.12) |
| `asoc/sec_audio_adaptation.c` (1472), `asoc/sec_voice_adaptation.[ch]` (293), `dsp/q6voice_adaptation.c` (1586), `include/asoc/sec_audio_adaptation.h`, `include/dsp/q6voice_adaptation.h` | ASoC platform `q6audio-adaptation` (compatible `samsung,q6audio-adaptation`, driver `samsung-q6audio-adaptation`): Samsung SoundAlive/SoundBooster/DHA/volume-monitor/voice params sent to ADSP via ASM/ADM/AFE/CVP. Registers mixer controls the HAL sets (below) and PCM device 46 "Audio ADAPTATION Hostless" | YES if the Samsung HAL sets these controls (mixer_paths / HAL strings; parent's task 3 decides). Missing controls make HAL `mixer_ctl_get` fail; most are effect params, not routing | NOT ported (needs hooks in q6asm/q6adm/q6afe/q6voice/msm-pcm-routing/msm-pcm-voice, listed in lahaina-samsung.patch-notes.md) |
| `asoc/msm-transcode-loopback-q6-v2.c`, `msm-dolby-common.h`, `msm-ds2-dap-config.h`, `dsp/usf.h`, `include/uapi/audio/**` | 5.4-vintage Qualcomm files dropped/moved in the 6.12 legacy tree (not Samsung) | transcode loopback: only if a PCM/compress index depends on it (parent's dai-link table check) | not ported |
| `config/lahaina_{a52s,a73,m52,...}.{conf,h}`, `arauto*` | per-project config | a52s one | settings listed above; add to 6.12 lahainaauto.conf/.h |

Controls registered by sec_audio_adaptation.c / sec_voice_adaptation.c (names frozen for the HAL):
`SA data`, `SA LISTENBACK RX volume`, `SA LISTENBACK RX data`, `VSP data`, `Audio DHA data`, `LRSM data`,
`VoiceTrackInfo`, `MSP data`, `SB enable`, `UPSCALER`, `SB rotation`, `SB flatmotion`, `DA data`,
`SB RX Volume`, `SB FM RX Volume`, `Remote Mic Vol Index`, `VM Energy`, `VM data`, `Listenback Enable`,
`Sec Set DHA data`, `NB Mode`, `Receiver Sensor Mode`, `Speaker Sensor Mode`, `BT SCO Rx Volume`,
`Loopback Enable`, `Voice Device Info`, `Echo Ref Mute`, `REF LCH MUTE`, `DSP AEC Effect`, `Voice Isolation Mode`.
DT: `samsung,q6audio-adaptation { adaptation,headset-rx-port-id=<0xb030>; bt-rx-port-id=<0x400e>;
usb-rx-port-id=<0x7000>; spk-rx-port-id=<0x1016>; device-tx-port-id=<0xb037>; }`.

## Sysfs / device nodes created (must stay)
- `/sys/class/audio/earjack/{select_jack,state,key_state,mic_adc,headset_state,l_impedance,r_impedance,force_enable_antenna,antenna_state}`
- `/sys/class/audio/codec/check_codec_id`
- `/sys/class/audio/amp/{temperature_max,temperature_keep_max,temperature_overcount,excursion_max,excursion_overcount,curr_temperature,surface_temperature}_{0,1}`
  (`audio,num-amp = <2>` trims AMP_2/3). DT node: `sec-audio-sysfs { compatible = "samsung,audio-sysfs"; audio,num-amp = <2>; }`.
  Values come from callbacks: tas256x bigdata (temperature_max/keep_max/overcount, excursion_max/overcount;
  curr_temperature and surface_temperature callbacks are not registered by the TAS code) and sec_wcd_sysfs_cb (jack).
- `/sys/class/tas25xx/{calib,valid,bigdata}/*`, `/dev/tas256x`, `/dev/tas_calib` (see tas256x/PORTING-NOTES.md).
- No switch/extcon/uevent of Samsung's own for the jack: detection is stock wcd-mbhc (SND_JACK input events).

## Samsung changes inside Qualcomm files (a52sxq-relevant)
- `asoc/lahaina.c`, `asoc/msm_dailink.h`: see lahaina-samsung.patch-notes.md.
- `asoc/codecs/wcd-mbhc-v2.c`, `wcd-mbhc-adc.c`, `include/asoc/wcd-mbhc-v2.h`: `CONFIG_SND_SOC_WCD_MBHC_SLOW_DET`
  (slow-insertion re-detection, extra delays/retries) and `CONFIG_SND_SOC_IMPED_SENSING` (impedance fields).
- `asoc/codecs/wcd938x/wcd938x-mbhc.c` (513, 594), `wcd938x.c` (4156, 4201), `bolero/rx-macro.c`
  (411, 769, 852 `sec_wcd_imp_offset`, 1652, 3234), `bolero/bolero-cdc.c` (259): Samsung headphone-impedance
  gain offset table (`CONFIG_SND_SOC_IMPED_SENSING`); controls/tables to diff in task 3.
- `dsp/q6afe.c`: TAS hunks (ported as patch) + CONFIG_SEC_SND_ADAPTATION volume monitor
  (`AFE_MODULE_PARAM_ID_GET_VOLUME_MONITOR`, lines 1074, 1239, 8328).
- `dsp/q6asm.c:183` `q6asm_get_audio_session()`, `dsp/q6adm.c:3517` (Samsung voice TX topologies),
  `dsp/q6voice.c` 163/7136/7605, `dsp/q6_init.[ch]`, `asoc/platform_init.[ch]` (`sec_soc_audio_platform_init`),
  `asoc/msm-pcm-routing-v2.c:32687-32808` (`q6audio_determine_curr_copp_idx` etc.),
  `asoc/msm-pcm-voice-v2.c` 24/770, `asoc/msm-dai-fe.c:2417` (CONFIG_SEC_SND_PRIMARY): all part of the
  adaptation layer.

## TAS256x hookup on 5.4 (facts)
- Backend dai link `LPASS_BE_QUIN_MI2S_RX` ("Quinary MI2S Playback", id MSM_BACKEND_DAI_QUINARY_MI2S_RX)
  and `LPASS_BE_QUIN_MI2S_TX`: cpu `msm-dai-q6-mi2s.8` / `.9`, codec `tas256x.18-004c`, dai `tas256x ASI1`,
  platform `msm-pcm-routing`; RX link `.init = lahaina_tas256x_init` -> `register_tas25xx_bigdata_cb(component)`.
  No name_prefix, no aux dev, no DT phandle from the sound node (name-matched).
- AFE port 0x1016 = AFE_PORT_ID_QUINARY_MI2S_RX (TX = 0x1017 for IV sense); TI modules rx 0x1000fc00, tx 0x1000fd00.
- DT (identical in r01 and r02 dts sources; r00 differs), under `qupv3_se1_i2c` = i2c@984000, alias `i2c18`,
  1 MHz (`qcom,clk-freq-out = <1000000>`):
  `tas256x@4c { compatible = "ti, tas256x"; reg = <0x4c>; ti,reset-gpio = <&tlmm 63 0>; ti,irq-gpio = <&tlmm 55 0>;
  ti,left-channel = <0x4d>; ti,right-channel = <0x4c>; ti,channels = <2>; ti,iv-width = <8>; ti,vbat-mon = <1>;
  ti,port_id = <0x1016>; ti,module_id_rx = <0x1000fc00>; ti,module_id_tx = <0x1000fd00>;
  pinctrl-0 = <&tas25xx_gpio_default>; #sound-dai-cells = <0>; }` (note the space in the compatible).
  `tas25xx_gpio_default`: tlmm gpio55 + gpio63, function gpio, bias-disable. No regulator in the node
  (amp supplies are always-on rails). The quinary MI2S pins/clock belong to the `msm-dai-q6-mi2s` quin node.
