#!/system/bin/sh
# Kernel features the OneUI 9 port works around on 5.4 (the "5.4 quirks"), BPF, cgroups/freezer, memory nodes.
# Read-only; kq (tools/selftest/oneui/kq) makes harmless probe syscalls. Each row is a probe that should flip
# from FAIL on 5.4 to PASS on 6.12, or stay equal.
. "${0%/*}/../dev-lib.sh"
KQ="${0%/*}/../kq"; q=; [ -x "$KQ" ] && q=$("$KQ" 2>&1)
kq() { printf '%s\n' "$q" | grep -m1 "^KQ $1 " | cut -d' ' -f3-; }
kqc() { # kqc <id> <owner> <kq name> <what>
	local r; r=$(kq "$3"); case "$r" in ok*) C "$1" PASS "$2" "ok" "$4: $r";; "") C "$1" SKIP "$2" "kq did not run" "$4";; *) C "$1" FAIL "$2" "${r%% *}" "$4: $r";; esac; }
C kernel.release PASS info "$(uname -r | cut -d. -f1,2)" "$(uname -r) $(uname -v | cut -c1-60)"
kqc quirk.close_range kernel sys.close_range "close_range(2) (5.9+; the port nops libc's failure path on 5.4)"
clc=$(rd /proc/sys/kernel/cap_last_cap)
C quirk.caps "$([ "${clc:-0}" -ge 40 ] && echo PASS || echo FAIL)" kernel "cap_last_cap=$clc" "CAP_PERFMON 38 / CAP_BPF 39 / CAP_CHECKPOINT_RESTORE 40 need >= 40; zygote CapBnd $(grep -m1 CapBnd /proc/$(pidof zygote64 | cut -d' ' -f1)/status 2>/dev/null | tr -s '\t ' ' ')"
if [ "$(kq bpf.array | cut -c1-2)" = ok ]; then kqc quirk.bpf_ringbuf kernel bpf.ringbuf "BPF_MAP_TYPE_RINGBUF creatable (5.8+; Google's netbpfload needs it)"; else C quirk.bpf_ringbuf SKIP kernel "cannot create any BPF map from here" "control array map: $(kq bpf.array)"; fi
u=$(kq uffd.open)
case "$u" in ok*) C quirk.userfaultfd "$(printf '%s' "$u" | grep -q 'minor_shmem=1' && echo PASS || echo FAIL)" kernel "$(printf '%s' "$u" | grep -oE 'minor_shmem=[01] move=[01]')" "$u";; "") C quirk.userfaultfd SKIP kernel "kq did not run";; *) C quirk.userfaultfd FAIL kernel "$u" "userfaultfd(2) refused";; esac
zp=$(pidof zygote64 | cut -d' ' -f1); cmc=0; [ -n "$zp" ] && cmc=$(grep -cE 'mark-compact|moving-space shadow|compact buffer' /proc/$zp/maps 2>/dev/null)
ssp=$(pidof system_server); log=$(logcat -d -b main,system -t 4000 2>/dev/null | grep -m1 -oE 'Using (CMC|CC|[A-Za-z ]+) GC[^,]*' )
C quirk.art_uffd_gc PASS kernel+ROM "ro.dalvik.vm.enable_uffd_gc=$(getprop ro.dalvik.vm.enable_uffd_gc) gc=$([ "${cmc:-0}" -gt 0 ] && echo CMC-userfaultfd || echo CC)" "zygote64 mark-compact mappings: ${cmc:-0}; force_disable_uffd_gc=$(getprop persist.device_config.runtime_native_boot.force_disable_uffd_gc) generational=$(getprop persist.device_config.runtime_native_boot.use_generational_gc) dalvik.vm.gctype=$(getprop dalvik.vm.gctype) ${log}"
if [ -r /sys/kernel/btf/vmlinux ]; then C quirk.btf PASS kernel "vmlinux BTF present" "$(wc -c < /sys/kernel/btf/vmlinux) bytes, $(ls /sys/kernel/btf | wc -l) entries"; else C quirk.btf FAIL kernel "no /sys/kernel/btf/vmlinux"; fi
ion=$([ -e /dev/ion ] && echo "ion:$(lz /dev/ion)" || echo "ion:absent")
hp=$(ls /dev/dma_heap 2>/dev/null | tr '\n' ' '); hl=$(ls -Z /dev/dma_heap 2>/dev/null | sed -e 's/u:object_r://' -e 's/:s0//' | tr '\n' ';')
C quirk.ion_node "$([ -e /dev/ion ] && echo PASS || echo FAIL)" kernel+ROM "$ion" "vendor blobs open /dev/ion on both kernels (6.12: ioncompat)"
setl quirk.dma_heaps kernel+ROM 0 "$hp"
C quirk.dma_heap_labels PASS kernel+ROM "$( [ -n "$hp" ] && echo "$(printf '%s\n' $hp | grep -c .) heaps" || echo "no /dev/dma_heap")" "$hl"
bl=$(svc bpfloader); be=$(dmesg 2>/dev/null | grep -E "init: Service 'bpfloader' \(pid [0-9]+\) (exited with status [0-9]+|received signal [0-9]+)" | tail -1 | grep -oE '(exited with status [0-9]+|received signal [0-9]+)')
pl=$(getprop bpf.progs_loaded)
if [ "$pl" = 1 ] && [ "$bl" != restarting ] && [ "${be:-exited with status 0}" = "exited with status 0" ]; then C quirk.bpfloader PASS kernel+ROM "bpf.progs_loaded=1" "init.svc.bpfloader=$bl; init log: ${be:-not in dmesg any more}; loader binary: $(grep -hoE '/system/bin/[a-z_0-9]*bpfload[a-z_0-9]*|/apex/[^ ]*netbpfload' /system/etc/init/bpfloader.rc /system/etc/init/*netbpfload*.rc 2>/dev/null | sort -u | tr '\n' ' ')"
else C quirk.bpfloader FAIL kernel+ROM "bpf.progs_loaded=$pl svc=$bl ${be}" "boot reason $(getprop sys.boot.reason) / $(getprop ro.boot.bootreason)"; fi
C quirk.boot_reason "$(getprop sys.boot.reason | grep -q bpfloader && echo FAIL || echo PASS)" kernel+ROM "no bpfloader-failed reboot" "sys.boot.reason=$(getprop sys.boot.reason) ro.boot.bootreason=$(getprop ro.boot.bootreason) last: $(getprop persist.sys.boot.reason.history | cut -c1-80)"
ap=$(pm list packages --apex-only --show-versioncode 2>/dev/null | sed -e 's/^package://' -e 's/ versionCode:/:/' | grep -E 'tethering|art|adbd|virt|conscrypt|os.statsd|media|permission|wifi|uwb|neuralnetworks|resolv|ipsec|cellbroadcast|extservices|mediaprovider|sdkext|scheduling|appsearch|ondevicepersonalization|healthfitness|configinfrastructure|rkpd|bt|nfcservices|crashrecovery|profiling|uprobestats' | sort | tr '\n' ' ')
setl quirk.mainline_modules ROM 5 "$ap"
C quirk.tethering_module "$(printf '%s' "$ap" | grep -q tethering && echo PASS || echo FAIL)" kernel+ROM "$(printf '%s\n' $ap | grep -m1 tethering)" "netd maps $(ls /sys/fs/bpf/netd_shared 2>/dev/null | grep -c .) tethering objs $(ls /sys/fs/bpf/tethering 2>/dev/null | grep -c .) net_shared $(ls /sys/fs/bpf/net_shared 2>/dev/null | grep -c .); activating apex: $(ls -d /apex/com.android.tethering@* /apex/com.google.android.tethering@* 2>/dev/null | tr '\n' ' ')"
kqc quirk.vsock kernel sock.vsock "AF_VSOCK (traced relay; 5.4 has none)"
C quirk.kvm PASS info "kvm=$([ -e /dev/kvm ] && echo present || echo absent)" "no EL2 on this bootloader: expected absent on both"
C quirk.apex_mounts "$([ "$(getprop apexd.status)" = ready ] && echo PASS || echo FAIL)" kernel+ROM "apexd.status=$(getprop apexd.status)" "$(grep -c ' /apex/[^ @]* ' /proc/mounts) apex mounts, virt apex $(ls -d /apex/com.android.virt 2>/dev/null | grep -c .)"
C quirk.syscalls PASS kernel "$(printf '%s\n' "$q" | grep '^KQ sys\.' | sed -e 's/^KQ sys\.//' | cut -d' ' -f1,2 | tr ' ' '=' | tr '\n' ' ')" "ENOSYS = the syscall does not exist on this kernel"
kc=$(getprop sys.kernel_check.ok)
if [ -n "$kc" ]; then C quirk.rom_kernel_check "$([ "$kc" = 1 ] && echo PASS || echo FAIL)" kernel+ROM "ok=$kc missing=$(getprop sys.kernel_check.missing)" "minor=$(getprop sys.kernel_check.minor) id=$(getprop sys.kernel_check.id) k612vb=$(getprop ro.boot.a52sxq.k612vb)"; else C quirk.rom_kernel_check SKIP ROM "sys.kernel_check.ok unset" "the ROM's kernel_check did not run"; fi
# the config is ~220 KB: as ONE printf argument it exceeds the kernel's 128 KiB limit per argument (exec fails, every
# value came out empty in the 2026-11-22 runs on both kernels), so it goes through a file
CF="${0%/*}/../.config.$$"; zcat /proc/config.gz > "$CF" 2>/dev/null
if [ -s "$CF" ]; then o=; for k in USERFAULTFD DEBUG_INFO_BTF USB_CONFIGFS_F_UVC VSOCKETS SAMSUNG_FREECESS SDP FSCRYPT_SDP SDFAT_FS EXFAT_FS CPU_FREQ_LIMIT SEC_INPUT_BOOSTER USB_F_SS_MON_GADGET USB_CONFIGFS_F_CONN_GADGET KSU KSU_SUSFS PSI UCLAMP_TASK SCHED_TUNE CGROUP_FREEZER MEMCG BPF_JIT KVM EROFS_FS_ZIP_ZSTD ZRAM_MULTI_COMP LRU_GEN \
	SCHED_WALT BPF_LSM FUSE_BPF INCREMENTAL_FS DM_USER DM_DEFAULT_KEY FS_ENCRYPTION_INLINE_CRYPT KPROBES KFENCE ARM64_MTE ARM64_BTI ARM64_PTR_AUTH CFI_CLANG SHADOW_CALL_STACK IO_URING USER_NS PID_NS ASHMEM ANDROID_BINDERFS RUST TRANSPARENT_HUGEPAGE HZ MODULE_SIG SECURITY_SELINUX_DEVELOP PROCA FIVE SECURITY_DEFEX UH; do o="$o $k=$(grep -m1 -E "^CONFIG_$k=" "$CF" | cut -d= -f2)"; done; C kernel.config PASS info "$(grep -c '^CONFIG_' "$CF") options set" "$o"
