# log_buf_len=1M and qcom-dload-mode on the OneUI 9 builds (2026-11-22, offline read; nothing built or run)

## 1. log_buf_len=1M
- 5.4: `CONFIG_LOG_BUF_SHIFT=20` (kernel_a52sxq_bone a52sxq_kor_single_defconfig:127) = 1 MiB; the stock vendor cmdline has
  no `log_buf_len=` (drivers612/realboot/out/rbou5d/work/stock-vendor-cmdline.txt). 6.12 GKI: `CONFIG_LOG_BUF_SHIFT=17`
  (bsp612/out/lahaina/.config:172) = 128 KiB, a GKI config we do not change. So the word is the only way to parity.
- Where the cmdline is built: build-realboot.sh :1108 writes the vendor cmdline `$VC`; :1109 REFUSES a build whose vendor
  cmdline or Qualcomm DT bootargs contain `log_buf_len=` ("test-only argument"). The DT bootargs are
  `$QCOM_BOOTARGS + $DIAG_BOOTARGS` (:1007); DIAG_BOOTARGS is not covered by the :1109 check.
- Works TODAY without a script edit (the rbou line already has DIAG=1 DIAG_BOOTARGS=none):
  `DIAG=1 DIAG_BOOTARGS="log_buf_len=1M"` -> the word lands in /chosen/bootargs, which the Samsung ABL keeps in front of
  the vendor cmdline. Same route as rb79/rb99m with 8M, proven on real boots.
- Proposal for the user of build-realboot.sh: a named option `LOGBUF=1M` that appends `log_buf_len=$LOGBUF` to `$VC`
  and exempts exactly that word from the :1109 check; default for OneUI dumps = 1M. Cost: 1 MiB of RAM, allocated
  early by memblock. cmdline length: +15 bytes (predicted length must stay below the 4096 limit, REPORT section 2).
- Verify on the phone: `dmesg | grep 'log_buf_len'` prints "printk: log_buf_len: 1048576 bytes"; a dmesg taken 3 min
  after boot still starts at 0.000000 (today the ring wraps in ~35 s under OneUI).
- This does not make anything survive a reset: that is pstore (ramoops@F0B00000 console-size 0x40000 in our tree).

## 2. qcom-dload-mode: what it is
6.12 module (bsp612/soc-repo/drivers/power/reset/qcom-dload-mode.c, `CONFIG_POWER_RESET_QCOM_DOWNLOAD_MODE=m`,
`..._DEFAULT=y`, .config:9081-9082):
- binds only to a DT node `compatible = "qcom,dload-mode"` (:474).
- probe (:402-452): `/sys/kernel/dload/*`, then `msm_enable_dump_mode(enable_dump)`; with DEFAULT=y enable_dump = 1, so the
  TCSR download-mode cookie is set to FULL DUMP from probe on, for the whole uptime.
- panic notifier (:347-356): sets the cookie again. Reboot notifier (:358-383): a CLEAN reboot clears it (NODUMP);
  `reboot edl` sets EDL; with the cookie set it forces a warm reset.
- Net effect: any reset that is not a clean reboot (panic, watchdog bite, hypervisor reset, thermal/PMIC reset that keeps
  TCSR) reaches the boot chain with "full RAM dump" requested.
- module param `download_mode` (:127) = enable_dump; 0 = cookie off + `qcom_scm_disable_sdi()`.

## 3. What the two kernels do today
- 5.4 bone (the ROM's 5.4): `POWER_RESET_QCOM_DOWNLOAD_MODE=y`, `_DEFAULT=y` (defconfig:2822-2823), node `dload_mode`
  (yupik.dtsi:3016). drivers/power/reset/msm-poweroff.c:60 `download_mode = 1`, :571 `set_dload_mode(download_mode)` at
  probe = cookie armed; :413 on restart it stays set only for a panic or `reboot dload`, a clean restart clears it; :520
  power-off clears it. `CONFIG_SEC_DEBUG` is NOT set in that defconfig (:6115), so the cmdline words the ABL passes
  (`sec_debug.enable=0 sec_debug.enable_user=0 androidboot.debug_level=0x4f4c androidboot.force_upload=0x0`,
  drivers612/realboot/out/rbou5d/cmdline-predicted.txt) have no reader in the bone kernel: bone 5.4 runs with the QC cookie
  ARMED.
- Stock Samsung 5.4 (SEC_DEBUG=y) for comparison: drivers/samsung/debug/sec_debug.c:105-125 the QC cookie follows the
  Samsung upload magic; :140-142 and :187-191 every normal reboot writes `set_dload_mode(0)` + RESTART_REASON_NORMAL; :542/
  :556 (peripheral-check paths) clear it when sec_debug is not enabled. With `sec_debug.enable=0` (debug level LOW = 0x4f4c, what this
  phone passes) a user device has the cookie OFF and a panic is a plain reboot.
- 6.12 today: the module is blocklisted (build-realboot.sh:654) AND could not bind: our board tree has no
  `qcom,dload-mode` node (checked in rbou5d/vendor_boot.dtb; only the `qcom,dload-mode = <&tcsr 0x13000>` address property
  of qcom_scm is there). Upstream qcom_scm owns the cookie: qcom_scm.c:36 `download_mode` = 0, :2028 writes it at probe
  (= clears whatever the ABL left), :2033 disables SDI, :2087 clears again at shutdown. So 6.12 = cookie OFF from
  qcom_scm probe on = the stock-Samsung user-device behaviour, and a panic reboots through panic_timeout.

## 4. Is loading it safe? Recommendation
- Do NOT load qcom-dload-mode on the OneUI (or any user) build, and do not add the DT node. With DEFAULT=y it would arm
  a full RAM dump for every unclean reset. What this Samsung boot chain does with an armed cookie at debug level LOW
  is UNVERIFIED on 6.12 (XBL has "Warm Reset by Kernel Panic / Watchdog Bite" and "not allow normal booting with
  warm_reset status!!!" strings, FIRMWARE-KERNEL-ASSUMPTIONS.md:105-111); the bad outcome is an upload/download screen
  that needs the keys, on the user's daily phone, after a crash he did not cause. Nothing on this ROM consumes a RAM
  dump (no SEC_DEBUG, no minidump: FIRMWARE-KERNEL-ASSUMPTIONS.md:26).
- "As 5.4" would mean bone's armed cookie. That is bone's accident (SEC_DEBUG off removed Samsung's disarm), not a
  feature to copy. Observed on bone 5.4 with an armed cookie: no record of what a 5.4 panic does on these
  phones (UNVERIFIED; worth one look in the 5.4 ROM session: `cat /sys/module/msm_poweroff/parameters/download_mode`
  and whether a 5.4 panic ever ended on an upload screen).
- If the 5.4 behaviour is ever wanted for a test, no module is needed: `qcom_scm.download_mode=full` (modules.options
  line `options qcom_scm download_mode=full`, or runtime `echo full > /sys/module/qcom_scm/parameters/download_mode`,
  `echo off` to undo before any reboot). Test phone only, someone at the phone.
- Keep as is: blocklist entry stays; add to the sweep (read-only): `/sys/module/qcom_scm/parameters/download_mode` = `off`.
- Interaction with WDT=1 (WDT-ONEUI.md): a watchdog bite with the cookie off is the case already seen to boot normally
  on bit 2 (rb56); with the cookie armed it is the unknown case. One more reason to keep the cookie off.
