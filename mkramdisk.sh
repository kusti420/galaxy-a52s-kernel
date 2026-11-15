#!/bin/sh
# Builds out-ack/ramdisk-a52.cpio.gz: our own minimal bring-up ramdisk (ramdisk/init) around
# the busybox, musl and unudhcpd binaries from the postmarketOS initramfs, plus tools/rb.
# Env (defaults = the 6.18 harness build): OUT_RD=<output cpio.gz>, HHWDT=<hhwdt.ko built for the
# target kernel>, EXTRA_DIR=<dir packed as /extra> (build-mainline.sh uses all three).
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
mkdir -p "$T/src" "$T/r/bin" "$T/r/lib" "$T/r/usr/bin" "$T/r/sbin"
( cd "$T/src" && zcat "$OLDPWD/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox bin/busybox-extras lib/ld-musl-aarch64.so.1 usr/bin/unudhcpd 2>/dev/null )
cp "$T/src/bin/busybox" "$T/src/bin/busybox-extras" "$T/r/bin/"
cp "$T/src/lib/ld-musl-aarch64.so.1" "$T/r/lib/"
ln -s ld-musl-aarch64.so.1 "$T/r/lib/libc.musl-aarch64.so.1"
cp "$T/src/usr/bin/unudhcpd" "$T/r/usr/bin/"
# optional payload: everything in ramdisk/extra/ lands in /extra (test modules, test programs)
EXTRA_DIR="${EXTRA_DIR:-ramdisk/extra}"
if [ -d "$EXTRA_DIR" ]; then mkdir -p "$T/r/extra"; cp -r "$EXTRA_DIR"/. "$T/r/extra/"; fi
cp ramdisk/init "$T/r/init"; cp ramdisk/leave "$T/r/leave"; cp tools/rb "$T/r/rb"; chmod 755 "$T/r/init" "$T/r/leave" "$T/r/rb"
# kexec chain (kexec/README.md): loader + launcher with the watchdog safety net
cp tools/kx "$T/r/kx"; cp ramdisk/kexec-run "$T/r/kexec-run"; chmod 755 "$T/r/kx" "$T/r/kexec-run"
HHWDT="${HHWDT:-modules/hhwdt/hhwdt.ko}"
OUT_RD="${OUT_RD:-out-ack/ramdisk-a52.cpio.gz}"
[ -f "$HHWDT" ] && cp "$HHWDT" "$T/r/hhwdt.ko"
( cd "$T/r" && find . | cpio -o -H newc --quiet -R 0:0 | gzip -9 ) > "$OUT_RD"
rm -rf "$T"
ls -la "$OUT_RD"
