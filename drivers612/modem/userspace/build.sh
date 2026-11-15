#!/bin/bash
# drivers612/modem/userspace/build.sh: static aarch64 (musl) builds of the open modem userspace for
# the kernel-only modem test M2-K (README section 10). Offline only; touches no phone.
#
#   src/qrtr        github.com/linux-msm/qrtr      29e36ae (2026-09-15)  BSD-3-Clause  libqrtr + qrtr-lookup
#   src/rmtfs       github.com/linux-msm/rmtfs     b30a3eb (2026-06-23)  BSD-3-Clause  + patches/rmtfs-0001
#   src/tqftpserv   github.com/linux-msm/tqftpserv eb4b9a0 (2026-10-27)  BSD-3-Clause  + patches/tqftpserv-0001
#   efsdump/        ours (GPL-2.0-only): RAM copies of modemst1/modemst2/fsg/fsc, O_RDONLY only
#   qmi-nas/        ours (GPL-2.0-only): QMI client over AF_QIPCRTR (DMS mode, NAS signal/serving/
#                   system info/RF band/network scan, UIM card status (read only), WDS data call,
#                   rmnet links over rtnetlink). Message layouts from libqmi's published
#                   qmi-service-*.json; no libqmi/libqrtr code. Host unit test: qmi-nas/test/
# src/ holds the unmodified upstream trees (without .git/ci); the patches are applied to a copy in
# the output directory. Not built: qrtr-ns (6.12's qrtr.ko has the in-kernel name service,
# net/qrtr/ns.c) and pd-mapper (the dsp stage loads the kernel locator qcom_pd_mapper_a52).
#
# Toolchain: AOSP clang r547379 + lld, sysroot prebuilts/build-tools/sysroots/aarch64-unknown-linux-musl
# (musl libc.a), compiler-rt builtins of the same clang. Output: ../out/userspace/bin/
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AOSP=${ANDROID_TREE:-$HOME/android}/prebuilts
CLANG=$AOSP/clang/host/linux-x86/clang-r547379
SYSROOT=$AOSP/build-tools/sysroots/aarch64-unknown-linux-musl
RT=$CLANG/lib/clang/20/lib/linux/aarch64-unknown-linux-musl/lib/linux/libclang_rt.builtins-aarch64.a
O=${OUT:-$HERE/../out/userspace}
fail() { echo "FAILED: $*" >&2; exit 1; }
for f in "$CLANG/bin/clang" "$SYSROOT/lib/libc.a" "$SYSROOT/lib/crt1.o" "$RT"; do [ -e "$f" ] || fail "missing $f"; done
[ "${1:-}" = clean ] && { rm -rf "$O"; exit 0; }

