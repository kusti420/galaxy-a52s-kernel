# Knox SDP kernel side on GKI 6.12, as a module

State 2026-11-22: built against bsp612, QEMU-tested on the bsp612 GKI Image (PASS).
**Not loaded on a phone, not run against the real framework.**

`sdp_dek.ko` = the 5.4 A52s kernel's `security/sdp` driver (`CONFIG_SDP=y`; Lineage tree and
bone-machine tree are identical for these files) as one loadable module:

| 5.4 object | what it is | in the module |
|---|---|---|
| `dek.c` | misc devices `/dev/dek_evt` (engine events, uid 1000 only), `/dev/dek_req` (DEK generate / wrap / unwrap for apps of the engine's user), `/dev/dek_log` (blocking log reader) | yes, UAPI unchanged (`include/sdp/dek_ioctl.h`, `__DEKIOC` 0x77, nr 0..11) |
| `kek_pack.c` | per-engine key store (public keys from boot/user-added, private + symmetric keys between unlock and lock) | yes |
| `dek_aes.c` + `fs/crypto/sdp/sdp_crypto.c` | AES-256-GCM wrap of a DEK with the engine's symmetric key or an ECDH shared secret (AAD "PROTECTED_BY_SDP") | yes (GKI has gcm(aes), sha512 built in) |
| `pub_crypto_emul.c` | netlink **29**: the kernel asks a userspace crypto daemon for RSA/DH/ECDH operations (`PID_SET` 3001, `RESULT` 3002) | yes |
| `fs_handler.c` | netlink **28** `SDP_FS_HANDLER`: kernel-to-framework file events (set sensitive/protected, audit) | yes: the socket and both message types work; **nothing in a module ever sends a request** (the senders are the fs hooks below) |
| `dek_sysfs.c` | `/sys/class/misc/dek_req/asym_alg` (RSA/DH/ECDH, default ECDH) | yes |
| `cache_cleanup.c` | `sdp_page_cleanup()`: zero a "sensitive" page-cache page when it is freed | **no**: caller is mm/filemap.c, flag is `AS_SENSITIVE` on the address_space (core mm) |

    drivers612/samsung-oneui/build.sh drivers612/samsung-oneui/sdp     # -> out/sdp_dek.ko
    drivers612/samsung-oneui/sdp/qemu-test/run.sh

## 1. What cannot be a module (needs a GKI Image change)

`CONFIG_FSCRYPT_SDP=y` on 5.4 is 3.7k lines in `fs/crypto/sdp/` plus hooks in `fs/crypto/{crypto,
keysetup,policy}.c`, `fs/f2fs/{file,super}.c`, `fs/ext4/{ioctl,super}.c`, `fs/namei.c`, `fs/libfs.c`,
`fs/read_write.c`, `mm/filemap.c`, `include/linux/fscrypt.h`:

- the per-file ioctls on f2fs/ext4 files: `FS_IOC_GET_SDP_INFO` ('l',0x11), `FS_IOC_SET_SDP_POLICY`
  (0x12), `FS_IOC_SET_SENSITIVE` (0x15), `FS_IOC_SET_PROTECTED` (0x16), `FS_IOC_ADD_CHAMBER` (0x17),
  `FS_IOC_REMOVE_CHAMBER` (0x18). On GKI 6.12 f2fs answers them with ENOTTY;
- the "sensitive file" key handling itself: the file's fscrypt key wrapped by the engine's keys in an
  xattr, unwrapped in `fscrypt_get_encryption_info()` only while the engine is unlocked;
- dropping the page cache and dentries of sensitive files at lock
  (`fscrypt_sdp_cache_drop_inode_mappings()`, called from `DEK_ON_DEVICE_LOCKED` and
  `DEK_DISK_CACHE_CLEANUP`; in the module these two events still drop the keys / are accepted, the
  cache drop is a no-op because no file is ever marked sensitive);
- zeroing freed sensitive pages (`cache_cleanup.c`).

GKI has no vendor hook in fscrypt key setup or in the f2fs ioctl path, and f2fs/fscrypt are built into
the Image, so none of this can be added from outside. The S26 6.12 kernel does not have it either:
Samsung dropped legacy SDP there (no `security/sdp`, no `/dev/dek_evt`, no `/dev/dek_req`) and ships
DualDAR instead (`security/ddar`: `/dev/dek_log`, `/dev/dd`, netlink 28, `fs/crypto/fscrypt_ddar.c`
built into its GKI core). So the framework of this port is one that already runs on a kernel without
the SDP file ioctls.

Net effect with the module: everything that talks to the **driver** behaves as on 5.4 (nodes, labels,
ioctls, key wrap/unwrap, both netlink families); a file can not be made "sensitive" (per-file key that
disappears at lock). Data stays protected by normal FBE.

## 2. Who uses it in this ROM, and how it degrades

The port's framework is the S26 (SM-S948B) One UI 9 one. Samsung itself has emptied legacy SDP there:

- `services.jar` `com/android/server/knox/dar/sdp/SdpManagerImpl`: the `native*` declarations are left
  (`nativeOnBoot`, `nativeOnDeviceUnlocked`, ...) but no library implements them and nothing calls them;
  every Java method is empty or returns 0/null/false. `DarManagerService.isSdpSupported`,
  `isSDPEnabled`, `isSdpSupportedSecureFolder`, `isSensitive` return false, `addEngine` returns 0.
  No SDP engine is created for any user; Secure Folder / work profile creation has no SDP kernel call.
- No smali in services.jar, framework.jar or knoxsdk.jar and no binary in system/vendor names
  `/dev/dek_evt`, `/dev/dek_req`, `/dev/dek_kek`, `/dev/sdp_mm` or `/dev/sdp_dlp`. The `DEK_ON_*` ioctl
  users (`libsdp_kekm.so`, `libsdp_crypto`, `libsdp_sdk`) exist only in the old A528B firmware, not in
  the port. `init.container.rc` only chowns the nodes (fails quietly when they are absent).
- The port's `knox_kernel_compat` patch does not touch SDP (it preinstalls the root manager); `knoxpatch`
  forces three `DarManagerService` trust answers; `deknox` removes DualDAR (`dualdard`).

What is still alive is in **vold** (`libepm.so`, `EnterprisePartitionManager`):

| consumer | what it does | kernel absent (6.12 before this module) | with `sdp_dek.ko` |
|---|---|---|---|
| `FsHandlerThread` | `socket(AF_NETLINK, SOCK_RAW, 28)`, sends type 3001 (44 bytes, its pid at offset 12), then waits for kernel requests: opcodes 51..54 become Knox audit events, others are answered -95; replies are type 3002 (u32 req_id, u8 opcode, s16 ret) | EPROTONOSUPPORT: logs "Kernel doesn't not provide netlink socket for sdp", the thread ends. Nothing else depends on it | socket opens, the pid is recorded, the thread sits in poll for good: the requests it waits for come only from the fs hooks of section 1 |
| `EpmLog::runThread` | `stat("/dev/dek_log")`, then `fopen` + `fgets(1024)` in a loop, forwards the driver's log lines | stat fails: logs once, the thread ends | reads "Initialized" and then blocks |

So for this ROM the module restores the two things the parity run flags (`sec.node.dek_*`,
`knox.sdp_netlink`) and puts vold's two EPM threads back into their 5.4 state (blocked in read/poll
instead of ended). No user-visible feature of One UI 9 comes back with it, and none is lost
without it. `/dev/dek_evt`, `/dev/dek_req` and netlink 29 are complete and tested but have no caller
in the port; they matter only if an SDP userspace (the A528B `libsdp_*` set) were ever brought back,
and even then "sensitive" files would still need the Image-side fscrypt work.

