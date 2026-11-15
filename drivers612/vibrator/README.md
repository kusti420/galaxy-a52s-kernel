# drivers612/vibrator — Samsung DC vibration motor on 6.12

The A52s has a coin DC motor switched by TLMM GPIO 62 (`samsung,dc_vibrator`, motor type
COINDC). The 5.4 drivers are Samsung's `sec_vibrator` framework (creates
`/sys/class/timed_output/vibrator/{enable,motor_type,use_sep_index}`, used by
`android.hardware.vibrator-service.samsung`) and `dc_vibrator` (the GPIO motor backend).

- `./port.sh` regenerates `src/` from the read-only 5.4 tree ($ANDROID_TREE/kernel/samsung/sm7325):
  `class_create()` without owner (6.4), void `.remove` (6.11). `./build.sh` builds
  `sec_vibrator.ko` + `dc_vibrator.ko` against bsp612/out/lahaina (no warnings).
- `a52sxq-vibrator.dtsi`: the phone's root node, verbatim (GPIO 62 is unused in the 6.12 base);
  overlay via `vib-overlay.dts`, applied in kexec/mkandroidtree.sh.
- Load order: `sec_vibrator.ko`, `dc_vibrator.ko` (Android test stage `vibrator`, after `power`).
- Verified 2026-11-14 (run ab-s57): probe OK, `cmd vibrator_manager synced -f oneshot 400` ->
  "[VIB] dc_vib_on: gpio on / 400ms / timeout, off". The HAL reports no frequency profile
  ("Invalid frequency profile", same as on a DC motor under 5.4: no resonance data).
