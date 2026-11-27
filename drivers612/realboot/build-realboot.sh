#!/bin/bash
# Builds the REAL boot path for a daily-driven Android 17 ROM (LineageOS, IchthysOS, the One UI 9 port) on the Qualcomm 6.12
# kernel or on the 6.18 port (ACK android17-6.18 + the forward-ported BSP), for test phone 2
# (PHONE2, LineageOS, bit-2 bootloader). BUILDS ONLY: nothing is flashed, no phone is
# touched. README.md has the install plan, CHECKLIST.md what hardware must still prove.
#
#   ./build-realboot.sh [name]               6.12 (default name rb-612) -> out/<name>/
#   KERNEL=618 ./build-realboot.sh [name]    6.18 (default name rb-618)
#
# Output (out/<name>/):
#   boot.img         header v3: GKI Image + the ROM's generic ramdisk (byte for byte),
#                    os_version/os_patch_level of the ROM's boot.img (Keymaster binds keys to
#                    them), unsigned AVB hash footer like the ROM's, padded to the partition
#   vendor_boot.img  header v3: merged board dtb, vendor cmdline, vendor ramdisk = the ROM's
#                    (fstab only) + /lib/modules (first-stage modules, modules.load/dep/...) +
#                    /force_debuggable + /adb_debug.prop (ro.bpf.kver_override only)
#   dtbo.img         one minimal overlay entry (board-id <0x22 2>) for the ABL
#   vendor-addon/    files for the vendor partition: lib/modules/6.<x> (audio, loaded after the
#                    ADSP runs), the wlan.ko for macloader's path lib/modules/5.4-gki/qca_cld3_wlan.ko
#                    (6.12: in 5.4-gki itself; 6.18: in lib/modules/6.18-wlan, which its rc binds over
#                    5.4-gki, so the 6.12 copy there stays), etc/init/a52sxq-k6<x>.rc
#   rollback/        sha256 of the phone's own boot/vendor_boot/dtbo dumps (the way back)
#   info/            avbtool info_image + unpack_bootimg dumps of the three images, dtbo table
#   REPORT.txt       every check, the module plan, the predicted command line, BLOCKERS
#
# The two kernels (everything else is shared):
#   KERNEL=612  Image/modules bsp612/out/dist (6.12.81, COMMAND_LINE_SIZE 4096 since 14:23),
#               modules byte for byte from drivers612/androidboot/out/<REF>-rd.cpio.gz (REF=s76 =
#               s74 + the bsp612/patches/soc-repo/0009 geni modules + stage kgsl with the GPU devfreq
#               governors + stage dcvs (bwmon, memlat), run ab-s76), tree = out-ack/kx/android-r02.dtb
#               rebuilt from its inputs; + drivers612/busdcvs (SCMI dt-fix, bus tunables in the vendor rc)
#   KERNEL=618  Image/modules bsp618/android/out/dist (6.18.33-4k-g00c8666046c2-dirty; ack/ has
#               COMMAND_LINE_SIZE 4096 already), modules from bsp618/android/out/<REF>-rd.cpio.gz
#               (REF=a10 = a9 (a8 + the 0009 geni modules) + the GPU governors in stage kgsl + stage dcvs
#               (bwmon, memlat): bsp618/android/mkrd-dcvs-618.sh, the 6.18 s76/s77), tree =
#               bsp618/android/out/android-r02-618.dtb (since 2026-11-15 from the busdcvs-fixed 6.12 tree)
#               WITHOUT its kexec-only a52ram earlycon reservation (dwc3 qcom,iommu-faults non-fatal
#               stays, as tested; SMMU_NONFATAL=0 drops it), DT bootargs + sched_proxy_exec=0 (as tested)
#   Both kernels get the same MODEM=1, SDCARD=1, bus/GPU DCVS and sync_state handling; what differs
#   is only the inputs (6.18 modem pack drivers612/modem/out-618/pack-modem-618-txfix.tgz, 6.18
#   dev_ril_bridge.ko) and the Wi-Fi path (6.18 binds its own wlan dir over 5.4-gki, below).
# Kexec artefacts that are never in a real boot: /reserved-memory/a52ram@f0be0000 + earlycon=,
# kexec/mkkexecdtb.py's memory/hypervisor/uh/watchdog/timer copies and the live rmtfs carry-over
# (the ABL and the hypervisor patch the real ones in), a52.* arguments, test modules.
#
# Environment:
#   DUMP=<dir>        partition dumps of the phone (default ../../testdev-PHONE2): boot.img,
#                     vendor_boot.img, dtbo.img, live.dtb (/sys/firmware/fdt of its 5.4 boot)
#   KERNEL=612|618    which kernel (default 612; an Image path here still means 612 + IMAGE=)
#   REF=<name>        tested kexec ramdisk whose modules are used (612: s76 of run ab-s76 = s74 +
#                     0009 i2c-msm-geni/msm_geni_serial + kgsl governors + dcvs stage; s77 = s76 + the
#                     busdcvs post script, same modules; 618: a9 = a8 of runs ab618-a8/a8e + the
#                     0009 modules). The 612 build needs the dcvs stage. The tree is in
#                     the 5.4 sysfs layout (research/sepolicy/PATHS.md): the build fails if a geni
#                     module of the plan lacks 0009.
#   IMAGE=<Image>     default: the dist Image of that kernel (the kernel of those runs)
#   SELINUX=enforcing (default: nothing on the cmdline, as the ROM) | permissive
#   USB_EXTCON=samsung (default, the phone's tree: dwc3 waits for the Samsung extcon of the
#                     power stack) | eud (test edit of kexec/mkfulltree.sh: EUD only)
#   MODEM=0           (default) modem remoteproc disabled in the tree, as in all real-boot test runs
#   MODEM=1           (both kernels; the phone's OWN modem, phone 1 PHONE1: rb12) cellular for the
#                     ROM's own radio userspace (rmt_storage, tftp_server, pd-mapper, qrtr-ns,
#                     pm-service, ipacm, Samsung rild): the modem/data modules of the kernel-only
#                     runs that brought LTE data up on 6.12 (drivers612/modem, kx-m2data3 =
#                     MODEM_PACK's m/ files byte for byte, minus the test-only a52_modem_guard) +
#                     dev_ril_bridge.ko, appended to the FIRST STAGE after wlanb (/dev/ipa must exist
#                     before ipa_fws.rc's early-boot write, /dev/uio "rmtfs" before rmt_storage, the
#                     ROM's own 5.4 rmnet loader paths load nothing on 6.x); msm_sharedmem leaves the
#                     blocklist; tree = drivers612/modem/dt/mkmodemtree.sh (modem_pas okay, memshare
#                     client_4 off, IPA IOVA fix dt/ipa-iova-fix.sh), modem subtrees checked against the
#                     run's kexec tree MODEM_TESTED_DTB; firmware_class.path gains
#                     /vendor/firmware-modem/image (modem.mdt directly, not via ueventd's fallback);
#                     ueventd owners of the new /dev nodes checked against the ROM's ueventd.rc and
#                     the 5.4 /dev listing (tools/ueventd-check.py -> modem-devnodes.txt).
#                     6.18: MODEM_PACK = out-618/pack-modem-618-txfix.tgz (the pack of run kx-m2k618 with
#                     the 6.18 ipam.ko of patch 0002, drivers612/modem/mk-txfix-pack.sh), dev_ril_bridge
#                     = the bsp618 port build (stripped); the modem subtrees are checked against the 6.12
#                     data run's tree AND the 6.18 modem run's tree (MODEM_TESTED_DTB2)
#   SDCARD=1          (default, both kernels) cqhci + sdhci-msm (soc-repo modules, not built in) in the
#                     first stage after the camera stage; SDCARD=0 keeps them out and blocklisted
#   IGNORE_UNUSED=1   (default) keep clk/pd/regulator_ignore_unused (every test ran with them)
#   MODULE_FAILURES=ignore (default: androidboot.first_stage_console=2, a first-stage module
#                     that fails is logged and skipped) | fatal (AOSP default: reboot loop)
#   EXTRA_CMDLINE=    appended to the vendor_boot command line
#   ADDON=vendor      (default on 6.18; 6.12 default is vendor_boot since 2026-11-19) the audio set, the wlan.ko and the rc live in the vendor add-on (written
#                     into /vendor from a 5.4 boot or TWRP)
#   ADDON=vendor_boot (2026-11-17) ROM-independent: NOTHING on /vendor. The audio set and wlan.ko are
#                     appended to the FIRST stage (vendor_boot /lib/modules, loaded by the ROM's own
#                     first-stage init, before any SELinux policy); a52sxq_dsp_boot attaches the audio
#                     devices again once the ADSP runs (rescan_after_adsp=1) and writes the bus DCVS
#                     tunables itself (built-in table from busdcvs.conf) at the WALT boost release,
#                     through kernfs + the attribute's store() (no VFS: under enforcing SELinux a
#                     kernel_write() from the kworker is denied, rb28 2026-11-17). Needs REF >= s84
#                     (pinctrl_lpi_dlkm defers until its hw-vote clock is bound, else no card).
#                     Wi-Fi: icnss2 probes the already-loaded wlan driver only at FW ready, i.e. after
#                     macloader wrote /sys/wifi/mac_addr and then wpss_boot, so the MAC is the EFS one;
#                     macloader's own finit_module() of /vendor/lib/modules/5.4-gki/... then fails
#                     harmlessly (5.4 vermagic, or EEXIST). The gate property is ro.boot.a52sxq.<kt>vb,
#                     so an old add-on rc left on /vendor stays inert. No vendor-addon/ output.
#   SYNC_STATE_ARGS   bootargs that let interconnect/clk providers sync_state after a timeout (bus DCVS floor;
#                     default "fw_devlink.sync_state=timeout deferred_probe_timeout=30", empty = off; both
#                     kernels parse both: drivers/base/core.c fw_devlink_sync_state_setup, dd.c)
#   DIAG=1            6.18: only DIAG_BOOTARGS on the DT bootargs (no 6.18 a52bc kernel exists, so no
#                     breadcrumbs/RAM console and no a52ram node; the pstore console is the log).
#                     6.12: instrumented build for a real-boot attempt that may fail early
#                     (rb6, after rb4/rb5 died before ramoops in a watchdog-bite loop):
#                     IMAGE defaults to bsp612/out/diag/Image (kernel-diag/build-diag-kernel.sh:
#                     same release/CRCs + a52bc breadcrumbs and RAM console at 0xf0be0000), the
#                     tree gets /reserved-memory/a52ram@f0be0000 ("a52,ramcon", no-map: what the
#                     6.18 harness prints as /proc/a52ram), the DT bootargs get DIAG_BOOTARGS
#                     (default: keep_bootcon initcall_debug ignore_loglevel softlockup_panic=1).
#                     DIAG_WDT=off adds a52bc.wdt=off (disable the hypervisor watchdog at the
#                     param stage; default: observe only). kernel-diag/README.md: how to read it.
#   BTSLIM=1          (6.12 default since 2026-11-19; 0 = off) slimbus + slim-qcom-ngd-ctrl + bt_fm_slim in the first stage after stage wlanb
#                     (Bluetooth audio over SLIMbus; modules only, see the comment at the option)
#   WDT=1 QRNG=1 HALL=1 VOLKEY=1 BWCOMPAT=1 ADSPFAC=1 THERMAL_X="adctm secth qmi bclmap"
#   ADSPFAC_KO=<file>  (default drivers612/sensors-factory/adsp_factory_dlkm.ko) the adsp_factory build ADSPFAC=1 installs
#                     (2026-11-19, all default off until proven) parity items: see the comments at the options
#   SOCSTATS=1 NTFS3=1 USBACC=1 ZRAM_LZ4=1 (2026-11-24, default off) qcom_stats / ntfs3 / USB Ethernet set in the first
#                     stage, zram.ko with lz4 as the default compressor: see the comments at the options
#   USERSPACE=samsung|aosp (default auto = nothing on the cmdline) a52sxq.userspace= on the vendor cmdline (a52sxq.ko)
#   A52SXQ_FIRST=1    (default 0 = the REF's position) a52sxq.ko (userspace switch, no depends) moved to line 1 of
#                     modules.load; nothing else changes order. The switch-order gate (tools/us-order-check.py) runs always.
#   WALT=1            (default 0 = no change) cpufreq governor walt + the 5.4 post_boot governor tunables
#                     (vendor-addon/a52sxq-walt.conf, SPEC/08): ADDON=vendor_boot: appended to a52sxq_dsp_boot's
#                     built-in table (applied at the WALT boost release, probe + 45 s) + a 300 s guard that puts walt
#                     back if the ROM's post_boot wrote schedutil after it; /proc/sys/walt stays at the WALT
#                     defaults (not writable from init or the table; measured equal); ADDON=vendor: rc fragment
#                     a52sxq-walt.rc.in on vendor.post_boot.parsed (switch persist.vendor.a52sxq.walt_gov)
#   HOLD_MS=<ms>      (default unset = the module's 4000) a52sxq_dsp_boot hold_release_ms: ms after adsp_running until the
#                     held audio tree is released (boot time: the sound card and audioserver come up that much later)
#   ASYNC_MODS="m ..." (default none) async_probe=1 for these first-stage modules (boot time)
#   STRIP_BTF=1       (default 0) no .BTF in the unsigned first-stage modules (boot time; see the option)
#   ASYNC_LAST="m ..." (default none) async_probe=1 + moved to the end of modules.load (boot time; see the option)
#   MODLOAD=parallel  (default unset = sequential; also performance|conservative) first-stage init loads the
#                     vendor_boot modules in parallel (bootconfig trailer on the boot ramdisk, see the option);
#                     MODLOAD_SEQ="m ..." = load_sequential=1 for those modules
#   UFS_POLL_MS=<ms>  (default unset = 60) UFS devfreq polling interval, set with the dsp_boot tunables at the boost release
#   UFS_QOS=0         (default unset = 1) ufshcd core CPU latency QoS off (pm_qos_enable 0 at the boost release): upstream
#                     6.12 votes CPU_DMA_LATENCY 0 (WFI only, every CPU) while UFS is scaled up; 5.4 has no such vote
#   UFS_WB=always     (default unset; REF >= s99n) WriteBooster on from probe instead of only while UFS is scaled up
#   UFS_CLKSCALE=0    (default unset = 1) UFS clock scaling off (clkscale_enable 0 at the boost release, after UFS_QOS):
#                     HS-G4 + WriteBooster stay on (6.12 ties WB to the scaled-up state; 5.4's Samsung WB policy did not)
#   ICE_RAW=1         (default 0; REF >= s99i) /data encryption in the ICE for standard keys (no blk-crypto-fallback)
#   LPM=1             (default 0) cpuidle governor qcom-cpu-lpm (WALT busy hysteresis, as 5.4 lpm-levels): see the option
#   GPU_BUSY_UP=<pct> (default unset; REF >= s97) adreno_tz governor steps up one level when >= pct busy (b5)
#   KSU_BUILTIN=1     (default 0; SUSFS=1 is the same switch; 6.12 + DIAG=1 only) the OneUI 9 Image variant with
#                     ReSukiSU 8770c7e3 BUILT IN + SUSFS v2.3.0 (modules/resukisu/build-susfs-image.sh ->
#                     bsp612/out/susfs/Image, same release and export CRCs, with a52bc). IMAGE defaults to it.
#                     Excludes KSU=1: no /ksuinit, no kernelsu.ko, no rdinit= (see modules/resukisu/SUSFS.md)
#   KSU=1             (default 0) KernelSU-Next LKM: /ksuinit + /kernelsu.ko in the vendor ramdisk, rdinit=/ksuinit
#                     (KSU_DIR=<dir> default modules/kernelsu/out); see the comment at the option
#   USBAUDIO=1        (default 0) snd-usb-audio-qmi in the first stage after stage wlanb (USB audio offload)
#   DIST_OVERRIDE=<dir> thermal modules found there replace the out/dist ones (soc-repo audit modules)
#   DEBUG=1           (default 0) adds androidboot.a52sxq.debug=1 to the vendor_boot command line:
#                     a52sxq_dsp_boot then creates /sys/devices/system/cpu/a52kmsg, the kernel log
#                     for root/system/shell on user builds (no dmesg there). Off by default since
#                     the 2026-11-18 audit: every SELinux domain can open files in that directory.
#                     Never for a release or a daily-phone build. Independent of DIAG.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
KSER=${KERNEL:-612}
case "$KSER" in 612|618) ;; *) [ -f "$KSER" ] && { IMAGE=$KSER; KSER=612; } || { echo "KERNEL=612|618" >&2; exit 2; };; esac
NAME=${1:-rb-$KSER}
DUMP=$(cd "${DUMP:-$TOP/testdev-PHONE2}" && pwd)
PB=${ANDROID_TREE:-$HOME/android}/prebuilts
SYNC_ARGS="${SYNC_STATE_ARGS-fw_devlink.sync_state=timeout deferred_probe_timeout=30}"
if [ "$KSER" = 612 ]; then
	KV=6.12; KT=k612; KDESC="Qualcomm 6.12 (GKI 6.12.81 + r70 BSP)"
	REF=${REF:-s95}; REFRD=$TOP/drivers612/androidboot/out/$REF-rd.cpio.gz
	# 6.12 defaults since 2026-11-19 (each proven on white cable: rb50..rb56): the kernel-only layout, Bluetooth
	# SLIMbus audio, the thermal cooling stack, the audit builds of the dist thermal modules. DEBUG/DIAG stay opt-in.
	ADDON=${ADDON:-vendor_boot}; BTSLIM=${BTSLIM:-1}; THERMAL=${THERMAL:-1}
	[ -n "${DIST_OVERRIDE+x}" ] || { [ -d "$TOP/bsp612/out/audit-soc-modules" ] && DIST_OVERRIDE=$TOP/bsp612/out/audit-soc-modules; }
	BSP=$TOP/bsp612; DIST=$BSP/out/dist; KCONFIG=$BSP/out/lahaina/.config
	SYMVERS=$BSP/out/gki/Module.symvers
	CLANG=$PB/clang/host/linux-x86/clang-r547379/bin
	KMAKE=(make -s -C "$BSP/kernel" ARCH=arm64 LLVM="$CLANG/" O="$BSP/out/lahaina" KCONFIG_EXT_PREFIX="$BSP/soc-repo/")
	DSPBOOT_KBUILD=$HERE/modules/dspboot/Kbuild
	TREF=$TOP/out-ack/kx/android-r02.dtb   # kexec/mkandroidtree.sh output = KEXEC_BASE of run ab-s74
	KEXEC_ONLY_NODES=""; EXTRA_BOOTARGS="$SYNC_ARGS"; SMMU_NONFATAL=0
	TESTED_CMDLINE_FILE=$TOP/drivers612/androidboot/out/android-cmdline.txt
	DIAG_KERNEL=1   # DIAG=1 uses the a52bc Image (kernel-diag/)
	# Wi-Fi: wlan.ko sits in the ROM's fixed macloader path /vendor/lib/modules/5.4-gki itself
	WLD=5.4-gki
	MODEM_PACK_DEF=$TOP/drivers612/modem/out/pack-modem-audit2.tgz   # rb51+: txfix pack + audit ipam/ipanetm/rmnet_shs + glink_pkt 0013
	MODEM_DRB_DEF=$TOP/drivers612/modem/out/stage-radio/dev_ril_bridge.ko
	MODEM_TESTED_DTB2_DEF=
else
	KV=6.18; KT=k618; KDESC="ACK android17-6.18 (6.18.33 + forward-ported r70 BSP, bsp618)"
	REF=${REF:-a10}; REFRD=$TOP/bsp618/android/out/$REF-rd.cpio.gz
	BSP=$TOP/bsp618; DIST=$BSP/android/out/dist; KCONFIG=$DIST/gki.config
	SYMVERS=$BSP/out-survey/gki/Module.symvers
	CLANG=$PB/clang/host/linux-x86/clang-r596125/bin
	RUSTBIN=$HOME/.rustup/toolchains/1.91.1-x86_64-unknown-linux-gnu/bin
	export LIBCLANG_PATH=$PB/clang/host/linux-x86/clang-r584948b/lib
	# the make line of bsp618/build-survey.sh (the port's "extra" build of this same module)
	KMAKE=(make -s -C "$TOP/ack" ARCH=arm64 LLVM="$CLANG/" RUSTC="$RUSTBIN/rustc" HOSTRUSTC="$RUSTBIN/rustc"
		BINDGEN=$PB/clang-tools/linux-x86/bin/bindgen O="$BSP/out-survey/lahaina" KCONFIG_EXT_PREFIX="$BSP/src/bsp612/soc-repo/")
	DSPBOOT_KBUILD=$BSP/src/drivers612/realboot/modules/dspboot/Kbuild   # + -Wno-error=missing-prototypes
	TREF=$BSP/android/out/android-r02-618.dtb  # bsp618/android/mkdtb-618.sh = KEXEC_BASE of ab618-a8
	# kexec-only: earlycon=a52ram ring (the Samsung ABL strips earlycon= on a real boot anyway)
	KEXEC_ONLY_NODES="/reserved-memory/a52ram@f0be0000"
	# ACK 6.18 has proxy execution on by default, 6.12 had it off (bsp618/PORT-STATUS.md)
	EXTRA_BOOTARGS="sched_proxy_exec=0${SYNC_ARGS:+ $SYNC_ARGS}"; SMMU_NONFATAL=${SMMU_NONFATAL:-1}
	TESTED_CMDLINE_FILE=$BSP/android/android-cmdline-618.txt
	DIAG_KERNEL=0   # no 6.18 a52bc kernel: DIAG=1 = DIAG_BOOTARGS only
	# Wi-Fi: macloader's path /vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko holds ONE 6.x wlan.ko and the
	# phones carry the 6.12 one there. The 6.18 add-on keeps its own copy in /vendor/lib/modules/6.18-wlan
	# (same files as a 5.4-gki dir) and its rc bind-mounts that dir over 5.4-gki on post-fs (before
	# macloader, post-fs-data); 6.12 and 5.4 never see the bind. README.md section 2g, vendor-addon/wlan-bind.rc.in.
	WLD=$KV-wlan
	MODEM_PACK_DEF=$TOP/drivers612/modem/out-618/pack-modem-618-txfix.tgz   # kx-m2k618 pack + 6.18 ipam with 0002
	MODEM_DRB_DEF=$BSP/src/drivers612/conn/rild/drb/dev_ril_bridge.ko         # bsp618 port build (stripped below)
	MODEM_TESTED_DTB2_DEF=$TOP/logs/kx-m2k618-p1-p1-194536/kexec.dtb          # the 6.18 modem run (modem up, no data call)
