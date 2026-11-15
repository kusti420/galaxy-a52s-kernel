# TAS256x (TI TAS2562/TAS2564 smart amp) — 5.4 Samsung techpack -> 6.12

Source: `$ANDROID_TREE/kernel/samsung/sm7325/techpack/audio/asoc/codecs/tas256x` (copied whole),
plus `techpack/audio/include/dsp/tas_qualcomm.h` -> `include/dsp/`.
Module name as on 5.4: `tas256x_dlkm.ko`. Config = `techpack/audio/config/lahaina_a52s.conf`
(TAS256X_REGMAP, TAS256X_CODEC, TAS256X_MISC, TAS25XX_ALGO, TAS25XX_CALIB_VAL_BIG, PLATFORM_QCOM),
passed as -D in `Kbuild`. Build: `../build.sh` (sec_audio first, then this).

## Changes to Samsung's code (full diff: ../patches/tas256x-5.4-to-6.12.diff)
1. `os_layer/src/tas256x-regmap.c`: `tas256x_i2c_probe(client, id)` -> `(client)` (6.3+ i2c probe
   signature; `id` was unused). `tas256x_i2c_remove()` returns void (6.1+).
2. `os_layer/src/tas256x-codec.c`: `.symmetric_rates` -> `.symmetric_rate` (5.13 rename).
3. `algo/src/tas25xx-calib-validation.c`: `class_create(THIS_MODULE, name)` -> `class_create(name)` (6.4).
4. `physical_layer/inc/tas256x-device.h`: `<stdbool.h>` -> `<linux/types.h>` (no libc headers in 6.12 kbuild).
5. `Kbuild` rewritten (old one included techpack conf files); 5.4 `Makefile` dropped.
Nothing else needed: the driver already used the snd_soc_component API, `mute_stream`,
`devm_snd_soc_register_component`, 3-argument `of_get_named_gpio`.

## Result
`tas256x_dlkm.ko` builds with no warnings. modpost: 4 undefined symbols, all Samsung additions
to `dsp/q6afe.c` (q6_dlkm) that the 6.12 donor lacks:
`afe_tas_smartamp_init`, `afe_tas_smartamp_get_calib_data`, `afe_tas_smartamp_set_calib_data`,
`register_tas256x_reset_func`.
Fix: `../patches/0001-dsp-q6afe-TAS25xx-smart-amp-algo-hooks.patch` (p1 against the 6.12
audio-kernel root; also adds `include/dsp/tas_qualcomm.h`). The patched q6afe.c was compiled
against bsp612 with `-DCONFIG_TAS25XX_ALGO=1` (object only) and exports all four. The audio
techpack build must define `CONFIG_TAS25XX_ALGO` (add `export CONFIG_TAS25XX_ALGO=m` to
lahainaauto.conf and `#define CONFIG_TAS25XX_ALGO 1` to lahainaautoconf.h). Then rebuild
tas256x with the q6 Module.symvers in KBUILD_EXTRA_SYMBOLS (build.sh picks up
`../audio-kernel/Module.symvers` and `../audio-kernel/dsp/Module.symvers` if present).
Differences from Samsung's q6afe hunk: statics made static, a NULL check before the DC-detect
reset callback, one pr_err format fixed (missing __func__, -Werror=format). Samsung's bug kept:
`afe_tas_smartamp_get_calib_data` tests `tas_module_rx` twice, so a TX-module get returns -EINVAL.
Other dependency: `sec_audio_sysfs.ko` must be loaded first: `register_tas25xx_bigdata_cb()`
(bigdata_tas_sysfs_cb.c, part of tas256x_dlkm) calls its `audio_register_*_cb` exports.

## Userspace/ASoC contract kept
- Component name `tas256x.18-004c` (driver name "tas256x" + i2c dev name): REQUIRES the I2C
  adapter to be bus 18 (`aliases { i2c18 = &qupv3_se1_i2c; }`, i2c@984000) or the dai link
  codec name must change. DAI `tas256x ASI1`.
- Misc devices `/dev/tas256x` (tas256x-misc.c) and `/dev/tas_calib` (tas25xx-calib.c), class
  `/sys/class/tas25xx/{calib,valid,bigdata}/*` (calibration, cstatus, rdc, temp, *_r, validation,
  status, exc_max, temp_max, ...). `libspeakercalibration.so` uses the sysfs + `/efs/tas25xx/*`.
- Mixer controls (no name prefix): `TAS25XX_ALGO_DIGITAL_GAIN_A/B`, `TAS256X IVSENSE ENABLE`,
  `SmartPA System Mute`, `SmartPA Mute`, `TAS256X DAC Mute`, `TAS256X ICN Switch`,
  `TAS256X_RX_SLOT_MAP`, DAPM `TAS256X ASI Left/Right Switch`, `TAS256X ASI1 SEL LEFT/RIGHT`
  (stereo, ti,channels = 2), plus the TAS25XX_ALGO_* controls in algo/src/tas25xx-algo-common.c.

## Not verifiable offline
- Regmap/IRQ behaviour on the real chips (0x4c right, 0x4d left; the driver creates the second
  address itself from `ti,left-channel`, one DT node only).
- AFE module ids 0x1000fc00 (rx) / 0x1000fd00 (tx) on port 0x1016 (QUIN MI2S RX) need the
  phone's ADSP image with TI's CAPI module; calibration get/set over APR untested.
- `/dev/tas256x`, `/dev/tas_calib` minors are dynamic (were 107, 84 on 5.4); blobs do not open them.
