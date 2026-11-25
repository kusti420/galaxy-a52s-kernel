# camera.ko out-p1: SOF-freeze watchdog 5000 ms as stock (SPEC/05 P1-3, misc row 2)

Built 2026-11-24, not on a phone.

- Change: `CAM_REQ_MGR_WATCHDOG_TIMEOUT` 1000 -> 5000 ms (`work/drivers/cam_req_mgr/cam_req_mgr_core.h:16`,
  made by `port612.py`, so `port.sh` regenerates it). Evidence: stock-derived 5.4
  `~/git/kernel_a52sxq_bone/techpack/camera/drivers/cam_req_mgr/cam_req_mgr_core.h:16` = 5000; LineageOS 5.4
  (`$ANDROID_TREE/kernel/samsung/sm7325/techpack/camera/...:16`, our donor) = 1000. Same for every ROM (no switch).
  Used at `cam_req_mgr_core.c:680-704`: the watchdog is re-armed to frame duration + this value.
- Build: `drivers612/camera/port.sh build` (incremental, 58 objects that include the header), 0 errors.
- Base check: the tree before the change, stripped, = the shipped module (s99w / s99ou9 ramdisks, rb108, rbou9):
  sha256 aad1088a...; new stripped module 8932c391... (same size 5973144), `SHA256SUMS` here. The .ko itself
  is not tracked (*.ko is ignored): rebuild with `port.sh build` + `llvm-strip --strip-debug`.
- ABI: `Module.symvers` byte-identical (75 lines, 0 changed), imports identical (319 entries, same CRC list
  hash 02ae53b8...), 0 new imports, depends unchanged (`ioncompat,qcom-scm,qcom_iommu_util,leds-qti-flash,
  sm5714_fled_stub`), vermagic `6.12.81-4k-g8a69376da734`. Plain `rd-swap-ko.py` swap of camera.ko.

## Test on a phone (no hands needed; LineageOS/IchthysOS and One UI alike)

1. Module is the new one: `sha256sum /lib/modules/camera.ko` (or the vendor_boot ramdisk copy) = 8932c391...;
   `dmesg | grep -ci 'camera.*disagrees'` = 0; `lsmod | grep -c '^camera '` = 1.
2. Regression: open the camera app, back preview 10 s, switch to front, to ultra-wide, to video, take one photo
   in each (IchthysOS: `tools/photo`; One UI: `am start -a android.media.action.STILL_IMAGE_CAMERA` + keyevent 27).
   Expected: `dmesg | grep -c 'SOF freeze'` = 0 and no `CAM_REQ_MGR_ERROR_TYPE_SOF_FREEZE` / "camera failed".
3. The value itself cannot be forced key-free (it only shows when a stream stalls). If a stall shows up in a
   log: the time between the last `cam_req_mgr_process_sof` activity and the `SOF freeze` report is about
   frame time + 5 s on this module (about frame time + 1 s on the old one), as on the 5.4 stock kernel.
4. Sweep: `tools/selftest` camera rows unchanged (4 cameras on One UI).

Needs hands: no.
