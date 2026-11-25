# camera.ko out-gpiofix: free only GPIOs the driver requested (pinctrl refcount leak, oops after ~25 sessions)

2026-11-24. On white cable in rb110 (LineageOS). `camera.ko` (stripped) sha256 in `SHA256SUMS` (c63f7b25...);
the .ko is not tracked: `drivers612/camera/port.sh` + `llvm-strip --strip-debug`.

- Bug: 6.12 `gpiod_free()` does `module_put(gdev->owner)` + `gpio_device_put()` even when the line is not
  requested (5.4 only when it really freed). The 5.4 camera driver frees a device's whole GPIO table at
  power-down whatever the requests returned: TLMM 11 (gpio 523) is CAM_VANA0 of the rear wide sensor AND
  MCU_VANA of the OIS MCU; the second requester gets -EBUSY (`cam_res_mgr` reads `sharedgpios`, the DT has
  `shared-gpios`: not treated as shared on 5.4 either), both free it. One pinctrl_yupik module reference and
  one gpio_device reference were lost per rear-camera session; at 0 every `gpio_request` returns -517,
  `cam_sensor_core_power_up` fails and its unwind oopses in `gpiod_free_commit` (freed gpio_device).
- Fix (port612.py block "GPIO request/free balance"): `cam_a52_gpio_request_one()` / `cam_a52_gpio_free()` in
  `cam_res_mgr.c` keep the list of GPIOs requested successfully by the camera driver (both request sites:
  `cam_res_mgr_gpio_request`, `cam_soc_util_request_gpio_table`); a free of anything else is skipped and
  counted. Same observable behaviour as 5.4 (a device can still free a line another camera device requested).
  `/sys/module/camera/parameters/a52_gpio_free_skipped` (skipped frees), `a52_gpio_held` (held now).
- Not changed: the -EBUSY itself ("gpio 523:MCU_VANA request fails rc = -16", 2 lines per rear session) is 5.4
  behaviour; the OIS drives the rail through `gpio_set_value` while the sensor holds the request. Making TLMM 11
  a real shared GPIO (`cam_res_mgr` shared list by `<&tlmm 11>`) is open.
- This build also carries the SOF-freeze watchdog 5000 ms change (out-p1, 061e02e), first time on a phone.
- ABI: export CRC sections identical to the shipped module (aad1088a), vermagic + depends identical; module
  parameters added. Swap: `rd-swap-ko.py <REF> <NEW> drivers612/camera/out-gpiofix/camera.ko` (1 entry,
  `a52/mods/camera/camera.ko`).
- Proof: rehearsal rh612p2a110b 66/4 = base; real boot rb110: `tools/camloop/camloop.sh 60` = 60/60 photos over
  ids 0 1 2 3 54, 12/12 video records (all on id 54), pinctrl_yupik 26 -> 26, pinctrl_msm 88 -> 88, front + rear
  JPEG pulled, torch on/off ok (`logs/camloop/20261124-204628.txt`). Before the fix: -1 per session.
- Lesson kept in port612.py: a first build replaced the `gpio_free(gpio);` text inside the new helper too
  (self-recursion, nothing was freed, every camera failed); the rehearsal rh612p2a110 caught it, never flashed.
