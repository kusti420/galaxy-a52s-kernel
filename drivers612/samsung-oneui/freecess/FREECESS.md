# Freecess (Samsung app freezing) kernel side on GKI 6.12, as a module

State 2026-11-22: built against bsp612, QEMU-tested on the bsp612 GKI Image (both modes PASS).
**Not loaded on a phone, not run against the real framework.**

`freecess.ko` registers netlink protocol 27 (`NETLINK_KFREECESS`) and sends the same reports as the
Samsung code that is built into the 5.4 A52s kernel (`drivers/staging/android/freecess*.c` + patches in
binder.c, binder_alloc.c, signal.c) and into the S26 6.12 kernel (same files, GKI core patched).
Here the GKI Image is not patched: every report hangs on an Android vendor hook or on netfilter.

    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/freecess     # -> out/freecess.ko
    drivers612/samsung-oneui/freecess/qemu-test/run.sh                      # default module, v1 mode
    FC_ARGS="max_version=6" KFT_ARG=full drivers612/samsung-oneui/freecess/qemu-test/run.sh

Ramdisk: `drivers612/androidboot/out/s99r-rd.cpio.gz` = s99q + `freecess.ko` at the end of stage
`vibrator` (rd-add-ko.py) + the new `nfc_sec.ko` (rd-swap-ko.py, section 6).

## 0. 2026-11-24: resume re-freeze (SPEC/07-art-suspendall-timeouts.md)

On 6.x a system resume half-thaws every process in a cgroup v1 FROZEN group (`thaw_processes()` restores the tasks
that were frozen in place in a futex/nanosleep/binder wait; nothing freezes them again). On the user's One UI phone
that was 44 ART "SuspendAll timeout" aborts of Freecess-frozen apps in two days. `freecess_refreeze.c` (PM notifier +
task work) sends those tasks back to the freezer after every PM thaw. Parameters `refreeze` (default 1),
`stat_refreeze_runs/escaped/queued`, `refreeze_now`. Proof: `qemu-test/run-resume.sh` (PASS; `refreeze=0` shows the
bug) and `tools/frztest` on white cable. Not yet run on a One UI phone.

## 1. What the framework does (services.jar of the port, smali)

- `FreecessHandler$NetLinkReceiverThread`: `Os.socket(AF_NETLINK, SOCK_DGRAM, 27)`, connect to the
  kernel, no bind (port = autobind). Started from `ActivityManagerService.finishBooting()`.
- **No protocol 27 in the kernel** (EPROTONOSUPPORT): stack trace to System.err, one retry after 1 s,
  then `reportSocketResult(false)`: Freecess, OLAF and "one freezer" are switched off for this boot.
  No crash, nothing else waits for it. This is the state of every 6.12 boot before this module.
- Hello: one LOOPBACK (type 1) per mod 1..4, 156 bytes, nlmsg type 0x1e and flags 0, payload
  `src_portid = myPid`, `dst_portid = 0x12341234`, **version word always 0x20000003** (fw version 2,
  bit 0 = cgroup2 capable, bit 1 = one freezer). It reads one 156-byte datagram per hello (500 ms
  timeout) and looks **only at the version word of the answer**:
  - `0x10000000`: cgroup v1 mode, freezing = `Process.setProcessMARsFrozen` = task profile `SFrozen` =
    join `/dev/freezer/frozen` (what the 5.4 kernel answers);
  - `0x20000000`: cgroup2 mode, freezing = `Process.setProcessFrozen` (`cgroup.freeze` of the app's
    `uid_/pid_` cgroup);
  - `0x60000000`: cgroup2 + one freezer (what the S26 kernel answers to this word);
  - anything else: "mismatch flag is true", every later binder report is treated as "mismatch".
- A missing answer or a mod the kernel ignores is not an error: user-to-kernel messages (MOD_PKG
  ADD_UID/DEL_UID, MOD_CFB 2 s after a freeze) are fire-and-forget. The cost is the missing wake-up.