fi
KSU_BUILTIN=${KSU_BUILTIN:-${SUSFS:-0}}; case "$KSU_BUILTIN" in 0|1) ;; *) echo "KSU_BUILTIN=0|1" >&2; exit 2;; esac
if [ "$KSU_BUILTIN" = 1 ]; then
	[ "$KSER" = 612 ] && [ "${DIAG:-0}" = 1 ] || { echo "KSU_BUILTIN=1 needs KERNEL=612 DIAG=1 (the variant is an a52bc Image)" >&2; exit 2; }
	[ "${KSU:-0}" = 0 ] || { echo "KSU_BUILTIN=1 excludes KSU=1 (KernelSU is in the Image: no /ksuinit, no kernelsu.ko)" >&2; exit 2; }
	IMAGE=${IMAGE:-$BSP/out/susfs/Image}
fi
DIAG=${DIAG:-0}
DEBUG=${DEBUG:-0}; case "$DEBUG" in 0|1) ;; *) echo "DEBUG=0|1" >&2; exit 2;; esac
SYSMAP=$DIST/System.map
if [ "$DIAG" = 1 ]; then
	if [ "$DIAG_KERNEL" = 1 ]; then IMAGE=${IMAGE:-$BSP/out/diag/Image}; SYSMAP=$(dirname "$IMAGE")/System.map; fi
	DIAG_BOOTARGS=${DIAG_BOOTARGS:-keep_bootcon initcall_debug ignore_loglevel softlockup_panic=1}
	# DIAG_BOOTARGS=none: the DIAG Image (the only proven 6.12 Image) + its RAM console node, but no debug words
	[ "$DIAG_BOOTARGS" = none ] && DIAG_BOOTARGS=
	[ "${DIAG_WDT:-}" = off ] && { [ "$DIAG_KERNEL" = 1 ] || { echo "DIAG_WDT=off needs the a52bc kernel (6.12)" >&2; exit 2; }; DIAG_BOOTARGS="$DIAG_BOOTARGS a52bc.wdt=off"; }
fi
[ "$DIAG" = 1 ] && [ "$DIAG_KERNEL" = 1 ] || DIAG_KERNEL=0
IMAGE=${IMAGE:-$DIST/Image}
BUSDCVS_CONF=$TOP/drivers612/busdcvs/busdcvs.conf
ADDON=${ADDON:-vendor}; case "$ADDON" in vendor|vendor_boot) ;; *) echo "ADDON=vendor|vendor_boot" >&2; exit 2;; esac
# HOLD_MS: a non-number would be a module parameter error = a52sxq_dsp_boot fails to load = FATAL first stage
if [ -n "${HOLD_MS:-}" ]; then case "$HOLD_MS" in *[!0-9]*) echo "HOLD_MS: digits only (ms, 0..10000)" >&2; exit 2;; esac
	[ "$HOLD_MS" -le 10000 ] || { echo "HOLD_MS: 0..10000 ms" >&2; exit 2; }; fi
SELINUX=${SELINUX:-enforcing}; USB_EXTCON=${USB_EXTCON:-samsung}; MODEM=${MODEM:-0}
case "$MODEM" in 0|1) ;; *) echo "MODEM=0|1" >&2; exit 2;; esac
# SDCARD=1 (default since 2026-11-15, both kernels): microSD host (cqhci + sdhci-msm), proven read-only
# kernel-only on 6.12 (run sdprobe-p1: mmcblk1 detected), rb16 on phone 1. The inserted card must never
# be formatted: vold only mounts it.
SDCARD=${SDCARD:-1}; case "$SDCARD" in 0|1) ;; *) echo "SDCARD=0|1" >&2; exit 2;; esac
if [ "$MODEM" = 1 ]; then
	MODEM_PACK=${MODEM_PACK:-$MODEM_PACK_DEF}         # pack of the kernel-only modem runs (modem.list + m/)
	MODEM_DRB=${MODEM_DRB:-$MODEM_DRB_DEF}
	MODEM_TESTED_DTB=${MODEM_TESTED_DTB:-$TOP/logs/kx-m2data3-p1-p1-103254/kexec.dtb}   # the tree of the 6.12 LTE data run (kernel-independent DT)
	MODEM_TESTED_DTB2=${MODEM_TESTED_DTB2-$MODEM_TESTED_DTB2_DEF}
	AND=${ANDROID_TREE:-$HOME/android}
	ROM_UEVENTD=${ROM_UEVENTD:-$AND/device/samsung/sm7325-common/init/ueventd.qcom.rc}   # = the ROM's /vendor/etc/ueventd.rc
	SYS_UEVENTD=${SYS_UEVENTD:-$AND/system/core/rootdir/ueventd.rc}
	ROM_CONFIGFS=${ROM_CONFIGFS:-$AND/device/samsung/sm7325-common/config.fs}
	AID_HEADER=${AID_HEADER:-$AND/system/core/libcutils/include/private/android_filesystem_config.h}
	DEV54=${DEV54:-$TOP/research/blob-uapi-evidence/dev_lZ.txt}                 # ls -lZ /dev of a 5.4 boot
fi
IGNORE_UNUSED=${IGNORE_UNUSED:-1}
MKDTBOIMG=${ANDROID_TREE:-$HOME/android}/system/libufdt/utils/src/mkdtboimg.py
BOOT_PART=100663296; VENDOR_BOOT_PART=100663296; DTBO_PART=25165824   # BoardConfigCommon.mk
O=$HERE/out/$NAME; W=$O/work
rm -rf "$O"; mkdir -p "$W" "$O/rollback"
R=$O/REPORT.txt; : > "$R"
say() { echo "$*" | tee -a "$R"; }
fail() { echo "CHECK FAILED: $*" | tee -a "$R" >&2; exit 1; }
BLOCKERS=(); blocker() { BLOCKERS+=("$*"); say "BLOCKER: $*"; }
for t in unpack_bootimg mkbootimg avbtool fdtget fdtput fdtoverlay dtc lz4 depmod modinfo python3 cpio; do
	command -v $t >/dev/null || fail "tool $t missing"; done
[ -f "$REFRD" ] || fail "no tested ramdisk $REFRD"
for f in boot.img vendor_boot.img dtbo.img live.dtb; do [ -f "$DUMP/$f" ] || fail "no $DUMP/$f"; done
if [ "$MODEM" = 1 ]; then for f in "$MODEM_PACK" "$MODEM_DRB" "$MODEM_TESTED_DTB" "$ROM_UEVENTD" "$SYS_UEVENTD" "$ROM_CONFIGFS" "$AID_HEADER" "$DEV54"; do
	[ -f "$f" ] || fail "MODEM=1: missing $f"; done
	[ -z "$MODEM_TESTED_DTB2" ] || [ -f "$MODEM_TESTED_DTB2" ] || fail "MODEM=1: missing $MODEM_TESTED_DTB2"; fi
say "realboot $NAME ($KV), $(date '+%F %T'); NOT FLASHED. dump=$DUMP ref=$REFRD image=$IMAGE"
say "options: SELINUX=$SELINUX USB_EXTCON=$USB_EXTCON MODEM=$MODEM SDCARD=$SDCARD IGNORE_UNUSED=$IGNORE_UNUSED DEBUG=$DEBUG DIAG=$DIAG${DIAG_BOOTARGS:+ ($DIAG_BOOTARGS)}$( [ "$DIAG" = 1 ] && [ "$DIAG_KERNEL" = 0 ] && echo ' [bootargs only: no a52bc kernel for this kernel]')"

# ---------------------------------------------------------------- 1. the phone's images
say "== 1. phone images ($DUMP)"
for i in boot vendor_boot dtbo; do sha256sum "$DUMP/$i.img" | sed "s|$DUMP/||" >> "$O/rollback/SHA256SUMS"; done
cp "$O/rollback/SHA256SUMS" "$O/rollback/SHA256SUMS.phone-dumps"
unpack_bootimg --boot_img "$DUMP/boot.img" --out "$W/b" --format mkbootimg > "$W/b.args"
unpack_bootimg --boot_img "$DUMP/vendor_boot.img" --out "$W/vb" --format mkbootimg > "$W/vb.args"
unpack_bootimg --boot_img "$DUMP/boot.img" --out "$W/b" > "$W/b.info"
unpack_bootimg --boot_img "$DUMP/vendor_boot.img" --out "$W/vb" > "$W/vb.info"
grep -q '^boot image header version: 3$' "$W/b.info" || fail "boot.img is not header v3"
grep -q '^vendor boot image header version: 3$' "$W/vb.info" || fail "vendor_boot.img is not header v3"
OSV=$(sed -n 's/^os version: //p' "$W/b.info"); OSP=$(sed -n 's/^os patch level: //p' "$W/b.info")
[ -n "$OSV" ] && [ -n "$OSP" ] || fail "no os version/patch level in boot.img"
STOCK_VC=$(sed -n 's/^vendor command line args: //p' "$W/vb.info"); printf '%s\n' "$STOCK_VC" > "$W/stock-vendor-cmdline.txt"
# A boot.img cmdline (OneUI 9 port: Samsung-style images carry the stock 5.4 words there too) is DROPPED (2026-11-22):
# the ABL builds the v3 cmdline as vendor_boot cmdline + " " + boot cmdline (donors/abl-edk2 QcomModulePkg/Library/
# BootLib/BootLinux.c CatCmdLine), so the ROM's 5.4 words would come AFTER ours and win (the one-entry firmware search
# path, swiotlb=0, lpm_levels, video=vfb...). Our boot.img always has an empty one (mkbootimg --cmdline ''), as on every
# LineageOS/IchthysOS boot; a52boot mkboot blanks it the same way; the OS version / patch level are kept.
BOOT_CMDLINE=$(sed -n 's/^command line args: //p' "$W/b.info")
if [ -n "$BOOT_CMDLINE" ]; then printf '%s\n' "$BOOT_CMDLINE" > "$W/rom-boot-cmdline.txt"
	say "boot.img of the ROM has a cmdline ($(echo "$BOOT_CMDLINE" | wc -w) words): DROPPED in our boot.img (the ABL appends it after the vendor cmdline, it would override our words): $W/rom-boot-cmdline.txt"; fi
VB_ARGS=$(sed -e "s/--vendor_cmdline '[^']*'//" -e 's/--dtb [^ ]*//' -e 's/--vendor_ramdisk [^ ]*//' "$W/vb.args")
say "boot: header v3, os $OSV / $OSP, cmdline $([ -n "$BOOT_CMDLINE" ] && echo dropped || echo empty); vendor_boot: $VB_ARGS"
# control: the packer arguments must rebuild the ROM's own images bit for bit
eval mkbootimg $(cat "$W/b.args") -o "$W/ctl-boot.img"
eval mkbootimg $(cat "$W/vb.args") --vendor_boot "$W/ctl-vendor_boot.img"
cmp -s "$W/ctl-boot.img" <(head -c "$(stat -c %s "$W/ctl-boot.img")" "$DUMP/boot.img") || fail "control repack of boot.img differs"
cmp -s "$W/ctl-vendor_boot.img" <(head -c "$(stat -c %s "$W/ctl-vendor_boot.img")" "$DUMP/vendor_boot.img") || fail "control repack of vendor_boot.img differs"
say "control: ROM boot.img and vendor_boot.img rebuilt byte-identical with these arguments"
# AVB footers of the ROM: unsigned (Algorithm NONE), verification is off in vbmeta (flags 3)
avbtool info_image --image "$DUMP/vbmeta.img" > "$W/vbmeta.info" 2>/dev/null || true
VBF=$(sed -n 's/^Flags: *//p' "$W/vbmeta.info" | head -1)
say "vbmeta flags: ${VBF:-unknown} (3 = verification + hashtree disabled: boot/vendor_boot/dtbo digests are not checked)"
[ "$VBF" = 3 ] || blocker "vbmeta flags are not 3: new boot/vendor_boot/dtbo would need a new vbmeta"
# Zero padding between the image content and its AVB footer, as the ROM has it (OneUI 9 port: UN1CA leaves 16 zero
# bytes after boot.img because this ABL refuses an image whose vbmeta follows the content directly): content size =
# the control repack (boot, vendor_boot) or the dt_table total_size (dtbo); pad = "Original image size" - content.
declare -A AVBPAD
for p in boot vendor_boot dtbo; do
	case $p in boot|vendor_boot) c=$(stat -c %s "$W/ctl-$p.img");; dtbo) c=$(od -An -tu4 --endian=big -j4 -N4 "$DUMP/dtbo.img" | tr -d ' ');; esac
	o=$(avbtool info_image --image "$DUMP/$p.img" | sed -n 's/^Original image size: *\([0-9]*\) bytes/\1/p')
	pad=$(( o - c )); [ "$pad" -ge 0 ] && [ "$pad" -lt 4096 ] || fail "$p: AVB original size $o vs content $c"
	python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(int(sys.argv[2])+int(sys.argv[3])); sys.exit(0 if not any(d[int(sys.argv[2]):]) else 1)' "$DUMP/$p.img" "$c" "$pad" || fail "$p: bytes between content and footer are not zero"
	AVBPAD[$p]=$pad; [ "$pad" = 0 ] || say "$p: the ROM image has $pad zero bytes before its AVB footer: ours get the same"
done
footer() {   # <part> <img> <size>: hash footer with the ROM's salt, props, padding (and key, if the ROM's is signed)
	local p=$1 img=$2 size=$3 info salt props=()
	info=$(avbtool info_image --image "$DUMP/$p.img")
	[ "${AVBPAD[$p]:-0}" = 0 ] || truncate -s +"${AVBPAD[$p]}" "$img"
	local sign=()
	if ! echo "$info" | grep -q 'Algorithm: *NONE'; then
		# signed ROM footer (OneUI 9 port: UN1CA signs boot/vendor_boot/dtbo with AOSP's public testkey_rsa4096): sign
		# ours the same way, only if the dump's public key IS that key (AVB_KEY=<pem> to name another)
		echo "$info" | grep -q 'Algorithm: *SHA256_RSA4096' || fail "$p dump footer: unknown algorithm"
		local key=${AVB_KEY:-$HOME/git/MonsterROM/security/avb/testkey_rsa4096.pem}
		[ -f "$key" ] || fail "$p dump footer is signed and no AVB key: set AVB_KEY"
		avbtool extract_public_key --key "$key" --output "$W/avbkey.pub"
		python3 -I - "$DUMP/$p.img" "$W/avbkey.pub" <<'PYEOF' || fail "$p dump footer is not signed with $key"
import sys, struct
d = open(sys.argv[1], 'rb').read(); pub = open(sys.argv[2], 'rb').read()
f = d[-64:]; assert f[:4] == b'AVBf'
vb_off, vb_size = struct.unpack('>QQ', f[20:36]); vb = d[vb_off:vb_off + vb_size]
auth, aux = struct.unpack('>QQ', vb[12:28]); pk_off, pk_size = struct.unpack('>QQ', vb[64:80])
sys.exit(0 if vb[256 + auth + pk_off:256 + auth + pk_off + pk_size] == pub else 1)
PYEOF
		sign=(--algorithm SHA256_RSA4096 --key "$key"); fi
	salt=$(echo "$info" | sed -n 's/^ *Salt: *//p' | head -1)
	while IFS= read -r l; do props+=(--prop "$l"); done < <(echo "$info" | sed -n "s/^ *Prop: \(.*\) -> '\(.*\)'$/\1:\2/p")
	avbtool add_hash_footer --image "$img" --partition_name "$p" --partition_size "$size" --salt "$salt" "${sign[@]}" "${props[@]}"
}
cp "$W/ctl-boot.img" "$W/ctl-boot-f.img"; footer boot "$W/ctl-boot-f.img" $BOOT_PART
if avbtool info_image --image "$DUMP/boot.img" | grep -q 'Algorithm: *NONE'; then
	cmp -s "$W/ctl-boot-f.img" "$DUMP/boot.img" || fail "control AVB footer of boot.img differs from the dump"
	say "control: ROM boot.img incl. AVB footer rebuilt byte-identical (footer recipe proven)"
else
	# signed: the signed blob carries avbtool's release string (ROM 1.3.0, ours may differ): compare everything else
	diff <(avbtool info_image --image "$DUMP/boot.img" | grep -v 'Release String') <(avbtool info_image --image "$W/ctl-boot-f.img" | grep -v 'Release String') > "$W/ctl-footer.diff" || fail "control AVB footer of boot.img differs from the dump ($W/ctl-footer.diff)"
	cmp -s <(head -c "$(stat -c %s "$W/ctl-boot.img")" "$W/ctl-boot-f.img") <(head -c "$(stat -c %s "$W/ctl-boot.img")" "$DUMP/boot.img") || fail "control boot content differs"
	say "control: ROM boot.img footer rebuilt equal to the dump (digest, salt, key, props, padding; only the avbtool release string may differ)"
fi

# ---------------------------------------------------------------- 2. kernel
say "== 2. kernel"
[ "$(od -An -tx4 -j56 -N4 "$IMAGE" | tr -d ' ')" = 644d5241 ] || fail "Image has no ARMd magic"
KREL=$(strings "$IMAGE" | sed -n 's/^Linux version \([^ ]*\) .*/\1/p' | head -1)
[ -d "$DIST/lib/modules/$KREL" ] || fail "no $KV dist modules for $KREL"
case "$KREL" in $KV.*) ;; *) fail "Image is $KREL, not $KV";; esac
KVER=${KREL%%-*}
ISZ=$(od -An -tu8 -j16 -N8 "$IMAGE" | tr -d ' ')
say "Image $KREL, image_size $(printf %#x "$ISZ"), file $(stat -c %s "$IMAGE") bytes"
if [ -f "$SYSMAP" ]; then
	CLS=$(python3 -I - "$SYSMAP" <<'EOF'
import sys
syms = [l.split() for l in open(sys.argv[1])]
for i, s in enumerate(syms):
    if len(s) == 3 and s[2] == 'boot_command_line':
        print(int(syms[i + 1][0], 16) - int(s[0], 16)); break
EOF
)
else CLS=0; fi
CLS_EFF=$(( CLS >= 4096 ? 4096 : CLS >= 2048 ? 2048 : CLS ))
say "boot_command_line is $CLS bytes in System.map -> COMMAND_LINE_SIZE $CLS_EFF"
[ "$CLS_EFF" = 4096 ] || blocker "COMMAND_LINE_SIZE $CLS_EFF: the Samsung ABL's ~2.7 KB append would be cut (needs the 4096 patch, patches/)"
CONFIG_CMDLINE=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$KCONFIG")
grep -q '^CONFIG_CMDLINE_EXTEND=y' "$KCONFIG" || fail "kernel is not CONFIG_CMDLINE_EXTEND: cmdline model wrong"
# drivers/of/fdt.c (both kernels): CONFIG_CMDLINE first, then " " + /chosen/bootargs, cut at
# COMMAND_LINE_SIZE - 1 (= tools/cmdline-sim.py's model)
say "CONFIG_CMDLINE (prepended): $CONFIG_CMDLINE"
if [ "$DIAG_KERNEL" = 1 ]; then
	grep -q ' a52bc_stage$' "$SYSMAP" && grep -q ' a52ram_write$' "$SYSMAP" || fail "DIAG=1 but $IMAGE has no a52bc (kernel-diag/build-diag-kernel.sh)"
	[ "$(sha256sum < "$IMAGE" | cut -d' ' -f1)" != "$(sha256sum < "$DIST/Image" | cut -d' ' -f1)" ] || fail "DIAG Image = dist Image"
	cmp -s <(sed -n 's/^release=//p' "$(dirname "$IMAGE")/BUILDINFO") <(echo "$KREL") || fail "DIAG kernel BUILDINFO release differs"
	say "DIAG kernel: $IMAGE = dist release + a52bc (breadcrumbs + RAM console); $(grep '^modversion' "$(dirname "$IMAGE")/BUILDINFO")"
	if [ "$KSU_BUILTIN" = 1 ]; then
		BI=$(dirname "$IMAGE")/BUILDINFO
		grep -q ' susfs_init$' "$SYSMAP" && grep -q ' ksu_handle_susfs_cmd$' "$SYSMAP" || fail "KSU_BUILTIN=1 but $IMAGE has no built-in KernelSU + SUSFS (modules/resukisu/build-susfs-image.sh)"
		grep -q '^modversion CRCs: .* identical' "$BI" || fail "KSU_BUILTIN=1: the variant's export CRCs differ from the GKI build ($(dirname "$IMAGE")/crc-changed.txt): the first-stage modules must be rebuilt against it"
		say "KSU_BUILTIN=1: $(grep '^variant:' "$BI"); $(grep '^ksu:' "$BI"); $(grep '^susfs:' "$BI"); no rdinit, no kernelsu.ko"
	else
		grep -q ' susfs_init$' "$SYSMAP" && fail "$IMAGE has built-in KernelSU + SUSFS: say KSU_BUILTIN=1 (and not KSU=1)"
	fi
	# boots the same Image in QEMU and checks every breadcrumb, the RAM console, the warm-reset
	# attempt counter and the no-reservation gate (kernel-diag/qemu-test.sh, ~40 s); QEMU_TEST=0 skips
	if [ "${QEMU_TEST:-1}" = 1 ]; then
		"$HERE/kernel-diag/qemu-test.sh" "$IMAGE" > "$W/qemu-test.log" 2>&1 || { tail -5 "$W/qemu-test.log"; fail "DIAG kernel QEMU smoke test"; }
		say "DIAG kernel QEMU smoke test: $(head -1 "$BSP/out/diag/qemu/VERDICT.txt")"
	else say "DIAG kernel QEMU smoke test SKIPPED (QEMU_TEST=0)"; fi