else C kernel.config SKIP info "no /proc/config.gz"; fi; rm -f "$CF"
C root.stack PASS info "$(su -v 2>/dev/null | head -1 | cut -c1-60)" "ksud: $(ls /data/adb/ksud 2>/dev/null | grep -c .) susfs: $(ls /data/adb/ksu/bin/ksu_susfs /data/adb/ksu/bin/susfs 2>/dev/null | grep -c .) modules: $(ls /data/adb/modules 2>/dev/null | tr '\n' ' ')"
# ---- BPF maps and programs
C bpf.fs "$(grep -q ' /sys/fs/bpf bpf ' /proc/mounts && echo PASS || echo FAIL)" kernel "bpffs mounted" "$(ls /sys/fs/bpf 2>/dev/null | tr '\n' ' ')"
for d in netd_shared net_shared net_private tethering netd_readonly netd_netd; do n=$(ls /sys/fs/bpf/$d 2>/dev/null | grep -c .); M "bpf_objs_$d" "$n"; done
setl bpf.pinned_top kernel+ROM 3 "$(ls /sys/fs/bpf 2>/dev/null | tr '\n' ' ')"
setl bpf.netd_shared kernel+ROM 5 "$(ls /sys/fs/bpf/netd_shared 2>/dev/null | tr '\n' ' ')"
setl bpf.tethering kernel+ROM 0 "$(ls /sys/fs/bpf/tethering 2>/dev/null | tr '\n' ' ')"
nd=$(DT=25 D netd | grep -iE 'bpf|cgroup' | head -12 | tr -s ' ' | tr '\n' ';')
tc=$(DT=25 D connectivity trafficcontroller 2>/dev/null | grep -m6 -iE 'mapfd|error|fail|not initialized|BPF' | tr -s ' ' | tr '\n' ';')
C bpf.netd_status "$(printf '%s%s' "$nd" "$tc" | grep -qiE 'fail|not initialized|error' && echo FAIL || echo PASS)" kernel+ROM "no failure in netd / TrafficController dumps" "$nd $tc"
C bpf.jit PASS kernel "bpf_jit_enable=$(rd /proc/sys/net/core/bpf_jit_enable)" "unprivileged_bpf_disabled=$(rd /proc/sys/kernel/unprivileged_bpf_disabled)"
# ---- cgroups / freezer / Samsung freecess
C cgroup.mounts PASS kernel+ROM "$(grep -E ' (cgroup2?) ' /proc/mounts | cut -d' ' -f2,3 | sort | tr '\n' ';')" "controllers: $(cut -f1,4 /proc/cgroups 2>/dev/null | grep -v '^#' | tr '\t' '=' | tr '\n' ' ')"
setl cgroup.cpuset_groups kernel+ROM 3 "$(ls -d /dev/cpuset/*/ 2>/dev/null | sed -e 's|/dev/cpuset/||' -e 's|/$||' | tr '\n' ' ')"
fz=; [ -e /sys/fs/cgroup/cgroup.freeze ] || [ -n "$(ls /sys/fs/cgroup/uid_0/cgroup.freeze /sys/fs/cgroup/*/uid_0/cgroup.freeze 2>/dev/null)" ] && fz=v2; [ -d /dev/freezer ] && grep -q ' /dev/freezer ' /proc/mounts && fz="${fz:+$fz+}v1(/dev/freezer)"; fz=${fz:-none}
C cgroup.freezer "$([ "$fz" = none ] && echo FAIL || echo PASS)" kernel+ROM "freezer=$fz" "app freezer: $(D activity settings | grep -m2 -iE 'use_freezer|freeze_debounce' | tr -s ' ' | tr '\n' ' ') frozen cgroups now: $(cat /sys/fs/cgroup/uid_*/pid_*/cgroup.freeze 2>/dev/null | grep -c 1)"
kqc cgroup.kfreecess kernel sock.netlink_kfreecess "Samsung NETLINK_KFREECESS (27): FreecessHandler/MARs kernel side"
kqc knox.sdp_netlink kernel sock.netlink_sdp_fs "Knox SDP_FS_HANDLER netlink (28)"
C cgroup.psi "$([ -r /proc/pressure/memory ] && echo PASS || echo FAIL)" kernel "psi $([ -r /proc/pressure/memory ] && echo readable || echo absent)" "$(head -1 /proc/pressure/memory 2>/dev/null)"
C cgroup.memcg PASS kernel+ROM "memcg=$(grep -cE ' /dev/memcg | memory' /proc/mounts) lmkd=$(svc lmkd)" "ro.lmk.use_psi=$(getprop ro.lmk.use_psi) ro.config.low_ram=$(getprop ro.config.low_ram) mglru=$(rd /sys/kernel/mm/lru_gen/enabled)"
C kernel.binder PASS kernel "binderfs=$(grep -c ' /dev/binderfs ' /proc/mounts)" "features: $(ls /dev/binderfs/features 2>/dev/null | tr '\n' ' ')"
C kernel.taint PASS info "tainted=$(rd /proc/sys/kernel/tainted)" "uptime $(cut -d. -f1 /proc/uptime) s; modules $(grep -c . /proc/modules 2>/dev/null)"