- Reports are dispatched by `mod` only: MOD_BINDER (flag 1 = oneway: interface token lists,
  `free_buffer_full`; else sync: unfreeze "Binder(0)"), MOD_SIG (`unfreezeForAppDied(pid = flag)`),
  MOD_PKG (unfreeze "Packet"), MOD_CFB (unfreeze "Cfb").

## 2. Hook map

| Samsung call site (5.4 A52s = S26 6.12) | GKI android16-6.12 hook used | Result |
|---|---|---|
| `netlink_kernel_create(NETLINK_KFREECESS)` built in | same call from the module (`__netlink_kernel_create` is exported, protocol 27 is free in GKI) | same |
| binder.c `binder_transaction()`: `freecess_sync_binder_report()` | `android_vh_binder_trans(target_proc, proc, thread, tr)`, the line above Samsung's call in S26 | same |
| binder.c `binder_transaction()`: `freecess_async_binder_report()` (after the buffer is allocated, `copy_from_user` of the interface token) | same `android_vh_binder_trans`, earlier in the function; token read with `copy_from_user_nofault` (hooks run with preemption off) | same; rpcname empty if the sender's page is not resident (it has just been written) |
| binder_alloc.c `binder_alloc_new_buf_locked()`: `binder_report(p, -1, "free_buffer_full", is_async)` | `android_vh_binder_alloc_new_buf_locked(size, &alloc->free_async_space, is_async, &should_fail)`, `alloc` by `container_of` | same condition as S26 (`< 3*size` or `< buffer_size/4`); 5.4 added `sizeof(struct binder_buffer)` to size |
| signal.c `do_send_sig_info()`: `sig_report()` for KILL/TERM/ABRT/QUIT/IO | `android_vh_do_send_sig_info(sig, current, p)`, same line | same |
| binder.c `binders_in_transcation(uid)` (MOD_CFB; walks the static `binder_procs`) | `android_vh_binder_preset(&binder_procs, &binder_procs_lock, proc)` at every binder open hands out both pointers; the walk itself is in the module, with the private binder headers of the Image's tree (`-I$(srctree)/drivers/android`) | same; no `fg_todo` list (Samsung FAST_TRACK is not in GKI) |
| freecess_pkg.c netfilter LOCAL_IN hooks (TCP for a recorded uid) | same (`nf_register_net_hooks`), through `pernet_operations` | same; like Samsung's it only sees packets whose socket was set by early demux |
| legacy_freezer.c `freezer_can_attach()` (only uid 1000 or CAP_SYS_ADMIN may move other tasks into a v1 freezer cgroup) | **no hook** (`android_vh_cgroup_attach` runs after the attach was decided and cannot refuse) | not ported. The stock v1 write check stays (root, same uid, or CAP_SYS_NICE), which is what lets system_server freeze apps; only Samsung's extra restriction is missing |
| `thread_group_is_frozen()` v1: `freezing() \|\| frozen()` | `freezing()` (exported `freezer_active` + `freezing_slow_path`); `frozen()` is not exported, replaced by its one line (`__state & TASK_FROZEN`) | same |

Other hooks that exist in this GKI and were looked at, not needed: `android_vh_binder_proc_transaction`,
`android_vh_binder_transaction_received`, `android_vh_binder_free_proc`, `android_vh_killed_process`,
`android_vh_exit_signal`, `android_vh_cgroup_set_task`, `android_vh_cgroup_attach`,
`android_rvh_refrigerator`, the `android_vh_tcp_rcv_established_*` / `android_vh_receive_sock` family
(netfilter does the socket rx part, as in Samsung's code). All used tracepoints are in
`bsp612/out/gki/Module.symvers`. No kprobes, no kallsyms tricks.

Differences from the Samsung code, on purpose:
- A report for a mod with no framework port bound is dropped at the start of the hook. Samsung
  unicasts it to portid 0 = its own kernel socket and logs "permission denied" each time.
- The framework's port is the netlink sender's (`NETLINK_CB(skb).portid`), not the payload's
  `src_portid` (the framework writes its pid there without binding; normally the same number).
- After `-ECONNREFUSED` (system_server gone) the port is forgotten until the next hello.
- Message layout and `caller_pid`/`pkg_info` use are S26's (the framework reads `version` of a binder
  report as caller pid and `pkg_info.cmd` as target pid).

