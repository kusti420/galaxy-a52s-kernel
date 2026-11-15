#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Offline test of the recovery zips: builds small zips with mk-twrp-zips.sh from a fake
# package (1 MiB images), then runs update-binary in a fake recovery root under bubblewrap
# (user namespace, no device access, no network) with Android's own mksh and toybox (AOSP
# host prebuilts, the same tools LineageOS recovery has) and stubs for getprop, mount, umount,
# blockdev, df, chcon, ls -Z, dd (fault injection) and sync. Regular files stand in for the
# block devices (A52S_TESTMODE=1). Every scenario checks the exit code, the messages, the
# partitions and /vendor afterwards, that no other "partition" changed, and that nothing
# under mmcblk* was touched.
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
