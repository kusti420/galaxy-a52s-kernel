# a52sxq_msm_subsys: the 5.4 `/sys/bus/msm_subsys` view on 6.12

The 5.4 interface: Qualcomm msm-5.4 `drivers/soc/qcom/subsystem_restart.c` (vendor module
`subsystem_restart.ko`). On 6.12 the subsystems are remoteprocs. This module puts back only
the sysfs part, for the stock OneUI vendor (A528BXXU5FWK4).

**It overlaps `drivers612/conn/subsys_compat`.** That module (another agent's directory, not
edited) already registers the same bus with the same devices and paths, plus `/dev/subsys_*`,
remoteproc boot/shutdown and `restart_level` -> remoteproc recovery. It is in
`first.load` line 203. This module is only a fallback and makes way for it:

- At init it does nothing if a bus called `msm_subsys` already exists (`kset_find_obj` on the
  bus kset). This avoids a duplicate `bus_register()` and its sysfs dup-name stack dump.
- A module notifier watches for the module named by `yield_to` (default `subsys_compat`). On
  `MODULE_STATE_COMING`, which runs before that module's init, it removes its bus, devices and
  parents right away, so subsys_compat's `bus_register()` and parent names succeed.
- If that module goes away again (`MODULE_STATE_GOING`: rmmod or a failed init), the fallback
  registers again from a work item.

So both modules can sit in `first.load` (this one at ~line 187, subsys_compat at 203). In a
build without subsys_compat, this one provides the nodes. Without the hand-over, the duplicate
bus would make subsys_compat's init fail, and a first-stage insmod failure is a bootloop.

Init never fails (it always returns 0) and never waits. The `.ko` has no module dependencies:
remoteproc, OF and the driver core are all in GKI vmlinux.

## Nodes

`/sys/bus/msm_subsys/devices/subsysN` is a symlink to
`/sys/devices/platform/soc/<5.4 PIL node>/subsysN`. The parent is an empty device with the
5.4 platform-device name, a child of the `/soc` platform device (6.12 `yupik.dtsi`:
`soc: soc`, so the path is `/sys/devices/platform/soc`). Before creating a parent the module
checks for a device with that name. None exists in the 6.12 real-boot tree
(`rbich45/work/vendor_boot.dtb`: remoteprocs are `remoteproc-{wpss,mss,adsp,cdsp}@...`).

| N | name (5.4) | parent (5.4 path) | 6.12 remoteproc compatible |
|---|---|---|---|
| 0 | yupik_ipa_fws | soc:qcom,ipa_fws | - (IPA fw, loaded in kernel) |
| 1 | a660_zap | soc:qcom,kgsl-hyp | - (GPU zap, loaded in kernel) |
| 2 | wpss | soc:qcom,wpss@8a00000 | qcom,yupik-wpss-pas |
| 3 | modem | 4080000.qcom,mss | qcom,yupik-modem-pas |
| 4 | adsp | 3700000.qcom,lpass | qcom,yupik-adsp-pas |
| 5 | cdsp | a300000.qcom,turing | qcom,yupik-cdsp-pas |
| 6 | venus | aab0000.qcom,venus | - (video fw, loaded in kernel) |

