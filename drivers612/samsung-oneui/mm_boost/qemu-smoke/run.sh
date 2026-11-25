#!/bin/bash
# Offline QEMU smoke test (bsp612 GKI Image, QEMU virt, no phone) of a52sxq_mm_boost.ko and blk_sec_stats.ko:
# load, nodes + modes, mem_boost_mode/am_app_launch writes + 5 s timeout, blk_sec_stats with no disk
# (-ENODEV, still loads) and with a virtio-blk disk (disks=vda): diskios deltas after dd, pios per-tgid
# accounting after pios_enable, pios_duration_ms cap + timeout, rmmod, no WARN/BUG.
# Pattern of drivers612/samsung-oneui/qemu-smoke/run.sh.
#   drivers612/samsung-oneui/mm_boost/qemu-smoke/run.sh   -> PASS/FAIL, $WORK/console.txt
set -euo pipefail
Q=$(cd "$(dirname "$0")" && pwd); S=$(cd "$Q/../.." && pwd); TOP=$(cd "$S/../.." && pwd)
GKI=$TOP/bsp612/out/gki/drivers
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK/rd/bin" "$WORK/rd/lib" "$WORK/rd/proc" "$WORK/rd/sys" "$WORK/rd/dev"
"$S/build.sh" "$S/mm_boost" >/dev/null
"$S/build.sh" "$S/blk_sec_stats" >/dev/null
( cd "$WORK" && zcat "$TOP/pmos-kodiak/binaries/initramfs.cpio.gz" | cpio -id --quiet bin/busybox lib/ld-musl-aarch64.so.1 2>/dev/null )
cp "$WORK/bin/busybox" "$WORK/rd/bin/"; cp "$WORK/lib/ld-musl-aarch64.so.1" "$WORK/rd/lib/"
cp "$S/mm_boost/out/a52sxq_mm_boost.ko" "$S/blk_sec_stats/out/blk_sec_stats.ko" \
	"$GKI/virtio/virtio_pci_legacy_dev.ko" "$GKI/virtio/virtio_pci_modern_dev.ko" "$GKI/virtio/virtio_pci.ko" \
	"$GKI/block/virtio_blk.ko" "$WORK/rd/"
cp "$Q/init.sh" "$WORK/rd/init"; chmod +x "$WORK/rd/init" "$WORK/rd/bin/"*
( cd "$WORK/rd" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 ) > "$WORK/rd.cpio.gz"
rm -f "$WORK/disk.raw"; truncate -s 64M "$WORK/disk.raw"
QM=(qemu-system-aarch64 -machine virt,virtualization=on,gic-version=3 -cpu max -smp 4 -m 4G -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$WORK/virt.dtb" >/dev/null 2>&1
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/v.dtb" "$WORK/virt.dtb"
timeout 300 "${QM[@]}" -kernel "$TOP/bsp612/out/dist/Image" -dtb "$WORK/v.dtb" -initrd "$WORK/rd.cpio.gz" \
	-drive file="$WORK/disk.raw",if=none,id=d0,format=raw -device virtio-blk-pci,drive=d0 \
	-append "console=ttyAMA0 kvm-arm.mode=none panic=-1 printk.devkmsg=on log_buf_len=4M" > "$WORK/console.txt" 2>&1 || true
C=$WORK/console.txt; f=0
chk() { if grep -aqE -- "$1" "$C"; then echo "ok   $2"; else echo "FAIL $2"; f=1; fi; }
chk "SMK: vda present 1" "virtio-blk disk vda"
chk "SMK: mmb rc=0" "a52sxq_mm_boost loads"
chk "SMK: ls -rw-r--r-- .* mem_boost_mode" "mem_boost_mode 0644"
chk "SMK: ls -rw-r--r-- .* am_app_launch" "am_app_launch 0644"
chk "SMK: mbm initial=\[0\]" "mem_boost_mode initial 0"
chk "SMK: mbm write 2 rc=0 -> \[2\]" "mem_boost_mode write 2 reads back 2"
chk "SMK: mbm write 3 rc=0 -> \[3\]" "mem_boost_mode write 3 (BOOST_KILL)"
chk "SMK: mbm write 4 rc=1 -> \[3\]" "mem_boost_mode 4 -> EINVAL, value kept"
chk "SMK: mbm write -1 rc=1" "mem_boost_mode -1 -> EINVAL"
chk "SMK: mbm write abc rc=1" "mem_boost_mode non-number -> EINVAL"
chk "SMK: mbm after 6s=\[0\]" "mem_boost_mode resets to 0 after 5 s (5.4 timeout)"
chk "SMK: aal write 1 rc=0 -> \[1\] write 2 rc=1 -> \[1\]" "am_app_launch 0/1 only"
chk "SMK: bss0 rc=0" "blk_sec_stats loads without a matching disk"
chk "SMK: bss0 diskios rc=1" "diskios -> error without disk"
chk "SMK: rmmod bss0 rc=0" "rmmod (no disk case)"
chk "SMK: bss rc=0" "blk_sec_stats disks=vda loads"
chk "SMK: ls -r--r--r-- .* diskios" "diskios 0444"
chk "SMK: ls -r--r--r-- .* pios\s*$" "pios 0444"
chk "SMK: ls -rw-r--r-- .* pios_enable" "pios_enable 0644"
chk "SMK: ls -rw-r--r-- .* pios_duration_ms" "pios_duration_ms 0644"
chk "SMK: defaults en=\[0\] dur=\[5000\]" "5.4 defaults pios_enable 0, duration 5000"
chk '^SMK: diskios2 "ReadC":"[1-9][0-9]*","ReadKB":"(8[0-9]{3}|9[0-9]{3})","WriteC":"0","WriteKB":"0","DiscardC":"0","DiscardKB":"0","IOT":"[0-9]+","Hours":"0"' "diskios after 8 MiB read: ReadKB ~8192, no writes"
chk '^SMK: diskios3 "ReadC":"0","ReadKB":"0","WriteC":"[1-9][0-9]*","WriteKB":"(4[0-9]{3}|5[0-9]{3})"' "diskios after 4 MiB write: delta only, WriteKB ~4096"
chk "SMK: pios disabled=\[\]" "pios empty while disabled"
chk "SMK: pios line [0-9]+ (2[0-9]{3}|3[0-9]{3}) 0 (dd|busybox)" "pios: dd tgid with ~2048 KB read"
chk "SMK: pios line [0-9]+ 0 (1[0-9]{3}|2[0-9]{3}) (dd|busybox|sync)" "pios: dd tgid with ~1024 KB written"
chk "SMK: pios reread=\[\]" "pios cleared by the read"
chk "SMK: dur 20000 -> \[10000\] 100 -> \[100\]" "pios_duration_ms capped at 10000"
chk "SMK: pios after timeout=\[\]" "accounting stops after pios_duration_ms"
chk "SMK: rmmod blk_sec_stats rc=0" "rmmod blk_sec_stats"
chk "SMK: rmmod a52sxq_mm_boost rc=0" "rmmod a52sxq_mm_boost"
chk "SMK: nodes after rmmod: vmscan=0 bss=0" "nodes removed"
chk "SMK: END" "script ran to the end"
if grep -aqE "WARNING:|BUG:|Call trace|Oops|unsupported RELA|cannot create duplicate" "$C"; then echo "FAIL kernel warning/oops"; f=1; else echo "ok   no WARN/BUG/oops"; fi
echo "console: $C"; [ $f = 0 ] && echo PASS || echo FAIL; exit $f