fi

# ---------------------------------------------------------------- 3. modules
say "== 3. modules (from the tested ramdisk $REF)"
python3 -I "$HERE/tools/cpiox.py" "$REFRD" "$W/ref" >> "$R"
# the realboot DSP starter (replaces helper2.sh's "@adsp" job), built against this kernel in a
# work copy (both kernels from the same source file)
mkdir -p "$W/dspboot"; cp "$HERE/modules/dspboot/a52sxq_dsp_boot.c" "$W/dspboot/"; cp "$DSPBOOT_KBUILD" "$W/dspboot/Kbuild"
if [ "$ADDON" = vendor_boot ]; then
	# bus DCVS tunables as a C table (the vendor rc's "write /sys/<path> <value>" lines, same order)
	# LPM=1: the idle governor switch + sleep enable go into the same table (applied at the boost release, in order)
	: > "$W/dspboot/extra.conf"
	if [ "${LPM:-0}" = 1 ]; then printf '%s\n' 'devices/system/cpu/cpuidle/current_governor qcom-cpu-lpm' 'devices/system/cpu/qcom_lpm/parameters/sleep_disabled 0' > "$W/dspboot/extra.conf"; fi
	# UFS_POLL_MS=<ms> (2026-11-21, default unset = the driver's 60): UFS devfreq polling interval (scale-up sooner on big writes)
	if [ -n "${UFS_POLL_MS:-}" ]; then case "$UFS_POLL_MS" in *[!0-9]*|'') fail "UFS_POLL_MS: digits only";; esac
		[ "$UFS_POLL_MS" -ge 5 ] && [ "$UFS_POLL_MS" -le 200 ] || fail "UFS_POLL_MS: 5..200"
		echo "devices/platform/soc/1d84000.ufshc/devfreq/1d84000.ufshc/polling_interval $UFS_POLL_MS" >> "$W/dspboot/extra.conf"; fi
	# UFS_QOS=0 / UFS_CLKSCALE=0 (2026-11-22, write gap): see the header; QoS first, so the scale-up of clkscale_enable 0
	# never votes CPU_DMA_LATENCY 0
	case "${UFS_QOS:-1}" in 0) echo "devices/platform/soc/1d84000.ufshc/pm_qos_enable 0" >> "$W/dspboot/extra.conf";; 1) ;; *) fail "UFS_QOS: 0 or 1";; esac
	case "${UFS_CLKSCALE:-1}" in 0) echo "devices/platform/soc/1d84000.ufshc/clkscale_enable 0" >> "$W/dspboot/extra.conf";; 1) ;; *) fail "UFS_CLKSCALE: 0 or 1";; esac
	# WALT=1 (SPEC/08): governor walt + its tunables, last in the table (after the bus DCVS rows)
	case "${WALT:-0}" in 1) grep -vE '^[[:space:]]*(#|$)' "$HERE/vendor-addon/a52sxq-walt.conf" >> "$W/dspboot/extra.conf";; 0) ;; *) fail "WALT: 0 or 1";; esac
	python3 -I - "$W/dspboot/a52sxq_tunables.h" "$TOP/drivers612/busdcvs/busdcvs.conf" "$W/dspboot/extra.conf" <<'PYEOF'
import sys
rows = []
for l in [x for f in sys.argv[2:] for x in open(f)]:
    l = l.strip()
    if not l or l.startswith('#'): continue
    p, _, v = l.partition(' '); v = v.strip()
    assert p and v and '"' not in v and '\\' not in v, l
    rows.append('\t{ "/sys/%s", "%s" },' % (p, v))
open(sys.argv[1], 'w').write('/* generated by build-realboot.sh from busdcvs.conf */\nstatic const struct a52_tunable a52_tunables[] = {\n' + '\n'.join(rows) + '\n};\n')
PYEOF
	echo 'ccflags-y += -DA52_TUNABLES' >> "$W/dspboot/Kbuild"
	# WALT=1: + the governor guard (re-applies the cpufreq rows for walt_guard_s = 300 s if the ROM's post_boot put schedutil back)
	# and re-opens that window when system_server restarts (post_boot runs again then; walt_guard_rearm=0 to switch off)
	if [ "${WALT:-0}" = 1 ]; then python3 -I "$HERE/modules/dspboot/mk-walt-source.py" "$W/dspboot/a52sxq_dsp_boot.c" "$HERE/modules/dspboot/a52sxq_walt_guard.inc" || fail "WALT=1: guard source"
		say "WALT=1: $(grep -c '/cpufreq/policy' "$W/dspboot/a52sxq_tunables.h") cpufreq rows (governor walt + tunables) at the end of the table + 300 s governor guard"; fi
	say "ADDON=vendor_boot: a52sxq_dsp_boot with $(grep -c '{ "/sys/' "$W/dspboot/a52sxq_tunables.h") built-in bus DCVS tunables"
fi
"${KMAKE[@]}" M="$W/dspboot" KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost modules > "$W/dspboot.log" 2>&1 \
	|| { tail -20 "$W/dspboot.log"; fail "a52sxq_dsp_boot build"; }
cp "$W/dspboot/a52sxq_dsp_boot.ko" "$W/a52sxq_dsp_boot.ko"; "$CLANG/llvm-strip" --strip-debug "$W/a52sxq_dsp_boot.ko"
say "a52sxq_dsp_boot.ko: $(modinfo -F vermagic "$W/a52sxq_dsp_boot.ko")"
# first stage = the kernel's bring-up set + every stage that the test loaded before Android's
# init, in the test order (a52.mods of runs ab-s74 / ab618-a8 =
# debug,secure,display,kgsl,video,i2c,nfc,touch,fingerprint,powerpd,vibrator,camera,dsp,wlanb,
# susp,audio@adsp,wlan@adsp, without "debug" (seaprobe) and "susp" (a52susp: the suspend-test
# safety module refuses every suspend not started by the test: never in a real boot));
# late = what waited for the ADSP
FIRST_STAGES="secure display kgsl video i2c nfc touch fingerprint powerpd vibrator camera dsp wlanb"
# + stage dcvs (bwmon, memlat) right after kgsl, as in run ab-s76 (a52.mods=...,kgsl,dcvs,video,...);
# REF s76 / a10 have the GPU devfreq governors before msm_kgsl in stage kgsl (drivers612/busdcvs/README.md)
FIRST_STAGES=${FIRST_STAGES/kgsl /kgsl dcvs }
MODEM_EXTRA=()
if [ "$MODEM" = 1 ]; then
	# the modem stage of the kernel-only runs (drivers612/modem: kpack/m1.sh "ld modem.list", the
	# order of stages/modem/resolved-kernelonly.list), from the pack that ran, minus the test-only
	# crash guard; then Samsung's /dev/drb (rild). Appended after the last tested stage, so the
	# rb11 prefix of modules.load is unchanged.
	mkdir -p "$W/modempack"; tar xzf "$MODEM_PACK" -C "$W/modempack" ./modem.list ./m
	MPL=$(grep -vE '^[[:space:]]*(#|$)' "$W/modempack/modem.list" | sed 's/[[:space:]].*//' | tr '\n' ' ')
	[ "$MPL" = "a52_modem_guard.ko msm_sharedmem.ko heap_mem_ext_v01.ko msm_memshare.ko glink_pkt.ko rmnet_mem.ko qcom_va_minidump.ko gsim.ko usb_f_gsi.ko ipam.ko ipanetm.ko rmnet_ctl.ko rmnet_core.ko rmnet_offload.ko rmnet_shs.ko " ] \
		|| fail "MODEM_PACK modem.list is not the list of the kx-m2data3 run: $MPL"
	for m in $MPL; do [ "$m" = a52_modem_guard.ko ] && continue; MODEM_EXTRA+=(--extra-after "wlanb:$W/modempack/m/$m"); done
	cp "$MODEM_DRB" "$W/dev_ril_bridge.ko"
	# a module build (6.18: the port tree's) carries debug info; the 6.12 stage-radio copy is stripped already
	"$CLANG/llvm-readelf" -S "$W/dev_ril_bridge.ko" | grep -q '\.debug_' && "$CLANG/llvm-strip" --strip-debug "$W/dev_ril_bridge.ko"
	MODEM_EXTRA+=(--extra-after "wlanb:$W/dev_ril_bridge.ko")
	say "MODEM=1: modem stage from $MODEM_PACK (sha256 $(sha256sum < "$MODEM_PACK" | cut -c1-16)) minus a52_modem_guard, + dev_ril_bridge.ko ($MODEM_DRB, $(sha256sum < "$MODEM_DRB" | cut -c1-16)), after wlanb"
fi
# SDCARD=1: microSD host. Both kernels build cqhci + sdhci-msm as soc-repo modules (dist
# lib/modules/<krel>/drivers/mmc/host; GKI has only mmc_core/mmc_block/sdhci/sdhci-pltfm built in, checked
# below): taken from the dist like every first-stage module of the tested ramdisks.
SD_EXTRA=()
if [ "$SDCARD" = 1 ]; then
	for m in cqhci sdhci-msm; do
		f=$(find "$DIST/lib/modules/$KREL" -name "$m.ko" | head -1); [ -n "$f" ] || fail "$m.ko not in dist"
		SD_EXTRA+=(--extra-after "camera:$f"); done   # dist modules are stripped already (no .debug_*)
	say "SDCARD=1: cqhci + sdhci-msm ($(find "$DIST/lib/modules/$KREL" -name sdhci-msm.ko | sed "s|$DIST/lib/modules/$KREL/||")) added to the first stage (after the camera stage)"
fi
# THERMAL=1: Qualcomm's thermal cooling stack (none of it was ever loaded: the DT cooling-maps of every CPU zone had
# no cooling device, only LMh in qcom-cpufreq-hw + the TSENS 125 C reset protected the CPUs). After stage dcvs
# (needs sched-walt, kgsl devfreq, qmi_helpers). msm_lmh_dcvs left out: qcom-cpufreq-hw owns the dcvsh IRQs.
TH_EXTRA=()
if [ "${THERMAL:-0}" = 1 ]; then
	# TH_MODS= overrides the list (A/B of single modules; default = all 9)
	TH_MODS=${TH_MODS:-thermal_pause cpu_hotplug qti_cpufreq_cdev cpu_voltage_cooling qti_devfreq_cdev qcom-spmi-temp-alarm bcl_pmic5 qti_qmi_cdev qti_qmi_sensor}
	for m in $TH_MODS; do
		f=$(find "$DIST/lib/modules/$KREL" -name "$m.ko" | head -1); [ -n "$f" ] || fail "$m.ko not in dist"
		# DIST_OVERRIDE=<dir>: a newer stripped build of a dist module (e.g. bsp612/out/audit-soc-modules) wins
		if [ -n "${DIST_OVERRIDE:-}" ] && [ -f "$DIST_OVERRIDE/$m.ko" ]; then f=$DIST_OVERRIDE/$m.ko; say "THERMAL: $m.ko from DIST_OVERRIDE ($(sha256sum < "$f" | cut -c1-16))"; fi
		TH_EXTRA+=(--extra-after "dcvs:$f"); done
	say "THERMAL=1: $(echo $TH_MODS | wc -w) thermal cooling modules added to the first stage after stage dcvs: $TH_MODS"
fi
# BTSLIM=1 (2026-11-18, default 0 until proven): Bluetooth audio over SLIMbus (SCO, A2DP offload). slimbus +
# slim-qcom-ngd-ctrl (soc-repo dist) + bt_fm_slim (drivers612/conn/bt/btfmslim; depends slimbus, btpower) right
# after stage wlanb (btpower is its last module), BEFORE the modem set (which must stay the tail). Modules only:
# the SLIM_7 back ends also need qcom,wcn-btfm = <1> on the sound node and the btfmslim codec registered at
# probe (it is: rb43 lists component btfmslim_slave + 4 DAIs at 4.26 s). bam_dma = the ngd's slimbam DMA
# controller@3a84000 (rb43 without it: "Failed to request RX dma channel", capability exchange timed-out).
# The tree gets qcom,wcn-btfm = <1> on the sound node below (the only DT difference to the tested tree).
BT_EXTRA=()
if [ "${BTSLIM:-0}" = 1 ]; then
	mkdir -p "$W/btslim"
	for m in bam_dma slimbus slim-qcom-ngd-ctrl; do
		f=$(find "$DIST/lib/modules/$KREL" -name "$m.ko" | head -1); [ -n "$f" ] || fail "BTSLIM=1: $m.ko not in dist"
		BT_EXTRA+=(--extra-after "wlanb:$f"); done
	BTFM=${BTFM_KO:-$TOP/drivers612/conn/bt/btfmslim/bt_fm_slim.ko}; [ -f "$BTFM" ] || fail "BTSLIM=1: no $BTFM (drivers612/conn/bt/build.sh btfmslim)"
	cp "$BTFM" "$W/btslim/bt_fm_slim.ko"; "$CLANG/llvm-strip" --strip-debug "$W/btslim/bt_fm_slim.ko"
	BT_EXTRA+=(--extra-after "wlanb:$W/btslim/bt_fm_slim.ko")
	say "BTSLIM=1: bam_dma, slimbus, slim-qcom-ngd-ctrl, bt_fm_slim ($(sha256sum < "$BTFM" | cut -c1-16)) added to the first stage after stage wlanb"
fi
# USBAUDIO=1 (2026-11-19, default 0 until proven): USB-C audio through the ADSP (USB audio offload, 5.4
# CONFIG_SND_USB_AUDIO_QMI=y). snd-usb-audio-qmi (soc-repo dist; depends qmi_helpers, qcom_ipc_logging, dwc3-msm:
# all earlier in the list) right after stage wlanb, before the BT and modem sets. Node /soc/usb_audio_qmi_dev
# (qcom,usb-audio-qmi-dev) is in the tree with the 5.4 values.
UA_EXTRA=()
if [ "${USBAUDIO:-0}" = 1 ]; then
	f=$(find "$DIST/lib/modules/$KREL" -name "snd-usb-audio-qmi.ko" | head -1); [ -n "$f" ] || fail "USBAUDIO=1: snd-usb-audio-qmi.ko not in dist"
	UA_EXTRA+=(--extra-after "wlanb:$f")
	say "USBAUDIO=1: snd-usb-audio-qmi ($(sha256sum < "$f" | cut -c1-16)) added to the first stage after stage wlanb"
fi
# ---- 2026-11-19 parity options (each default 0 until proven on white cable; PARITY-2026-11-18.md) ----
X_EXTRA=(); mkdir -p "$W/xmod"
xmod() {   # <stage> <file.ko> [name.ko]: stripped copy into the first stage after <stage>
	local n=${3:-$(basename "$2")}; [ -f "$2" ] || fail "missing module $2"
	cp "$2" "$W/xmod/$n"; "$CLANG/llvm-strip" --strip-debug "$W/xmod/$n"; X_EXTRA+=(--extra-after "$1:$W/xmod/$n")
}
distko() { local f; f=$(find "$DIST/lib/modules/$KREL" -name "$1.ko" | head -1); [ -n "$f" ] || fail "$1.ko not in dist"; echo "$f"; }
# WDT=1: the hypervisor watchdog as on 5.4 (hh_virt_wdt built in there): qcom_wdt_core + gh_virt_wdt right after
# stage secure (depends minidump, qcom-scm). Kernel-petted (RT kthread, 9.36 s; bark 11 s, bite +3 s), disabled across
# suspend by the driver. qcom_soc_wdt stays out and is blocklisted: the ABL disables /soc/qcom,wdt@17c10000.
if [ "${WDT:-0}" = 1 ]; then
	xmod secure "$(distko qcom_wdt_core)"; xmod secure "$(distko gh_virt_wdt)"
	say "WDT=1: qcom_wdt_core + gh_virt_wdt added to the first stage after stage secure; qcom_soc_wdt blocklisted"
fi
# WDT=oneui (2026-11-24, drivers612/samsung-oneui/WDT-ONEUI.md): the same two modules from drivers612/samsung-oneui/wdt
# (same names and exports): bark 20 s / bite 23 s / pet 9.36 s, a panic is NOT turned into a watchdog bite, an already
# armed watchdog is adopted, a watchdog that cannot be disabled refuses the suspend. gh_virt_wdt.enable=0 on the
# kernel command line switches it off for one boot.
case "${WDT:-0}" in 0|1|oneui|a52) ;; *) fail "WDT: 0, 1, oneui or a52 (a52 = oneui: the same variant modules, name for AOSP ROM builds)";; esac
if [ "${WDT:-0}" = oneui ] || [ "${WDT:-0}" = a52 ]; then
	WV=$TOP/drivers612/samsung-oneui/wdt/out
	for m in qcom_wdt_core gh_virt_wdt; do
		[ "$(modinfo -F vermagic "$WV/$m.ko" | cut -d' ' -f1)" = "$KREL" ] || fail "WDT=oneui: $WV/$m.ko missing or built for another kernel (samsung-oneui/build.sh wdt)"
	done
	modinfo -p "$WV/qcom_wdt_core.ko" | grep -q '^bite_on_panic:' && modinfo -p "$WV/gh_virt_wdt.ko" | grep -q '^enable:' || fail "WDT=oneui: not the a52 variant"
	xmod secure "$WV/qcom_wdt_core.ko"; xmod secure "$WV/gh_virt_wdt.ko"
	say "WDT=oneui: a52 qcom_wdt_core $(sha256sum < "$WV/qcom_wdt_core.ko" | cut -c1-8) + gh_virt_wdt $(sha256sum < "$WV/gh_virt_wdt.ko" | cut -c1-8) after stage secure; qcom_soc_wdt blocklisted"
fi
# QRNG=1: hardware RNG (5.4 HW_RANDOM_MSM_LEGACY): qrng_dlkm (platform driver msm-rng) + the 5.4 node properties
if [ "${QRNG:-0}" = 1 ]; then
	xmod secure "$TOP/drivers612/secure/securemsm/src/qrng_dlkm.ko"
	say "QRNG=1: qrng_dlkm added to the first stage after stage secure (+ /soc/rng@10d3000 as qcom,msm-rng)"
fi
# LPM=1 (2026-11-21): Qualcomm's cpuidle governor qcom-cpu-lpm (qcom_lpm.ko, soc-repo dist; depends sched-walt) instead of
# menu. It honours WALT's busy hysteresis (sched_lpm_disallowed_time: a CPU that just ran a >= 15 % task is kept out of the
# power-collapse states for 5 ms), as 5.4's lpm-levels did. With menu a thread that waits ~13 ms for the GPU/video core/UFS
# interrupt pays the 1.4-2.4 ms exit latency of cpu-sleep-* on every wake-up: that is the 6.12 "GPU never scales" (busy
# ratio 85 % instead of 95 %: TZ says stay), the hw decode gap and the offscreen GL gap.
# The module registers the governor; dsp_boot's tunables table selects it and clears sleep_disabled (module default 1 =
# WFI only, which is what the 11-16 "cluster never idles" test saw) at the boost release.
if [ "${LPM:-0}" = 1 ]; then
	[ "$ADDON" = vendor_boot ] || fail "LPM=1 needs ADDON=vendor_boot (the governor is selected by dsp_boot's tunables table)"
	xmod powerpd "$(distko qcom_lpm)"
	say "LPM=1: qcom_lpm added to the first stage after stage powerpd; governor qcom-cpu-lpm + sleep_disabled=0 in the tunables table"
fi
# VOLKEY=1: /sys/power/volkey_wakeup (5.4 Samsung: RESIN wake on/off, default off; IchthysOS Abyss writes it)
if [ "${VOLKEY:-0}" = 1 ]; then
	xmod secure "$HERE/modules/out/a52sxq_volkey.ko"
	say "VOLKEY=1: a52sxq_volkey added to the first stage after stage secure"