rm -rf "$O"; mkdir -p "$O/src" "$O/obj" "$O/bin"
cp -r "$HERE/src/qrtr" "$HERE/src/rmtfs" "$HERE/src/tqftpserv" "$O/src/"
for p in "$HERE"/patches/*.patch; do
	(cd "$O/src" && patch -p1 --no-backup-if-mismatch -s < "$p") || fail "patch $(basename "$p")"
done

CC=("$CLANG/bin/clang" --target=aarch64-linux-musl --sysroot="$SYSROOT" -nostdinc
	-isystem "$CLANG/lib/clang/20/include" -isystem "$SYSROOT/include"
	-O2 -g0 -fno-stack-protector -fPIE -Wall -Werror
	-Wno-unused-parameter -Wno-sign-compare -Wno-unused-but-set-variable -Wno-missing-field-initializers)
link() { # link <out> <objs...>: fully static, no host libraries
	local out=$1; shift
	"$CLANG/bin/clang" --target=aarch64-linux-musl -fuse-ld=lld -static -nostdlib -o "$out" \
		"$SYSROOT/lib/crt1.o" "$SYSROOT/lib/crti.o" "$SYSROOT/lib/crtbeginT.o" \
		"$@" "$SYSROOT/lib/libc.a" "$RT" "$SYSROOT/lib/crtend.o" "$SYSROOT/lib/crtn.o"
	"$CLANG/bin/llvm-strip" "$out"
}
cc() { local o=$1; shift; "${CC[@]}" "$@" -c -o "$o"; }

# libqrtr
Q=$O/src/qrtr; QO=$O/obj/qrtr; mkdir -p "$QO"
for s in logging qmi qrtr; do cc "$QO/$s.o" -I"$Q/include" "$Q/lib/$s.c"; done
LIBQRTR=("$QO/logging.o" "$QO/qmi.o" "$QO/qrtr.o")
cc "$QO/lookup.o" -I"$Q/include" "$Q/src/lookup.c"
link "$O/bin/qrtr-lookup" "$QO/lookup.o" "${LIBQRTR[@]}"

# rmtfs (RAM-only variant: storage.c refuses to compile without -DA52SXQ_RAM_EFS)
R=$O/src/rmtfs; RO=$O/obj/rmtfs; mkdir -p "$RO"
for s in qmi_rmtfs rmtfs rproc sharedmem storage util; do
	cc "$RO/$s.o" -DA52SXQ_RAM_EFS -D_GNU_SOURCE -I"$Q/include" -I"$R" "$R/$s.c"
done
link "$O/bin/rmtfs" "$RO"/*.o "${LIBQRTR[@]}"

# tqftpserv (no xz/zstd: the modem's files are plain on the phone's modem partition)
T=$O/src/tqftpserv; TO=$O/obj/tqftpserv; mkdir -p "$TO"
for s in translate tqftpserv; do cc "$TO/$s.o" -DA52SXQ_RAM_RW -I"$Q/include" -I"$T" "$T/$s.c"; done
link "$O/bin/tqftpserv" "$TO"/*.o "${LIBQRTR[@]}"

# efsdump (ours)
cc "$O/obj/efsdump.o" -D_GNU_SOURCE "$HERE/efsdump/efsdump.c"
link "$O/bin/efsdump" "$O/obj/efsdump.o"

# qmi-nas (ours): QMI over AF_QIPCRTR; the codec is unit-tested on the host first
QN=$HERE/qmi-nas; QNO=$O/obj/qmi-nas; mkdir -p "$QNO"
HOSTCC=$(type -P cc || true)	# not the cc() helper above
if [ -n "$HOSTCC" ]; then
	"$HOSTCC" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare -I"$QN" \
		"$QN/test/test-qmi.c" "$QN/qmi.c" -o "$QNO/test-qmi-host" || fail "qmi-nas host test build"
	"$QNO/test-qmi-host" > "$O/qmi-nas-test.log" 2>&1 || { cat "$O/qmi-nas-test.log"; fail "qmi-nas host unit test"; }
	tail -1 "$O/qmi-nas-test.log"
	# data / data-probe control flow against test/fake-modem.c (no QRTR, no network: the socket,
	# ioctl and rtnetlink calls go to the fake; --run is a plain echo)
	"$HOSTCC" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare -D_GNU_SOURCE -I"$QN" \
		-include "$QN/test/fake-modem.h" "$QN/qmi-nas.c" "$QN/qmi.c" "$QN/test/fake-modem.c" -o "$QNO/qmi-nas-fake" \
		|| fail "qmi-nas fake-modem test build"
	fk() { # fk <mode> <want rc 0|1> <expected line> <qmi-nas args...>
		local m=$1 w=$2 e=$3 r; shift 3
		r=0; FAKE_MODE=$m "$QNO/qmi-nas-fake" -t 2 "$@" > "$O/qmi-nas-fake-$m.log" 2>&1 || r=$?
		{ [ "$w" = 0 ] && [ $r = 0 ]; } || { [ "$w" = 1 ] && [ $r != 0 ]; } || { cat "$O/qmi-nas-fake-$m.log"; fail "fake modem $m: rc $r"; }
		grep -qF -- "$e" "$O/qmi-nas-fake-$m.log" || { cat "$O/qmi-nas-fake-$m.log"; fail "fake modem $m: no \"$e\""; }
	}
	R='echo RUN ip=$QMI_IP qmap=$QMI_QMAP flags=$QMI_RMNET_FLAGS'
	fk ctl 0 "== data-probe: attempt 1.1 SUCCESS" data-probe --ipa rmnet_ipa0 --rmnet rmnet_data0 --run "$R"
	fk hw 0 "== data-probe: attempt 1.3 SUCCESS" data-probe --ipa rmnet_ipa0 --rmnet rmnet_data0 --run "$R"
	fk none 1 "== data-probe: NO variant brought a call up" data-probe --ipa rmnet_ipa0 --rmnet rmnet_data0 --run "$R"
	grep -qF "== data-probe summary: 2.8 " "$O/qmi-nas-fake-none.log" || fail "fake modem none: phase 2 missing"
	fk ctl 0 "RUN ip=10.0.0.2 qmap=qmapv5 flags=0x63" data --dpm ctl --ep 4:1 --ipa rmnet_ipa0 --rmnet rmnet_data0 \
		--wda 2:9:9:32:16384 --mux 1 --ipfam --run "$R"
	echo "qmi-nas: data / data-probe flow against the fake modem: ok (ctl, hw, none, qmapv5)"
else
	echo "note: no host cc, qmi-nas unit test skipped"
fi
for s in qmi qmi-nas; do cc "$QNO/$s.o" -D_GNU_SOURCE -I"$QN" "$QN/$s.c"; done
link "$O/bin/qmi-nas" "$QNO/qmi.o" "$QNO/qmi-nas.o"
# the aarch64 binary decodes libqmi's network-scan vector the same way (offline, qemu-user)
if command -v qemu-aarch64 >/dev/null; then
	V=$(sed -n '/^static const uint8_t netscan/,/};/p' "$QN/test/test-qmi.c" | grep -o '0x[0-9A-Fa-f][0-9A-Fa-f]' | tr '\n' ' ')
	qemu-aarch64 "$O/bin/qmi-nas" decode nas "$V" > "$O/qmi-nas-qemu.log" 2>&1 || true
	grep -q 'net\[7\] mcc=214 mnc=03 rat=umts status=0xa9 current-serving' "$O/qmi-nas-qemu.log" \
		|| { cat "$O/qmi-nas-qemu.log"; fail "qmi-nas (aarch64, qemu) decode of the network-scan vector"; }
	echo "qmi-nas: aarch64 binary decodes the libqmi network-scan vector (qemu-aarch64)"
fi

# checks: static aarch64 executables, no interpreter; the RAM-only guarantees are in the binary
# (pipefail off: "grep -q" closes the pipe early and the writer then fails with SIGPIPE)
set +o pipefail
for b in qrtr-lookup rmtfs tqftpserv efsdump qmi-nas; do
	f=$O/bin/$b
	file "$f" | grep -q "ARM aarch64.*statically linked" || fail "$b is not a static aarch64 executable: $(file "$f")"
	"$CLANG/bin/llvm-readelf" -l "$f" | grep -q INTERP && fail "$b has an ELF interpreter"
done
strings "$O/bin/rmtfs" | grep -q "a52sxq RAM-only build" || fail "rmtfs: not the RAM-only variant"
# rmtfs must not contain the upstream raw-partition / O_RDWR storage paths
"$CLANG/bin/llvm-objdump" -d "$RO/storage.o" | grep -qE "bl\s.*<(pwrite|fdatasync|pwrite64)>" && fail "storage.o calls pwrite/fdatasync"
"$CLANG/bin/llvm-nm" -u "$RO/storage.o" | grep -qwE "pwrite|pwrite64|fdatasync" && fail "storage.o imports pwrite/fdatasync"
"$CLANG/bin/llvm-nm" -u "$O/obj/efsdump.o" | grep -qwE "pwrite|pwrite64" && fail "efsdump imports pwrite"
# microSD (mmcblk*) HARD RULE: efsdump must carry its refusal; qmi-nas opens no files at all
strings "$O/bin/efsdump" | grep -q "microSD/eMMC device, never used" || fail "efsdump: no mmcblk refusal"
"$CLANG/bin/llvm-nm" -u "$QNO/qmi-nas.o" "$QNO/qmi.o" | grep -qwE "open|openat|fopen|creat|pwrite|write" && fail "qmi-nas opens or writes files"
ls -l "$O/bin"
echo "userspace: $O/bin/{rmtfs,tqftpserv,qrtr-lookup,efsdump,qmi-nas} (static aarch64 musl)"
