#!/bin/bash
# Offline QEMU test of out/ntfs3.ko on the bsp612 dist Image: mkntfs image (virtio-blk disk; virtio_pci + virtio_blk from bsp612/out/dist),
# ro mount + read, rw mount with vold-like options, write/mkdir/rename/unlink, remount + read back, rmmod;
# afterwards the image is checked on the host with ntfsfix -n and ntfscat.   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/.." && pwd); TOP=$(cd "$S/../../.." && pwd)
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
I=$WORK/ntfs.img; rm -f "$I"; truncate -s 32M "$I"; mkntfs -q -F -f -L A52NTFS "$I" >/dev/null 2>&1
echo "hello from mkntfs" > "$WORK/hello.txt"; head -c 5000000 /dev/urandom > "$WORK/big.bin"
ntfscp -q "$I" "$WORK/hello.txt" hello.txt; ntfscp -q "$I" "$WORK/big.bin" big.bin
BIG=$(sha256sum < "$WORK/big.bin" | cut -c1-16)
M=$TOP/bsp612/out/dist/lib/modules/6.12.81-4k-g8a69376da734/kernel/drivers
cp "$S/out/ntfs3.ko" "$M"/virtio/virtio_pci*.ko "$M/block/virtio_blk.ko" "$WORK/rd/"; cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -1 ) > "$WORK/rd.cpio.gz"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-drive if=none,id=d0,format=raw,file="$I" -device virtio-blk-pci,drive=d0 \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "NTF: insmod rc=0" "insmod ntfs3.ko on the dist Image"
chk "NTF: filesystems: 1" "ntfs3 registered"
chk "NTF: mount ro rc=0" "mount -t ntfs3 ro"
chk "NTF: read hello=\[hello from mkntfs\]" "read a host-written file"
chk "NTF: read big sha=$BIG" "5 MB file sha256 matches the host's"
chk "NTF: mount rw rc=0" "rw mount with uid/gid/fmask/dmask/iocharset=utf8"
chk "NTF: write rc=0" "create + write"
chk "NTF: write 3M rc=0 size=3072000" "3 MB write"
chk "NTF: mkdir\+rename rc=0" "mkdir + rename"
chk "NTF: utf8 name rc=0" "UTF-8 file name"
chk "NTF: unlink rc=0" "unlink"
chk "NTF: umount rw rc=0" "umount after writes"
chk "NTF: remount rc=0" "mount again"
chk "NTF: readback new=\[written by 6.12 ntfs3\]" "new file reads back"
chk "NTF: readback 3M sha match" "3 MB file reads back identical"
chk "NTF: readback moved=\[hello from mkntfs\] big_gone=yes utf8=\[utf8 ok\]" "rename, unlink, UTF-8 persisted"
chk "NTF: owner host-made file: -rwxrwx--- 1023 1023" "uid/gid/fmask applied to files without WSL attributes"
chk "NTF: rmmod rc=0 left=0" "rmmod"
chk "NTF: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|Protected symbol|NTF: dmesg .*(error|corrupt)" "$C"; then echo "FAIL kernel warning/oops/ntfs error"; f=1; else echo "ok   no WARN/BUG/oops/ntfs3 error"; fi
# host cross-check of what the kernel wrote
if [ "$(ntfscat -q "$I" new.txt 2>/dev/null)" = "written by 6.12 ntfs3" ]; then echo "ok   host ntfscat reads the kernel-written file"; else echo "FAIL host ntfscat"; f=1; fi
if ntfsfix -n "$I" > "$WORK/ntfsfix.txt" 2>&1; then echo "ok   host ntfsfix -n: volume consistent"; else echo "FAIL host ntfsfix -n (see $WORK/ntfsfix.txt)"; f=1; fi
if ntfsls -q "$I" 2>/dev/null | grep -q "täht õ.txt"; then echo "ok   host ntfsls shows the UTF-8 name"; else echo "FAIL host ntfsls UTF-8 name"; f=1; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