fi
# THERMAL_X="adctm secth qmi bclmap adspfac-free list": thermal extras, each separable
#   adctm  = qcom-spmi-adc-tm5 after stage powerpd (zones quiet/camera/rear-cam/xo-therm-usr)
#   secth  = sec_thermistor after stage powerpd (ap/wf/pa thermistors; values to be checked on a real boot)
#   qmi    = qti_qmi_sensor with index 30 named msm_skin_therm as Samsung's 5.4 table (replaces the dist module)
#   bclmap = pm8350c-bcl-lvl0 cooling maps on the cpuN_pause devices instead of the cpuN-isolate placeholders (DT)
THERMAL_X=${THERMAL_X:-}
for t in $THERMAL_X; do case "$t" in adctm|secth|qmi|bclmap) ;; *) fail "THERMAL_X: unknown item $t";; esac; done
case " $THERMAL_X " in *" adctm "*) xmod powerpd "$(distko qcom-spmi-adc-tm5)";; esac
case " $THERMAL_X " in *" secth "*) xmod powerpd "$TOP/drivers612/power/src/sec_thermistor/sec_thermistor.ko";; esac
if [ "${THERMAL:-0}" = 1 ]; then case " $THERMAL_X " in *" qmi "*)
	QS=$HERE/modules/qmisensor/qti_qmi_sensor.stripped.ko; [ -f "$QS" ] || fail "THERMAL_X=qmi: no $QS"
	for i in "${!TH_EXTRA[@]}"; do case "${TH_EXTRA[$i]}" in dcvs:*/qti_qmi_sensor.ko) cp "$QS" "$W/xmod/qti_qmi_sensor.ko"; TH_EXTRA[$i]="dcvs:$W/xmod/qti_qmi_sensor.ko";; esac; done
	say "THERMAL_X=qmi: qti_qmi_sensor.ko from modules/qmisensor ($(sha256sum < "$QS" | cut -c1-16))";; esac; fi
[ -n "$THERMAL_X" ] && say "THERMAL_X: $THERMAL_X"
# ADSPFAC=1: Samsung adsp_factory (netlink 23 + /sys/class/sensors/*: factory_ssc restarted every 11 s without it)
if [ "${ADSPFAC:-0}" = 1 ]; then
	# ADSPFAC_KO=<file>: another build of the module (default: the in-place one, as before). The P1 build
	# drivers612/sensors-factory/out-p1/adsp_factory_dlkm.ko (vibrator -> accelerometer motor notifier, SPEC/01 gap 8)
	# binds to sec_vibrator.ko with symbol_get from a delayed work (2 s x 90), so it needs NO load-order change, but
	# the REF must carry the sec_vibrator.ko that exports sec_vib_notifier_register (vibrator/out-p1), checked here.
	ADSPFAC_KO=${ADSPFAC_KO:-$TOP/drivers612/sensors-factory/adsp_factory_dlkm.ko}
	xmod powerpd "$ADSPFAC_KO" adsp_factory_dlkm.ko
	if grep -aq 'no sec_vib_notifier_register after' "$ADSPFAC_KO"; then
		sv=$(find "$W/ref" -name sec_vibrator.ko | head -1)
		[ -n "$sv" ] && grep -aq '^sec_vib_notifier_register$' <(strings "$sv") || fail "ADSPFAC_KO has the motor notifier but the REF's sec_vibrator.ko does not export sec_vib_notifier_register (swap vibrator/out-p1/sec_vibrator.ko into the REF)"
	fi
	say "ADSPFAC=1: adsp_factory_dlkm ($(sha256sum < "$W/xmod/adsp_factory_dlkm.ko" | cut -c1-16)) added to the first stage after stage powerpd"
fi
# BWCOMPAT=1: /sys/class/devfreq/soc:qcom,cpu-{cpu-llcc,llcc-ddr}-bw compat nodes for the ROM's powerhint.json
# (11 nodes, 1870 failed Power HAL writes per boot), forwarded to bus_dcvs
if [ "${BWCOMPAT:-0}" = 1 ]; then
	xmod dcvs "$HERE/modules/out/a52sxq_bwcompat.ko"
	say "BWCOMPAT=1: a52sxq_bwcompat added to the first stage after stage dcvs"
fi
# SOCSTATS=1 (2026-11-24, SPEC/03 G5): qcom_stats (/sys/power/soc_sleep/stats: AOSD/CXSD/DDR residency, as 5.4's
# QCOM_SOC_SLEEP_STATS); depends qcom_aoss + smem (base stage)
if [ "${SOCSTATS:-0}" = 1 ]; then
	xmod powerpd "$(distko qcom_stats)"
	say "SOCSTATS=1: qcom_stats added to the first stage after stage powerpd"
fi
# NTFS3=1 (SPEC/03 G12/D16): ntfs3.ko (external build of the unmodified GKI fs/ntfs3, samsung-oneui/ntfs3/mk.sh, QEMU 24/24);
# 5.4 had read-only NTFS built in; One UI vold uses ntfs3 when the filesystem is registered. No dependencies.
if [ "${NTFS3:-0}" = 1 ]; then
	xmod powerpd "$TOP/drivers612/samsung-oneui/ntfs3/out/ntfs3.ko"
	say "NTFS3=1: ntfs3 added to the first stage after stage powerpd"
fi
# USBACC=1 (SPEC/03 G12/U12): the USB Ethernet set 5.4 had built in (usbnet, cdc_ether, cdc_ncm, r8152, asix,
# ax88179_178a; GKI =m, dist), in dependency order. smsc75xx/95xx and HID_SAMSUNG are not in the GKI config: not added.
if [ "${USBACC:-0}" = 1 ]; then
	for m in mii usbnet cdc_ether cdc_ncm r8152 asix ax88179_178a; do xmod powerpd "$(distko $m)"; done
	say "USBACC=1: mii usbnet cdc_ether cdc_ncm r8152 asix ax88179_178a added to the first stage after stage powerpd"
fi
python3 -I "$HERE/tools/modplan.py" --ref "$W/ref" --first "$FIRST_STAGES" --late audio --wlan wlan \
	--extra-after "dsp:$W/a52sxq_dsp_boot.ko" "${X_EXTRA[@]}" "${UA_EXTRA[@]}" "${BT_EXTRA[@]}" "${MODEM_EXTRA[@]}" "${SD_EXTRA[@]}" "${TH_EXTRA[@]}" --drop "seaprobe testguard hhwdt a52susp a52_modem_guard" --out "$W/plan" | tee -a "$R"
if [ "$ADDON" = vendor_boot ]; then
	# the vendor add-on's two groups move to the END of the first stage (the tested prefix stays):
	# the audio set in its tested order, then wlan.ko (file name wlan.ko again; module name "wlan")
	cp "$W/plan/late.load" "$W/plan/addon-late.load"; cp "$W/plan/wlan.load" "$W/plan/addon-wlan.load"
	for m in $(cat "$W/plan/late.load"); do
		[ -f "$W/plan/first/$m" ] && fail "ADDON=vendor_boot: $m already in the first stage"
		mv "$W/plan/late/$m" "$W/plan/first/$m"; echo "$m" >> "$W/plan/first.load"; done
	[ "$(cat "$W/plan/wlan.load")" = qca_cld3_wlan.ko ] || fail "ADDON=vendor_boot: wlan group is not qca_cld3_wlan.ko"
	[ -f "$W/plan/first/wlan.ko" ] && fail "ADDON=vendor_boot: wlan.ko already in the first stage"
	mv "$W/plan/wlan/qca_cld3_wlan.ko" "$W/plan/first/wlan.ko"; echo wlan.ko >> "$W/plan/first.load"
	cat "$W/plan/late.params" "$W/plan/wlan.params" 2>/dev/null >> "$W/plan/first.params" || true
	echo "options a52sxq_dsp_boot rescan_after_adsp=1 hold_until_adsp=qcom,adsp-notify+qcom,msm-audio-apr+qcom,audio-ref-clk+qcom,msm-cdc-pinctrl+qcom,q6core-audio+qcom,adsp-loader hold_late=qcom,wcd938x-codec${HOLD_MS:+ hold_release_ms=$HOLD_MS}" >> "$W/plan/first.params"
	: > "$W/plan/late.load"; : > "$W/plan/wlan.load"; : > "$W/plan/late.params"
	say "ADDON=vendor_boot: $(wc -l < "$W/plan/addon-late.load") audio modules + wlan.ko appended to the first stage ($(wc -l < "$W/plan/first.load") modules); a52sxq_dsp_boot rescan_after_adsp=1"
fi
# ZRAM_LZ4=1 (SPEC/03 G13): zram.ko rebuilt from the unmodified GKI sources with default_compressor "lz4" (= CONFIG_
# ZRAM_DEF_COMP_LZ4; samsung-oneui/zram-lz4/mk.sh, GKI out/gki config, same imports + parameters as the dist module).
# 6.12 falls back to the default on every zram reset; One UI configures lz4.
if [ "${ZRAM_LZ4:-0}" = 1 ]; then
	ZL=$TOP/drivers612/samsung-oneui/zram-lz4/out/zram.ko; [ -f "$ZL" ] || fail "ZRAM_LZ4=1: no $ZL (run samsung-oneui/zram-lz4/mk.sh)"
	[ -f "$W/plan/first/zram.ko" ] || fail "ZRAM_LZ4=1: zram.ko not in the first stage"
	[ "$(modinfo -F vermagic "$ZL")" = "$(modinfo -F vermagic "$W/plan/first/zram.ko")" ] || fail "ZRAM_LZ4=1: vermagic differs"
	[ "$(modinfo -F depends "$ZL")" = "$(modinfo -F depends "$W/plan/first/zram.ko")" ] || fail "ZRAM_LZ4=1: depends differs"
	grep -aq 'lz4' "$ZL" || fail "ZRAM_LZ4=1: no lz4 in $ZL"
	cp "$ZL" "$W/plan/first/zram.ko"
	say "ZRAM_LZ4=1: first-stage zram.ko = zram-lz4 ($(sha256sum < "$ZL" | cut -c1-16)), default compressor lz4"
fi
for st in debug susp; do [ -f "$W/ref/a52/mods/$st.list" ] && say "stage $st of $REF NOT in the real boot: $(tr '\n' ' ' < "$W/ref/a52/mods/$st.list")"; done
cat "$W/plan/first.load" "$W/plan/late.load" "$W/plan/wlan.load" | grep -qx 'a52susp.ko\|seaprobe.ko\|testguard.ko\|hhwdt.ko\|a52_modem_guard.ko' && fail "test module planned"
{	# GPU + bus DCVS (both kernels) (drivers612/busdcvs/README.md): devfreq governors before msm_kgsl (kgsl looks its
	# governor up once, at probe: "Unable to find governor" -> no GPU DCVS); bwmon/memlat after
	# every module they use (qcom-dcvs, sched-walt, qcom-pmu-lib + its llcc/scmi deps)
	pos() { grep -nx "$1" "$W/plan/first.load" | cut -d: -f1; }
	for m in governor_msm_adreno_tz.ko governor_gpubw_mon.ko msm_kgsl.ko bwmon.ko memlat.ko qcom-dcvs.ko qcom-pmu-lib.ko qcom_llcc_pmu.ko qcom_scmi_client.ko sched-walt.ko; do
		[ -n "$(pos $m)" ] || fail "DCVS: $m not in the first stage (REF=$REF needs the kgsl2 + dcvs stages: s76 / a10)"; done
	for g in governor_msm_adreno_tz.ko governor_gpubw_mon.ko; do [ "$(pos $g)" -lt "$(pos msm_kgsl.ko)" ] || fail "DCVS: $g after msm_kgsl"; done
	for d in qcom-dcvs.ko sched-walt.ko qcom-pmu-lib.ko qcom_llcc_pmu.ko qcom_scmi_client.ko; do
		for m in bwmon.ko memlat.ko; do [ "$(pos $d)" -lt "$(pos $m)" ] || fail "DCVS: $m before its dependency $d"; done; done
	say "DCVS: GPU governors at $(pos governor_msm_adreno_tz.ko)/$(pos governor_gpubw_mon.ko) < msm_kgsl $(pos msm_kgsl.ko); bwmon $(pos bwmon.ko), memlat $(pos memlat.ko) after qcom-dcvs $(pos qcom-dcvs.ko), sched-walt $(pos sched-walt.ko), qcom-pmu-lib $(pos qcom-pmu-lib.ko)"
}
if [ "$MODEM" = 1 ]; then
	MODEM_MODS="msm_sharedmem heap_mem_ext_v01 msm_memshare glink_pkt rmnet_mem gsim usb_f_gsi ipam ipanetm rmnet_ctl rmnet_core rmnet_offload rmnet_shs dev_ril_bridge"
	for m in $MODEM_MODS qcom_va_minidump; do grep -qx "$m.ko" "$W/plan/first.load" || fail "MODEM=1: $m.ko not in the first stage"; done
	# the tested prefix (rb11's first stage) is untouched: the modem set comes after it, in pack order
	NM=$(echo $MODEM_MODS | wc -w)
	# ADDON=vendor_boot: the add-on group (audio + wlan) follows the modem set
	NADD=0; [ "$ADDON" = vendor_boot ] && NADD=$(( $(wc -l < "$W/plan/addon-late.load") + 1 ))
	[ "$(head -n -"$NADD" "$W/plan/first.load" | tail -n "$NM" | sed 's/\.ko$//' | tr '\n' ' ')" = "$MODEM_MODS " ] || fail "MODEM=1: the modem modules are not the tail of the tested modules.load in pack order"
	for m in $MODEM_MODS; do
		[ "$m" = dev_ril_bridge ] && src=$W/dev_ril_bridge.ko || src=$W/modempack/m/$m.ko
		cmp -s "$src" "$W/plan/first/$m.ko" || fail "MODEM=1: $m.ko is not the tested file"; done
	cmp -s "$W/modempack/m/qcom_va_minidump.ko" "$W/plan/first/qcom_va_minidump.ko" || fail "MODEM=1: qcom_va_minidump of the pack differs from the first stage's"
	grep -qE '^(rmnet|ipa|gsim|msm_sharedmem|msm_memshare|glink_pkt|dev_ril)' "$W/plan/late.load" "$W/plan/wlan.load" && fail "MODEM=1: a modem module in the vendor add-on"
	say "MODEM=1: $NM modem/data modules are the last $NM lines of modules.load (byte-identical to the run's pack; qcom_va_minidump already in the first stage, same file)"
fi
# ASYNC_LAST="<module> ..." (2026-11-22, default none; boot time): async_probe=1 AND moved to the very end of modules.load.
# Async probing alone (ASYNC_MODS, rb91) gains nothing: every later non-async module's do_init_module() runs
# async_synchronize_full() and waits for the async probe anyway. At the end nothing in the first stage waits for it;
# the probe finishes in the background while init mounts and switches root. Only leaf modules (nothing in the
# first stage depends on them) that come after the rehearsal helper's sequential prefix (zram) are accepted, so the
# rehearsal runs exactly this order.
for m in ${ASYNC_LAST:-}; do
	grep -qx "$m.ko" "$W/plan/first.load" || fail "ASYNC_LAST: $m.ko is not a first-stage module"
	p=$(grep -nx "$m.ko" "$W/plan/first.load" | cut -d: -f1); z=$(grep -nx "zram.ko" "$W/plan/first.load" | cut -d: -f1)
	[ -n "$z" ] && [ "$p" -gt "$z" ] || fail "ASYNC_LAST: $m.ko is inside the rehearsal's sequential prefix (<= zram)"
	depmod_x=$(cd "$W/plan/first" && for k in *.ko; do modinfo -F depends "$k" 2>/dev/null | tr ',' '\n' | grep -qx "$(modinfo -F name "$m.ko")" && echo "$k"; done; true)
	[ -z "$depmod_x" ] || fail "ASYNC_LAST: $m.ko has first-stage dependents: $depmod_x"
	grep -vx "$m.ko" "$W/plan/first.load" > "$W/plan/first.load.t"; echo "$m.ko" >> "$W/plan/first.load.t"; mv "$W/plan/first.load.t" "$W/plan/first.load"
	grep -q "^options $m " "$W/plan/first.params" && fail "ASYNC_LAST: $m already has an options line"
	echo "options $m async_probe=1" >> "$W/plan/first.params"
	say "ASYNC_LAST: $m.ko async_probe=1, moved from line $p to the end of modules.load"
done
# A52SXQ_FIRST=1 (2026-11-25, default 0): a52sxq.ko (userspace switch) to line 1 of modules.load, every other module keeps
# its relative order. Consumers resolve the switch with symbol_get() and get the AOSP answer until it is loaded, so a
# probe-time reader before it runs the AOSP variant (usb_notify_layer set_otg_notify from usb_notifier's probe, rbou9ds).
# a52sxq_core_init only reads its parameter and /chosen/bootargs: no depends, no device, safe as the first module.
case "${A52SXQ_FIRST:-0}" in 0) ;; 1)
	p=$(grep -nx a52sxq.ko "$W/plan/first.load" | cut -d: -f1); [ -n "$p" ] || fail "A52SXQ_FIRST=1: a52sxq.ko is not a first-stage module"
	[ -z "$(modinfo -F depends "$W/plan/first/a52sxq.ko")" ] || fail "A52SXQ_FIRST=1: a52sxq.ko has depends: $(modinfo -F depends "$W/plan/first/a52sxq.ko")"
	{ echo a52sxq.ko; grep -vx a52sxq.ko "$W/plan/first.load"; } > "$W/plan/first.load.t"
	[ "$(wc -l < "$W/plan/first.load.t")" = "$(wc -l < "$W/plan/first.load")" ] || fail "A52SXQ_FIRST=1: line count changed"
	mv "$W/plan/first.load.t" "$W/plan/first.load"
	say "A52SXQ_FIRST=1: a52sxq.ko moved from line $p to line 1 of modules.load";;
