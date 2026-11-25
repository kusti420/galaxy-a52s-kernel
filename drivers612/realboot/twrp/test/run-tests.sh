#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Offline test of the recovery zips: builds small zips with mk-twrp-zips.sh from a fake
# package (1 MiB images), then runs update-binary in a fake recovery root under bubblewrap
# (user namespace, no device access, no network) with Android's own mksh and toybox (AOSP
# host prebuilts, the same tools LineageOS recovery has) and stubs for getprop, mount, umount,
# blockdev, df, chcon, ls -Z, dd (fault injection) and sync. Regular files stand in for the
# block devices (A52S_TESTMODE=1). Every scenario checks the exit code, the messages, the
# partitions and /vendor afterwards, that no other "partition" changed, and that nothing
# under mmcblk* was touched. Second part (2026-11-18): the ROM-independent MODE=ak zips
# (mk-ak-zips.sh) with the REAL ROM images (IchthysOS + LineageOS dumps, see the AK_* paths below;
# skipped when they are missing), bin/a52boot as host build and as the shipped arm64 binary
# (qemu-aarch64), plus a52boot on mkbootimg-made header v4 images.
#   test/run-tests.sh [mksh|bash|all]      (default all)
# Env: ABT = AOSP prebuilts/build-tools/linux-x86 (mksh as bin/sh, toybox, ziptool).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TW=$(dirname "$HERE")
ABT=${ABT:-$HOME/git/android/prebuilts/build-tools/linux-x86}
SHELLS=${1:-all}
[ "$SHELLS" = all ] && SHELLS="mksh bash"
T=$(mktemp -d "${TMPDIR:-/tmp}/a52s-twrp-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
[ -n "${KEEP:-}" ] && { trap - EXIT; echo "work dir kept: $T"; }
for b in sh toybox ziptool; do [ -x "$ABT/bin/$b" ] || { echo "missing $ABT/bin/$b" >&2; exit 2; }; done
command -v bwrap > /dev/null || { echo "needs bubblewrap" >&2; exit 2; }

# ------------------------------------------------------------------ fake alpha package
SZ_B=1048576; SZ_D=262144
mkimg() { # <file> <size> <marker>
	head -c "$2" /dev/zero > "$1"
	printf '%s' "$3" | dd of="$1" bs=1 seek=8192 conv=notrunc status=none
	head -c 3000 /dev/urandom | dd of="$1" bs=1 seek=20000 conv=notrunc status=none
}
P=$T/alphaT/pkg
mkdir -p "$P" "$T/img/k" "$T/img/s"
for p in boot vendor_boot dtbo; do
	sz=$SZ_B; [ $p = dtbo ] && sz=$SZ_D
	mkimg "$T/img/k/$p.img" $sz "Linux version 6.12.81-4k-test (build@host) $p"
	mkimg "$T/img/s/$p.img" $sz "Linux version 5.4.302-qgki-test (build@host) $p"
done
tar --owner=0 --group=0 -cf "$P/a52s-k612-alphaT-AP.tar" -C "$T/img/k" boot.img vendor_boot.img dtbo.img
tar --owner=0 --group=0 -cf "$P/a52s-lineage-20261028-stock-AP.tar" -C "$T/img/s" boot.img vendor_boot.img dtbo.img
A=$P/vendor-addon
mkdir -p "$A/lib/modules/6.12" "$A/lib/modules/5.4-gki" "$A/etc/init"
for m in snd_event_dlkm q6_dlkm machine_dlkm; do head -c 5000 /dev/urandom > "$A/lib/modules/6.12/$m.ko"; done
echo "snd_event_dlkm.ko:" > "$A/lib/modules/6.12/modules.dep"
: > "$A/lib/modules/6.12/modules.options"
head -c 70000 /dev/urandom > "$A/lib/modules/5.4-gki/qca_cld3_wlan.ko"
: > "$A/lib/modules/5.4-gki/modules.dep"
echo "on early-boot && property:ro.boot.a52sxq.k612=1" > "$A/etc/init/a52sxq-k612.rc"
echo "fake README" > "$P/README.txt"
echo "fake installer" > "$P/install-addon.sh"
(cd "$P" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)

echo "== building test zips (twice, for determinism)"
PART_SIZES="$SZ_B $SZ_B $SZ_D" "$TW/mk-twrp-zips.sh" "$P" "$T/out" > "$T/mk1.log" 2>&1 || { cat "$T/mk1.log"; exit 1; }
cp "$T/out/SHA256SUMS" "$T/sums1"
PART_SIZES="$SZ_B $SZ_B $SZ_D" "$TW/mk-twrp-zips.sh" "$P" "$T/out" > "$T/mk2.log" 2>&1 || { cat "$T/mk2.log"; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
cmp -s "$T/sums1" "$T/out/SHA256SUMS" && ok "mk-twrp-zips is deterministic" || bad "zips differ between two builds"
ZK=$T/out/a52s-k612-alphaT-twrp.zip
ZS=$T/out/a52s-lineage-stock-restore-twrp.zip
python3 -I - "$ZK" "$ZS" <<'EOF' && ok "zip metadata: fixed dates, unix modes, no extra fields, no dir entries" || bad "zip metadata"
import sys, zipfile
for z in sys.argv[1:]:
    for i in zipfile.ZipFile(z).infolist():
        assert i.date_time == (2008, 1, 1, 0, 0, 0), i
        assert i.extra == b"" and not i.filename.endswith("/"), i
        m = i.external_attr >> 16
        want = 0o100755 if i.filename.endswith("update-binary") else 0o100644
        assert m == want, (i.filename, oct(m))
    n = zipfile.ZipFile(z).namelist()
    for need in ("META-INF/com/android/metadata", "META-INF/com/google/android/update-binary",
                 "META-INF/com/google/android/updater-script", "a52s-k612.conf", "SHA256SUMS",
                 "images/boot.img", "images/vendor_boot.img", "images/dtbo.img"):
        assert need in n, need
EOF

# ------------------------------------------------------------------ fake recovery root
TBX=$T/tbx
mkdir -p "$TBX"
for a in $("$ABT/bin/toybox"); do ln -sf /abt/bin/toybox "$TBX/$a"; done
ln -sf /abt/bin/ziptool "$TBX/unzip"
ln -sf /usr/bin/chown "$TBX/chown"   # toybox host build has no chown

# new_root <name>: stock phone state, nothing mounted, ROM lineage 24.0-20261028
new_root() {
	R=$T/r/$1
	rm -rf "$R"
	mkdir -p "$R/blk/by-name" "$R/blk/mapper" "$R/sdcard" "$R/tmp" "$R/fake/parts" "$R/vendor" "$R/system_root"
	cp "$T/img/s/boot.img" "$R/blk/sda19"
	cp "$T/img/s/vendor_boot.img" "$R/blk/sda21"
	cp "$T/img/s/dtbo.img" "$R/blk/sda22"
	head -c 65536 /dev/urandom > "$R/blk/sda18"      # modem: must never change
	head -c 65536 /dev/urandom > "$R/blk/mmcblk1p1"  # microSD: must never change
	ln -s /dev/block/sda19 "$R/blk/by-name/boot"
	ln -s /dev/block/sda21 "$R/blk/by-name/vendor_boot"
	ln -s /dev/block/sda22 "$R/blk/by-name/dtbo"
	ln -s /dev/block/sda18 "$R/blk/by-name/modem"
	: > "$R/blk/dm-0"; : > "$R/blk/dm-1"
	ln -s /dev/block/dm-0 "$R/blk/mapper/system"
	ln -s /dev/block/dm-1 "$R/blk/mapper/vendor"
	S=$R/fake/parts/dm-0.d
	mkdir -p "$S/system"
	printf 'ro.build.version.release=17\nro.build.display.id=lineage_a52sxq-userdebug 17\nro.lineage.version=24.0-20261028-NIGHTLY-a52sxq\n' > "$S/system/build.prop"
	V=$R/fake/parts/dm-1.d
	mkdir -p "$V/lib/modules/5.4-gki" "$V/etc/init"
	printf 'ro.product.vendor.name=lineage_a52sxq\nro.vendor.build.version.release=17\n' > "$V/build.prop"
	head -c 9000 /dev/urandom > "$V/lib/modules/qca_cld3_wlan.ko"
	head -c 8000 /dev/urandom > "$V/lib/modules/5.4-gki/qca_cld3_wlan.ko"
	echo "service x /vendor/bin/x" > "$V/etc/init/hw.rc"
	printf 'ro.product.device=a52sxq\nro.build.product=a52sxq\nro.boot.bootloader=A528BXXU5FWK4\n' > "$R/fake/props"
	printf '/tmp tmpfs 2900000\n/sdcard /dev/block/dm-40 4000000\n/tmp/a52s-k612/vendor /dev/block/dm-1 300000\n/vendor /dev/block/dm-1 300000\n' > "$R/fake/df.conf"
	: > "$R/fake/mounts"; : > "$R/fake/cmd.log"; : > "$R/fake/labels"
	touch "$R/fake/ro.dm-0" "$R/fake/ro.dm-1"        # dm nodes start read-only
	(cd "$R/blk" && sha256sum sda18 mmcblk1p1) > "$R/fake/untouchable.sha"
}

# twrp_mounts: TWRP state: system at /system_root and vendor at /vendor, both ro
twrp_mounts() { echo "twrp_mounts" > "$R/fake/.twrp"; }

# run_zip <zip> <shell>: runs update-binary like a recovery (api 3, OUTFD 3); sets RC
run_zip() {
	unzip -p "$ZK" META-INF/com/google/android/update-binary > "$R/tmp/update-binary"   # same in both zips
	chmod 755 "$R/tmp/update-binary"
	local sh="" pre=""   # mksh: exec'd through the shebang like a recovery does
	[ "$2" = bash ] && sh="/usr/bin/bash --posix"
	[ -e "$R/fake/.twrp" ] && : > "$R/fake/mounts"   # fresh namespace: TWRP mounts again
	[ -e "$R/fake/.twrp" ] && pre='/stubs/mount -o ro /dev/block/mapper/system /system_root && /stubs/mount -o ro /dev/block/mapper/vendor /vendor && '
	bwrap --unshare-all --uid 0 --gid 0 --cap-add ALL --die-with-parent \
		--ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin \
		--proc /proc --dev /dev --bind "$R/blk" /dev/block \
		--bind "$R/sdcard" /sdcard --bind "$R/tmp" /tmp --bind "$R/fake" /fake \
		--bind "$R/vendor" /vendor --bind "$R/system_root" /system_root \
		--ro-bind "$ABT" /abt --ro-bind "$TBX" /tbx --ro-bind "$HERE/stubs" /stubs \
		--ro-bind "$ABT/bin/sh" /system/bin/sh \
		--ro-bind "$1" /sideload/package.zip \
		--clearenv --setenv PATH /stubs:/tbx --setenv A52S_TESTMODE 1 \
		--setenv A52S_TEST_MOUNTS /fake/mounts \
		/usr/bin/bash -c "$pre exec $sh /tmp/update-binary 3 3 /sideload/package.zip 3>/fake/ui.txt" \
		> "$R/fake/out.txt" 2>&1
	RC=$?
	sed -n 's/^ui_print //p' "$R/fake/ui.txt" | grep -v '^$' > "$R/fake/ui.msg"
}

# ------------------------------------------------------------------ assertions
expect_rc() { [ "$RC" = "$1" ] && ok "$SC: exit $RC" || { bad "$SC: exit $RC (want $1)"; sed 's/^/      /' "$R/fake/ui.msg" "$R/fake/out.txt" | tail -n 25; }; }
expect_msg() { grep -q -- "$1" "$R/fake/ui.msg" && ok "$SC: says '$1'" || { bad "$SC: no message '$1'"; sed 's/^/      /' "$R/fake/ui.msg" | tail -n 15; }; }
expect_parts() { # <img dir>
	local p dev
	for p in boot vendor_boot dtbo; do
		case $p in boot) dev=sda19;; vendor_boot) dev=sda21;; dtbo) dev=sda22;; esac
		cmp -s "$1/$p.img" "$R/blk/$dev" || { bad "$SC: $p does not hold $(basename "$(dirname "$1/x")")/$p.img"; return; }
	done
	ok "$SC: boot/vendor_boot/dtbo = $(basename "$1")"
}
expect_safe() {
	(cd "$R/blk" && sha256sum -c --quiet "$R/fake/untouchable.sha") && ok "$SC: modem + mmcblk untouched" || bad "$SC: other partition changed"
	grep -q mmcblk "$R/fake/cmd.log" && bad "$SC: a command named mmcblk" || ok "$SC: no command touched mmcblk"
	[ -s "$R/fake/mounts" ] && { bad "$SC: still mounted: $(cat "$R/fake/mounts")"; } || ok "$SC: everything unmounted"
	[ -e "$R/tmp/a52s-k612" ] && bad "$SC: /tmp/a52s-k612 left behind" || ok "$SC: work dir removed"
}
expect_safe_twrp() { # TWRP mounts must be back read-only
	(cd "$R/blk" && sha256sum -c --quiet "$R/fake/untouchable.sha") && ok "$SC: modem + mmcblk untouched" || bad "$SC: other partition changed"
	[ "$(awk '$2 == "/vendor" { print substr($4,1,2) }' "$R/fake/mounts")" = ro ] && ok "$SC: TWRP's /vendor back read-only" || bad "$SC: /vendor not ro: $(cat "$R/fake/mounts")"
	[ "$(awk '$2 == "/system_root" { print substr($4,1,2) }' "$R/fake/mounts")" = ro ] && ok "$SC: TWRP's /system_root left read-only" || bad "$SC: /system_root changed"
}
expect_addon() { # installed and labelled
	local V=$R/fake/parts/dm-1.d f l want
	(cd "$A" && find . -type f | sed 's#^\./##' | sort) > "$R/fake/addon.list"
	while read -r f; do
		cmp -s "$A/$f" "$V/$f" || { bad "$SC: /vendor/$f differs"; return; }
		[ "$(stat -c %a "$V/$f")" = 644 ] || { bad "$SC: /vendor/$f mode $(stat -c %a "$V/$f")"; return; }
		want=u:object_r:vendor_file:s0; case $f in etc/init/*) want=u:object_r:vendor_configs_file:s0;; esac
		l=$(python3 -I -c 'import os,sys; print(os.getxattr(sys.argv[1], "user.selinux").decode())' "$V/$f" 2>/dev/null)
		[ "$l" = "$want" ] || { bad "$SC: /vendor/$f label '$l'"; return; }
	done < "$R/fake/addon.list"
	[ "$(stat -c %a "$V/lib/modules/6.12")" = 755 ] || { bad "$SC: 6.12 dir mode"; return; }
	[ -f "$V/lib/modules/qca_cld3_wlan.ko" ] && [ -f "$V/etc/init/hw.rc" ] || { bad "$SC: ROM vendor files lost"; return; }
	ok "$SC: add-on in /vendor: content, 0644/0755, labels; ROM files kept"
}
expect_no_addon() {
	local V=$R/fake/parts/dm-1.d
	[ ! -e "$V/lib/modules/6.12" ] && [ ! -e "$V/etc/init/a52sxq-k612.rc" ] && ok "$SC: no 6.12 add-on in /vendor" || bad "$SC: add-on present"
}
backup_dir() { ls -d "$R"/sdcard/a52s-k612-backup/*/ 2>/dev/null | head -n1; }
expect_backup() { # <img dir>
	local d; d=$(backup_dir)
	[ -n "$d" ] || { bad "$SC: no backup dir"; return; }
	for p in boot vendor_boot dtbo; do cmp -s "$1/$p.img" "$d/$p.img" || { bad "$SC: backup $p.img wrong"; return; }; done
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) || { bad "$SC: backup SHA256SUMS"; return; }
	[ -f "$d/install.log" ] && [ -f "$d/info.txt" ] || { bad "$SC: backup log/info missing"; return; }
	ok "$SC: backup in $(echo "$d" | sed "s#^$R##") verified"
}
expect_no_backup() { [ -z "$(backup_dir)" ] && ok "$SC: no backup written" || bad "$SC: backup written"; }

