# ufs_sec_sysfs.ko: Samsung 5.4 UFS sysfs nodes on 6.12

The 5.4 nodes under `/sys/class/sec/ufs` and the `SEC_UFS_*` nodes under
`/sys/class/scsi_host/host0`, with the 5.4 names, modes and print formats, for the 6.12 GKI +
soc-repo ufs-qcom stack. It is a separate module and does not change the UFS driver.
Built offline only. It has not been loaded on a phone.

## Reference (what 5.4 really has)
These sources are confirmed to match the stock FWK4 kernel (`5.4.233-qgki-27763529-abA528BXXU5FWK4`,
extracted from `~/git/MonsterROM/out/fw/SM-A528B_BTU/kernel/boot.img`). `strings` finds
`ufs_set_sec_unique_number`, the 10x`%02X` format, `man_id`, `transferred_cnt`, `SEC_UFS_op_cnt`
and the JSON formats in it, and **no `unique_number` attribute**. The node list and modes match
`research/blob-uapi-evidence/sec_detail.txt` (a live 5.4 phone).

- `$ANDROID_TREE/kernel/samsung/sm7325/drivers/scsi/ufs/ufs-qcom.c`
  - 2455-2486 `ufs_set_sec_features()` (device descriptor, then UN + health), called from
    `ufs_qcom_apply_dev_quirks()` at the first init (2519-2523)
  - 4366-4410 `ufs_set_sec_unique_number()`
  - 4413-4440 `ufs_get_health_desc()`
  - 4442-4497 `un`/`lt`/`lc`/`man_id` attributes
  - 4644-4686 `transferred_cnt` and `ufs_sec_create_sysfs()` (`sec_device_create(hba, "ufs")`)
  - 4565-4615 `sec_wb_enable` (CONFIG_SEC_UFS_WB_FEATURE=y in the defconfig)
- `ufs-qcom.h:305-317`: `UFS_UN_20_DIGITS 20`, `UFS_UN_MAX_DIGITS 21`, `SERIAL_NUM_SIZE 7`
- `ufs-sysfs.c:1231-1347` and `ufs-sysfs.h:124-129`: `SEC_UFS_*` (0444) on `hba->host->shost_dev`,
  created from `ufshcd_init()` (`ufshcd.c:9812`)

## Nodes

| path | mode | format (5.4) | 6.12 value |
|---|---|---|---|
| /sys/class/sec/ufs/un | 0440 | `"%s\n"`, 20 upper-case hex digits | same as 5.4 (computed the 5.4 way) |
| /sys/class/sec/ufs/lt | 0444 | `"%01x\n"` bDeviceLifeTimeEstA | real; the health descriptor is re-read on each read (as in 5.4) |
| /sys/class/sec/ufs/lc | 0664 | `"%u\n"`, RAM only (stores u32) | as 5.4 |
| /sys/class/sec/ufs/man_id | 0444 | `"%04x\n"` wManufacturerID | real (`hba->dev_info`) |
| /sys/class/sec/ufs/transferred_cnt | 0444 | `"%llu\n"` | **0** (5.4 counted in ufs-qcom completions; 6.12 has no counter) |
| /sys/class/sec/ufs/sec_wb_enable | 0664 | `"Enabled\n"` / `"off\n"`, refcount store | **no-op**: refcount kept, WriteBooster not switched (the GKI core owns WB) |
| /sys/class/scsi_host/host0/SEC_UFS_{op,uic_cmd,uic_err,fatal,utp,query}_cnt, SEC_UFS_err_sum, sense_err_count, sense_err_logging | 0444 | 5.4 JSON-ish strings | **all counters 0** (5.4 fed them from Samsung hooks inside ufshcd.c) |
| /sys/class/scsi_host/host0/unique_number | 0440 | same string as `un` | **only with `legacy_shost_un=1`** (default 0, see below) |

The real directory is `/sys/devices/virtual/sec/ufs` (sec_core `device_create(sec_class, NULL, ...)`,
as in 5.4). The host directory is `/sys/devices/platform/soc/1d84000.ufshc/host0/scsi_host/host0`.