One thing to watch on the first phone boot: vold restarts `FsHandlerThread::main()` in a loop without
a pause on any failure other than EPROTONOSUPPORT. With the protocol registered, a failing `sendto`
(e.g. an SELinux denial on vold's `netlink_socket`, which the port's policy allows: read write create
bind) would spin a vold thread. Look for vold CPU and "fs_handler setPid success" in logcat.
(These findings are from a static read of the smali and of `libepm.so`; vold itself was not run.)


## 3. Differences from the 5.4 sources (all marked "a52sxq 6.12" in the code)

- one `module_init` in `sdp_main.c` in the 5.4 link order instead of four built-in initcalls; real
  unwinding in `dek_init()`, and a module exit that deregisters the nodes, frees the log and zero-frees
  every key (`kek_pack_exit`);
- API renames: `kzfree` -> `kfree_sensitive`, `getnstimeofday` -> `ktime_get_real_ts64`,
  `crypto/sha.h` -> `crypto/sha2.h`, `fallthrough;`;
- `CONFIG_CRYPTO_FIPS` forced off inside `sdp_crypto.c` (5.4 A52s config: off), `CONFIG_FSCRYPT_SDP`
  and `CONFIG_SDP_KEY_DUMP` are not defined;
- netlink 28/29 receive: the message length is checked before the payload is read (5.4 reads
  `audit_status.pid` and the result struct whatever the length);
