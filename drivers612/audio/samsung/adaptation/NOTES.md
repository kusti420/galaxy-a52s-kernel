# Samsung CONFIG_SEC_SND_ADAPTATION on the 6.12 legacy techpack

Patch: `0003-sec-snd-adaptation.patch` (`patch -p1` in the audio-kernel root; made as
`diff -urN a b`, where `a/` = the techpack snapshot of 2026-11-11 20:51 with 0001/0002 applied).
Work tree: `b/`. Build: `./build-b.sh -k` -> 30 modules, 0 compile errors, 0 modpost errors
(log `build-b.log`; `register_tas25xx_bigdata_cb` resolves from `../tas256x/Module.symvers`).
`port.py` is the script that carried the #ifdef blocks (anchor = preceding line of the 5.4 file).
Nothing was run on hardware.

## Ported (source: $ANDROID_TREE/kernel/samsung/sm7325/techpack/audio)
New files, same module as on 5.4:
- `asoc/sec_audio_adaptation.c` -> platform_dlkm. Platform driver `samsung,q6audio-adaptation`,
  component with 19 controls: SA data, VSP data, Audio DHA data, LRSM data, MSP data, UPSCALER,
  SB enable, SB rotation, SB flatmotion, SB RX Volume, SB FM RX Volume, SA LISTENBACK RX data,
  SA LISTENBACK RX volume, Remote Mic Vol Index, VoiceTrackInfo, VM Energy, VM data,
  Listenback Enable, DA data (names untouched).
- `asoc/sec_voice_adaptation.[ch]` -> platform_dlkm. 11 controls added to the msm-pcm-voice
  component: Sec Set DHA data, NB Mode, Receiver Sensor Mode, Speaker Sensor Mode, Loopback
  Enable, Voice Device Info, REF LCH MUTE, Echo Ref Mute, DSP AEC Effect, Voice Isolation Mode,
  BT SCO Rx Volume (names untouched).
- `dsp/q6voice_adaptation.c` -> q6_dlkm (CVS/CVP APR clients, exported `sec_voice_*`).
- `include/asoc/sec_audio_adaptation.h`, `include/dsp/q6voice_adaptation.h`.
Hunks (all under `#ifdef CONFIG_SEC_SND_ADAPTATION`, unchanged text):
- `dsp/q6afe.c`: include, `volume_monitor_data` in `struct afe_ctl`, `volumemonitor_afe_cb_handler`,
  its branch in `afe_callback`, `afe_set_volume_monitor`/`afe_get_volume_monitor` (+ the other
  functions of that 175-line block after `afe_loopback_gain`).
- `dsp/q6adm.c`: include, 16 kHz rate for the Samsung voice TX topologies in `adm_open`.
- `dsp/q6asm.c` + `include/dsp/q6asm-v2.h`: `q6asm_get_audio_session()`.
- `dsp/q6voice.c` + `include/dsp/q6voice.h`: `voice_get_common_data()`, loopback start/end
  calls in `voice_start_voice`/`voice_end_voice` paths.
- `dsp/q6_init.[ch]`: `voice_adaptation_init/exit`.
- `asoc/platform_init.[ch]`: `sec_soc_audio_platform_init/exit`.
- `asoc/msm-pcm-routing-v2.[ch]`: `q6audio_get_copp_idx_from_port_id()` (one block, placed
  just before `msm_soc_routing_platform_init`; nothing else in that file is touched).
- `asoc/msm-pcm-voice-v2.c`: include + `sec_voice_adaptation_add_controls(component)` in probe.
- `asoc/lahaina.c`: "Audio ADAPTATION Hostless" appended to `msm_common_misc_fe_dai_links`
  (index 46, `no_pcm`), `asoc/msm_dailink.h`: `q6audio_adaptation` DEFS.
- `asoc/Kbuild`, `dsp/Kbuild`: object lists. `config/lahainaauto.conf`, `lahainaautoconf.h`:
  `CONFIG_SEC_SND_ADAPTATION`.
`msm-dai-fe.c` has no SEC_SND_ADAPTATION hunk on 5.4 (nothing to port).

## Changes made for 6.12 (everything else is verbatim)
1. `asoc/sec_multi_ext.h` (new): `SOC_SINGLE_MULTI_EXT` + `snd_soc_info_multi_ext()`. On 5.4
   they are in the kernel (Qualcomm's soc.h/soc-ops.c); GKI 6.12 lacks them and the legacy
   techpack keeps a private copy in each file. The copy from msm-pcm-voice-v2.c is used
   (count kept in `.max`, value maximum in `.platform_max`). Included by both sec files.
2. `sec_audio_adaptation.c`: platform `.remove` returns void; removed the
   `volume_monitor_value == NULL` test on a local array (-Werror,-Wtautological-pointer-compare).
3. `q6voice_adaptation.c`: `sh_mem_block.dma_buf` -> `sh_mem_block.mem_handle` (5 places);
   6.12 renamed the field in `struct mem_map_table` and `msm_audio_ion_free()` takes the handle.
Nothing is stubbed.

## Device tree the card now REQUIRES
`lahaina.c` resolves platform names through `asoc-platform-names`. With this patch the sound
node must carry, as on the phone:
- `asoc-platform = ..., <&samsung_q6audio_adaptation>;` and
  `asoc-platform-names = ..., "q6audio-adaptation";` (14th entry). Without it
  `msm_populate_dai_link_component_of_node` fails and the card does not register.
- node under /soc (values from downstream-dt/a52sxq-r02.dts):
  `samsung_q6audio_adaptation: samsung,q6audio-adaptation { compatible =
  "samsung,q6audio-adaptation"; adaptation,device-tx-port-id = <0xb037>;
  adaptation,spk-rx-port-id = <0x1016>; adaptation,usb-rx-port-id = <0x7000>;
  adaptation,bt-rx-port-id = <0x400e>; adaptation,headset-rx-port-id = <0xb030>; };`

## For hardware to confirm
- The card still registers with link 46 and PCM numbering 0..45 is unchanged (`/proc/asound/pcm`).
- `tinymix` lists the 30 names above; the HAL stops logging missing-control errors.
- The ADSP firmware accepts the Samsung module ids (SoundAlive 0x10001fa0 family, volume
  monitor 0x10001f41, voice CVP/CVS params): same ADSP image as 5.4, so expected, not verified.
- Voice loopback start/end around call setup (`voice_sec_loopback_*`), only testable with a call.
- Merge note: the parent tree is changing routing/pp/rx-macro/lahaina dai-links at the same
  time; this patch touches lahaina.c only at the end of `msm_common_misc_fe_dai_links` and
  routing only before `msm_soc_routing_platform_init`.