### How UN is derived (5.4 ufs-qcom.c:4366-4410, copied 1:1)
1. Read the full device descriptor (`ufshcd_query_descriptor_retry`, READ_DESC, IDN_DEVICE).
2. Read the string descriptor at index `desc[DEVICE_DESC_PARAM_SN]` (0x16) the same way (raw
   query, 255-byte buffer, no UTF-16 conversion: "spec is unicode but sec uses hex data").
3. `sprintf("%02X" x10, desc[0x19] /* low byte of wManufacturerID */, desc[0x12], desc[0x13]
   /* wManufactureDate raw */, str[2..8] /* first 7 raw bytes after the 2-byte header */)`.
   This gives 20 characters, NUL-terminated. A failed read leaves it empty, so the node shows `"\n"`, as in 5.4.

The 6.12 calls are the same exported GKI function with the same opcode, index, selector and buffer
length. `ufshcd_copy_query_response()` is identical in 5.4 and 6.12 (memcpy of the data segment).
The S26 6.12 Samsung code (`ufs-sec-feature.c:60-98`) uses the same format. I see no source of
byte difference. The one remaining risk is the read failing or running before UFS is operational,
which would give an empty UN. The work waits for that state.

### Why no scsi_host/host0/unique_number by default
5.4 on the A52s never had it. The OneUI init.rc labels that block "legacy", and the
`/sys/class/sec/ufs` block "# UFS from R OS". Every framework and engmode reader tries
`scsi_host/host0/unique_number` first and then falls back to `/sys/class/sec/ufs/un`, so with the
same string the result is the same either way. Two readers differ:
- `vendor/bin/vaultkeeperd` only has `cat /sys/class/scsi_host/host0/unique_number` (a TA-requested
  runCommand). On 5.4 that command fails. Adding the node would give the Vault Keeper TA a value
  it never had.
- `vendor/bin/wvkprov` (factory keybox installer, no rc service). The vendor policy allows it only
  `vendor_sysfs_scsi_host`, not the `un` label. On 5.4 it got no UN at all.
`legacy_shost_un=1` (module option) creates the node if this is ever wanted.

## Consumers (strings of the OneUI 9 port's work_dir)
- vendor: `vaultkeeperd` (scsi_host unique_number), `wvkprov` (scsi_host unique_number, sec/ufs/un),
  `libengmode_server.so` (mmcblk0 unique_number, scsi_host unique_number, sec/ufs/un),
  `com.qti.chi.override.so` (sec/ufs/sec_wb_enable), dumpstate HAL (sec/ufs/lt, lc + scsi_host SEC_UFS_*,
  lt/lc/man_date/hw_rst_info), `etc/hqm_device.xml` (sec/ufs/lt, lc + scsi_host SEC_UFS_*,
  sense_err_*, SEC_UFS_TW/HPB_info).
- system: framework.jar, hqm.jar (unique_number + un), services.jar (unique_number, un, lt, proc_name),
  init (un, lt, lc, ic, shi, vlu_support, post_ffu, scsi_host lc/SEC_UFS_s_info; Samsung LIBFFU),
  vold/gsid/update_engine/libfs_mgr/libsnapshot (un, scsi_host proc_name), at_distributor (un, man_id,
  otp_ver, shi), dumpstate, fsdbg, GalaxyResourceUpdater (lt, flt).

Not created on purpose, because 5.4 on this phone does not have them (newer-generation Samsung nodes):
`sec/ufs/{otp_ver, shi, ic, flt, eli, cmd_log, hist, post_ffu, vlu_support}` and
`scsi_host/host0/{lt, lc, man_date, man_id, hw_rst_info, SEC_UFS_err_summary, SEC_UFS_TW_info,
SEC_UFS_HPB_info, SEC_UFS_HPB_err_info, SEC_UFS_s_info}`. Do not add `ic`/`shi`/`post_ffu`/
`vlu_support`: init's built-in Samsung UFS firmware updater (`ffu`, LIBFFU) reads them.
5.4 WB nodes that no consumer reads were also left out: `sec_wb_support`, the `wb_*`/`lp_wb_*`
threshold and delay nodes, `wb_state`, and the `wb_*_stat` nodes.