KI=$T/img/k; SI=$T/img/s
# ------------------------------------------------------------------ scenarios
for SH in $SHELLS; do
echo "== shell: $SH"

SC="$SH/install-fresh"; new_root i1
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_backup "$SI"; expect_safe
cmp -s "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$A/lib/modules/5.4-gki/qca_cld3_wlan.ko" && \
	[ -f "$(backup_dir)/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko" ] && ok "$SC: ROM's 5.4-gki wlan.ko saved in the backup" || bad "$SC: 5.4-gki backup"
expect_msg "ROM: LineageOS 24.0-20261028"
expect_msg "Current kernel: Linux version 5.4.302"
grep -q 'blockdev --setrw /dev/block/dm-1' "$R/fake/cmd.log" && ok "$SC: vendor dm set rw first" || bad "$SC: no setrw"

SC="$SH/reflash-same"   # same root again: nothing to back up, partitions untouched
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_safe
expect_msg "boot: already up to date"
[ "$(ls -d "$R"/sdcard/a52s-k612-backup/*/ | wc -l)" = 1 ] && ok "$SC: no second backup" || bad "$SC: second backup"

SC="$SH/restore"   # same root: back to stock
run_zip "$ZS" "$SH"
expect_rc 0; expect_parts "$SI"; expect_no_addon; expect_safe
cmp -s "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$A/lib/modules/5.4-gki/qca_cld3_wlan.ko" && ok "$SC: 5.4-gki left alone" || bad "$SC: 5.4-gki changed"
expect_msg "removed /vendor/lib/modules/6.12"
[ "$(ls -d "$R"/sdcard/a52s-k612-backup/*/ | wc -l)" = 2 ] && ok "$SC: backup of the 6.12 images taken" || bad "$SC: restore backup"

SC="$SH/install-twrp-mounted"; new_root i2; twrp_mounts
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_backup "$SI"; expect_safe_twrp
grep -q 'mount -o remount,rw /vendor' "$R/fake/cmd.log" && ok "$SC: remounted TWRP's /vendor rw" || bad "$SC: no remount"

SC="$SH/restore-twrp-mounted"
run_zip "$ZS" "$SH"
expect_rc 0; expect_parts "$SI"; expect_no_addon; expect_safe_twrp

SC="$SH/wrong-bootloader"; new_root w1; sed -i 's/^ro.boot.bootloader=.*/ro.boot.bootloader=A525FXXU4CVJB/' "$R/fake/props"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe
expect_msg "not an SM-A528B bootloader"; expect_msg "Nothing was written"

SC="$SH/wrong-device"; new_root w2; sed -i 's/=a52sxq$/=a52q/' "$R/fake/props"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe; expect_msg "not a52sxq"

SC="$SH/no-bootloader-prop"; new_root w3; sed -i '/^ro.boot.bootloader=/d' "$R/fake/props"
run_zip "$ZS" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_backup; expect_safe; expect_msg "cannot read the bootloader"

SC="$SH/rom-not-lineage"; new_root r1; sed -i '/ro.lineage.version/d' "$R/fake/parts/dm-0.d/system/build.prop"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe; expect_msg "not LineageOS"

SC="$SH/rom-lineage-23"; new_root r2; sed -i 's/^ro.lineage.version=.*/ro.lineage.version=23.2-20260901-NIGHTLY-a52sxq/' "$R/fake/parts/dm-0.d/system/build.prop"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe; expect_msg "is not LineageOS 24"

SC="$SH/rom-other-24"; new_root r3; sed -i 's/^ro.lineage.version=.*/ro.lineage.version=24.0-20261111-NIGHTLY-a52sxq/' "$R/fake/parts/dm-0.d/system/build.prop"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_safe; expect_msg "only 24.0-20261028 was tested"

SC="$SH/system-erofs"; new_root r4; echo erofs > "$R/fake/fstype.dm-0"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_safe
grep -q 'mount -t erofs -o ro /dev/block/dm-0' "$R/fake/cmd.log" && ok "$SC: erofs fallback used" || bad "$SC: no erofs mount"

SC="$SH/system-unreadable-vendor-lineage"; new_root r5; rm "$R/blk/mapper/system"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_safe; expect_msg "cannot read /system/build.prop"; expect_msg "looks like LineageOS"

