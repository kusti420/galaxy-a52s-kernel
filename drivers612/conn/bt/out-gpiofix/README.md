# btpower.ko out-gpiofix: free only the GPIOs the driver holds

2026-11-25, built offline, not on a phone yet. Stripped module sha256 in `SHA256SUMS` (9966462f...; the .ko is not
tracked). Shipped module (s99off, rb110: `a52/mods/wlanb/btpower.ko`) = 0cc64e4a...

- Bug class: 6.12 `gpiod_free()` does `module_put(gdev->owner)` + `gpio_device_put()` even for a line that is not
  requested (camera fix of 2026-11-24, `drivers612/camera/out-gpiofix`). `bluetooth_power()` freed the BT reset GPIO
  (and the debug GPIO) whenever the number was valid: power 0 after retention (0 -> 2 -> 0), a second power 0, a
  failed `gpio_request` at power on (`gpio_fail` label), a debug GPIO that was never asserted. Each such free leaked
  one pinctrl_yupik module reference. The normal 1 -> 0 sequence was balanced.
- Fix (`btpower/btpower.c`, patch `patches/0002-btpower-free-only-held-gpios.patch`): `bt_rst_gpio_held` /
  `bt_dbg_gpio_held`, set after a successful `gpio_request`, cleared at the free; nothing else changes. The XO reset
  path was already balanced (requests and frees in one function, returns before the free on failure); the sw_ctrl
  GPIO is never requested.
- Build: `drivers612/conn/bt/build.sh btpower`, then `llvm-strip --strip-debug` (clang-r547379).
- ABI: vermagic, `__kcrctab`, `__kcrctab_gpl`, `__versions`, `__ksymtab_strings`, `.modinfo` byte-identical to the
  shipped module: swap btpower.ko alone (btfmslim binds to the same exports).
- Swap on any REF: `python3 -I drivers612/realboot/tools/rd-swap-ko.py <REF>-rd.cpio.gz <NEW>-rd.cpio.gz
  drivers612/conn/bt/out-gpiofix/btpower.ko` (1 entry).
- Phone check: `tools/camloop/btloop.sh 20` (BT off/on, pinctrl_yupik / pinctrl_msm refcnt per cycle, PASS when
  first = last and BT is back in its initial state).