## 3. Mode: `max_version` (module parameter, default 1)

| max_version | answer to 0x20000003 | framework freezes via | kernel "is frozen" test |
|---|---|---|---|
| **1 (default)** | 0x10000000 | `/dev/freezer/frozen` (cgroup v1) | v1 freezer state of the group leader |
| 2 | 0x20000000 | cgroup2 `cgroup.freeze` | `JOBCTL_TRAP_FREEZE` |
| 6 | 0x60000000 | cgroup2 + one freezer | `JOBCTL_TRAP_FREEZE` |

Default 1 = byte-for-byte what the port has always seen from the 5.4 kernel, so the framework takes
the path it has been running on. 6 is the S26 behaviour; it has never run on this port (needs the
`/sys/fs/cgroup/apps/uid_*/pid_*` layout and the CachedAppOptimizer "one freezer" path): try it
later with the module option `max_version=6` (insmod argument in the stage list).

## 4. cgroup v1 freezer on GKI 6.12

- `CONFIG_CGROUP_FREEZER=y`; `kernel/cgroup/legacy_freezer.c` is built. The controller has no cgroup2
  files, so cgroup2 never claims it (`cgroup.controllers` = `cpuset cpu io memory` in the test) and
  `mount -t cgroup -o freezer none /dev/freezer` works with cgroup2 already mounted. QEMU: mount,
  mkdir frozen/olaf/abnormal, FROZEN/THAWED writes, `freezer.state` reads back, `/proc/cgroups`
  shows the hierarchy. A task moved into the FROZEN group freezes; moved to the root it thaws.
- A v1-frozen task does not die from SIGKILL until thawed (QEMU: alive after the kill, dead after
  the move to the root), on 6.12 as on 5.4. That is what MOD_SIG is for: kill -> report ->
  `unfreezeForAppDied`. A cgroup2-frozen task dies at once.
- **`freezer.killable`**: `vendor/etc/init/hw/init.a52sxq.rc:41` writes
  `/dev/freezer/frozen/freezer.killable 1`. Neither the Lineage 5.4 tree, nor the bone-machine 5.4
  kernel the port runs on, nor the S26 6.12 source has such a file (grep: no `killable` in any
  `legacy_freezer.c`/`freezer.c`), and nothing in services.jar or the native libs names it. On 5.4
  the write fails with ENOENT and init logs it; on 6.12 the same. Not implemented: there is no
  reference for its semantics, and "frozen tasks die from SIGKILL" cannot be done from a module
  (the freeze decision is `freezing_slow_path()`, no hook). `cgroup_add_legacy_cftypes` and
  `freezer_cgrp_subsys` are exported, so a file could be added if a meaning turns up.
- `cgroups.json` names the controller `sfreezer` (`Optional: true`). No kernel here has a subsystem
  of that name (5.4, bone, S26: no hit); the real mount is the rc line. Same on 6.12.

## 5. ROM-side lines needed

With the default (`max_version=1`): **none**. Already in the port:
- `vendor/etc/init/hw/init.a52sxq.rc` (on init): `mkdir /dev/freezer`, `mount cgroup none
  /dev/freezer freezer`, `mkdir frozen`/`thaw`, `write frozen/freezer.state FROZEN`, chowns;