SC="$SH/system-unreadable-vendor-other"; new_root r6; rm "$R/blk/mapper/system"; echo "ro.product.vendor.name=a52sxqxx" > "$R/fake/parts/dm-1.d/build.prop"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_backup; expect_safe; expect_msg "cannot tell which ROM"

SC="$SH/low-sdcard-space"; new_root s1; sed -i 's#^/sdcard .*#/sdcard /dev/block/dm-40 300000#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_addon; expect_no_backup; expect_safe; expect_msg "600 MB needed"

SC="$SH/sdcard-not-mounted"; new_root s2; sed -i 's#^/sdcard .*#/sdcard rootfs 3000000#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_no_backup; expect_safe; expect_msg "internal storage is not mounted"

SC="$SH/sdcard-is-microsd"; new_root s3; sed -i 's#^/sdcard .*#/sdcard /dev/block/mmcblk1p1 9000000#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_no_backup; expect_msg "microSD"
(cd "$R/blk" && sha256sum -c --quiet "$R/fake/untouchable.sha") && ok "$SC: microSD untouched" || bad "$SC: microSD changed"

SC="$SH/low-tmp"; new_root s4; sed -i 's#^/tmp .*#/tmp tmpfs 1000#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe; expect_msg "not enough space in /tmp"

SC="$SH/vendor-full"; new_root s5; sed -i 's#^\(/tmp/a52s-k612/vendor\|/vendor\) /dev/block/dm-1 .*#\1 /dev/block/dm-1 50#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_safe; expect_msg "not enough space on /vendor"; expect_msg "Nothing was written"

SC="$SH/vendor-shared-blocks"; new_root v1; touch "$R/fake/norw.dm-1"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_safe; expect_msg "cannot mount vendor"; expect_msg "Nothing was written"

SC="$SH/vendor-dm-stuck-ro-twrp"; new_root v2; twrp_mounts; touch "$R/fake/stuckro.dm-1"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_safe_twrp; expect_msg "cannot remount /vendor read-write"

SC="$SH/vendor-wrong-label"; new_root v3; touch "$R/fake/wronglabel"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_safe; expect_msg "has SELinux label"; expect_msg "boot/vendor_boot/dtbo were NOT changed"

SC="$SH/vendor-label-unreadable"; new_root v5; touch "$R/fake/nochcon"
run_zip "$ZK" "$SH"
expect_rc 0; expect_parts "$KI"; expect_safe; expect_msg "could not read the SELinux label"

SC="$SH/restore-vendor-ro"; new_root v4; touch "$R/fake/norw.dm-1"
cp "$KI/boot.img" "$R/blk/sda19"; cp "$KI/vendor_boot.img" "$R/blk/sda21"; cp "$KI/dtbo.img" "$R/blk/sda22"
run_zip "$ZS" "$SH"
expect_rc 0; expect_parts "$SI"; expect_safe; expect_msg "The add-on stays in /vendor"

SC="$SH/part-size-mismatch"; new_root p1; head -c 4096 /dev/zero >> "$R/blk/sda21"; cp "$R/blk/sda21" "$R/sda21.before"
run_zip "$ZK" "$SH"
expect_rc 1; cmp -s "$R/blk/sda21" "$R/sda21.before" && cmp -s "$R/blk/sda19" "$SI/boot.img" && ok "$SC: partitions unchanged" || bad "$SC: changed"
expect_no_addon; expect_no_backup; expect_safe; expect_msg "not the expected partition layout"

SC="$SH/boot-on-mmcblk"; new_root p2; rm "$R/blk/by-name/boot"; ln -s /dev/block/mmcblk1p1 "$R/blk/by-name/boot"
run_zip "$ZK" "$SH"
expect_rc 1; expect_no_addon; expect_no_backup; expect_safe; expect_msg "microSD): refusing"

SC="$SH/write-verify-fails-restore-backup"; new_root f1; touch "$R/fake/corrupt.sda21"
run_zip "$ZK" "$SH"
expect_rc 1; expect_parts "$SI"; expect_safe; expect_msg "verification failed for: vendor_boot"; expect_msg "previous kernel was restored and verified"

SC="$SH/write-verify-fails-no-backup"; new_root f2; touch "$R/fake/corrupt.sda21"; sed -i 's#^/sdcard .*#/sdcard /dev/block/dm-40 100#' "$R/fake/df.conf"
run_zip "$ZK" "$SH"
expect_rc 1; expect_safe; expect_msg "DANGER"; expect_msg "Do NOT reboot"

SC="$SH/truncated-zip"; new_root z1; head -c $(( $(stat -c %s "$ZK") / 2 )) "$ZK" > "$R/bad.zip"
run_zip "$R/bad.zip" "$SH"
expect_rc 1; expect_parts "$SI"; expect_no_addon; expect_no_backup; expect_safe
done

# ================================================================== MODE=ak (ROM-independent zip)
# Real images: the zip is made from the real-boot build AK_SRC (default out/rbich5, built from the
# IchthysOS images AK_ICH); it is installed over the IchthysOS images and over the LineageOS images
# AK_LIN (alpha5's ROM, whose build out/rb24 = alpha5 has the same kernel, so its boot.img is the
# expected boot image there). bin/a52boot runs as the host build (stubs/akexec-host) or, in the
# arm64 scenarios, as the zip's own static arm64 binary under qemu-aarch64 (stubs/akexec-qemu).
RB=$(cd "$TW/.." && pwd)
TOP=$(cd "$RB/../.." && pwd)
AK_SRC=${AK_SRC:-$RB/out/rbich5}
AK_ICH=${AK_ICH:-$TOP/testdev-ichthys-202611112021}
AK_LIN=${AK_LIN:-$TOP/testdev-PHONE2}
AK_RB24=${AK_RB24:-$RB/out/rb24}
AKB=$RB/anykernel/a52boot/out
akmiss=""
for f in "$AK_SRC/boot.img" "$AK_SRC/vendor-addon" "$AK_ICH/boot.img" "$AK_ICH/vbmeta.img" "$AK_LIN/boot.img" "$AK_LIN/vbmeta.img" "$AK_RB24/boot.img"; do
	[ -e "$f" ] || akmiss="$akmiss $f"
done
command -v qemu-aarch64 > /dev/null || akmiss="$akmiss qemu-aarch64"
if [ -n "$akmiss" ]; then
	echo "== MODE=ak: SKIPPED (missing:$akmiss)"
else
echo "== MODE=ak: building zips from $AK_SRC (twice, for determinism)"
DUMP=$AK_ICH CHECK_DUMPS=$AK_LIN "$TW/mk-ak-zips.sh" "$AK_SRC" "$T/ak" > "$T/mkak1.log" 2>&1 || { cat "$T/mkak1.log"; exit 1; }
cp "$T/ak/SHA256SUMS" "$T/aksums1"
DUMP=$AK_ICH "$TW/mk-ak-zips.sh" "$AK_SRC" "$T/ak" > "$T/mkak2.log" 2>&1 || { cat "$T/mkak2.log"; exit 1; }
cmp -s "$T/aksums1" "$T/ak/SHA256SUMS" && ok "mk-ak-zips is deterministic" || bad "ak zips differ between two builds"
grep -q 'boot, vendor_boot, dtbo: match the build' "$T/mkak1.log" && ok "mk-ak-zips self-check: the build's images rebuilt byte for byte from its ROM images" || bad "mk-ak-zips self-check"
grep -q 'origin=match' "$T/mkak1.log" && ok "mk-ak-zips: LineageOS images give a matching origin" || bad "mk-ak-zips CHECK_DUMPS"
ZA=$(ls "$T"/ak/a52s-k612-*-twrp.zip | grep -v restore)
ZR=$T/ak/a52s-k612-restore-twrp.zip
# ICE_RAW=1 variant (2026-11-21): the same zip with ICE_RAW=1 in its conf (SHA256SUMS redone like mk-ak-zips)
rm -rf "$T/akice"; mkdir -p "$T/akice/z"; (cd "$T/akice/z" && unzip -q "$ZA")
sed -i 's/^ICE_RAW=.*/ICE_RAW=1/' "$T/akice/z/a52s-k612.conf"; grep -q '^ICE_RAW=1' "$T/akice/z/a52s-k612.conf" || echo ICE_RAW=1 >> "$T/akice/z/a52s-k612.conf"
(cd "$T/akice/z" && find . -type f ! -path './META-INF/*' ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | xargs sha256sum > ../sums && mv ../sums SHA256SUMS && zip -qr -X ../ice.zip .)
ZI=$T/akice/ice.zip
# kernel-only build (ADDON=vendor_boot, no vendor-addon/): AK_KO_SRC, default out/rbich7 (2026-11-19)
AK_KO_SRC=${AK_KO_SRC:-$RB/out/rbich7}
confzip() { # <zip> <name> <sed expr for the conf>: the same zip with a changed conf (SHA256SUMS redone) -> CZ
	rm -rf "$T/$2"; mkdir -p "$T/$2/z"; (cd "$T/$2/z" && unzip -q "$1")
	sed -i "$3" "$T/$2/z/a52s-k612.conf"
	(cd "$T/$2/z" && find . -type f ! -path './META-INF/*' ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | xargs sha256sum > ../sums && mv ../sums SHA256SUMS && zip -qr -X ../v.zip .)
	CZ=$T/$2/v.zip
}
ZK=""
if [ -f "$AK_KO_SRC/boot.img" ] && [ ! -d "$AK_KO_SRC/vendor-addon" ]; then
	DUMP=$AK_ICH "$TW/mk-ak-zips.sh" "$AK_KO_SRC" "$T/akko" > "$T/mkak3.log" 2>&1 || { cat "$T/mkak3.log"; exit 1; }
	ZK=$(ls "$T"/akko/a52s-k612-*-twrp.zip | grep -v restore)
	unzip -p "$ZK" a52s-k612.conf | grep -qx 'ADDON=none' && ok "kernel-only zip: ADDON=none, no vendor-addon" || bad "kernel-only zip conf"
	EXK=$T/exp-ko; mkdir -p "$EXK"; cp "$AK_KO_SRC"/{boot,vendor_boot,dtbo}.img "$EXK/"
	unzip -p "$ZK" a52s-k612.conf | grep -q '^TITLE=Linux 6.12 kernel .* for the Galaxy A52s 5G, any ROM$' && ok "kernel-only zip: title says any ROM" || bad "kernel-only zip title"
	unzip -p "$ZK" a52s-k612.conf | grep -q '^ALLOW_' && bad "kernel-only zip: ROM key in the conf" || ok "kernel-only zip: no ROM key in the conf"
	unzip -p "$ZK" README-TWRP.txt | grep -q 'tested:' && ! unzip -p "$ZK" README-TWRP.txt | grep -q 'based on LineageOS' && ok "kernel-only zip: README is ROM-generic" || bad "kernel-only zip README"
	# conf variants of the kernel-only zip: an older zip's ROM keys, ICE_RAW=1; and the add-on zip with ALLOW_ONEUI9=1
	confzip "$ZK" akko-old '$a ALLOW_ONEUI9=1\nALLOW_ICHTHYS=1'; ZKO=$CZ
	confzip "$ZK" akko-ice 's/^ICE_RAW=.*/ICE_RAW=1/'; ZKI=$CZ
	confzip "$T/ak/$(basename "$(ls "$T"/ak/a52s-k612-*-twrp.zip | grep -v restore)")" ak-oneui '$a ALLOW_ONEUI9=1'; ZAO=$CZ
	unzip -p "$ZAO" a52s-k612.conf | grep -q '^TITLE=.*LineageOS 24 based ROMs (with /vendor add-on)$' && ok "add-on zip: title names LineageOS 24" || bad "add-on zip title"