*) fail "A52SXQ_FIRST: 0 or 1";; esac
for k in $(ls "$W"/plan/{first,late,wlan}/*.ko 2>/dev/null); do strings "$k" | grep -q "^vermagic=$KREL " || fail "wrong vermagic: $k"; done
# modules.dep/alias/softdep, flat paths, symbols checked against the kernel's System.map
depmod_dir() {   # <outdir> <dir with .ko>...
	local out=$1; shift; rm -rf "$out"; mkdir -p "$out/lib/modules/$KREL"
	for d in "$@"; do ls "$d"/*.ko > /dev/null 2>&1 || continue; cp "$d"/*.ko "$out/lib/modules/$KREL/"; done
	depmod -b "$out" -F "$DIST/System.map" -e "$KREL" 2> "$out.err" || true
	grep -v "^depmod: WARNING: could not open modules\.\(order\|builtin\)" "$out.err" > "$out.unresolved" || true
}
depmod_dir "$W/dep1" "$W/plan/first"
[ -s "$W/dep1.unresolved" ] && { head "$W/dep1.unresolved"; fail "first-stage set: unresolved symbols (needs a late module?)"; }
depmod_dir "$W/depall" "$W/plan/first" "$W/plan/late" "$W/plan/wlan"
[ -s "$W/depall.unresolved" ] && { head "$W/depall.unresolved"; fail "full set: unresolved symbols"; }
VR=$W/vr; LM=$VR/lib/modules; mkdir -p "$LM"
cp "$W"/plan/first/*.ko "$LM/"
# STRIP_BTF=1 (2026-11-22, default 0; boot time): drop .BTF/.BTF.base from every UNSIGNED first-stage module (the signed
# GKI ones keep theirs: an edited signed module fails its signature check and would be refused). Boot-time kprobes in
# rehearsals rh612p2a101k3..k5: the MODULE_STATE_COMING notifier chain costs ~4.6 ms per module, ~3.2 ms of it
# btf_module_notify parsing the module BTF (17.8 MB over 260 modules, 21 % of the first-stage bytes). Module BTF is
# only for BPF CO-RE/bpftool on module types (/sys/kernel/btf/<module>); Android's BPF programs do not use it and 5.4
# had no BTF at all. Sections only; code, data, symbols, relocations and modinfo are untouched (checked below).
if [ "${STRIP_BTF:-0}" = 1 ]; then
	nb=0; bb=0
	for k in "$LM"/*.ko; do
		tail -c 28 "$k" | grep -q 'Module signature appended' && continue
		readelf -SW "$k" | grep -qE ' \.BTF(\.base)? ' || continue
		b0=$(stat -c %s "$k")
		"$CLANG/llvm-objcopy" --remove-section=.BTF --remove-section=.BTF.base "$k" "$k.nobtf" || fail "STRIP_BTF: objcopy $k"
		cmp -s <("$CLANG/llvm-objcopy" -O binary --only-section=.modinfo "$k" /dev/stdout) <("$CLANG/llvm-objcopy" -O binary --only-section=.modinfo "$k.nobtf" /dev/stdout) || fail "STRIP_BTF: modinfo changed in $k"
		cmp -s <("$CLANG/llvm-objcopy" -O binary --only-section=.text "$k" /dev/stdout) <("$CLANG/llvm-objcopy" -O binary --only-section=.text "$k.nobtf" /dev/stdout) || fail "STRIP_BTF: .text changed in $k"
		[ "$(readelf -sW "$k" | wc -l)" = "$(readelf -sW "$k.nobtf" | wc -l)" ] || fail "STRIP_BTF: symbol table changed in $k"
		mv "$k.nobtf" "$k"; nb=$((nb + 1)); bb=$((bb + b0 - $(stat -c %s "$k")))
	done
	say "STRIP_BTF=1: .BTF removed from $nb unsigned first-stage modules ($((bb / 1048576)) MiB less)"
fi
for f in modules.dep modules.alias modules.softdep; do cp "$W/dep1/lib/modules/$KREL/$f" "$LM/$f"; done
cp "$W/plan/first.load" "$LM/modules.load"
while read -r m; do grep -q "^$m:" "$LM/modules.dep" || fail "$m of modules.load is not in modules.dep"; done < "$LM/modules.load"
# userspace switch order (tools/us-order-check.py): no module that reads a52sxq_userspace_get (import or symbol_get
# name) may load before a52sxq.ko; notifier/hint-only users are listed as INFO. Standalone: us-order-check.py <plan dir>
python3 -I "$HERE/tools/us-order-check.py" --load "$LM/modules.load" --dir "$LM" ${MODLOAD:+--parallel} > "$W/us-order.txt" \
	|| { cat "$W/us-order.txt"; fail "userspace switch: a consumer loads before a52sxq.ko (A52SXQ_FIRST=1 or move it in the REF)"; }
tee -a "$R" < "$W/us-order.txt" > /dev/null; tail -n1 "$W/us-order.txt"
# blocked in every test (bsp612/mkramdisk-612.sh DROP, pack-android-612.sh BLOCK); the
# blocklist stops an alias or softdep from pulling them in
BLOCK="qcom_edac qcom-dload-mode gh_virt_wdt qcom_wdt_core tz_log_dlkm sdhci-msm cqhci phy-msm-ssusb-qmp msm_sharedmem"
# MODEM=1: msm_sharedmem is rmt_storage's UIO buffer: loaded, so not blocked
[ "$MODEM" = 1 ] && BLOCK=${BLOCK% msm_sharedmem}
[ "$SDCARD" = 1 ] && BLOCK=${BLOCK/ sdhci-msm cqhci/}
[ "${WDT:-0}" != 0 ] && BLOCK="${BLOCK/ gh_virt_wdt qcom_wdt_core/} qcom_soc_wdt"
for b in $BLOCK; do echo "blocklist $b"; done > "$LM/modules.blocklist"
for b in $BLOCK; do grep -qx "$b.ko" "$LM/modules.load" && fail "blocked module $b in modules.load"; done
# no SD host driver in any set (phone 1 has a microSD, mmcblk1, that nothing may touch)
[ "$SDCARD" = 1 ] || { ls "$W"/plan/{first,late,wlan}/ | grep -q '^sdhci\|^cqhci\|^mmc' && fail "SD/MMC host module in the module plan"; }
grep -q 'sdhci-msm\|cqhci' "$DIST/lib/modules/$KREL/modules.builtin" && fail "sdhci-msm/cqhci built into the kernel"
# GPU_BUSY_UP=<percent> (2026-11-19, default unset): b5 workaround for the adreno_tz governor leaving a busy GPU on
# the lowest OPP on 6.12 (needs REF >= s97, whose governor_msm_adreno_tz has a52_busy_up_pct, soc-repo patch 0018):
# when TZ does not ask for a faster level and the window was at least <percent> busy, step one level up.
if [ -n "${GPU_BUSY_UP:-}" ]; then
	case "$GPU_BUSY_UP" in *[!0-9]*) fail "GPU_BUSY_UP: a number 1..100";; esac
	strings "$W/plan/first/governor_msm_adreno_tz.ko" | grep -q '^parmtype=a52_busy_up_pct:' || fail "GPU_BUSY_UP: the governor of REF=$REF has no a52_busy_up_pct (needs s97+)"
	echo "options governor_msm_adreno_tz a52_busy_up_pct=$GPU_BUSY_UP" >> "$W/plan/first.params"
	say "GPU_BUSY_UP=$GPU_BUSY_UP: modules.options governor_msm_adreno_tz a52_busy_up_pct=$GPU_BUSY_UP"
fi
# ICE_RAW=1 (2026-11-21, default 0; REF >= s99i, soc-repo patch 0021): /data inline crypto in the ICE hardware for the
# ROM's standard (raw) keys instead of blk-crypto-fallback on the CPU: qcom_ice a52_no_hwkm=1 (ICE legacy mode, the
# DT's qcom,ice-use-hwkm ignored) + ufshcd_crypto_qti a52_raw_keys=1 (advertise standard keys, program them with the
# SCM ice_set_key call). Known-answer test vs AES-256-XTS: rehearsals rh612p2a87i/j.
if [ "${ICE_RAW:-0}" = 1 ]; then
	strings "$W/plan/first/qcom_ice.ko" | grep -q '^parmtype=a52_no_hwkm:' || fail "ICE_RAW=1: qcom_ice of REF=$REF has no a52_no_hwkm (needs s99i+)"
	strings "$W/plan/first/ufshcd-crypto-qti.ko" | grep -q '^parmtype=a52_raw_keys:' || fail "ICE_RAW=1: ufshcd-crypto-qti of REF=$REF has no a52_raw_keys (needs s99i+)"
	# one options line per module: libmodprobe keeps only one line per module name
	printf '%s\n' 'options qcom_ice a52_no_hwkm=1' "options ufshcd_crypto_qti a52_raw_keys=1$([ "${ICE_KAT_FAIL:-0}" = 1 ] && echo ' a52_kat_fail=1')" >> "$W/plan/first.params"
	say "ICE_RAW=1: modules.options qcom_ice a52_no_hwkm=1, ufshcd_crypto_qti a52_raw_keys=1"
	# ICE_KAT_FAIL=1 (test builds only): the boot-time known-answer test is made to fail (s99k+): proves the fallback
	if [ "${ICE_KAT_FAIL:-0}" = 1 ]; then
		strings "$W/plan/first/ufshcd-crypto-qti.ko" | grep -q '^parmtype=a52_kat_fail:' || fail "ICE_KAT_FAIL=1 needs REF >= s99k"
		say "ICE_KAT_FAIL=1: TEST BUILD, the ICE known-answer test fails on purpose (a52_kat_fail=1 on the ufshcd_crypto_qti line)"
	fi
fi
# SHM_BRIDGE_OFF=1 (2026-11-22 test; soc-repo patch 0024): qcom_scm a52_no_shm_bridge=1 = the TZ SHM bridge stays off
# as on 5.4; with it on, Samsung's PROCA TA cannot map HLOS memory and the vaultkeeper TA refuses its clients.
if [ "${SHM_BRIDGE_OFF:-0}" = 1 ]; then
	strings "$W/plan/first/qcom-scm.ko" | grep -q '^parmtype=a52_no_shm_bridge:' || fail "SHM_BRIDGE_OFF=1: qcom-scm of REF=$REF has no a52_no_shm_bridge (soc-repo 0024)"
	grep -q '^options qcom_scm ' "$W/plan/first.params" 2>/dev/null && fail "SHM_BRIDGE_OFF=1: an options line for qcom_scm exists already"
	echo 'options qcom_scm a52_no_shm_bridge=1' >> "$W/plan/first.params"
	say "SHM_BRIDGE_OFF=1: modules.options qcom_scm a52_no_shm_bridge=1 (TZ SHM bridge off, 5.4 behaviour)"
fi
# UFS_WB=always (2026-11-22, default unset = WB tied to clock scaling; REF >= s99n, soc-repo patch 0023): ufs_qcom
# a52_wb_always=1 = WriteBooster on from probe, not switched by clock scaling (5.4: Samsung's load-based WB policy)
case "${UFS_WB:-}" in '') ;; always)
	strings "$W/plan/first/ufs-qcom.ko" | grep -q '^parmtype=a52_wb_always:' || fail "UFS_WB=always: ufs-qcom of REF=$REF has no a52_wb_always (needs s99n+)"
	echo 'options ufs_qcom a52_wb_always=1' >> "$W/plan/first.params"
	say "UFS_WB=always: modules.options ufs_qcom a52_wb_always=1";;
*) fail "UFS_WB: unset or always";; esac
# MODLOAD_SEQ="<module> ..." (2026-11-22, with MODLOAD): modules.options load_sequential=1 (libmodprobe loads them alone)
for m in ${MODLOAD_SEQ:-}; do
	[ -n "${MODLOAD:-}" ] || fail "MODLOAD_SEQ needs MODLOAD"
	[ -f "$W/plan/first/$m.ko" ] || fail "MODLOAD_SEQ: $m.ko is not a first-stage module"
	echo "options $m load_sequential=1" >> "$W/plan/first.params"
done
# ASYNC_MODS="<module> ..." (2026-11-21, default none): probe these first-stage modules asynchronously
# (modules.options async_probe=1, as sec_battery): their slow synchronous probes no longer hold up first-stage init
for m in ${ASYNC_MODS:-}; do
	[ -f "$W/plan/first/$m.ko" ] || fail "ASYNC_MODS: $m.ko is not a first-stage module"
	echo "options $m async_probe=1" >> "$W/plan/first.params"
	say "ASYNC_MODS: modules.options $m async_probe=1"
done
dupo=$(awk '$1=="options"{print $2}' "$W/plan/first.params" | tr - _ | sort | uniq -d | tr '\n' ' ')
[ -z "$dupo" ] || fail "modules.options: more than one options line for: $dupo(libmodprobe keeps only one)"
cp "$W/plan/first.params" "$LM/modules.options"
# The test loaded every module with a plain insmod in list order, so no softdep ever applied.
# libmodprobe would honour the "pre:" ones and pull e.g. qcom_hwspinlock before smem, qcom-pdc
# before pinctrl-msm: keep the tested order, the depmod result stays next to it for reference.
mv "$LM/modules.softdep" "$LM/modules.softdep.depmod"; : > "$LM/modules.softdep"
say "softdeps NOT used (tested order kept): $(grep -vc '^#' "$LM/modules.softdep.depmod") in modules.softdep.depmod"
grep -q '^testguard\|^hhwdt\|^seaprobe\|^a52susp' "$LM/modules.load" && fail "test module in modules.load"
say "first stage: $(wc -l < "$LM/modules.load") modules ($(du -sb "$LM" | cut -f1) bytes); options: $(tr '\n' ';' < "$LM/modules.options")"
if [ "$ADDON" = vendor ]; then
# vendor add-on: late dir with deps reduced to modules of the same dir (the first-stage ones are
# loaded already; libmodprobe would try to open their files otherwise)
VA=$O/vendor-addon; mkdir -p "$VA/lib/modules/$KV" "$VA/lib/modules/$WLD" "$VA/lib/modules/5.4-gki" "$VA/etc/init"
late_dir() {   # <plan group> <dest>
	local g=$1 dst=$2
	cp "$W/plan/$g"/*.ko "$dst/"
	python3 -I - "$W/depall/lib/modules/$KREL/modules.dep" "$W/plan/$g.load" "$W/plan/first.load" "$dst/modules.dep" <<'EOF'
import sys
dep, load, first, out = sys.argv[1:5]
mine = set(l.strip() for l in open(load) if l.strip()); fs = set(l.strip() for l in open(first) if l.strip())
with open(out, 'w') as fh:
    for l in open(dep):
        k, _, v = l.partition(':'); k = k.strip()
        if k not in mine: continue
        deps = v.split(); bad = [d for d in deps if d not in mine and d not in fs]
        if bad: sys.exit(f"{k}: needs {bad}, neither in this dir nor in the first stage")
        # depmod format, no trailing blank: libmodprobe splits on single spaces, and "a.ko: "
        # gives an empty dependency -> "<dir>/" -> every module without deps (and all that need
        # them) fails to load (rehearsal rh612a/rh618a, 2026-11-14: no audio module loaded)
        fh.write(k + ':' + ''.join(' ' + d for d in deps if d in mine) + '\n')
EOF
	cp "$W/plan/$g.load" "$dst/modules.load.order"
	cp "$W/plan/$g.params" "$dst/modules.options"
}
late_dir late "$VA/lib/modules/$KV"
# WLD = the directory macloader will see as /vendor/lib/modules/5.4-gki: 5.4-gki itself (6.12) or
# 6.18-wlan, bind-mounted over 5.4-gki by the 6.18 rc (6.18 keeps the 6.12 files in 5.4-gki untouched;
# the add-on's 5.4-gki is then an empty mount point dir, never pushed over the phone's)
late_dir wlan "$VA/lib/modules/$WLD"
# 5.4-gki/: macloader is the ONLY loader of wlan.ko (it writes wpss_boot first, then finit_module()s
# the file by path; that is what ran in the rehearsal). libmodprobe must see no module there: else
# init.target.rc's "on boot" modprobe -d 5.4-gki qca_cld3_wlan races macloader. Empty modules.dep
# = `modprobe -l` lists nothing (vendor_modprobe.sh's 5.4-gki fallback loads nothing either).
printf '# empty on purpose: wlan.ko here is loaded by macloader only (drivers612/realboot)\n' > "$VA/lib/modules/$WLD/modules.dep"
# vendor_modprobe.sh (early-init) falls back to 5.4-gki/ on 6.12 and loads every module there in
# parallel: block qca_cld3_wlan from that path, macloader and init.target.rc load it later.
echo "blocklist qca_cld3_wlan" > "$VA/lib/modules/$WLD/modules.blocklist"
: > "$VA/lib/modules/$WLD/modules.load"
[ "$WLD" = 5.4-gki ] || [ -z "$(ls -A "$VA/lib/modules/5.4-gki")" ] || fail "the $KV add-on must not carry files in 5.4-gki (the other 6.x kernel's wlan lives there)"
AUDIO=$(sed 's/\.ko$//' "$W/plan/late.load" | tr '\n' ' ' | sed 's/ $//')
# Wi-Fi part: wlan-5.4-gki.rc.in (6.12: wlan.ko in 5.4-gki itself, nothing to do) or wlan-bind.rc.in
# (6.18: bind its own $WLD over 5.4-gki on post-fs; README.md section 2g). init runs `mount` itself (not
# in vendor_init; system/core/init builtins.cpp) and may mounton vendor_file dirs (system/sepolicy
# private/init.te); /vendor/lib/modules/* are vendor_file on this ROM.
[ "$WLD" = 5.4-gki ] && WRC=wlan-5.4-gki.rc.in || WRC=wlan-bind.rc.in
cat "$HERE/vendor-addon/a52sxq-kernel.rc.in" "$HERE/vendor-addon/$WRC" | sed -e "s|@AUDIO_MODULES@|$AUDIO|" -e "s|@KT@|$KT|g" -e "s|@KV@|$KV|g" \
	-e "s|@KDESC@|$KDESC|" -e "s|@NAME@|$NAME|" -e "s|@WLD@|$WLD|g" > "$VA/etc/init/a52sxq-$KT.rc"
grep -q '@[A-Z_]*@' "$VA/etc/init/a52sxq-$KT.rc" && fail "unreplaced placeholder in a52sxq-$KT.rc"
if [ "$WLD" != 5.4-gki ]; then
	grep -q "^    mount none /vendor/lib/modules/$WLD /vendor/lib/modules/5.4-gki bind$" "$VA/etc/init/a52sxq-$KT.rc" || fail "wlan bind line"
	# init's do_mount: "mount <type> <source> <target> [flags]", flag "bind" = MS_BIND (mount_flags[])
	grep -q '{ "bind", *MS_BIND }' ${ANDROID_TREE:-$HOME/android}/system/core/init/builtins.cpp || fail "init has no bind mount flag?"
	say "vendor rc: on post-fs bind /vendor/lib/modules/$WLD over /vendor/lib/modules/5.4-gki (macloader path; the phone's 6.12 wlan.ko there stays)"
fi
{
	# bus DCVS tunables + end of the boot boost + interconnect sync_state, once Android has booted
	# (drivers612/busdcvs/busdcvs.conf; Qualcomm's post_boot does the same; vendor rc writes run as
	# vendor_init, which may write every sysfs file). The paths are checked against the tree in step 4.
	{ printf '\n# Bus DCVS (drivers612/busdcvs/busdcvs.conf, generated by build-realboot.sh): the ROM'"'"'s 5.4 post_boot\n'
	  printf '# writes /sys/class/devfreq nodes that do not exist on %s; these are their bus_dcvs equivalents,\n' "$KV"
	  printf '# then the qcom-dcvs boot boost is dropped and the interconnect providers are told to sync_state\n'
	  printf '# (without that DDR/LLCC keep the INT_MAX boot floor). A failed write is only logged by init.\n'
	  printf 'on property:sys.boot_completed=1 && property:ro.boot.a52sxq.%s=1\n' "$KT"
	  grep -vE '^[[:space:]]*(#|$)' "$BUSDCVS_CONF" | while read -r p v; do printf '    write /sys/%s "%s"\n' "$p" "$v"; done
	} >> "$VA/etc/init/a52sxq-$KT.rc"
	NW=$(grep -c '^    write /sys/' "$VA/etc/init/a52sxq-$KT.rc")
	[ "$NW" = "$(grep -cvE '^[[:space:]]*(#|$)' "$BUSDCVS_CONF")" ] || fail "bus DCVS rc: $NW writes for $(grep -cvE '^[[:space:]]*(#|$)' "$BUSDCVS_CONF") conf lines"
	say "vendor rc: $NW bus-DCVS writes on sys.boot_completed (busdcvs.conf $(sha256sum < "$BUSDCVS_CONF" | cut -c1-16))"
	if [ "${WALT:-0}" = 1 ]; then
		sed -e "s|@KT@|$KT|g" "$HERE/vendor-addon/a52sxq-walt.rc.in" >> "$VA/etc/init/a52sxq-$KT.rc"
		grep -q '@[A-Z_]*@' "$VA/etc/init/a52sxq-$KT.rc" && fail "unreplaced placeholder in a52sxq-$KT.rc (WALT)"
		[ "$(grep -c '/walt/\|scaling_governor "walt"' "$VA/etc/init/a52sxq-$KT.rc")" = "$(grep -cvE '^[[:space:]]*(#|$)' "$HERE/vendor-addon/a52sxq-walt.conf")" ] || fail "WALT rc: write count differs from a52sxq-walt.conf (regenerate a52sxq-walt.rc.in)"
		say "vendor rc: WALT governor + tunables on vendor.post_boot.parsed (persist.vendor.a52sxq.walt_gov=0 reverts)"
	fi
}
say "late (vendor /vendor/lib/modules/$KV, after the ADSP): $(wc -l < "$W/plan/late.load") modules; wlan: $(cat "$W/plan/wlan.load") in /vendor/lib/modules/$WLD"
cp "$W/plan/plan.txt" "$O/module-plan.txt"
# insmod simulation of the real boot order: first stage (modules.load), vendor rc (late.load),
# macloader (wlan): vermagic, symbols, modversion CRCs, duplicate exports, built-in clashes
python3 -I "$HERE/tools/loadsim.py" --krel "$KREL" --symvers "$SYMVERS" --builtin "$DIST/lib/modules/$KREL/modules.builtin" \
	"first:$LM:$LM/modules.load" "late:$VA/lib/modules/$KV:$VA/lib/modules/$KV/modules.load.order" \
	"wlan:$VA/lib/modules/$WLD:$W/plan/wlan.load" > "$W/loadsim.txt" || { cat "$W/loadsim.txt"; fail "insmod simulation"; }
tee -a "$R" < "$W/loadsim.txt" > /dev/null; cat "$W/loadsim.txt"; cp "$W/loadsim.txt" "$O/insmod-simulation.txt"
# libmodprobe dry run of the config files exactly as the ROM's loaders read them (tools/modprobesim.py)
MPS="python3 -I $HERE/tools/modprobesim.py"
{ $MPS --label first-stage --dir "$LM" --as /lib/modules --load-file modules.load \
  && $MPS --label "vendor rc" --dir "$VA/lib/modules/$KV" --as /vendor/lib/modules/$KV --modules $AUDIO; } > "$W/modprobesim.txt" 2>&1 \
	|| { cat "$W/modprobesim.txt"; fail "libmodprobe dry run (modprobesim.py)"; }
$MPS --label 5.4-gki --dir "$VA/lib/modules/$WLD" --as /vendor/lib/modules/5.4-gki --modules qca_cld3_wlan > /dev/null 2>&1 \
	&& fail "libmodprobe would load wlan from 5.4-gki (races macloader)"
echo "modprobe dry run 5.4-gki ($WLD): libmodprobe resolves nothing there (macloader loads qca_cld3_wlan.ko by path)" >> "$W/modprobesim.txt"
tee -a "$R" < "$W/modprobesim.txt" > /dev/null; cat "$W/modprobesim.txt"
else
	# ADDON=vendor_boot: no vendor add-on; the first stage holds everything (checked like the rest)
	VA=$W/no-vendor-addon; rm -rf "$VA"; mkdir -p "$VA"
	for m in $(cat "$W/plan/addon-late.load") wlan.ko; do grep -qx "$m" "$LM/modules.load" || fail "ADDON=vendor_boot: $m not in modules.load"; done
	NAL=$(echo ${ASYNC_LAST:-} | wc -w)   # ASYNC_LAST modules follow wlan.ko
	[ "$(head -n -"$NAL" "$LM/modules.load" | tail -n1)" = wlan.ko ] || fail "ADDON=vendor_boot: wlan.ko is not the last first-stage module (before ASYNC_LAST)"
	grep -qx 'options a52sxq_dsp_boot rescan_after_adsp=1 hold_until_adsp=qcom,adsp-notify+qcom,msm-audio-apr+qcom,audio-ref-clk+qcom,msm-cdc-pinctrl+qcom,q6core-audio+qcom,adsp-loader hold_late=qcom,wcd938x-codec'"${HOLD_MS:+ hold_release_ms=$HOLD_MS}" "$LM/modules.options" || fail "ADDON=vendor_boot: no rescan_after_adsp/hold_until_adsp options"
	modinfo -p "$W/a52sxq_dsp_boot.ko" | grep -q '^rescan_after_adsp:' || fail "a52sxq_dsp_boot.ko has no rescan_after_adsp"
	modinfo -p "$W/a52sxq_dsp_boot.ko" | grep -q '^tunables:' || fail "a52sxq_dsp_boot.ko has no built-in tunables"
	if [ "${WALT:-0}" = 1 ]; then modinfo -p "$W/a52sxq_dsp_boot.ko" | grep -q '^walt_guard_s:' || fail "WALT=1: a52sxq_dsp_boot.ko has no walt_guard_s"; modinfo -p "$W/a52sxq_dsp_boot.ko" | grep -q '^walt_guard_rearm:' || fail "WALT=1: a52sxq_dsp_boot.ko has no walt_guard_rearm"; fi
	cp "$W/plan/plan.txt" "$O/module-plan.txt"
	python3 -I "$HERE/tools/loadsim.py" --krel "$KREL" --symvers "$SYMVERS" --builtin "$DIST/lib/modules/$KREL/modules.builtin" \
		"first:$LM:$LM/modules.load" > "$W/loadsim.txt" || { cat "$W/loadsim.txt"; fail "insmod simulation"; }
	tee -a "$R" < "$W/loadsim.txt" > /dev/null; cat "$W/loadsim.txt"; cp "$W/loadsim.txt" "$O/insmod-simulation.txt"
	MPS="python3 -I $HERE/tools/modprobesim.py"
	$MPS --label first-stage --dir "$LM" --as /lib/modules --load-file modules.load > "$W/modprobesim.txt" 2>&1 \
		|| { cat "$W/modprobesim.txt"; fail "libmodprobe dry run (modprobesim.py)"; }
	tee -a "$R" < "$W/modprobesim.txt" > /dev/null; cat "$W/modprobesim.txt"
	say "ADDON=vendor_boot: no vendor add-on, no vendor rc; first stage $(wc -l < "$LM/modules.load") modules ($(du -sb "$LM" | cut -f1) bytes)"
fi

# ---------------------------------------------------------------- 4. device tree
say "== 4. device tree"
H=$TOP/drivers612/hwbringup/dt; T=$W/dt
MERGED=$TOP/drivers612/boarddt/out/build/merged-r02.dtb
OVS1="$H/gpu.dtbo $H/video.dtbo"
OVS2="$H/audio.dtbo $H/fastrpc.dtbo $TOP/drivers612/camera/dt-work/check-overlay.dtbo $TOP/drivers612/fingerprint/dt-work/a52sxq-fingerprint.dtbo $TOP/drivers612/vibrator/a52sxq-vibrator.dtbo $TOP/drivers612/nfc/dt-work/a52sxq-nfc.dtbo"
for f in $MERGED $OVS1 $OVS2; do [ -f "$f" ] || fail "missing dt input $f (run kexec/mkandroidtree.sh once)"; done
mkdir -p "$T"
# the same steps as kexec/mkandroidtree.sh, from its already built inputs, WITHOUT
# kexec/mkfulltree.sh's test edit (ssusb extcon cut to the EUD)
cp "$MERGED" "$T/base.dtb"
[ "$USB_EXTCON" = eud ] && fdtput -t u "$T/base.dtb" /soc/ssusb@a600000 extcon "$(fdtget -t u "$T/base.dtb" /soc/ssusb@a600000 extcon | cut -d' ' -f1)"
fdtoverlay -i "$T/base.dtb" -o "$T/gv.dtb" $OVS1
for n in qcom,secure_cdsp qcom,display; do fdtput -t s "$T/gv.dtb" /soc/qcom,dma-heaps/$n status disabled; done
fdtoverlay -i "$T/gv.dtb" -o "$T/rb.dtb" $OVS2
fdtput -t s "$T/rb.dtb" /soc/qcom,pmic_glink/qcom,battery_charger status disabled
B=/soc/qcom,msm-audio-apr/qcom,q6core-audio/bolero-cdc
for n in rx-macro@3200000/rx_swr_master tx-macro@3220000/tx_swr_master wsa-macro@3240000/wsa_swr_master; do
	fdtput -t x "$T/rb.dtb" $B/$n qcom,swr-master-version 0x01060000; done
# bus DCVS: no SCMI vendor-protocol nodes (the CPUCP firmware lacks them; else qcom-pmu-lib + memlat defer
# forever): the same step as in kexec/mkandroidtree.sh (drivers612/busdcvs/dt-fix.sh); the 6.18 tested
# tree (mkdtb-618.sh) is made from that 6.12 tree, so it has the same edit
DTFIX=$("$TOP/drivers612/busdcvs/dt-fix.sh" "$T/rb.dtb") || fail "busdcvs dt-fix.sh"; say "$DTFIX"
# the modem stays off for the comparison with the tested tree; MODEM=1 switches it on below
fdtput -t s "$T/rb.dtb" "$(fdtget "$T/rb.dtb" /__symbols__ modem_pas)" status disabled
# 6.18: bsp618/android/mkdtb-618.sh's test-safety edit (kept: the tested tree had it): a dwc3
# SMMU context fault is printed and terminated instead of the forked arm_smmu's BUG()
U=/soc/ssusb@a600000/dwc3@a600000
[ "$SMMU_NONFATAL" = 1 ] && fdtput -t s "$T/rb.dtb" $U qcom,iommu-faults non-fatal
# 5.4 sysfs paths for the ROM's genfscon labels (research/sepolicy/PATHS.md): QUP I2C/SPI/UART
# nodes as /soc children with qcom,wrapper-core, /aliases i2cN = the 5.4 bus numbers; the same
# step as at the end of kexec/mkandroidtree.sh (so the tested tree below matches)
SC="python3 -I $TOP/drivers612/boarddt/tools/sysfscompat.py"
cp "$T/rb.dtb" "$T/rb-wrapperlayout.dtb"
$SC apply "$T/rb-wrapperlayout.dtb" "$T/rb.dtb" > "$W/sysfscompat.txt" || { cat "$W/sysfscompat.txt"; fail "sysfscompat apply"; }
$SC verify "$T/rb-wrapperlayout.dtb" "$T/rb.dtb" >> "$W/sysfscompat.txt" || { cat "$W/sysfscompat.txt"; fail "sysfscompat verify"; }
say "5.4 sysfs layout: $(tail -1 "$W/sysfscompat.txt")"
# the moved nodes need the geni drivers with bsp612/patches/soc-repo/0009 (wrapper by phandle)
GENI=$(ls "$W"/plan/{first,late,wlan}/{i2c-msm-geni,spi-msm-geni,msm_geni_serial}.ko 2>/dev/null || true)
[ -n "$GENI" ] || fail "no geni module in the module plan"
$SC ko-patched $GENI >> "$W/sysfscompat.txt" 2>&1 || { cat "$W/sysfscompat.txt"; fail "geni modules of $REF lack soc-repo patch 0009 (the 5.4-layout tree needs it)"; }
say "geni modules with 0009: $(for g in $GENI; do basename "$g"; done | tr '\n' ' ')"
# simulated sysfs paths of the i2c clients / UARTs (sysfscompat.py sim: of_device_make_bus_id +
# the i2c core's alias numbering); the two the rb10 denials were about must be the 5.4 ones
$SC sim "$T/rb.dtb" | grep -E '\.i2c/i2c-[0-9]+/|qup_uart|qup_hsuart' > "$W/sysfs-sim.txt"
for p in /devices/platform/soc/98c000.i2c/i2c-21/21-0049 /devices/platform/soc/a94000.i2c/i2c-25/25-0049; do
	cut -f1 "$W/sysfs-sim.txt" | grep -qx "$p" || fail "simulated sysfs: no $p (5.4 path of the genfscon label)"; done
say "simulated sysfs: SM5714 /sys$(cut -f1 "$W/sysfs-sim.txt" | grep -x '.*/21-0049'), touch /sys$(cut -f1 "$W/sysfs-sim.txt" | grep -x '.*/25-0049')"
cp "$W/sysfs-sim.txt" "$W/sysfscompat.txt" "$O/" 2>/dev/null || true
# proof that this is the tested tree: against the run's KEXEC_BASE (minus its kexec-only nodes)
# only the extcon may differ (none with USB_EXTCON=eud)
if [ -f "$TREF" ]; then
	cp "$TREF" "$T/tref.dtb"
	for n in $KEXEC_ONLY_NODES; do
		fdtget -l "$T/tref.dtb" "$n" >/dev/null 2>&1 || fail "tested tree $TREF has no $n (kexec-only node expected)"
		fdtput -r "$T/tref.dtb" "$n"; say "tested tree: kexec-only node $n left out"
	done
	if [ "$SMMU_NONFATAL" != 1 ] && fdtget "$T/tref.dtb" $U qcom,iommu-faults >/dev/null 2>&1; then fdtput -d "$T/tref.dtb" $U qcom,iommu-faults; fi
	dtc -q -I dtb -O dts -o "$T/ref.dts" "$T/tref.dtb"; dtc -q -I dtb -O dts -o "$T/rb.dts" "$T/rb.dtb"
	diff "$T/ref.dts" "$T/rb.dts" > "$T/vs-tested.diff" || true
	NDIFF=$(grep -c '^[<>]' "$T/vs-tested.diff" || true)
	if [ "$USB_EXTCON" = eud ]; then [ "$NDIFF" = 0 ] || fail "tree differs from the tested $TREF ($T/vs-tested.diff)"
	else [ "$NDIFF" = 2 ] && grep -q '^> .*extcon = <' "$T/vs-tested.diff" || fail "tree differs from the tested $TREF beyond the extcon ($T/vs-tested.diff)"; fi
	say "tree = the tested $(basename "$TREF") ($REF) except: $( [ "$NDIFF" = 0 ] && echo nothing || sed -n 's/^> *//p' "$T/vs-tested.diff")"
else fail "no tested tree $TREF to compare with"; fi
if [ "$MODEM" = 1 ]; then
	# drivers612/modem/dt/mkmodemtree.sh = the tree edit of the kernel-only modem runs (modem_pas okay,
	# memshare client_4 off) + dt/ipa-iova-fix.sh, and its checks (mpss/IPA GSI regions, IPA, rmnet,
	# rmtfs UIO, glinkpkt and memshare nodes enabled, no upstream qcom,rmtfs-mem, no qcom,sc7280)
	cp "$T/rb.dtb" "$T/rb-nomodem.dtb"
	"$TOP/drivers612/modem/dt/mkmodemtree.sh" "$T/rb-nomodem.dtb" "$T/rb.dtb" > "$W/mkmodemtree.txt" 2>&1 || { cat "$W/mkmodemtree.txt"; fail "MODEM=1: mkmodemtree.sh"; }
	grep -q '^ipa-iova-fix: ' "$W/mkmodemtree.txt" || fail "MODEM=1: the IPA IOVA fix did not run"
	MSS=$(fdtget "$T/rb.dtb" /__symbols__ modem_pas); IPA=/soc/qcom,ipa@1e00000
	IPAFIX="--allow $IPA:#address-cells --allow $IPA:#size-cells --allow /soc/ipa_ap_iommu_region_partition:iommu-addresses --allow /soc/ipa_uc_iommu_region_partition:iommu-addresses"
	# 1) against the tree without the modem: exactly these properties changed, nothing else in the whole tree
	python3 -I "$HERE/tools/dtcompare.py" "$T/rb-nomodem.dtb" "$T/rb.dtb" --path / --allow "$MSS:status" \
		--allow /soc/qcom,memshare/qcom,client_4:status $IPAFIX > "$W/modem-delta.txt" || { cat "$W/modem-delta.txt"; fail "MODEM=1: the modem edit changed more than expected"; }
	[ "$(grep -c '^allowed: ' "$W/modem-delta.txt")" = 6 ] || { cat "$W/modem-delta.txt"; fail "MODEM=1: expected 6 changed properties"; }
	# 2) the modem subtrees = those of the kexec tree that brought LTE data up on 6.12 (phandles compared
	#    by target path), except the IPA IOVA fix
	MRES=$(for l in pil_mpss_mem pil_ipa_gsi_mem memshare_mem modem_shared_mem; do fdtget "$T/rb.dtb" /__symbols__ $l 2>/dev/null || fail "MODEM=1: no symbol $l"; done)
	SP2P=/soc/qcom,smp2p-modem; fdtget -l "$T/rb.dtb" $SP2P > /dev/null || fail "MODEM=1: no $SP2P"
	#    and, for 6.18, also those of the 6.18 kernel-only modem run (MODEM_TESTED_DTB2: modem up on 6.18)
	MPATHS=$(for p in "$MSS" /soc/qcom,memshare $IPA /soc/ipa_ap_iommu_region_partition \
		/soc/ipa_uc_iommu_region_partition /soc/qcom,rmnet-ipa /soc/qcom,msm_gsi /soc/qcom,rmtfs_sharedmem@0 /soc/qcom,glinkpkt $SP2P $MRES; do echo --path "$p"; done)
	python3 -I "$HERE/tools/dtcompare.py" "$T/rb.dtb" "$MODEM_TESTED_DTB" $MPATHS \
		$IPAFIX > "$W/modem-vs-tested.txt" || { cat "$W/modem-vs-tested.txt"; fail "MODEM=1: modem subtrees differ from the tested $MODEM_TESTED_DTB"; }
	if [ -n "$MODEM_TESTED_DTB2" ]; then
		python3 -I "$HERE/tools/dtcompare.py" "$T/rb.dtb" "$MODEM_TESTED_DTB2" $MPATHS \
			$IPAFIX > "$W/modem-vs-tested2.txt" || { cat "$W/modem-vs-tested2.txt"; fail "MODEM=1: modem subtrees differ from the tested $MODEM_TESTED_DTB2"; }
		cp "$W/modem-vs-tested2.txt" "$O/"
		say "MODEM=1 tree vs $(basename "$(dirname "$MODEM_TESTED_DTB2")") ($KV modem run): $(tail -1 "$W/modem-vs-tested2.txt" | sed 's/^dtcompare: //')"
	fi
	# 3) what the kernel will make of the IPA IOVA reservations (model checked against the run logs:
	#    the old tree gives the logged "Cannot reserve IOVA region of 0 size" lines)
	for cb in ap uc; do python3 -I "$HERE/tools/iommu-resv-sim.py" "$T/rb.dtb" $IPA/ipa_smmu_$cb --expect-fast 20000000-3fffffff --expect-no-warn; done > "$W/ipa-iova.txt" \
		|| { cat "$W/ipa-iova.txt"; fail "MODEM=1: IPA IOVA window is not the 5.4 pool"; }
	[ "$(fdtget "$T/rb.dtb" /soc/qcom,rmtfs_sharedmem@0 compatible)" = qcom,sharedmem-uio ] && [ "$(fdtget "$T/rb.dtb" /soc/qcom,rmtfs_sharedmem@0 reg-names)" = rmtfs ] \
		&& [ "$(fdtget "$T/rb.dtb" /soc/qcom,rmtfs_sharedmem@0 status 2>/dev/null || echo okay)" = okay ] || fail "MODEM=1: no enabled rmtfs UIO node"
	cp "$W/mkmodemtree.txt" "$W/modem-delta.txt" "$W/modem-vs-tested.txt" "$W/ipa-iova.txt" "$O/"
	say "MODEM=1 tree: $(tail -1 "$W/mkmodemtree.txt" | sed 's#.*: ##'); delta to the tested tree: $(grep -c '^allowed: ' "$W/modem-delta.txt") properties (modem_pas status, client_4 status, IPA cells + 2 iommu-addresses); vs $(basename "$(dirname "$MODEM_TESTED_DTB")"): $(tail -1 "$W/modem-vs-tested.txt" | sed 's/^dtcompare: //')"
	say "MODEM=1 IPA IOVA: $(grep 'fastmap IOVA range' "$W/ipa-iova.txt" | sed 's/.*ipa_smmu_\([a-z]*\): merged \(.*\); fastmap IOVA range \(.*\)/\1 \3/' | tr '\n' ' ')(5.4 pool 0x20000000 + 512 MiB; was [0x40000000, 0xffffffff] in the runs)"
	say "MODEM=1 rmtfs UIO: /soc/qcom,rmtfs_sharedmem@0 qcom,sharedmem-uio reg-names rmtfs size $(fdtget -t x "$T/rb.dtb" /soc/qcom,rmtfs_sharedmem@0 reg | awk '{print $NF}') (dynamic buffer, no fixed rmtfs region)"
fi
# real-boot additions: the DSP starter node, the Qualcomm bootargs, a marker
if [ "${BTSLIM:-0}" = 1 ]; then
	SND=/soc/qcom,msm-audio-apr/qcom,q6core-audio/sound
	fdtget "$T/rb.dtb" $SND qcom,model > /dev/null || fail "BTSLIM=1: no $SND"
	[ "$(fdtget "$T/rb.dtb" /soc/slim@3ac0000/ngd@1/btfmslim-driver compatible)" = slim217,221 ] || fail "BTSLIM=1: no btfmslim child under slim@3ac0000/ngd@1"
	fdtput -t u "$T/rb.dtb" $SND qcom,wcn-btfm 1
	say "BTSLIM=1: $SND qcom,wcn-btfm = <1> (BT back ends, codec btfmslim_slave: SLIMBUS_7_RX/TX with the 99916b9 machine_dlkm = the 5.4 set; + SLIMBUS_8_TX with the s88 one)"
fi
if [ "${QRNG:-0}" = 1 ]; then
	N=/soc/rng@10d3000; fdtget "$T/rb.dtb" $N reg > /dev/null || fail "QRNG=1: no $N"
	GEM=$(fdtget -tx "$T/rb.dtb" /soc/interconnect@9100000 phandle); CN2=$(fdtget -tx "$T/rb.dtb" /soc/interconnect@1500000 phandle)
	RPMH=$(fdtget -tx "$T/rb.dtb" /soc/rsc@18200000/drv@2/qcom,rpmhclk phandle)
	[ -n "$GEM" ] && [ -n "$CN2" ] && [ -n "$RPMH" ] || fail "QRNG=1: provider phandles"
	fdtput -t s "$T/rb.dtb" $N compatible qcom,msm-rng
	fdtput -t x "$T/rb.dtb" $N qcom,no-qrng-config
	fdtput -t s "$T/rb.dtb" $N interconnect-names data_path
	fdtput -t x "$T/rb.dtb" $N interconnects 0x$GEM 0x2 0x$CN2 0x20f
	fdtput -t s "$T/rb.dtb" $N clock-names km_clk_src
	fdtput -t x "$T/rb.dtb" $N clocks 0x$RPMH 0x18
	say "QRNG=1: $N = qcom,msm-rng with the 5.4 qrng properties (km_clk_src = rpmh HWKM, icc data_path gem_noc -> cnoc2 hwkm)"
fi
if [ "${HALL:-0}" = 1 ]; then
	fdtget "$T/rb.dtb" /soc/hall_keys/hall linux,code > /dev/null || fail "HALL=1: no /soc/hall_keys/hall"
	fdtput -t s "$T/rb.dtb" /soc/hall_keys status okay
	fdtput -t s "$T/rb.dtb" /soc/hall_keys label hall
	fdtput -t x "$T/rb.dtb" /soc/hall_keys/hall linux,code 0
	say "HALL=1: /soc/hall_keys okay, input 'hall', SW_LID (gpio-keys, built in; 5.4: Samsung hall_ic, SW_LID)"
fi
# ARGOS=1: Samsung /soc/argos (drivers612/samsung-oneui/argos/argos.dtsi; the vendor argosd exits without it, sec_argos.ko
# reads it); applied as an overlay (labels soc/gem_noc/mc_virt from the tree's __symbols__)
if [ "${ARGOS:-0}" = 1 ]; then
	AD=$TOP/drivers612/samsung-oneui/argos/argos.dtsi; [ -f "$AD" ] || fail "ARGOS=1: no $AD"
	printf '/dts-v1/;\n/plugin/;\n#include "%s"\n' "$AD" > "$T/argos-ov.dts"
	cpp -nostdinc -undef -x assembler-with-cpp -P "$T/argos-ov.dts" | dtc -@ -q -I dts -O dtb -o "$T/argos.dtbo" - || fail "ARGOS=1: argos overlay does not compile"
	fdtoverlay -i "$T/rb.dtb" -o "$T/rb-argos.dtb" "$T/argos.dtbo" || fail "ARGOS=1: argos overlay does not apply"
	mv "$T/rb-argos.dtb" "$T/rb.dtb"
	[ "$(fdtget -l "$T/rb.dtb" /soc/argos | grep -c '^boot_device@')" = 7 ] || fail "ARGOS=1: /soc/argos without 7 boot_device@ children"
	say "ARGOS=1: /soc/argos with 7 boot_device@N (5.4 fragment@84) + interconnects gem_noc 2 -> mc_virt 512"
fi
# PROCA_HDR_RES=<phys>: keep the kernel's Image header page [_text, _stext) out of the page allocator (6.12 reserves only
# from _stext, 5.4 from _text) so the PROCA TA can read the header magic at runtime; <phys> = the ABL's kernel load
# address (rbou4: /proc/iomem "Kernel code" 0xa00d0000 - 0x10000). Plain reserved-memory, not no-map. (test, 2026-11-22)
if [ -n "${PROCA_HDR_RES:-}" ]; then
	N=/reserved-memory/proca_hdr@$(printf %x "$PROCA_HDR_RES")
	fdtput -c "$T/rb.dtb" "$N" && fdtput -t x "$T/rb.dtb" "$N" reg 0 "$(printf %x "$PROCA_HDR_RES")" 0 10000 || fail "PROCA_HDR_RES: fdtput"
	say "PROCA_HDR_RES: $N reg <0 $PROCA_HDR_RES 0 0x10000> (Image header page kept)"
fi
case " ${THERMAL_X:-} " in *" bclmap "*)
	for n in 4 5 6 7; do ph=$(fdtget -t u "$T/rb.dtb" /soc/qcom,cpu-pause/cpu$n-pause phandle) || fail "THERMAL_X=bclmap: no cpu$n-pause"
		fdtput -t u "$T/rb.dtb" /soc/thermal-zones/pm8350c-bcl-lvl0/cooling-maps/vph_cpu$n cooling-device $ph 1 1; done
	say "THERMAL_X=bclmap: pm8350c-bcl-lvl0 vph_cpu4..7 -> cpuN-pause cooling devices";; esac