## SELinux and rc (OneUI port: vendor/etc/selinux, system/etc/init/hw/init.rc)
- genfscon `/devices/virtual/sec/ufs/un` -> `sysfs_ski_hidden_writable`; `.../man_id` ->
  `sysfs_ski_storage_readable`; `.../lc`, `.../lt` -> `sysfs_ski_ufs_writable`. `transferred_cnt`
  and `sec_wb_enable` have no rule (they get the generic sysfs label, as on 5.4).
- genfscon `/devices/platform/soc/1d84000.ufshc/host0` -> `vendor_sysfs_scsi_host` (all scsi_host
  nodes); vendor_file_contexts:593 has the same for `.../host0/scsi_host/host0(/.*)?`.
- init.rc `on init`: `chown system system` for sec/ufs/{un, lc, lt, flt, man_id, eli, ic, shi,
  transferred_cnt, sec_wb_enable, cmd_log, hist, post_ffu}, `chmod 444 /sys/class/sec/ufs/lc`;
  `chown system system` for scsi_host/host0/{unique_number, lt, lc, SEC_UFS_*, sense_err_*,
  man_date, man_id, hw_rst_info}; `chmod 444` host0/lc; early-init `chmod 000 /sys/class/sec/ufs/post_ffu`.
  No vendor rc or ueventd line touches these paths.
- So `un` must exist before second-stage `on init`, or it stays root:root 0440 and system_server
  cannot read it. It is created synchronously in module init. The scsi_host nodes come from the
  work a few ms later. They are 0444, so a missed chown changes only the user.

## Load position (first stage, vendor_boot modules.load)
- Hard dependency: `sec_core.ko` (`modinfo -F depends` = `sec_core`). In
  `drivers612/realboot/out/rbich43/work/plan/first.load` it is line 143, and ufs-qcom is line 77.
  Put `ufs_sec_sysfs.ko` anywhere after line 143 (the plan is ~182). The modules.dep line must
  list sec_core.
- All other symbols are GKI exports (checked against bsp612/out/lahaina/Module.symvers, including
  `ufshcd_query_descriptor_retry` 0x80f62e29). sec_core CRCs (`sec_core.symvers` here, from
  ko2symvers on the ramdisk's sec_core.ko) match `samsung612/modules/sec_core/Module.symvers`.
- Module init only creates the sec device and schedules work, and it always returns 0. The work
  polls every 250 ms, for up to 60 s, until `1d84000.ufshc` is bound, `ufs_device_wlun` exists,
  the hba is OPERATIONAL and shost_dev is registered. It then reads the descriptors under
  `host_sem` plus a runtime-PM reference on the device W-LUN (the same pattern as GKI ufs-sysfs).

## Build
    EXTRA_SYMVERS=$PWD/drivers612/samsung-oneui/ufs_sec/sec_core.symvers \
      drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/ufs_sec
Output: `out/ufs_sec_sysfs.ko`, 0 warnings, reproducible.

## Verify on a phone
    adb -s <serial> push drivers612/samsung-oneui/ufs_sec/check.sh /data/local/tmp/ufs_sec_check.sh
    adb -s <serial> shell /system/bin/su -c 'sh /data/local/tmp/ufs_sec_check.sh'
Run it on the same phone under 5.4 (OneUI/NERV/Lineage, built-in nodes) and under 6.12. The
`un: len=20 prefix=... sha256=...` line must be identical. `un bytes incl. newline` must be 21.
The `ls -lZ` modes and labels must match too. `lt` and `man_id` should match. The SEC_UFS
counters are 0 on 6.12. Add `full` to print the raw UN (it is a device identifier, so do not
paste it into logs or the repo). A quick raw compare:
`adb shell su -c 'cat /sys/class/sec/ufs/un | sha256sum'` under each kernel.