else
	echo "NOTE: no kernel-only build at $AK_KO_SRC: kernel-only cases skipped"
fi
python3 -I - "$ZA" "$ZR" <<'PY' && ok "ak zip metadata: fixed dates, modes (update-binary + bin/a52boot 0755), no images inside" || bad "ak zip metadata"
import sys, zipfile
for z in sys.argv[1:]:
    n = zipfile.ZipFile(z).namelist()
    for i in zipfile.ZipFile(z).infolist():
        assert i.date_time == (2008, 1, 1, 0, 0, 0) and i.extra == b"", i
        m = i.external_attr >> 16
        want = 0o100755 if i.filename in ("META-INF/com/google/android/update-binary", "bin/a52boot") else 0o100644
        assert m == want, (i.filename, oct(m))
        assert not i.filename.endswith(".img"), i.filename
    for need in ("META-INF/com/android/metadata", "META-INF/com/google/android/update-binary", "a52s-k612.conf", "SHA256SUMS", "bin/a52boot"):
        assert need in n, need
    if "restore" not in z:
        for need in ("kernel/Image", "kernel/vendor_boot.dtb", "kernel/vendor-cmdline.txt", "kernel/vendor-ramdisk-a52.cpio.lz4", "kernel/dtbo.raw"):
            assert need in n, need
PY
unzip -p "$ZA" bin/a52boot > "$T/a52boot-zip" && cmp -s "$T/a52boot-zip" "$AKB/a52boot-arm64" && file "$T/a52boot-zip" | grep -q 'ARM aarch64.*statically linked' &&
	ok "zip's bin/a52boot = the static arm64 build" || bad "bin/a52boot in the zip"

# expected images: the build itself (IchthysOS), rb24's boot (LineageOS, same kernel)
EXI=$T/exp-ich; mkdir -p "$EXI"; cp "$AK_SRC"/{boot,vendor_boot,dtbo}.img "$EXI/"
EXL=$T/exp-lin; mkdir -p "$EXL"
AKH=$AKB/a52boot-host
mkdir -p "$T/akx"; "$AKH" extract "$AK_SRC/boot.img" "$AK_SRC/vendor_boot.img" "$AK_SRC/dtbo.img" "$T/akx" > /dev/null
"$AKH" mkvendor "$AK_LIN/vendor_boot.img" "$T/akx/vendor_boot.dtb" "$T/akx/vendor-cmdline.txt" "$T/akx/vendor-ramdisk-a52.cpio.lz4" "$EXL/vendor_boot.img" > /dev/null
"$AKH" mkdtbo "$AK_LIN/dtbo.img" "$T/akx/dtbo.raw" "$EXL/dtbo.img" > /dev/null
cp "$AK_RB24/boot.img" "$EXL/boot.img"
avbtool info_image --image "$EXL/vendor_boot.img" | grep -q "Partition Name: *vendor_boot" && ok "LineageOS expected vendor_boot: avbtool reads the footer" || bad "avbtool footer"

# new_root_ak <name> <ROM image dir> <lineage|ichthys>: a stock phone with that ROM's images; data
# not decrypted (/sdcard empty dir on rootfs, as TWRP 3.7.1 on IchthysOS), /cache mounted
new_root_ak() {
	R=$T/r/$1
	rm -rf "$R"
	mkdir -p "$R/blk/by-name" "$R/blk/mapper" "$R/sdcard" "$R/tmp" "$R/fake/parts" "$R/vendor" "$R/system_root" "$R/data/media/0" "$R/cache"
	cp --sparse=always "$2/boot.img" "$R/blk/sda19"
	cp --sparse=always "$2/vendor_boot.img" "$R/blk/sda21"
	cp --sparse=always "$2/dtbo.img" "$R/blk/sda22"
	cp "$2/vbmeta.img" "$R/blk/sde19"
	head -c 65536 /dev/urandom > "$R/blk/sda18"
	head -c 65536 /dev/urandom > "$R/blk/mmcblk1p1"
	ln -s /dev/block/sda19 "$R/blk/by-name/boot"; ln -s /dev/block/sda21 "$R/blk/by-name/vendor_boot"
	ln -s /dev/block/sda22 "$R/blk/by-name/dtbo"; ln -s /dev/block/sda18 "$R/blk/by-name/modem"
	ln -s /dev/block/sde19 "$R/blk/by-name/vbmeta"
	: > "$R/blk/dm-0"; : > "$R/blk/dm-1"; : > "$R/blk/dm-2"
	ln -s /dev/block/dm-0 "$R/blk/mapper/system"; ln -s /dev/block/dm-1 "$R/blk/mapper/vendor"; ln -s /dev/block/dm-2 "$R/blk/mapper/product"
	S=$R/fake/parts/dm-0.d; P=$R/fake/parts/dm-2.d; V=$R/fake/parts/dm-1.d
	mkdir -p "$S/system" "$P/etc" "$V/lib/modules" "$V/etc/init/hw" "$V/bin"
	if [ "$3" = lineage ]; then
		printf 'ro.build.version.release=17\nro.build.version.sdk=37\nro.build.display.id=lineage_a52sxq-userdebug 17 CP2A.260605.016\nro.build.version.incremental=eng.lineage\n' > "$S/system/build.prop"
		printf 'ro.lineage.version=24.0-20261028-NIGHTLY-a52sxq\nro.lineage.device=a52sxq\n' > "$P/etc/build.prop"
		mkdir -p "$V/lib/modules/5.4-gki"
		{ printf 'ROM 5.4 wlan module '; head -c 6000 /dev/urandom; printf 'vermagic=5.4.302-qgki SMP preempt mod_unload'; } > "$V/lib/modules/5.4-gki/qca_cld3_wlan.ko"
		echo "/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko:" > "$V/lib/modules/5.4-gki/modules.dep"
	else
		printf 'ro.build.version.release=17\nro.build.version.sdk=37\nro.build.display.id=CP2A.260605.016\nro.build.version.incremental=ichthys202611112021\nro.lineage.device=a52sxq\n' > "$S/system/build.prop"
		printf 'ro.lineage.device=a52sxq\n' > "$P/etc/build.prop"
	fi
	printf 'ro.product.vendor.device=a52sxq\nro.product.vendor.name=lineage_a52sxq\nro.vendor.build.version.release=17\nro.vendor.build.version.sdk=37\n' > "$V/build.prop"
	head -c 9000 /dev/urandom > "$V/lib/modules/qca_cld3_wlan.ko"
	echo "#!/vendor/bin/sh" > "$V/bin/modprobe"
	echo "on boot" > "$V/etc/init/hw/init.target.rc"
	echo "service macloader /vendor/bin/hw/macloader" > "$V/etc/init/wifi_sec.rc"
	echo "service x /vendor/bin/x" > "$V/etc/init/hw.rc"
	printf 'ro.product.device=a52sxq\nro.build.product=a52sxq\nro.boot.bootloader=A528BXXU5FWK4\n' > "$R/fake/props"
	printf '/tmp tmpfs 2900000\n/sdcard rootfs 2000000\n/data/media/0 rootfs 2000000\n/cache /dev/block/sda29 75000\n/tmp/a52s-k612/vendor /dev/block/dm-1 300000\n/vendor /dev/block/dm-1 300000\n' > "$R/fake/df.conf"
	: > "$R/fake/mounts"; : > "$R/fake/cmd.log"; : > "$R/fake/labels"
	touch "$R/fake/ro.dm-0" "$R/fake/ro.dm-1" "$R/fake/ro.dm-2"
	(cd "$R/blk" && sha256sum sda18 mmcblk1p1) > "$R/fake/untouchable.sha"
}
# set_rom <release> <sdk> <display id> <incremental>: a ROM without any ro.lineage.* property
set_rom() {
	printf 'ro.build.version.release=%s\nro.build.version.sdk=%s\nro.build.display.id=%s\nro.build.version.incremental=%s\n' "$@" > "$R/fake/parts/dm-0.d/system/build.prop"
	: > "$R/fake/parts/dm-2.d/etc/build.prop"
}
expect_no_msg() { grep -q -- "$1" "$R/fake/ui.msg" && { bad "$SC: says '$1'"; grep -- "$1" "$R/fake/ui.msg" | sed 's/^/      /' | head -n 5; } || ok "$SC: does not say '$1'"; }
sdcard_ok() { # internal storage decrypted and mounted (backup goes there, raw images)
	sed -i 's#^/sdcard .*#/sdcard /dev/block/dm-40 4000000#; s#^/data/media/0 .*#/data/media/0 /dev/block/dm-40 4000000#' "$R/fake/df.conf"
}