fdtput -c "$T/rb.dtb" /soc/a52sxq-dsp-boot
fdtput -t s "$T/rb.dtb" /soc/a52sxq-dsp-boot compatible "a52sxq,dsp-boot"
fdtput -t x "$T/rb.dtb" /soc/a52sxq-dsp-boot qcom,adsp-rproc "$(fdtget -t x "$T/rb.dtb" "$(fdtget "$T/rb.dtb" /__symbols__ adsp_pas)" phandle)"
fdtput -t x "$T/rb.dtb" /soc/a52sxq-dsp-boot qcom,cdsp-rproc "$(fdtget -t x "$T/rb.dtb" "$(fdtget "$T/rb.dtb" /__symbols__ cdsp_pas)" phandle)"
# Qualcomm's yupik /chosen/bootargs: the Samsung ABL APPENDS to them (live tree of the 5.4
# boot), so on a real boot they apply, unlike kexec_file_load which replaced them. Replaced
# here by the subset every Android run used (drivers612/androidboot/out/android-cmdline.txt);
# left out of Qualcomm's list (untested): fw_devlink.strict=1, cpufreq.default_governor=
# performance, sysctl.kernel.panic_on_rcu_stall=1, ftrace_dump_on_oops, slub_debug=-,
# swiotlb=0, pcie_ports=compat, printk.console_no_auto_verbose=1, loglevel=6, log_buf_len=512K.
QCOM_BOOTARGS="android_arch_task_struct_size=512 rcupdate.rcu_expedited=1 rcu_nocbs=0-7 kpti=0 arm64.nosme sysctl.kernel.sched_pelt_multiplier=4 no-steal-acc irqaffinity=0-1 kasan=off cgroup_disable=pressure restrict_cma_redirect=false${EXTRA_BOOTARGS:+ $EXTRA_BOOTARGS}"
# every one of them was on the tested kexec command line of this kernel
TESTED_CMDLINE=$(cat "$TESTED_CMDLINE_FILE")
# UNTESTED_OK: words allowed although no kexec-tested cmdline had them; they must be proven by a real-boot
# rehearsal (rehearse.sh runs the real-boot cmdline) before a flash. sync_state timeout: bus DCVS floor (2026-11-15).
UNTESTED_OK=" fw_devlink.sync_state=timeout deferred_probe_timeout=30 "
for w in $QCOM_BOOTARGS; do case " $TESTED_CMDLINE " in *" $w "*) ;; *) case "$UNTESTED_OK" in *" $w "*) say "WARNING: DT bootarg $w is new (allowed; rehearse before flashing)";; *) fail "DT bootarg $w was not on the tested $KV cmdline";; esac;; esac; done
say "Qualcomm DT bootargs were: $(fdtget "$T/rb.dtb" /chosen bootargs)"
DT_BOOTARGS="$QCOM_BOOTARGS${DIAG_BOOTARGS:+ $DIAG_BOOTARGS}"
fdtput -t s "$T/rb.dtb" /chosen bootargs "$DT_BOOTARGS"
printf '%s\n' "$DT_BOOTARGS" > "$W/dt-bootargs.txt"
fdtput -t s "$T/rb.dtb" /soc a52sxq,realboot-base "$NAME"
if [ "$DIAG_KERNEL" = 1 ]; then
	# the a52bc area (kernel-diag/a52bc.c): 128 KiB at 0xf0be0000, the last 128 KiB of the 5.4
	# ramoops MiB, outside our ramoops (0xf0b00000+0xe0000); survives a warm reset (0xf0c00000
	# does not); the 6.18 harness reserves the same range and prints it as /proc/a52ram
	A=/reserved-memory/a52ram@f0be0000
	fdtput -c "$T/rb.dtb" $A; fdtput -t s "$T/rb.dtb" $A compatible a52,ramcon
	fdtput -t x "$T/rb.dtb" $A reg 0 f0be0000 0 20000; fdtput "$T/rb.dtb" $A no-map
	python3 -I "$HERE/tools/resv-overlap.py" "$T/rb.dtb" a52ram@f0be0000 || fail "a52ram region overlaps another reservation"
	fdtput -t s "$T/rb.dtb" /soc a52sxq,realboot-diag "a52bc ring 0xf0be0000; bootargs: $DIAG_BOOTARGS"
	say "DIAG: /reserved-memory/a52ram@f0be0000 (a52,ramcon, no-map) added; DT bootargs + $DIAG_BOOTARGS"
