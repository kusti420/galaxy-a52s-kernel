# stm_ts.ko out-merged: ONE build with the charger (VBUS) hook AND lp_dump_inf

2026-11-25. sha256 57ea5f7b... (`SHA256SUMS`), stripped; the .ko is not tracked. Not on a phone yet.

- This is the current `drivers612/touch/src` tree (`./build.sh`, default VBUS=1) = commits 662d737 (VBUS noise-mode
  hook, late `symbol_get` of `a52sxq_vbus_notifier_register`), c0b975e (sec_input gesture key, in sec_common_fn.ko)
  and 071fe75 (`lp_dump_inf` parameter, `src/stm/stm_fn.c`). The SPEC/06 build of 11-24 19:32 already came from this
  tree: it overwrote `out-flavor/stm_ts.ko` (was f4a2c6a1 = the module shipped in rb107b..rb110) with these same
  bytes; rebuilt here from scratch-clean objects, same sha.
- Contents checked in the binary: `parm=lp_dump_inf` + `parm=defer_first_probe`, `stm_ts_vbus_notification`,
  `a52sxq_vbus_notifier_register/unregister` strings; depends line unchanged.
- ABI vs the shipped f4a2c6a1 (s99off `a52/mods/touch/10-stm_ts.ko`): vermagic, `__kcrctab*`, `__versions`,
  `__ksymtab_strings` identical; `.modinfo` differs only by the new parameter. The 7 other touch modules rebuilt
  byte-identical to s99off (sec_common_fn 9b5fa978, sec_cmd ec5b075c, sec_input_notifier 5ea66f50, sec_tclm_v2,
  sec_tsp_log, sec_tsp_dumpkey, sec_secure_touch): swap stm_ts.ko only.
- BEHAVIOUR CHANGE with the default: `lp_dump_inf=0` = legacy LP dump ring, no DUMPFLUSH wake IRQs (IchthysOS /
  LineageOS 5.4). Stock One UI behaviour needs `stm_ts.lp_dump_inf=1` (modules.options line or
  `/sys/module/stm_ts/parameters/lp_dump_inf`, read at the next LPM entry).
- Swap on any REF: `python3 -I drivers612/realboot/tools/rd-swap-ko.py <REF>-rd.cpio.gz <NEW>-rd.cpio.gz
  drivers612/touch/out-merged/stm_ts.ko` (1 entry, `a52/mods/touch/10-stm_ts.ko`).
- Phone check: `cat /sys/module/stm_ts/parameters/lp_dump_inf` = N; no "no a52sxq_vbus_notifier_register after"
  line in dmesg (hook bound; a `stm_ts_vbus_notification` line appears on a cable plug/unplug); touch input device
  present (`getevent -lp` lists sec_touchscreen with ABS_MT_POSITION_X/Y, ABS_MT_TRACKING_ID); screen off/on once
  (LPM entry runs the new branch) with no stm_ts error line.
