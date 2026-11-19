# Changes made to donor code (reasons)

- `0001-physwizz-donor-changes.diff` (physwizz A24/A15/A16 6.12 tree):
  - `muic/common/muic_param.c`: `#if IS_BUILTIN(CONFIG_MUIC_NOTIFIER)` block (`__setup`,
    `early_param`) disabled: not allowed in a module; the values exist as module params.
  - `battery/common/sec_battery.c`: `#include <linux/vbus_notifier.h>` no longer requires
    `CONFIG_LSI_IFPMIC` (the file uses the vbus notifier without it; on the donor's platform
    another header pulled it in).
  - `usb/typec/sm/sm5714/sm5714_pd.c`: `#if defined(CONFIG_IF_CB_MANAGER)` ->
    `IS_ENABLED()` in `sm5714_disable_bc12()`. As a module the option is `_MODULE`, so the
    call was compiled out; 5.4 has it built in and does disable BC1.2 there.
- `0002-crdroid-pca9468-6.12.diff`: i2c `probe(client)` and `void remove()` signatures (6.12).
- `0003-s26-usb_notifier.diff`: `reverse_bypass_drive` / `get_support_reverse_bypass_en`
  initialisers dropped (S26-only members; the usb_notify core here is the physwizz one).
  `usb_notifier.h` is the S26 one. The physwizz MediaTek `usb_notifier.c` is kept beside it
  as `usb_notifier.c.physwizz-mtk.unused` for reference only.
- `0004-54-leds-sm5714-fled.diff`, `0005-54-sec_thermistor.diff` (phone's 5.4 drivers):
  `void remove()`, `strlcpy` -> `strscpy`.
- Unchanged copies: everything else under `src/`, `include/linux/**` from physwizz;
  `include/linux/{switch,host_notify,external_notify,vbus_notifier,usb_hw_param}.h`,
  `src/switch/switch_class.c`, `src/vbus_notifier/vbus_notifier.c` from S26;
  `include/dt-bindings/battery/sec-battery.h`, `include/linux/platform_data/sec_thermistor.h`
  from the phone's 5.4 tree.
- New files: `src/glue/a52sxq_usb_glue.[ch]`; stubs `include/linux/samsung/sec_param.h`
  (empty), `include/linux/sec_debug.h` (no-op `battery_last_dcvs()`).
- `0006-audit-1118-pdic-lpcharge-manager-leak.diff` (audit 2026-11-18, paths relative to `src/`):
  - `usb/typec/common/pdic_param.c`: `is_lpcharge_pdic_param()` derives off-mode charging from
    `/chosen/bootargs` (`androidboot.mode=charger` / `sec-battery.lpcharge=1`) when no module
    param is given. As a module the `early_param("androidboot.mode")` is compiled out and the
    bootloader passes nothing for pdic, so PDIC/MUIC/manager never saw LPM.
  - `usb/typec/manager/usb_typec_manager_notifier.c`: `manager_event_notify()` frees
    `event_work` on the duplicate-USB and repeated-water early exits (was a leak per event).