fi
dtc -q -I dtb -O dtb -o "$W/vendor_boot.dtb" "$T/rb.dtb"   # repack (fdtput leaves slack)
D=$W/vendor_boot.dtb
# checks of research/bootloader-acceptance.md
strings "$D" | grep -qx __symbols__ || fail "base dtb has no __symbols__"
for p in /soc/qcom,wdt@17c10000 /soc/timer /chosen /reserved-memory /firmware/android; do fdtget -l "$D" $p >/dev/null 2>&1 || fail "$p missing (ABL / hypervisor overlay target)"; done
for l in soc intc reserved_memory aliases firmware wdog arch_timer qcom_tzlog; do fdtget "$D" /__symbols__ $l >/dev/null 2>&1 || fail "label $l lost"; done
[ "$(fdtget "$D" / qcom,msm-id)" = "475 65536 515 65536" ] && [ "$(fdtget "$D" / qcom,board-id)" = "0 0" ] || fail "root msm-id/board-id are not the stock base values"
fdtget -l "$D" /reserved-memory | grep -qi '^kaslr_region@a0001000$' || fail "no kaslr_region@A0001000 (ABL writes its KASLR offset there)"
fdtget -l "$D" /reserved-memory | grep -qi '^ramoops@f0b00000$' || fail "no ramoops@F0B00000"
fdtget -l "$D" /reserved-memory | grep -qi 'rmtfs' && fail "tree has an rmtfs region (kexec carry-over?)" || say "no fixed rmtfs region (5.4 uses a dynamic qcom,sharedmem-uio one; nothing assigns 0x9c900000 without the harness)"
# no kexec artefact may be in the real tree (kexec/mkkexecdtb.py, bsp618/android/mkdtb-618.sh)
KXRE='^kexec-live\|^uh_guest_region\|^uh_heap_region'; [ "$DIAG_KERNEL" = 1 ] || KXRE="^a52ram\\|$KXRE"
fdtget -l "$D" /reserved-memory | grep -qi "$KXRE" && fail "kexec-only reserved-memory node in the tree"
if [ "$DIAG_KERNEL" = 1 ]; then [ "$(fdtget "$D" /reserved-memory/a52ram@f0be0000 compatible)" = a52,ramcon ] || fail "DIAG: a52ram node missing"; fi
fdtget -l "$D" / | grep -qx hypervisor && fail "/hypervisor in the tree (the hypervisor's own overlay adds it on a real boot)"
[ "$(fdtget "$D" /soc/qcom,wdt@17c10000 status 2>/dev/null || echo none)" = reserved ] && fail "watchdog status from a kexec live tree"
MEMN=$(fdtget -l "$D" / | grep '^memory' | head -1)
[ -n "$MEMN" ] && [ "$(fdtget -t x "$D" "/$MEMN" reg 2>/dev/null | wc -w)" -gt 4 ] && fail "memory banks filled in (kexec copy): the ABL fills /memory"
say "no kexec artefacts: no a52ram/kexec-live/uh_* reserved-memory, no /hypervisor, watchdog status and /$MEMN reg as in the stock base ($(fdtget -t x "$D" "/$MEMN" reg 2>/dev/null))"
[ "$(fdtget "$D" /soc/ssusb@a600000 extcon | wc -w)" = $([ "$USB_EXTCON" = eud ] && echo 1 || echo 2) ] || fail "ssusb extcon not as USB_EXTCON=$USB_EXTCON"
say "vendor_boot dtb: $(stat -c %s "$D") bytes, msm-id/board-id = stock base, labels and ABL targets present"
python3 -I "$TOP/drivers612/busdcvs/check-conf.py" "$D" "$BUSDCVS_CONF" > "$W/busdcvs-check.txt" || { cat "$W/busdcvs-check.txt"; fail "bus DCVS conf vs tree"; }
say "bus DCVS: $(tail -1 "$W/busdcvs-check.txt")"
if [ "$MODEM" = 1 ]; then
	[ "$(fdtget "$D" "$(fdtget "$D" /__symbols__ modem_pas)" status)" = okay ] || fail "MODEM=1: modem_pas not okay in the final tree"
	# /dev nodes of the modem/data modules: owner/group/mode the ROM's ueventd gives them (system
	# ueventd.rc, then the vendor one; last match wins) = what the same nodes had on 5.4
	python3 -I "$HERE/tools/ueventd-check.py" --ueventd "$SYS_UEVENTD" --ueventd "$ROM_UEVENTD" --config-fs "$ROM_CONFIGFS" \
		--aid-header "$AID_HEADER" --dev54 "$DEV54" --dtb "$D" --modules "$LM" -o "$O/modem-devnodes.txt" > "$W/ueventd-check.txt" \
		|| { cat "$W/ueventd-check.txt"; fail "MODEM=1: ueventd owners of the modem device nodes"; }
	cp "$W/ueventd-check.txt" "$O/"; tee -a "$R" < "$W/ueventd-check.txt" > /dev/null
	grep -q '^firmware_directories .*/vendor/firmware-modem/image/' "$ROM_UEVENTD" || fail "MODEM=1: ROM ueventd has no /vendor/firmware-modem/image firmware directory"
	say "MODEM=1 ueventd: $(tail -1 "$W/ueventd-check.txt") (ROM ueventd $(sha256sum < "$ROM_UEVENTD" | cut -c1-16), 5.4 /dev listing $(basename "$DEV54"))"
fi
# dtbo
sed "s|@MARKER@|$NAME|" "$HERE/dts/a52sxq-realboot-dtbo.dts" > "$W/dtbo.dts"
# -p 65536: the ABL's libufdt re-writes the merged tree into a buffer sized base + overlays and grows the
# string table by ~1.1 KB; without free space in the dtbo entry it NULL-derefs (rb4..rb8 bootloops,
# ABL-HANG.md). Stock dtbo entries carry ~256 KB.
dtc -q -@ -p 65536 -I dts -O dtb -o "$W/realboot.dtbo" "$W/dtbo.dts"
strings "$W/realboot.dtbo" | grep -qx __fixups__ || fail "dtbo has no __fixups__"
fdtoverlay -i "$D" -o "$W/merged-by-abl.dtb" "$W/realboot.dtbo" || fail "dtbo does not apply on the base"
[ "$(stat -c %s "$W/merged-by-abl.dtb")" -lt $((0x201000)) ] || fail "merged dtb >= 0x201000 (ABL limit)"
[ "$(fdtget "$W/merged-by-abl.dtb" /soc a52sxq,realboot)" = "$NAME" ] || fail "marker not applied"
"$HERE/tools/ufdt-host/check.sh" "$D" "$W/realboot.dtbo" 16384 >> "$R" 2>&1 || fail "ABL libufdt emulation: merged tree does not fit with 16 KiB to spare (tools/ufdt-host/check.sh)"
say "ABL libufdt emulation: overlay merge fits ($(tail -1 "$R"))"
python3 -I "$MKDTBOIMG" create "$W/dtbo-raw.img" --page_size=4096 "$W/realboot.dtbo" > /dev/null
python3 -I "$MKDTBOIMG" dump "$W/dtbo-raw.img" > "$W/dtbo-table.txt"
say "dtbo: 1 entry, board-id <0x22 2> (rev >= 2), applies on the base (fdtoverlay; the ABL's libufdt was never run offline)"

# ---------------------------------------------------------------- 5. command line
say "== 5. command line"
FWPATH=/vendor/firmware_mnt/image,/vendor/firmware
# MODEM=1: modem.mdt/.bNN are in /vendor/firmware-modem/image (the phone's own modem partition): loaded
# directly instead of through force_sysfs_fallback + ueventd (5.4's way; the second recovery of run
# ab-s18 got -ENOENT from that path, unexplained); last entry, so nothing else is looked up there first
[ "$MODEM" = 1 ] && FWPATH=$FWPATH,/vendor/firmware-modem/image
VC="console=null androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 loop.max_part=7 firmware_class.path=$FWPATH iptable_raw.raw_before_defrag=1 ip6table_raw.raw_before_defrag=1 printk.devkmsg=on"
# IGNORE_UNUSED=1 all three, 0 none, or a list of the ones to KEEP: "clk pd regulator" (A/B of single words)
case "$IGNORE_UNUSED" in 1) IGN="clk pd regulator";; 0) IGN=;; *) IGN=$IGNORE_UNUSED;; esac
for w in $IGN; do case "$w" in clk|pd|regulator) VC="$VC ${w}_ignore_unused";; *) fail "IGNORE_UNUSED: $w";; esac; done
# the gate of the vendor add-on rc; ADDON=vendor_boot sets a different one, so an add-on rc left on
# /vendor by an earlier install stays inert (nothing may come from /vendor)
[ "$ADDON" = vendor ] && VC="$VC androidboot.a52sxq.$KT=1" || VC="$VC androidboot.a52sxq.${KT}vb=1"
# first-stage init loads modules.load strictly: the first module whose init fails ends in
# LOG(FATAL) -> reboot to the bootloader, every boot. "2" (IGNORE_FAILURE, userdebug init only)
# logs the failure and goes on; the ROM is userdebug. MODULE_FAILURES=fatal leaves it out.
[ "${MODULE_FAILURES:-ignore}" = ignore ] && VC="$VC androidboot.first_stage_console=2"
[ "$SELINUX" = permissive ] && VC="$VC androidboot.selinux=permissive"
# DEBUG=1: a52sxq_dsp_boot's kernel-log file /sys/devices/system/cpu/a52kmsg (off without this flag)
[ "$DEBUG" = 1 ] && { VC="$VC androidboot.a52sxq.debug=1"; say "DEBUG=1: androidboot.a52sxq.debug=1 (a52kmsg kernel log for root/system/shell): NOT for a release or daily build"; }
# KSU=1 (2026-11-19, default 0; IchthysOS line, proven by hand as rbich20 on broken screen): KernelSU-Next as an LKM.
# /ksuinit (static, 0755) + /kernelsu.ko (0644) at the ROOT of the vendor ramdisk fragment and rdinit=/ksuinit:
# ksuinit runs as PID 1, resolves the module's unexported symbols from kallsyms, insmods it and execs the ROM's
# /init; its crash guard skips KSU for one boot when pstore holds a panic record. boot.img is unchanged.
KSU=${KSU:-0}; case "$KSU" in 0|1) ;; *) fail "KSU=0|1";; esac
if [ "$KSU" = 1 ]; then
	KSUD=${KSU_DIR:-$HERE/modules/kernelsu/out}
	[ -f "$KSUD/ksuinit" ] && [ -f "$KSUD/kernelsu.ko" ] || fail "KSU=1: no $KSUD/ksuinit + kernelsu.ko"
	file -b "$KSUD/ksuinit" | grep -q 'ELF 64-bit.*ARM aarch64.*statically linked' || fail "KSU=1: ksuinit is not a static aarch64 executable"
	strings "$KSUD/kernelsu.ko" | grep -q "^vermagic=$KREL " || fail "KSU=1: kernelsu.ko vermagic is not $KREL"
	echo " $VC " | grep -q ' rdinit=' && fail "KSU=1: the command line already has an rdinit="
	VC="$VC rdinit=/ksuinit"
	say "KSU=1: rdinit=/ksuinit; ksuinit $(sha256sum < "$KSUD/ksuinit" | cut -c1-16), kernelsu.ko $(sha256sum < "$KSUD/kernelsu.ko" | cut -c1-16) at the root of the vendor ramdisk fragment"
fi
# USERSPACE=samsung|aosp (2026-11-24, SPEC/05 section 2): a52sxq.userspace= for a52sxq.ko (first-stage init passes
# a52sxq.* cmdline words to the module as options); default auto = nothing (the module detects it).
case "${USERSPACE:-auto}" in
	auto) ;;
	samsung|aosp)
		echo " $VC " | grep -q ' a52sxq\.userspace=' && fail "USERSPACE: the command line already has a52sxq.userspace="
		VC="$VC a52sxq.userspace=$USERSPACE"
		say "USERSPACE=$USERSPACE: a52sxq.userspace=$USERSPACE on the vendor cmdline";;
	*) fail "USERSPACE: samsung, aosp or auto";;
esac
[ -n "${EXTRA_CMDLINE:-}" ] && VC="$VC $EXTRA_CMDLINE"
printf '%s\n' "$VC" > "$W/vendor-cmdline.txt"
case " $VC $QCOM_BOOTARGS " in *" a52."*|*" a52sxq-"*|*" loglevel=7 "*|*" earlycon"*|*" log_buf_len="*) fail "test-only argument in the cmdline";; esac
say "vendor_boot cmdline (${#VC}): $VC"
say "dtb /chosen/bootargs (${#DT_BOOTARGS}): $DT_BOOTARGS"
python3 -I - "$W/vb/dtb" "$W/stock-base.dtb" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read(); i = 0; last = None
while i < len(d):
    assert d[i:i + 4] == b'\xd0\x0d\xfe\xed'; n = struct.unpack('>I', d[i + 4:i + 8])[0]; last = d[i:i + n]; i += n
open(sys.argv[2], 'wb').write(last)
EOF
set +e
python3 -I "$HERE/tools/cmdline-sim.py" --live "$DUMP/live.dtb" --stock-vendor-cmdline "$W/stock-vendor-cmdline.txt" \
	--stock-dtb "$W/stock-base.dtb" --dt-bootargs "$W/dt-bootargs.txt" --vendor-cmdline "$W/vendor-cmdline.txt" \
	--config-cmdline "$CONFIG_CMDLINE" --cmdline-size "$CLS_EFF" -o "$O/cmdline-predicted.txt" | tee -a "$R"
SIM=${PIPESTATUS[0]}
python3 -I "$HERE/tools/cmdline-sim.py" --live "$DUMP/live.dtb" --stock-vendor-cmdline "$W/stock-vendor-cmdline.txt" \
	--stock-dtb "$W/stock-base.dtb" --dt-bootargs "$W/dt-bootargs.txt" --vendor-cmdline "$W/vendor-cmdline.txt" \
	--config-cmdline "$CONFIG_CMDLINE" --cmdline-size 4096 -o "$O/cmdline-predicted-4096.txt" | sed 's/^/with COMMAND_LINE_SIZE 4096: /' | tee -a "$R"
# worst case: the bootloader appends 2.8 KiB (measured on phone 2: ~2.7 KB)
python3 -I "$HERE/tools/cmdline-sim.py" --live "$DUMP/live.dtb" --stock-vendor-cmdline "$W/stock-vendor-cmdline.txt" \
	--stock-dtb "$W/stock-base.dtb" --dt-bootargs "$W/dt-bootargs.txt" --vendor-cmdline "$W/vendor-cmdline.txt" \
	--config-cmdline "$CONFIG_CMDLINE" --cmdline-size "$CLS_EFF" --abl-min 2868 -o "$O/cmdline-predicted-abl2.8k.txt" | sed 's/^/with a 2.8 KiB ABL append: /' | tee -a "$R"
SIM28=${PIPESTATUS[0]}
set -e
[ "$SIM28" = 0 ] || blocker "a 2.8 KiB bootloader append would not fit COMMAND_LINE_SIZE $CLS_EFF ($O/cmdline-predicted-abl2.8k.txt)"
[ "$SIM" = 3 ] && blocker "COMMAND_LINE_SIZE $CLS_EFF cuts off bootloader arguments (androidboot.bootloader, em.model, sales_code, ...: $O/cmdline-predicted.txt). Rebuild bsp612 with patches/bsp612-kernel-0001-arm64-COMMAND_LINE_SIZE-4096.patch"
[ "$SIM" = 0 ] || [ "$SIM" = 3 ] || fail "cmdline simulation failed"

# ---------------------------------------------------------------- 6. ramdisks
say "== 6. ramdisks"
# boot: the ROM's generic ramdisk, unchanged
cp "$W/b/ramdisk" "$W/boot-ramdisk"
# MODLOAD=parallel|performance|conservative (2026-11-22, default unset = sequential): the ROM's first-stage init loads
# the vendor_boot module list in parallel when /proc/bootconfig has androidboot.load_modules_parallel = "true" (or
# "performance"/"conservative"); this vendor_boot is header v3 (no bootconfig section), so the bootconfig goes at the
# END of the generic (boot.img) ramdisk = the end of the initrd (v3: vendor ramdisk first, generic ramdisk right after);
# the kernel (CONFIG_BOOT_CONFIG=y, "bootconfig" in CONFIG_CMDLINE) finds the trailer there and cuts it off the initrd
# (init/main.c get_boot_config_from_initrd). If a bootloader ever moved it, the trailer is simply not found = sequential.
# Modules with load_sequential=1 in modules.options are loaded alone (MODLOAD_SEQ="m ...").
rm -f "$W/bootconfig.bin"
case "${MODLOAD:-}" in '') ;; parallel|performance|conservative)
	v=$MODLOAD; [ "$v" = parallel ] && v=true
	python3 -I - "$W/bootconfig.bin" "$v" <<'PYEOF'