- `system/etc/init/hw/init.rc:522-557`: `frozen`, `olaf`, `abnormal` + owners/modes;
- `task_profiles.json`: `SFrozen`/`SUnfrozen`/`Slowdown*`/`Olaf*` on `/dev/freezer`.
Only the kernel side has to load `freecess.ko` (s99r does, first stage, before the first binder open).

To check on the phone after boot (root): `cat /proc/mounts | grep freezer`;
`grep . /sys/module/freecess/parameters/*` (`stat_loopback` 4 = the framework said hello,
`kernel_version` 1, `binder_procs_known` 1, counters per report); `dmesg | grep freecess`;
logcat for `mismatch flag` (must not appear) and MARs unfreeze reasons `Binder(0)`, `Signal`,
`Packet`, `Cfb`. SELinux: system_server's `netlink_socket` create/read/write is in the port's
policy already (same generic class for protocol 27 on 5.4); a denial there would show as the quiet
"no kernel support" path.

To switch Freecess off again: do not load the module (the framework's quiet path), nothing else.

## 6. /sys/class/nfc_sec/pvdd (drivers612/nfc)

`init.nfc.samsung.rc` writes "1" (late-init), "2" (post-fs-data), "3" (boot). The 5.4 A52s kernel has
no such node (`# CONFIG_NFC_PVDD_LATE_ENABLE is not set`; its store is under that ifdef): the writes
fail with ENOENT and PVDD is enabled in probe. The S26 donor's store (nxp_combined) is write-only and
acts on '1' only. The 6.12 `nfc_sec.ko` now has the node (write-only 0200, while the driver is bound):
"1"/"2"/"3" = make sure PVDD is on (no-op when probe enabled it, else one `regulator_enable()`), never
disables, never enables in LPM charging, never fails the write; probe and store share one reference.
Built clean, patch regenerated (`drivers612/nfc/patches/0001-sec-nfc-6.12.patch`), stripped copy
`drivers612/nfc/out/nfc_sec.ko` in s99r. Not run on hardware; the node's SELinux label on 6.12 is
unchecked (a denial fails the write as on 5.4).

## 7. What the QEMU test proves, and what it does not

`qemu-test/run.sh` (bsp612 `out/dist/Image`, QEMU virt, `test/kfreecess_test` as the framework):
EPROTONOSUPPORT without the module; load; hello for mods 1..4 with the real word (answer version 1
by default, 6 with `max_version=6`, 1 again for a word without bit 0); a hello from uid 0 is ignored;
MOD_SIG for SIGKILL to a frozen uid (v1 and v2); MOD_BINDER for a oneway call (code, flag, interface
token decoded from a real parcel, target pid, caller pid) and for a sync call into a frozen binder
context manager, none for a running one; MOD_CFB found for a queued sync call, not for a queued
oneway, not for another uid (this is the check of the private binder struct layouts against the
Image); MOD_PKG for TCP data to a recorded uid over a veth pair, once, not after DEL_UID; rmmod;
no WARN/BUG. Both runs PASS.

Not covered: the real framework (message timing, the 156-byte read, SELinux), `free_buffer_full`
(hook registered, never triggered in the test), IPv6, load on the phone, behaviour under load
(the binder and signal hooks are on hot paths: they return after one atomic read until the
framework has said hello, and after one uid/frozen test afterwards).

Risks:
- The CFB walk reads `struct binder_proc`/`binder_thread`/`binder_transaction` through private
  headers. They must match the Image: rebuild the module whenever the GKI Image changes (vermagic
  alone does not catch a binder struct change inside the same release string).
- If the ROM ever switches to the Rust binder (`CONFIG_ANDROID_BINDER_IPC_RUST=m` exists), none of the
  binder hooks fire; MOD_SIG and MOD_PKG would still work.
- With Freecess alive for the first time on 6.12, apps really get frozen in `/dev/freezer/frozen`.
  A missed wake-up shows as a frozen app that does not react (notification, incoming binder call):
  compare with a boot without the module (s99q) before blaming anything else.