- netlink 28/29 send with no listener registered fails at once. 5.4 unicasts to portid 0, which is
  its own kernel socket, and (netlink 29) then waits out a 3 s timeout before failing the ioctl.
- `/dev/dek_log` read: a record is cut to the caller's buffer size (5.4 copies it whole), and a
  signal while waiting restarts the read (5.4 returns 0 bytes, which vold's `fgets` takes for EOF);
- `include/sdp/dek_common.h`: only the include path of `sdp_crypto.h`.

Unchanged on purpose, including the odd parts: `/dev/dek_evt` accepts only real uid 1000; a KEK of an
engine whose Android user id is 10..199 is only handed to a caller of that user (or root), so
system_server itself gets EACCES on `/dev/dek_req` for a container engine; netlink 28/29 take
`PID_SET` from any sender.

## 4. ROM side

Nothing to add. Already in the port:
- `system/init.container.rc`: `chown system system /dev/dek_evt` 0600, `chown system 8001
  /dev/dek_req` 0660 (also `/dev/dek_kek`, `/dev/sdp_dlp`, which no kernel here creates);
  `/dev/dek_log` is not touched there (stays root 0600, as on 5.4);
- `vendor/etc/selinux/vendor_file_contexts`: `/dev/dek_evt`, `/dev/dek_log` -> `knox_dar_device`,
  `/dev/dek_req` -> `knox_dar_shared_device` (by path: no genfscon needed).
The module has to be loaded before `on init` (first stage), so the nodes exist when the chown lines run.

Check on the phone (root): `ls -lZ /dev/dek_*`; `cat /sys/class/misc/dek_req/asym_alg` (ECDH);
`dmesg | grep -iE "dek|SDP_|KEK_PACK"`; the selftest lines `sec.node.dek_evt`, `sec.node.dek_req`,
`sec.node.dek_log`, `knox.sdp_netlink` (tools/selftest/oneui/checks/70-kernel.sh).

## 5. QEMU test

`qemu-test/run.sh` (bsp612 `out/dist/Image`, QEMU virt, `test/sdp_test`): without the module netlink
28 gives EPROTONOSUPPORT and `/dev/dek_evt` ENOENT; load; three misc nodes + `asym_alg` 0600 "ECDH";
`/dev/dek_log` returns "Initialized", "Added user"; `/dev/dek_evt` refuses uid 0 and an app uid;
netlink 28 socket + PID_SET + a RESULT for an unknown request; a netlink 29 daemon registers; as uid
1000: USER_ADDED, ON_BOOT; as an app of the engine's user: IS_KEK_AVAIL, GENERATE_DEK (32 bytes);
while locked ENCRYPT_DEK goes kernel -> netlink 29 daemon (ECDH shared secret) -> AES-GCM in the
kernel -> blob type 6 length 324, DECRYPT_DEK is refused (EIO); after DEVICE_UNLOCKED the blob
decrypts to the original DEK, ENCRYPT_DEK gives the symmetric form (type 2, 60 bytes) and it
round-trips, a flipped bit is refused (EBADMSG); DEVICE_LOCKED drops the keys again; caller of another
Android user gets EACCES; DISK_CACHE_CLEANUP, CHANGE_PASSWORD, USER_REMOVED, unknown ioctl; rmmod;
second insmod + rmmod; no WARN/BUG. PASS.

Not covered: the real framework and its daemon on netlink 29 (message timing, real ECDH), 32-bit
callers (the structs have no pointers or longs: same layout), SELinux, the phone.

## 6. Ramdisk fragment

One module, no dependencies, no parameters, any first-stage position (needs only GKI symbols):

    drivers612/samsung-oneui/sdp/out/sdp_dek.ko
    sha256 54775bbf9048e813eb7723b7d8692473ce81deaf7543089b44c8315b4b38c949
    vermagic 6.12.81-4k-g8a69376da734, debug + BTF stripped, 115192 bytes

Stage list line: `sdp_dek.ko` (e.g. at the end of stage `vibrator`, after `freecess.ko`:
`rd-add-ko.py IN OUT vibrator drivers612/samsung-oneui/sdp/out/sdp_dek.ko`).