import struct, sys
data = ('androidboot.load_modules_parallel = "%s"\n' % sys.argv[2]).encode() + b'\0'
data += b'\0' * (-len(data) % 4)
open(sys.argv[1], 'wb').write(data + struct.pack('<II', len(data), sum(data) & 0xffffffff) + b'#BOOTCONFIG\n')
PYEOF
	cat "$W/bootconfig.bin" >> "$W/boot-ramdisk"
	say "MODLOAD=$MODLOAD: bootconfig androidboot.load_modules_parallel = \"$v\" appended to the boot ramdisk ($(stat -c %s "$W/bootconfig.bin") bytes)";;
*) fail "MODLOAD: unset, parallel, performance or conservative";; esac
# vendor: the ROM's vendor ramdisk (first_stage_ramdisk/fstab.qcom), unchanged, + our cpio
python3 -I "$HERE/tools/cpiox.py" "$W/vb/vendor_ramdisk" "$W/rom-vr" >> "$R"
# OneUI 9 port (2026-11-22): its vendor ramdisk also carries the 5.4 vendor modules (lib/modules/*.ko + modules.{alias,
# dep,load,softdep}) and the touch firmware (lib/firmware/...). Our cpio comes after it, so our modules.load/dep/alias/
# softdep (and every module of the same file name) replace those; the other 5.4 .ko files stay unreferenced. Anything
# else (a modules.blocklist / modules.options of the ROM would apply to OUR list) is refused.
rvx=$(cd "$W/rom-vr" && find . -type f ! -name .cpiox-nodes.txt ! -path ./first_stage_ramdisk/fstab.qcom ! -path './lib/firmware/*' ! -regex '\./lib/modules/[^/]*\.ko' ! -regex '\./lib/modules/modules\.\(alias\|dep\|load\|softdep\)' | sort)
[ -z "$rvx" ] || fail "ROM vendor ramdisk has unexpected files: $rvx"
[ -f "$W/rom-vr/first_stage_ramdisk/fstab.qcom" ] || fail "ROM vendor ramdisk has no first_stage_ramdisk/fstab.qcom"
NROMKO=$(find "$W/rom-vr/lib/modules" -name '*.ko' 2>/dev/null | wc -l)
[ "$NROMKO" = 0 ] || say "ROM vendor ramdisk: $NROMKO 5.4 modules + its modules.* lists (ours replace the lists; the 5.4 .ko files stay unreferenced)$( [ -d "$W/rom-vr/lib/firmware" ] && echo "; firmware kept: $(cd "$W/rom-vr" && find lib/firmware -type f | tr '\n' ' ')")"
grep -q 'by-name/userdata' "$W/rom-vr/first_stage_ramdisk/fstab.qcom" || fail "ROM fstab has no userdata (wrong file?)"
# /force_debuggable: AOSP's debug-ramdisk hook (first_stage_init.cpp); with an unlocked
# bootloader second-stage init loads /adb_debug.prop after every build.prop. Used for ONE
# property: the ROM sets ro.bpf.kver_override=5.10.239 for its 5.4 kernel, which makes netd
# abort on 6.12 (netd1shot -> reboot_on_failure -> reboot loop, run ab-s4). On the 5.4 kernel
# this vendor_boot is not used, so the ROM's value stays right there.
# /cache as first_stage_mount (only in THIS vendor_boot): the vendor add-on is installed with
# `adb remount`, whose overlayfs upper dirs live in /cache/overlay (no scratch partition on this ROM).
# fs_mgr mounts those overlays in first stage only when /cache is mounted there; the ROM's fstab mounts
# /cache later (mount_all), so on the 5.4 kernel the add-on stays invisible (as intended) and on the 6.x
# kernel this line makes it appear before second-stage init parses /vendor/etc/init.
# OFF by default since rb9 (2026-11-15): with /cache mounted in first stage, fs_mgr also applies the adb-remount
# overlays in /cache/overlay and the enforcing second-stage overlay_remounter cannot reach them -> init exits ->
# panic (rb9). The add-on is installed into the vendor ext4 directly instead (README section 3). CACHE_FSM=1
# brings the old behaviour back.
if [ "${CACHE_FSM:-0}" = 1 ]; then
	mkdir -p "$VR/first_stage_ramdisk"
	# In FIRST stage only /dev/block/by-name/<part> exists (the bootdevice symlink comes from ueventd in second
	# stage): a first_stage_mount entry with the ROM's /dev/block/bootdevice/by-name/cache path never appears ->
	# "Failed to mount required partitions early" -> reboot,bootloader = Download mode (rb4 on 2026-11-14).
	python3 -I -c 'import re,sys; s=open(sys.argv[1]).read(); n=re.subn(r"^/dev/block/bootdevice/by-name/cache(\t/cache\t.*\t)wait,check$", r"/dev/block/by-name/cache\1wait,check,first_stage_mount", s, flags=re.M); assert n[1]==1, "cache line not found"; open(sys.argv[2],"w").write(n[0])' "$W/rom-vr/first_stage_ramdisk/fstab.qcom" "$VR/first_stage_ramdisk/fstab.qcom"
	grep -qP '^/dev/block/by-name/cache\t.*wait,check,first_stage_mount$' "$VR/first_stage_ramdisk/fstab.qcom" || fail "cache first_stage_mount edit failed"
	# every first_stage_mount entry must use a /dev/block/by-name/ path or a logical partition name
	awk -F'\t' '$0 !~ /^#/ && $3 != "emmc" && $NF ~ /first_stage_mount/ && $1 ~ /^\// && $1 !~ /^\/dev\/block\/by-name\// {print "bad first-stage device: " $1; bad=1} END {exit bad}' "$VR/first_stage_ramdisk/fstab.qcom" || fail "first-stage fstab entry with a path first stage cannot resolve"
fi
if [ "$KSU" = 1 ]; then install -m 0755 "$KSUD/ksuinit" "$VR/ksuinit"; install -m 0644 "$KSUD/kernelsu.ko" "$VR/kernelsu.ko"; fi
: > "$VR/force_debuggable"
printf '# drivers612/realboot: loaded by init after all build.prop files (unlocked bootloader only)\nro.bpf.kver_override=%s\n' "$KVER" > "$VR/adb_debug.prop"
find "$VR" -exec touch -h -d @0 {} +   # reproducible cpio (no build-time mtimes)
( cd "$VR" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet ) | lz4 -l -12 --favor-decSpeed -q > "$W/vr-add.cpio.lz4"
# The ABL hands the kernel vendor ramdisk + boot ramdisk as ONE blob. lz4 legacy has no end marker: the kernel's
# unlz4 runs on into whatever follows and only stops at a zero chunk size, another lz4 magic or the end. A ROM boot
# ramdisk that is not lz4 (OneUI: gzip) -> "rootfs image is not initramfs (Decoding failed)" -> no /init -> panic loop
# (rbou2 real flash, 2026-11-22). So: 4 zero bytes (= chunk size 0, "end of file" in lib/decompress_unlz4.c) after our
# fragment unless the boot ramdisk is lz4 legacy itself (LineageOS: bytes unchanged). tools/qemu-initrd-check.sh proves it.
if [ "$(head -c 4 "$W/boot-ramdisk" | od -An -tx1 | tr -d ' \n')" != 02214c18 ]; then
	printf '\0\0\0\0' >> "$W/vr-add.cpio.lz4"; say "boot ramdisk is not lz4 legacy: lz4 end marker (4 zero bytes) after our fragment"
fi
cat "$W/vb/vendor_ramdisk" "$W/vr-add.cpio.lz4" > "$W/vendor-ramdisk"
RB=$(stat -c %s "$W/boot-ramdisk"); RV=$(stat -c %s "$W/vendor-ramdisk")
BUDGET=$((0x5600000 - 0x482000)); NEED=$(( ISZ + ((RB + RV + 4095) / 4096) * 4096 ))
say "boot ramdisk $RB, vendor ramdisk $RV bytes; image_size + ramdisks = $(printf %#x $NEED) (ABL fallback budget $(printf %#x $BUDGET))"
[ "$NEED" -le "$BUDGET" ] || fail "kernel + ramdisks exceed the ABL's fallback load region"

# ---------------------------------------------------------------- 7. images
say "== 7. images"
# PROCA_MAGIC=1 (OneUI): arm64 Image header res3 (offset 0x28, Samsung's _proca_conf_offset) = 0xecefecef, as on the
# port's 5.4 kernel (UN1CA patches/proca): the PROCA TA then accepts that there is no PROCA config. With 0 there it
# logs "Config is not initialized in SWD" and the vaultkeeper TA refuses its clients (-10032 "no VK ID", 2026-11-22).
BOOTK=$IMAGE
if [ "${PROCA_MAGIC:-0}" = 1 ]; then
	[ "$(od -An -tx1 -j40 -N4 "$IMAGE" | tr -d ' \n')" = 00000000 ] || fail "PROCA_MAGIC=1: Image header 0x28 is not zero"
	BOOTK=$W/Image-proca; cp "$IMAGE" "$BOOTK"
	printf '\xef\xec\xef\xec' | dd of="$BOOTK" bs=1 seek=40 conv=notrunc status=none
	[ "$(od -An -tx1 -j40 -N4 "$BOOTK" | tr -d ' \n')" = efecefec ] || fail "PROCA_MAGIC=1: header patch"
	NCH=4
	# PROCA_TEXTOFF=1: header text_offset 0x80000 like the 5.4 Image, so the ABL loads the kernel at base + 0x80000
	# (KernelLoadAddr += TextOffset) where the secure world may expect the Image header (test, 2026-11-22)
	if [ "${PROCA_TEXTOFF:-0}" = 1 ]; then
		[ "$(od -An -tx1 -j8 -N8 "$IMAGE" | tr -d ' \n')" = 0000000000000000 ] || fail "PROCA_TEXTOFF=1: text_offset is not 0"
		printf '\x00\x00\x08\x00' | dd of="$BOOTK" bs=1 seek=8 conv=notrunc status=none; NCH=5
		say "PROCA_TEXTOFF=1: Image header text_offset = 0x80000 (5.4 placement)"
	fi
	cmp -l "$IMAGE" "$BOOTK" | wc -l | grep -qx $NCH || fail "PROCA_MAGIC=1: more header bytes changed than intended"
	say "PROCA_MAGIC=1: Image header 0x28 = ef ec ef ec (PROCA config intentionally absent; 4 bytes differ from $IMAGE)"
fi
mkbootimg --header_version 3 --os_version "$OSV" --os_patch_level "$OSP" --kernel "$BOOTK" \
	--ramdisk "$W/boot-ramdisk" --cmdline '' -o "$O/boot.img"
eval mkbootimg $VB_ARGS --vendor_cmdline "'$VC'" --dtb "$D" --vendor_ramdisk "$W/vendor-ramdisk" --vendor_boot "$O/vendor_boot.img"
cp "$W/dtbo-raw.img" "$O/dtbo.img"
footer boot "$O/boot.img" $BOOT_PART
footer vendor_boot "$O/vendor_boot.img" $VENDOR_BOOT_PART
footer dtbo "$O/dtbo.img" $DTBO_PART
for i in boot vendor_boot dtbo; do
	avbtool info_image --image "$O/$i.img" > "$W/$i.avb" || fail "$i footer unreadable"
done
[ "$(stat -c %s "$O/boot.img")" = $BOOT_PART ] && [ "$(stat -c %s "$O/vendor_boot.img")" = $VENDOR_BOOT_PART ] && [ "$(stat -c %s "$O/dtbo.img")" = $DTBO_PART ] || fail "image sizes are not the partition sizes"
# read back what the bootloader will see
unpack_bootimg --boot_img "$O/boot.img" --out "$W/chk-b" > "$W/chk-b.info"
unpack_bootimg --boot_img "$O/vendor_boot.img" --out "$W/chk-vb" > "$W/chk-vb.info"
cmp -s "$W/chk-b/kernel" "$BOOTK" && cmp -s "$W/chk-b/ramdisk" "$W/boot-ramdisk" || fail "boot.img read-back differs"
cmp -s "$W/chk-vb/dtb" "$D" && cmp -s "$W/chk-vb/vendor_ramdisk" "$W/vendor-ramdisk" || fail "vendor_boot.img read-back differs"
grep -q "^os patch level: $OSP$" "$W/chk-b.info" || fail "patch level not kept"
python3 -I "$HERE/tools/cpiox.py" "$W/chk-vb/vendor_ramdisk" "$W/chk-vr" >> "$R"
[ "$(sort "$W/chk-vr/lib/modules/modules.load" | md5sum)" = "$(sort "$LM/modules.load" | md5sum)" ] || fail "vendor ramdisk read-back: modules.load differs"
[ -f "$W/chk-vr/first_stage_ramdisk/fstab.qcom" ] && [ -f "$W/chk-vr/force_debuggable" ] || fail "vendor ramdisk read-back incomplete"
if [ "$KSU" = 1 ]; then
	cmp -s "$W/chk-vr/ksuinit" "$KSUD/ksuinit" && cmp -s "$W/chk-vr/kernelsu.ko" "$KSUD/kernelsu.ko" || fail "KSU=1: ksuinit/kernelsu.ko read-back differs"
	[ "$(stat -c %a "$W/chk-vr/ksuinit")" = 755 ] && [ "$(stat -c %a "$W/chk-vr/kernelsu.ko")" = 644 ] || fail "KSU=1: modes in the vendor ramdisk are not 755/644"
	grep -q ' rdinit=/ksuinit' "$O/vendor-cmdline.txt" 2>/dev/null || echo " $VC " | grep -q ' rdinit=/ksuinit ' || fail "KSU=1: rdinit missing from the vendor cmdline"
	say "KSU=1 read-back: /ksuinit 0755 + /kernelsu.ko 0644 in the vendor ramdisk (cmp OK)"
else
	[ ! -e "$W/chk-vr/ksuinit" ] && [ ! -e "$W/chk-vr/kernelsu.ko" ] || fail "KSU=0 but ksuinit/kernelsu.ko in the vendor ramdisk"
fi
[ "$(sed -n 's/^vendor command line args: //p' "$W/chk-vb.info")" = "$VC" ] || fail "vendor_boot read-back: cmdline differs"
[ "$(fdtget "$W/chk-vb/dtb" /chosen bootargs)" = "$DT_BOOTARGS" ] || fail "vendor_boot read-back: dtb bootargs differ"
[ "$(sed -n 's/^ro.bpf.kver_override=//p' "$W/chk-vr/adb_debug.prop")" = "$KVER" ] || fail "adb_debug.prop kver"
# the headers must still be the ROM's (only cmdline, dtb, ramdisk, kernel changed)
diff <(grep -v '^vendor command line args\|^vendor ramdisk total size\|^vendor ramdisk size\|^dtb size' "$W/vb.info") \
	<(grep -v '^vendor command line args\|^vendor ramdisk total size\|^vendor ramdisk size\|^dtb size' "$W/chk-vb.info") > "$W/vb-header.diff" || fail "vendor_boot header differs from the ROM's beyond cmdline/sizes ($W/vb-header.diff)"
diff <(grep -v '^kernel_size\|^ramdisk size\|^command line args' "$W/b.info") <(grep -v '^kernel_size\|^ramdisk size\|^command line args' "$W/chk-b.info") > "$W/b-header.diff" || fail "boot header differs from the ROM's beyond the sizes ($W/b-header.diff)"
say "read-back OK: kernel, ramdisks, dtb, cmdline, dtb bootargs, other header fields = ROM's, patch level $OSP, footers (unsigned, as the ROM's)"
# no firmware image may ever be part of these outputs (2026-11-13 incident)
find "$O" -path "$W" -prune -o -type f -regextype posix-extended -regex '.*\.(mdt|mbn|b[0-9][0-9])$' -print | grep -q . && fail "firmware image in the output"
find "$W/chk-vr" "$VA" -type f -regextype posix-extended -regex '.*\.(mdt|mbn|b[0-9][0-9])$' | grep -q . && fail "firmware image in the vendor ramdisk / add-on"
# info dumps
mkdir -p "$O/info"
for i in boot vendor_boot dtbo; do cp "$W/$i.avb" "$O/info/$i.avbtool-info.txt"; done
cp "$W/chk-b.info" "$O/info/boot.unpack_bootimg.txt"; cp "$W/chk-vb.info" "$O/info/vendor_boot.unpack_bootimg.txt"
cp "$W/b.info" "$O/info/rom-boot.unpack_bootimg.txt"; cp "$W/vb.info" "$O/info/rom-vendor_boot.unpack_bootimg.txt"
cp "$W/dtbo-table.txt" "$O/info/dtbo-table.txt"
unpack_bootimg --boot_img "$O/boot.img" --out "$W/fmt-b" --format mkbootimg > "$O/info/boot.mkbootimg-args.txt"
unpack_bootimg --boot_img "$O/vendor_boot.img" --out "$W/fmt-vb" --format mkbootimg > "$O/info/vendor_boot.mkbootimg-args.txt"
rm -rf "$W/fmt-b" "$W/fmt-vb"

# the initrd exactly as the ABL concatenates it must unpack in the build's own kernel (QEMU; key-free). QEMU_CHECK=0 skips.
if [ "${QEMU_CHECK:-1}" = 1 ]; then
	"$HERE/tools/qemu-initrd-check.sh" "$O" "$W/qemu-initrd" > "$W/qemu-initrd.log" 2>&1 || { tail -5 "$W/qemu-initrd.log"; fail "QEMU: the ABL-concatenated initrd does not unpack/start init (tools/qemu-initrd-check.sh)"; }
	say "QEMU initrd check PASS: vendor ramdisk + boot ramdisk unpack, init started"
fi

# ---------------------------------------------------------------- 8. summary
( cd "$O" && sha256sum boot.img vendor_boot.img dtbo.img > SHA256SUMS
  [ "$ADDON" = vendor ] && { find vendor-addon -type f | LC_ALL=C sort | xargs sha256sum > vendor-addon.SHA256SUMS; } || true )
cp "$W/vendor_boot.dtb" "$O/vendor_boot.dtb"; cp "$W/realboot.dtbo" "$O/realboot.dtbo"
cp "$W/vendor-cmdline.txt" "$W/dt-bootargs.txt" "$O/"; cp "$LM/modules.load" "$O/first-stage.modules.load"
[ -f "$T/vs-tested.diff" ] && cp "$T/vs-tested.diff" "$O/dtb-vs-tested.diff"
printf 'name=%s kernel=%s krel=%s ref=%s image=%s tree=%s diag=%s modem=%s sdcard=%s wlan=%s addon=%s debug=%s btslim=%s\n' "$NAME" "$KV" "$KREL" "$REFRD" "$IMAGE" "$TREF" "$DIAG" "$MODEM" "$SDCARD" "$WLD" "$ADDON" "$DEBUG" "${BTSLIM:-0}" > "$O/BUILDINFO"
sed -i "s/\$/ usbaudio=${USBAUDIO:-0} wdt=${WDT:-0} qrng=${QRNG:-0} hall=${HALL:-0} volkey=${VOLKEY:-0} bwcompat=${BWCOMPAT:-0} adspfac=${ADSPFAC:-0} ksu=${KSU:-0} lpm=${LPM:-0} hold_ms=${HOLD_MS:-} ice_raw=${ICE_RAW:-0} ice_kat_fail=${ICE_KAT_FAIL:-0} ufs_poll_ms=${UFS_POLL_MS:-} ufs_qos=${UFS_QOS:-1} ufs_clkscale=${UFS_CLKSCALE:-1} ufs_wb=${UFS_WB:-} modload=${MODLOAD:-} modload_seq=$(echo ${MODLOAD_SEQ:-} | tr ' ' '+') async_mods=$(echo ${ASYNC_MODS:-} | tr " " "+") async_last=$(echo ${ASYNC_LAST:-} | tr ' ' '+') strip_btf=${STRIP_BTF:-0} thermal=${THERMAL:-0} thermal_x=$(echo ${THERMAL_X:-} | tr ' ' '+')/" "$O/BUILDINFO"
sed -i "s/\$/ argos=${ARGOS:-0} proca_magic=${PROCA_MAGIC:-0} shm_bridge_off=${SHM_BRIDGE_OFF:-0}/" "$O/BUILDINFO"
sed -i "s/\$/ ksu_builtin=${KSU_BUILTIN:-0}/" "$O/BUILDINFO"
sed -i "s/\$/ walt=${WALT:-0}/" "$O/BUILDINFO"
sed -i "s/\$/ socstats=${SOCSTATS:-0} ntfs3=${NTFS3:-0} usbacc=${USBACC:-0} zram_lz4=${ZRAM_LZ4:-0} userspace=${USERSPACE:-auto}/" "$O/BUILDINFO"
[ "${A52SXQ_FIRST:-0}" = 1 ] && sed -i "s/\$/ a52sxq_first=1/" "$O/BUILDINFO"   # only when set: default BUILDINFO unchanged
if [ "$DIAG_KERNEL" = 1 ]; then cp "$(dirname "$IMAGE")/BUILDINFO" "$O/diag-kernel.BUILDINFO"; fi
say "== summary"
sed 's/^/  /' "$O/SHA256SUMS" | tee -a "$R"
if [ ${#BLOCKERS[@]} -gt 0 ]; then
	say "NOT READY TO FLASH: ${#BLOCKERS[@]} blocker(s):"; for b in "${BLOCKERS[@]}"; do say "  - $b"; done
else say "no blockers found by the offline checks (CHECKLIST.md still applies)"; fi
say "NOTHING WAS FLASHED. Flashing needs an explicit OK, and only on the test phones PHONE2 / PHONE1 (README.md, 2d)."