# run_ak <zip> <shell> [host|qemu]: like run_zip, with /data, /cache and the a52boot runner
run_ak() {
	unzip -p "$ZA" META-INF/com/google/android/update-binary > "$R/tmp/update-binary"   # same in both zips
	chmod 755 "$R/tmp/update-binary"
	local sh="" ex=/stubs/akexec-${3:-host} zp=${ZIPNAME:-package.zip}
	[ "$2" = bash ] && sh="/usr/bin/bash --posix"
	bwrap --unshare-all --uid 0 --gid 0 --cap-add ALL --die-with-parent \
		--ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin \
		--proc /proc --dev /dev --bind "$R/blk" /dev/block \
		--bind "$R/sdcard" /sdcard --bind "$R/tmp" /tmp --bind "$R/fake" /fake \
		--bind "$R/vendor" /vendor --bind "$R/system_root" /system_root \
		--bind "$R/data" /data --bind "$R/cache" /cache \
		--ro-bind "$ABT" /abt --ro-bind "$TBX" /tbx --ro-bind "$HERE/stubs" /stubs --ro-bind "$AKB" /akhost \
		--ro-bind "$ABT/bin/sh" /system/bin/sh \
		--ro-bind "$1" "/sideload/$zp" \
		--clearenv --setenv PATH /stubs:/tbx --setenv A52S_TESTMODE 1 \
		--setenv A52S_TEST_MOUNTS /fake/mounts --setenv A52S_TEST_EXEC "$ex" \
		/usr/bin/bash -c "exec $sh /tmp/update-binary 3 3 /sideload/$zp 3>/fake/ui.txt" \
		> "$R/fake/out.txt" 2>&1
	RC=$?
	sed -n 's/^ui_print //p' "$R/fake/ui.txt" | grep -v '^$' > "$R/fake/ui.msg"
	cp "$R/tmp/a52s-k612.log" "$R/fake/last.log" 2>/dev/null
}
expect_rc() { [ "$RC" = "$1" ] && ok "$SC: exit $RC" || { bad "$SC: exit $RC (want $1)"; sed 's/^/      /' "$R/fake/ui.msg" "$R/fake/out.txt" | tail -n 25; }; }
expect_akparts() { # <dir with boot/vendor_boot/dtbo.img>
	local p dev
	for p in boot vendor_boot dtbo; do
		case $p in boot) dev=sda19;; vendor_boot) dev=sda21;; dtbo) dev=sda22;; esac
		cmp -s "$1/$p.img" "$R/blk/$dev" || { bad "$SC: $p is not $1/$p.img"; return; }
	done
	ok "$SC: boot/vendor_boot/dtbo = $(basename "$1") byte for byte"
}
expect_ak_safe() {
	(cd "$R/blk" && sha256sum -c --quiet "$R/fake/untouchable.sha") && ok "$SC: modem + mmcblk untouched" || bad "$SC: other partition changed"
	cmp -s "$R/blk/sde19" "$VBM_SRC" && ok "$SC: vbmeta untouched" || bad "$SC: vbmeta changed"
	grep -q mmcblk "$R/fake/cmd.log" && bad "$SC: a command named mmcblk" || ok "$SC: no command touched mmcblk"
	[ -s "$R/fake/mounts" ] && bad "$SC: still mounted: $(cat "$R/fake/mounts")" || ok "$SC: everything unmounted"
	[ -e "$R/tmp/a52s-k612" ] && bad "$SC: /tmp/a52s-k612 left behind" || ok "$SC: work dir removed"
}
ak_bk() { ls -d "$R"/cache/a52s-k612-backup/*/ "$R"/sdcard/a52s-k612-backup/*/ 2>/dev/null; }
expect_ak_backup() { # <where: cache|sdcard> <dir with the images>
	local d; d=$(ls -d "$R/$1"/a52s-k612-backup/*/ 2>/dev/null | tail -n 1)
	[ -n "$d" ] || { bad "$SC: no backup in /$1"; return; }
	for p in boot vendor_boot dtbo; do
		if [ "$1" = cache ]; then
			"$AKH" unpack "$d/$p.img.a52pack" "$T/unp.img" > /dev/null 2>&1 && cmp -s "$T/unp.img" "$2/$p.img" || { bad "$SC: /cache backup $p wrong"; return; }
		else
			cmp -s "$d/$p.img" "$2/$p.img" || { bad "$SC: /sdcard backup $p wrong"; return; }
		fi
	done
	[ "$(grep -c . "$d/SHA256SUMS")" = 3 ] && [ -f "$d/info.txt" ] && [ -f "$d/install.log" ] || { bad "$SC: backup sums/info/log"; return; }
	grep -q "^format: $( [ "$1" = cache ] && echo pack || echo raw)$" "$d/info.txt" || { bad "$SC: backup format line"; return; }
	ok "$SC: backup in /$1 holds the previous images exactly"
}
expect_no_ak_backup() { [ -z "$(ak_bk)" ] && ok "$SC: no backup written" || bad "$SC: backup written: $(ak_bk)"; }
expect_vendor_rom() { # vendor as the ROM had it (no add-on files, ROM files back)
	local V=$R/fake/parts/dm-1.d
	[ ! -e "$V/lib/modules/6.12" ] && [ ! -e "$V/etc/init/a52sxq-k612.rc" ] || { bad "$SC: add-on still in /vendor"; return; }
	cmp -s "$V/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$R/rom-54gki.ko" 2>/dev/null || [ ! -e "$R/rom-54gki.ko" ] || { bad "$SC: ROM 5.4-gki wlan.ko not back"; return; }
	if [ ! -e "$R/rom-54gki.ko" ]; then [ ! -e "$V/lib/modules/5.4-gki" ] || { bad "$SC: 5.4-gki (created by the add-on) left"; return; }; fi
	[ -f "$V/lib/modules/qca_cld3_wlan.ko" ] && [ -f "$V/etc/init/hw.rc" ] || { bad "$SC: ROM vendor files lost"; return; }
	ok "$SC: /vendor back to the ROM's files"
}
expect_akaddon() {
	local V=$R/fake/parts/dm-1.d
	(cd "$AK_SRC/vendor-addon" && find . -type f | sed 's#^\./##' | sort) | while read -r f; do
		cmp -s "$AK_SRC/vendor-addon/$f" "$V/$f" || echo "$f"
	done > "$R/fake/addon.diff"
	[ -s "$R/fake/addon.diff" ] && { bad "$SC: add-on files differ: $(head -n 3 "$R/fake/addon.diff")"; return; }
	ok "$SC: add-on installed in /vendor"
}

for SH in $SHELLS; do
echo "== MODE=ak, shell: $SH"
VBM_SRC=$AK_ICH/vbmeta.img

SC="$SH/ak-install-ichthys"; new_root_ak a1 "$AK_ICH" ichthys
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_akaddon; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "ROM: LineageOS-based"; expect_msg "Current kernel: 5.4"; expect_msg "the ROM's ramdisk (Android 17.0.0, patch level 2026-06)"
[ -e "$R/fake/parts/dm-1.d/lib/modules/6.12/.a52-created-5.4-gki" ] && ok "$SC: 5.4-gki marked as created" || bad "$SC: no 5.4-gki marker"
grep -q 'sdcard not mounted' "$R/fake/last.log" && ok "$SC: undecrypted /sdcard skipped" || bad "$SC: /sdcard reason not logged"

SC="$SH/ak-reflash-same"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_ak_safe; expect_msg "already hold these images"
[ "$(ak_bk | wc -l)" = 1 ] && ok "$SC: no second backup" || bad "$SC: second backup"

SC="$SH/ak-restore-ichthys"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_ICH"; expect_vendor_rom; expect_ak_safe
expect_msg "matches the current 6.12 images"; expect_msg "removed /vendor/lib/modules/5.4-gki (created"

SC="$SH/ak-restore-again"   # nothing left to do: images = backup
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "already hold this backup's images"

SC="$SH/ak-install-lineage-sdcard"; new_root_ak l1 "$AK_LIN" lineage; sdcard_ok; VBM_SRC=$AK_LIN/vbmeta.img
cp "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$R/rom-54gki.ko"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXL"; expect_akaddon; expect_ak_backup sdcard "$AK_LIN"; expect_ak_safe
expect_msg "ROM: LineageOS 24.0-20261028"; expect_msg "patch level 2026-10"
d=$(ak_bk | tail -n 1); cmp -s "$d/vendor/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$R/rom-54gki.ko" && ok "$SC: ROM 5.4-gki wlan.ko in the backup" || bad "$SC: 5.4-gki not backed up"
[ -z "$(ls "$R"/cache/a52s-k612-backup 2>/dev/null)" ] && ok "$SC: nothing in /cache" || bad "$SC: /cache used"

SC="$SH/ak-restore-lineage"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_LIN"; expect_vendor_rom; expect_ak_safe; expect_msg "put back 2 ROM file"

SC="$SH/ak-over-old-612-zip"   # LineageOS on rb24 = alpha5 (old zip), its raw backup of the ROM images on /sdcard
new_root_ak l2 "$AK_LIN" lineage; sdcard_ok
for p in boot vendor_boot dtbo; do cp --sparse=always "$AK_RB24/$p.img" "$R/blk/$(case $p in boot) echo sda19;; vendor_boot) echo sda21;; dtbo) echo sda22;; esac)"; done
ob=$R/sdcard/a52s-k612-backup/20261117-120000; mkdir -p "$ob"
for p in boot vendor_boot dtbo; do cp --sparse=always "$AK_LIN/$p.img" "$ob/$p.img"; (cd "$ob" && sha256sum $p.img >> SHA256SUMS); done
printf 'a52sxq kernel backup, taken by: Linux 6.12 kernel alpha5 (install)\ndate: 20261117-120000\nkernel: Linux version 5.4.302-qgki\n' > "$ob/info.txt"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXL"; expect_ak_safe; expect_msg "a 6.x kernel of this project: no new backup"; expect_msg "used by the restore zip): /sdcard/a52s-k612-backup/20261117-120000"
grep -q 'removed_a52_fragments=1' "$R/fake/last.log" && ok "$SC: rb24's first-stage fragment replaced, not stacked" || bad "$SC: old fragment"
SC="$SH/ak-restore-to-old-zip-backup"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_LIN"; expect_ak_safe; expect_msg "Backup: /sdcard/a52s-k612-backup/20261117-120000"

SC="$SH/ak-restore-wrong-rom"   # 6.12 over IchthysOS, only a LineageOS backup around
new_root_ak w1 "$AK_ICH" ichthys; VBM_SRC=$AK_ICH/vbmeta.img
for p in boot vendor_boot dtbo; do cp --sparse=always "$EXI/$p.img" "$R/blk/$(case $p in boot) echo sda19;; vendor_boot) echo sda21;; dtbo) echo sda22;; esac)"; done
cp "$R/blk/sda19" "$R/b.before"
mkdir -p "$R/cache/a52s-k612-backup/20261101-000000"; ob=$R/cache/a52s-k612-backup/20261101-000000
for p in boot vendor_boot dtbo; do "$AKH" pack "$AK_LIN/$p.img" "$ob/$p.img.a52pack" > /dev/null; (cd "$AK_LIN" && sha256sum $p.img >> "$ob/SHA256SUMS"); done
printf 'date: 20261101-000000\nkernel: Linux version 5.4.302-qgki\nformat: pack\n' > "$ob/info.txt"
run_ak "$ZR" "$SH"
expect_rc 1; expect_akparts "$EXI"; expect_ak_safe; expect_msg "no backup (1 looked at) holds the ROM images"; expect_msg "Nothing was written"
grep -q 'origin=differs: boot header' "$R/fake/last.log" && ok "$SC: origin mismatch logged" || bad "$SC: origin reason"

SC="$SH/ak-restore-damaged-backup"; new_root_ak w2 "$AK_ICH" ichthys
run_ak "$ZA" "$SH" > /dev/null
d=$(ak_bk | tail -n 1); printf '\x01' | dd of="$d/boot.img.a52pack" bs=1 seek=300000 conv=notrunc status=none
run_ak "$ZR" "$SH"
expect_rc 1; expect_akparts "$EXI"; expect_ak_safe; expect_msg "is damaged (checksums): skipped"

SC="$SH/ak-restore-on-stock"; new_root_ak w3 "$AK_ICH" ichthys
run_ak "$ZR" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "is not a 6.x kernel of this project"

SC="$SH/ak-no-backup-space"; new_root_ak b1 "$AK_ICH" ichthys; sed -i 's#^/cache .*#/cache /dev/block/sda29 30000#' "$R/fake/df.conf"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_no_addon
expect_msg "no place for a backup"; expect_msg "MB needed"; expect_msg "Nothing was written"

SC="$SH/ak-nobackup-zipname"; new_root_ak b2 "$AK_ICH" ichthys; sed -i 's#^/cache .*#/cache /dev/block/sda29 30000#' "$R/fake/df.conf"
ZIPNAME=k-nobackup.zip run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_no_ak_backup; expect_ak_safe; expect_msg "installing WITHOUT one"

SC="$SH/ak-cache-not-writable"; new_root_ak b3 "$AK_ICH" ichthys; chmod 0555 "$R/cache"; touch "$R/cache/.ro"
sed -i 's#^/cache .*#/cache rootfs 75000#' "$R/fake/df.conf"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "/cache not mounted"
chmod 0755 "$R/cache"

SC="$SH/ak-sdcard-is-microsd"; new_root_ak b4 "$AK_ICH" ichthys; sed -i 's#^/sdcard .*#/sdcard /dev/block/mmcblk1p1 9000000#' "$R/fake/df.conf"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_ak_backup cache "$AK_ICH"; expect_ak_safe

SC="$SH/ak-vbmeta-verification-on"; new_root_ak c1 "$AK_ICH" ichthys
printf '\x00' | dd of="$R/blk/sde19" bs=1 seek=123 conv=notrunc status=none; cp "$R/blk/sde19" "$R/vbm"; VBM_SRC=$R/vbm
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "AVB verification is enabled"
VBM_SRC=$AK_ICH/vbmeta.img

SC="$SH/ak-rom-android16"; new_root_ak c2 "$AK_ICH" ichthys
sed -i 's/^ro.build.version.release=.*/ro.build.version.release=16/; s/^ro.build.version.sdk=.*/ro.build.version.sdk=36/' "$R/fake/parts/dm-0.d/system/build.prop"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "not Android 17"

SC="$SH/ak-rom-not-lineage"; new_root_ak c3 "$AK_ICH" ichthys
sed -i '/ro.lineage/d' "$R/fake/parts/dm-0.d/system/build.prop" "$R/fake/parts/dm-2.d/etc/build.prop"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "not LineageOS-based"

SC="$SH/ak-rom-lineage23"; new_root_ak c4 "$AK_LIN" lineage; VBM_SRC=$AK_LIN/vbmeta.img
sed -i 's/^ro.lineage.version=.*/ro.lineage.version=23.2-20260901-NIGHTLY-a52sxq/' "$R/fake/parts/dm-2.d/etc/build.prop"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_LIN"; expect_ak_safe; expect_msg "is not LineageOS 24"
VBM_SRC=$AK_ICH/vbmeta.img

SC="$SH/ak-ice-wrappedkey"; new_root_ak iceA "$AK_ICH" ichthys
mkdir -p "$R/fake/parts/dm-1.d/etc"
printf '/dev/block/bootdevice/by-name/userdata /data f2fs noatime,inlinecrypt latemount,wait,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0,metadata_encryption=aes-256-xts:wrappedkey_v0\n' > "$R/fake/parts/dm-1.d/etc/fstab.default"
run_ak "$ZI" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "hardware-wrapped keys"

SC="$SH/ak-ice-standard-keys"; new_root_ak iceB "$AK_ICH" ichthys
mkdir -p "$R/fake/parts/dm-1.d/etc"
printf '# wrappedkey in a comment is ignored\n/dev/block/bootdevice/by-name/userdata /data f2fs noatime,inlinecrypt latemount,wait,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized\n' > "$R/fake/parts/dm-1.d/etc/fstab.default"
run_ak "$ZI" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_ak_safe
grep -q 'fstab: /data without wrappedkey' "$R/fake/last.log" && ok "$SC: fstab checked" || { bad "$SC: fstab check not logged"; grep -E 'fstab|vendor' "$R/fake/last.log" | tail -5; ls -la "$R/fake/parts/dm-1.d/etc"; }

SC="$SH/ak-ice-hw-fstab-only"; new_root_ak iceD "$AK_ICH" ichthys
mkdir -p "$R/fake/parts/dm-1.d/etc"; printf 'ro.boot.hardware=qcom\n' >> "$R/fake/props"
printf '/dev/block/bootdevice/by-name/userdata /data f2fs noatime,inlinecrypt latemount,wait,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+emmc_optimized+wrappedkey_v0\n' > "$R/fake/parts/dm-1.d/etc/fstab.emmc"
printf '/dev/block/bootdevice/by-name/userdata /data f2fs noatime,inlinecrypt latemount,wait,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized\n' > "$R/fake/parts/dm-1.d/etc/fstab.qcom"
run_ak "$ZI" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_ak_safe
grep -q 'fstab: /data without wrappedkey (.*fstab.qcom)' "$R/fake/last.log" && ok "$SC: only fstab.qcom checked" || bad "$SC: fstab.<hardware> not used"

SC="$SH/ak-ice-no-fstab"; new_root_ak iceC "$AK_ICH" ichthys
run_ak "$ZI" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "no fstab in /vendor/etc"

SC="$SH/ak-vendor-not-a52sxq"; new_root_ak c5 "$AK_ICH" ichthys
sed -i 's/^ro.product.vendor.device=.*/ro.product.vendor.device=a52q/' "$R/fake/parts/dm-1.d/build.prop"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "not an a52sxq vendor"

SC="$SH/ak-vendor-no-wifi_sec"; new_root_ak c6 "$AK_ICH" ichthys; rm "$R/fake/parts/dm-1.d/etc/init/wifi_sec.rc"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "lacks what the 6.12 add-on needs: etc/init/wifi_sec.rc"

SC="$SH/ak-system-unmountable"; new_root_ak c7 "$AK_ICH" ichthys; rm -r "$R/fake/parts/dm-0.d"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "cannot mount system read-only"

SC="$SH/ak-boot-header-v2"; new_root_ak c8 "$AK_ICH" ichthys
printf '\x02' | dd of="$R/blk/sda19" bs=1 seek=40 conv=notrunc status=none; cp "$R/blk/sda19" "$R/b.v2"
run_ak "$ZA" "$SH"
expect_rc 1; cmp -s "$R/blk/sda19" "$R/b.v2" && ok "$SC: boot unchanged" || bad "$SC: boot changed"; expect_ak_safe
expect_msg "boot image header version 2 is not supported"

SC="$SH/ak-boot-is-not-boot"; new_root_ak c9 "$AK_ICH" ichthys; head -c 4096 /dev/zero | dd of="$R/blk/sda19" conv=notrunc status=none; cp "$R/blk/sda19" "$R/b.z"
run_ak "$ZA" "$SH"
expect_rc 1; cmp -s "$R/blk/sda19" "$R/b.z" && ok "$SC: boot unchanged" || bad "$SC: boot changed"; expect_ak_safe; expect_msg "does not hold a boot image"

SC="$SH/ak-write-verify-fails"; new_root_ak f1 "$AK_ICH" ichthys; touch "$R/fake/corrupt.sda21"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "verification failed for: vendor_boot"; expect_msg "previous kernel was restored and verified"

SC="$SH/ak-restore-write-fails"; rm -f "$R/fake/corrupt.sda21"; run_ak "$ZA" "$SH" > /dev/null; touch "$R/fake/corrupt.sda22"
run_ak "$ZR" "$SH"
expect_rc 1; expect_akparts "$EXI"; expect_ak_safe; expect_msg "verification failed for: dtbo"; expect_msg "previous kernel was restored and verified"

SC="$SH/ak-low-tmp"; new_root_ak t1 "$AK_ICH" ichthys; sed -i 's#^/tmp .*#/tmp tmpfs 100000#' "$R/fake/df.conf"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "not enough space in /tmp"

SC="$SH/ak-truncated-zip"; new_root_ak t2 "$AK_ICH" ichthys; head -c $(( $(stat -c %s "$ZA") / 2 )) "$ZA" > "$R/bad.zip"
run_ak "$R/bad.zip" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe

SC="$SH/ak-concurrent-run"; new_root_ak k1 "$AK_ICH" ichthys   # another install holds the lock (pid 1 = alive)
mkdir -p "$R/tmp/a52s-k612.lock" "$R/tmp/a52s-k612/z"; echo 1 > "$R/tmp/a52s-k612.lock/pid"; echo other > "$R/tmp/a52s-k612/z/marker"; echo "other run" > "$R/tmp/a52s-k612.log"
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_msg "another a52s-k612 zip is being installed"
[ -f "$R/tmp/a52s-k612/z/marker" ] && grep -q "other run" "$R/tmp/a52s-k612.log" && [ -d "$R/tmp/a52s-k612.lock" ] &&
	ok "$SC: the other run's work dir, log and lock untouched" || bad "$SC: other run disturbed"
SC="$SH/ak-stale-lock"; rm -rf "$R/tmp/a52s-k612" "$R/tmp/a52s-k612.log"; echo 99999 > "$R/tmp/a52s-k612.lock/pid"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akparts "$EXI"; expect_ak_safe
[ ! -e "$R/tmp/a52s-k612.lock" ] && ok "$SC: lock released" || bad "$SC: lock left"
SC="$SH/ak-reinstall-addon-files-not-backed-up"   # ROM images again (backup exists), an older add-on rc on /vendor
cp --sparse=always "$AK_ICH/boot.img" "$R/blk/sda19"; cp --sparse=always "$AK_ICH/vendor_boot.img" "$R/blk/sda21"; cp --sparse=always "$AK_ICH/dtbo.img" "$R/blk/sda22"
echo "# older add-on rc" > "$R/fake/parts/dm-1.d/etc/init/a52sxq-k612.rc"
run_ak "$ZA" "$SH"
expect_rc 0; expect_akaddon; expect_akparts "$EXI"; expect_msg "already backed up"
[ ! -e "$(ak_bk | tail -n 1)/vendor/etc/init/a52sxq-k612.rc" ] && ok "$SC: old add-on rc not saved as a ROM file" || bad "$SC: add-on rc in the backup"
[ "$(ls "$(ak_bk | tail -n 1)" | grep -c '^install.*log$')" -ge 2 ] && ok "$SC: second run's log kept beside the first" || bad "$SC: install.log overwritten"

if [ -n "$ZK" ]; then
VBM_SRC=$AK_ICH/vbmeta.img
SC="$SH/ak-ko-install-clean"; new_root_ak k2 "$AK_ICH" ichthys   # kernel-only on a ROM that never had an add-on
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_no_addon; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "nothing is installed into /vendor (no older add-on there)"
grep -qE '^mount .*(-o rw|remount,rw)' "$R/fake/cmd.log" && bad "$SC: /vendor was mounted read-write" || ok "$SC: /vendor never mounted read-write"
[ ! -e "$R/fake/parts/dm-1.d/lib/modules/5.4-gki" ] && ok "$SC: no 5.4-gki created" || bad "$SC: 5.4-gki created"
SC="$SH/ak-ko-restore-clean"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_ICH"; expect_vendor_rom; expect_ak_safe

SC="$SH/ak-ko-over-addon-ichthys"; new_root_ak k3 "$AK_ICH" ichthys   # add-on build first (the daily-phone case), then kernel-only
run_ak "$ZA" "$SH" > /dev/null
[ -e "$R/fake/parts/dm-1.d/lib/modules/6.12/.a52-created-5.4-gki" ] || bad "$SC: setup (add-on install)"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_vendor_rom; expect_ak_safe
expect_msg "add-on of an earlier install is not needed"; expect_msg "removed /vendor/lib/modules/5.4-gki (created"; expect_msg "removed /vendor/lib/modules/6.12 and"
expect_msg "no new backup"
SC="$SH/ak-ko-over-addon-restore"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_ICH"; expect_vendor_rom; expect_ak_safe; expect_msg "not installed: nothing to remove"

SC="$SH/ak-ko-over-addon-lineage"; new_root_ak k4 "$AK_LIN" lineage; sdcard_ok; VBM_SRC=$AK_LIN/vbmeta.img
cp "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/qca_cld3_wlan.ko" "$R/rom-54gki.ko"
run_ak "$ZA" "$SH" > /dev/null
run_ak "$ZK" "$SH"
expect_rc 0; expect_vendor_rom; expect_ak_safe; expect_msg "put back 2 ROM file"
SC="$SH/ak-ko-over-addon-lineage-restore"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_LIN"; expect_vendor_rom; expect_ak_safe

SC="$SH/ak-ko-stale-wlan-only"; new_root_ak k5 "$AK_ICH" ichthys; VBM_SRC=$AK_ICH/vbmeta.img   # only a 6.x wlan.ko left on the 5.4-gki path
mkdir -p "$R/fake/parts/dm-1.d/lib/modules/5.4-gki"
{ head -c 3000 /dev/urandom; printf 'vermagic=6.12.81-4k SMP preempt'; } > "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/qca_cld3_wlan.ko"
echo "# drivers612/realboot" > "$R/fake/parts/dm-1.d/lib/modules/5.4-gki/modules.dep"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_vendor_rom; expect_ak_safe; expect_msg "removed the 6.x wlan.ko"

SC="$SH/ak-ko-vendor-ro"; new_root_ak k6 "$AK_ICH" ichthys   # old add-on, but /vendor cannot go read-write: install still succeeds
run_ak "$ZA" "$SH" > /dev/null
touch "$R/fake/norw.dm-1"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe
rm -f "$R/fake/norw.dm-1"; expect_msg "add-on stays in /vendor"
VBM_SRC=$AK_ICH/vbmeta.img

# ---- the kernel-only zip installs over ANY ROM (2026-11-23): the ROM is identified only for the description
# and for warnings; what protects the phone (device, vbmeta, image types, wrapped keys) still aborts
SC="$SH/ak-ko-tested-roms"; new_root_ak g0 "$AK_ICH" ichthys
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_msg "ROM: IchthysOS ichthys202611112021 (Android 17)"; expect_no_msg "WARNING"
new_root_ak g0l "$AK_ICH" lineage
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_msg "ROM: LineageOS 24.0-20261028-NIGHTLY-a52sxq (Android 17)"; expect_no_msg "WARNING"
expect_msg "Package: Linux 6.12 kernel .* for the Galaxy A52s 5G, any ROM"

SC="$SH/ak-ko-rom-made-up"; new_root_ak g1 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_no_addon; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "ROM: FooOS-17.0-20261101-a52sxq (Android 17)"; expect_msg "WARNING: this kernel was never tested with this ROM"
expect_msg "Tested: LineageOS 24, IchthysOS, K4_UN1CA One UI 9 port"; expect_msg "Installing anyway"; expect_no_msg "than Android 17"
grep -qx 'rom: FooOS-17.0-20261101-a52sxq' "$(ak_bk | tail -n 1)info.txt" && ok "$SC: backup info names the ROM" || bad "$SC: backup info rom line"
SC="$SH/ak-ko-rom-made-up-restore"
run_ak "$ZR" "$SH"
expect_rc 0; expect_akparts "$AK_ICH"; expect_ak_safe; expect_msg "your ROM's own kernel is back"

SC="$SH/ak-ko-rom-android14"; new_root_ak g2 "$AK_ICH" ichthys   # a tested ROM name on an older Android: warning, no abort
sed -i 's/^ro.build.version.release=.*/ro.build.version.release=14/; s/^ro.build.version.sdk=.*/ro.build.version.sdk=34/' "$R/fake/parts/dm-0.d/system/build.prop"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "(Android 14)"; expect_msg "WARNING: Android 14 is older than Android 17: this kernel is untested there and may not boot"
expect_msg "Installing anyway"; expect_no_msg "never tested with this ROM"

SC="$SH/ak-ko-rom-lineage21-android14"; new_root_ak g3 "$AK_ICH" lineage   # both warnings
sed -i 's/^ro.build.version.release=.*/ro.build.version.release=14/; s/^ro.build.version.sdk=.*/ro.build.version.sdk=34/' "$R/fake/parts/dm-0.d/system/build.prop"
sed -i 's/^ro.lineage.version=.*/ro.lineage.version=21.0-20250101-NIGHTLY-a52sxq/' "$R/fake/parts/dm-2.d/etc/build.prop"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe
expect_msg "ROM: LineageOS 21.0-20250101-NIGHTLY-a52sxq (Android 14)"; expect_msg "is older than Android 17"; expect_msg "never tested with this ROM"

SC="$SH/ak-ko-rom-sdk-only"; new_root_ak g4 "$AK_ICH" ichthys; set_rom VanillaIceCream 35 "BarOS test build" eng.bar   # codename release: SDK decides
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe; expect_msg "ROM: BarOS test build (Android VanillaIceCream)"; expect_msg "is older than Android 17"
set_rom "" "" "BarOS test build" eng.bar; cp --sparse=always "$AK_ICH/boot.img" "$R/blk/sda19"; cp --sparse=always "$AK_ICH/vendor_boot.img" "$R/blk/sda21"; cp --sparse=always "$AK_ICH/dtbo.img" "$R/blk/sda22"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_msg "cannot tell this ROM's Android version"

SC="$SH/ak-ko-rom-android18"; new_root_ak g5 "$AK_ICH" ichthys
sed -i 's/^ro.build.version.release=.*/ro.build.version.release=18/; s/^ro.build.version.sdk=.*/ro.build.version.sdk=38/' "$R/fake/parts/dm-0.d/system/build.prop"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe; expect_msg "WARNING: Android 18 is newer than Android 17"

# the OneUI 9 port: stock Samsung vendor (Android 14 props, none of the add-on's files), no key in the conf needed;
# a conf of an older zip with ALLOW_ONEUI9=1 / ALLOW_ICHTHYS=1 is still accepted
for z in "$ZK" "$ZKO"; do
SC="$SH/ak-ko-rom-oneui9$([ "$z" = "$ZKO" ] && echo -old-conf)"; new_root_ak g6 "$AK_ICH" ichthys; set_rom 17 37 "OneUI9.3.140-98b20bd9 release-keys" 98b20bd9
rm -r "$R/fake/parts/dm-1.d/bin" "$R/fake/parts/dm-1.d/etc/init"
printf 'ro.product.vendor.device=a52sxq\nro.vendor.build.version.release=14\nro.vendor.build.version.sdk=34\n' > "$R/fake/parts/dm-1.d/build.prop"
run_ak "$z" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_no_addon; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "ROM: One UI 9 port OneUI9.3.140-98b20bd9 (Android 17)"; expect_no_msg "WARNING"
grep -qE '^mount .*(-o rw|remount,rw)' "$R/fake/cmd.log" && bad "$SC: /vendor was mounted read-write" || ok "$SC: /vendor never mounted read-write"
done

SC="$SH/ak-ko-system-unmountable"; new_root_ak g7 "$AK_ICH" ichthys; rm -r "$R/fake/parts/dm-0.d"   # ROM not identifiable: warning only
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
expect_msg "ROM: unknown (system cannot be mounted in this recovery)"; expect_msg "could not be identified"; expect_msg "never tested with this ROM"

SC="$SH/ak-ko-vendor-not-a52sxq"; new_root_ak g8 "$AK_ICH" ichthys
sed -i 's/^ro.product.vendor.device=.*/ro.product.vendor.device=a52q/' "$R/fake/parts/dm-1.d/build.prop"
run_ak "$ZK" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe; expect_msg "WARNING: the vendor partition is made for 'a52q', not a52sxq"

# the checks that protect the phone still abort, whatever the ROM
SC="$SH/ak-ko-made-up-vbmeta-verification-on"; new_root_ak h1 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
printf '\x00' | dd of="$R/blk/sde19" bs=1 seek=123 conv=notrunc status=none; cp "$R/blk/sde19" "$R/vbm"; VBM_SRC=$R/vbm
run_ak "$ZK" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "AVB verification is enabled"
VBM_SRC=$AK_ICH/vbmeta.img

SC="$SH/ak-ko-made-up-wrappedkey"; new_root_ak h2 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
mkdir -p "$R/fake/parts/dm-1.d/etc"; printf 'ro.boot.hardware=qcom\n' >> "$R/fake/props"
printf '/dev/block/bootdevice/by-name/userdata /data f2fs noatime,inlinecrypt latemount,wait,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0\n' > "$R/fake/parts/dm-1.d/etc/fstab.qcom"
run_ak "$ZKI" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "hardware-wrapped keys"; expect_msg "standard (not hardware-wrapped) keys only"
sed -i 's/+wrappedkey_v0//' "$R/fake/parts/dm-1.d/etc/fstab.qcom"
run_ak "$ZKI" "$SH"
expect_rc 0; expect_akparts "$EXK"; expect_ak_safe; expect_msg "never tested with this ROM"

SC="$SH/ak-ko-made-up-wrong-phone"; new_root_ak h3 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
sed -i 's/^ro.boot.bootloader=.*/ro.boot.bootloader=A525FXXU4CVJB/' "$R/fake/props"
run_ak "$ZK" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_msg "is not an SM-A528B bootloader"

SC="$SH/ak-ko-made-up-boot-is-not-boot"; new_root_ak h4 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
head -c 4096 /dev/zero | dd of="$R/blk/sda19" conv=notrunc status=none; cp "$R/blk/sda19" "$R/b.z"
run_ak "$ZK" "$SH"
expect_rc 1; cmp -s "$R/blk/sda19" "$R/b.z" && ok "$SC: boot unchanged" || bad "$SC: boot changed"; expect_no_ak_backup; expect_ak_safe; expect_msg "does not hold a boot image"

SC="$SH/ak-ko-made-up-no-backup-space"; new_root_ak h5 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
sed -i 's#^/cache .*#/cache /dev/block/sda29 30000#' "$R/fake/df.conf"
run_ak "$ZK" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe

# the zip WITH a /vendor add-on stays LineageOS-only
SC="$SH/ak-addon-rom-made-up"; new_root_ak h6 "$AK_ICH" ichthys; set_rom 17 37 "FooOS-17.0-20261101-a52sxq" eng.foo
run_ak "$ZA" "$SH"
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_no_addon
expect_msg "not LineageOS-based"; expect_msg "Use the kernel-only zip for other ROMs"
SC="$SH/ak-addon-rom-oneui9"; new_root_ak h7 "$AK_ICH" ichthys; set_rom 17 37 "OneUI9.3.140-98b20bd9 release-keys" 98b20bd9
run_ak "$ZAO" "$SH"   # even with ALLOW_ONEUI9=1 in the conf
expect_rc 1; expect_akparts "$AK_ICH"; expect_no_ak_backup; expect_ak_safe; expect_no_addon; expect_msg "not LineageOS-based"
fi

# the shipped static arm64 binary itself (qemu-aarch64): full install + restore
SC="$SH/ak-arm64-install"; new_root_ak q1 "$AK_ICH" ichthys
run_ak "$ZA" "$SH" qemu
expect_rc 0; expect_akparts "$EXI"; expect_akaddon; expect_ak_backup cache "$AK_ICH"; expect_ak_safe
SC="$SH/ak-arm64-restore"
run_ak "$ZR" "$SH" qemu
expect_rc 0; expect_akparts "$AK_ICH"; expect_vendor_rom; expect_ak_safe
done

# ------------------------------------------------------------------ a52boot on header v4 (synthetic)
echo "== a52boot: boot/vendor_boot header v4 (mkbootimg-made)"
V4=$T/v4; mkdir -p "$V4"
head -c 300000 /dev/urandom > "$V4/k-old"; printf 'ARMd' | dd of="$V4/k-old" bs=1 seek=56 conv=notrunc status=none
head -c 5000 /dev/urandom > "$V4/rd"; head -c 3000 /dev/urandom > "$V4/sig"
head -c 7000 /dev/urandom > "$V4/vr1"; head -c 9000 /dev/urandom > "$V4/vr2"; printf 'bootconfig.x=1\n' > "$V4/bc"
mkbootimg --header_version 4 --os_version 17.0.0 --os_patch_level 2026-06 --kernel "$V4/k-old" --ramdisk "$V4/rd" --cmdline 'x=1' -o "$V4/boot.img" 2> /dev/null &&
avbtool add_hash_footer --image "$V4/boot.img" --partition_name boot --partition_size 67108864 > /dev/null 2>&1 &&
mkbootimg --header_version 4 --vendor_boot "$V4/vb.img" --vendor_cmdline 'rom=1' --dtb "$T/akx/vendor_boot.dtb" \
	--ramdisk_type platform --ramdisk_name rom1 --vendor_ramdisk_fragment "$V4/vr1" \
	--ramdisk_type dlkm --ramdisk_name rom2 --vendor_ramdisk_fragment "$V4/vr2" --vendor_bootconfig "$V4/bc" 2> /dev/null &&
truncate -s 33554432 "$V4/vb.img" || { bad "v4: mkbootimg/avbtool cannot make the test images"; V4=""; }
if [ -n "$V4" ]; then
	"$AKH" mkboot "$V4/boot.img" "$T/akx/Image" "$V4/nb.img" > "$V4/nb.out" 2>&1 && unpack_bootimg --boot_img "$V4/nb.img" --out "$V4/ub" > "$V4/ub.txt" &&
	cmp -s "$V4/ub/kernel" "$T/akx/Image" && cmp -s "$V4/ub/ramdisk" "$V4/rd" && grep -q 'os patch level: 2026-06' "$V4/ub.txt" &&
	grep -q '^command line args: *$' "$V4/ub.txt" && grep -qx cmdline_blanked=1 "$V4/nb.out" && avbtool info_image --image "$V4/nb.img" > /dev/null && "$AKH" info "$V4/nb.img" | grep -q avb_hash_ok=1 &&
		ok "v4 boot: kernel replaced, ramdisk/os/patch kept, boot cmdline blanked (ABL appends it after ours), AVB footer valid" || bad "v4 boot: $(cat "$V4/nb.out")"
	"$AKH" mkvendor "$V4/vb.img" "$T/akx/vendor_boot.dtb" "$T/akx/vendor-cmdline.txt" "$T/akx/vendor-ramdisk-a52.cpio.lz4" "$V4/nv.img" > "$V4/nv.out" 2>&1 &&
	"$AKH" mkvendor "$V4/nv.img" "$T/akx/vendor_boot.dtb" "$T/akx/vendor-cmdline.txt" "$T/akx/vendor-ramdisk-a52.cpio.lz4" "$V4/nv2.img" > "$V4/nv2.out" 2>&1 &&
	cmp -s "$V4/nv.img" "$V4/nv2.img" && grep -q removed_a52_fragments=1 "$V4/nv2.out" &&
	unpack_bootimg --boot_img "$V4/nv.img" --out "$V4/uv" > "$V4/uv.txt" &&
	cmp -s "$V4/uv/vendor_ramdisk00" "$V4/vr1" && cmp -s "$V4/uv/vendor_ramdisk01" "$V4/vr2" && cmp -s "$V4/uv/vendor_ramdisk02" "$T/akx/vendor-ramdisk-a52.cpio.lz4" &&
	grep -q 'name: a52sxq-k612' "$V4/uv.txt" && cmp -s "$V4/uv/bootconfig" "$V4/bc" && cmp -s "$V4/uv/dtb" "$T/akx/vendor_boot.dtb" &&
		ok "v4 vendor_boot: ROM fragments + bootconfig kept, ours added as 'a52sxq-k612', re-run replaces it (idempotent)" || bad "v4 vendor_boot: $(cat "$V4/nv.out" "$V4/nv2.out" | tail -n 3)"
	"$AKH" mkboot "$V4/boot.img" "$V4/rd" "$V4/x.img" > /dev/null 2>&1 && bad "a52boot took a non-Image kernel" || ok "a52boot refuses a kernel without the ARMd magic"
	printf '\x01' | dd of="$V4/nb.img" bs=1 seek=$(( 67108864 - 64 - 4096 + 100 )) conv=notrunc status=none
	"$AKH" mkboot "$V4/boot.img" "$T/akx/Image" "$V4/nb.img" > /dev/null 2>&1; "$AKH" info "$V4/nb.img" | grep -q avb_hash_ok=1 && ok "a52boot output replaces a partially written file" || bad "rewrite"
fi
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