Sources for the numbering (the phone's own 5.4 data, not the DT order alone):
`research/blob-uapi-evidence/subsys.txt` (`/dev/subsys_*` minors 0..6 = the subsys index:
ipa_fws 0, a660_zap 1, wpss 2, modem 3, adsp 4, cdsp 5, venus 6; attribute list of each
subsysN), `system_fds_raw.txt` (the seven real paths, e.g. `.../4080000.qcom,mss/subsys3`,
`.../aab0000.qcom,venus/subsys6`), and `downstream-dt/a52sxq-r02.dts` (`qcom,firmware-name` =
`desc->name`; `qcom,trustedvm@d0800000` is disabled, so there is no 8th entry). This matches
subsys_compat's table.

## Attributes (5.4 format)

| file | mode | read | write |
|---|---|---|---|
| name | 0444 | `<name>\n` | - |
| state | 0444 | `ONLINE\n` for RUNNING/ATTACHED/SUSPENDED, `OFFLINING\n` for CRASHED, else `OFFLINE\n` | - |
| crash_count | 0444 | `%d\n` = `rproc->crash_cnt` (0 without a remoteproc) | - |
| restart_level | 0644 | `SYSTEM\n` (5.4 default RESET_SOC) / `RELATED\n` | 5.4 `strncasecmp` prefix match up to the newline, else `-EPERM` |
| firmware_name | 0644 | `<fw name>\n` (5.4 default = name) | stored only |
| system_debug | 0644 | `set\n` / `reset\n` | `set`/`reset`, else `-EPERM` |

The state is looked up each time it is read: `of_find_compatible_node` ->
`rproc_get_by_phandle` -> read the state -> `rproc_put`. No reference is held, so the module
works no matter when the remoteprocs register, and never blocks qcom_q6v5_pas from unloading.
The writes are stored only: nothing here touches remoteproc recovery or firmware. That is
subsys_compat's job. 5.4's `wakeup/` subdirectory is not created, so no wakeup sources are
added. Parameters: `yield_to=` (empty = never yield), `soc_path=` (default `/soc`; empty = no
parents), `default_related=1`.

Who reads these on OneUI (strings in the work_dir images): `libmdmdetect.so` and
`sec_diag_uart_log` (`%s/%s/name`, `%s/%s/state` under `/sys/bus/msm_subsys/devices`),
`vendor/bin/ssr_setup` (name, writes `restart_level`; started from `init.qcom.rc` on
`persist.vendor.ssr.restart_level=*`), and `vendor/bin/ssr_diag`. No rc file reads
`msm_subsys` directly.

## SELinux (vendor_sepolicy.cil + vendor_file_contexts)

Labels follow the real path (`/sys/devices/platform/soc/...`), not the `/sys/bus` symlink.
On 5.4 the parent was the PIL platform device, and that is what makes the per-device entries
match. Without a parent the files would sit in `/sys/devices/subsysN` and get plain `sysfs`.

- `genfscon sysfs /bus/msm_subsys` -> `vendor_sysfs_ssr` (bus directory, `devices/`, the
  symlinks; ssr_setup and per_mgr have `lnk_file` rules for it).
- Longest-prefix genfscon (+ the matching `vendor_file_contexts` regex for ueventd's restorecon):
  - `soc:qcom,ipa_fws/subsys0/name` -> `vendor_sysfs_ssr`, `.../restart_level` -> `vendor_sysfs_ssr_toggle`
  - `4080000.qcom,mss/subsys3/name` -> `vendor_sysfs_ssr`, `.../restart_level` -> `vendor_sysfs_ssr_toggle`
  - kgsl-hyp/subsys1, venus/subsys6: no genfscon for these indices, but file_contexts
    `/sys/devices/platform/soc/soc:qcom,kgsl-hyp/subsys[0-9]+/name` (and venus) ->
    `vendor_sysfs_ssr` / `_toggle`. These apply once ueventd's coldboot restorecon has run.
  - wpss/subsys2, lpass/subsys4, turing/subsys5: no entry in either file -> `sysfs`. It is
    the same policy on 5.4, so it behaves the same.
  - `state`, `crash_count`, `firmware_name`, `system_debug`: no entry -> `sysfs`.
- `vendor_sysfs_ssr` readers: vendor_per_mgr, vendor_sensors, vendor_cnd, vendor_rmt_storage,
  base_typeattr_663 (the libmdmdetect users), ssr_setup (read/write), vendor_init (write).

## Build / test

    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/msm_subsys     # -> out/a52sxq_msm_subsys.ko
    drivers612/samsung-oneui/msm_subsys/qemu/run.sh                           # QEMU virt, PASS/FAIL

`qemu/run.sh` adds a `/soc` simple-bus and a driverless `qcom,yupik-modem-pas` node to the virt
dtb. It checks the 7 paths and values, modes, the write semantics and 40 state reads (the
rproc lookup finds nothing, as expected in QEMU). It tests the hand-over to a stand-in owner
(`qemu/fakeowner/msub_fakeowner.ko`, `yield_to=msub_fakeowner`; deliberately NOT named
subsys_compat so it can never be packed by mistake) and getting the bus back after its rmmod.
It also covers an idle load behind an existing bus, `soc_path=/nonexistent`, rmmod, and checks
there is no WARN/BUG/dup-filename.

## On-phone check (not run; offline only so far)

    ls -l /sys/bus/msm_subsys/devices/
    for d in /sys/bus/msm_subsys/devices/subsys*; do echo "$d $(readlink -f $d)"; \
      for a in name state crash_count restart_level firmware_name system_debug; do echo "  $a=$(cat $d/$a)"; done; done
    ls -Z /sys/devices/platform/soc/4080000.qcom,mss/subsys3/ /sys/devices/platform/soc/soc:qcom,ipa_fws/subsys0/
    ls -Zd /sys/bus/msm_subsys /sys/bus/msm_subsys/devices/subsys3
    lsmod | grep -E 'a52sxq_msm_subsys|subsys_compat'
    dmesg | grep -E 'a52sxq_msm_subsys|subsys_compat'   # with subsys_compat: "subsys_compat loading: handing msm_subsys over"
    cat /sys/class/remoteproc/remoteproc*/name /sys/class/remoteproc/remoteproc*/state  # compare with subsys2..5 state
    getprop persist.vendor.ssr.restart_level; logcat -d | grep -i ssr_setup
    dmesg | grep -i 'avc.*ssr'
