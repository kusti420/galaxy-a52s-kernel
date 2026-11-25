#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Image VARIANT for the OneUI 9 port: the bsp612 GKI kernel (6.12.81-4k-g8a69376da734) + ReSukiSU 8770c7e3 BUILT IN
# (CONFIG_KSU=y, KSU_SUSFS inline hooks) + SUSFS v2.3.0 (susfs4ksu gki-android16-6.12) + a52bc (as bsp612/out/diag).
# BUILDS ONLY, flashes nothing. See SUSFS.md.
#
#   drivers612/realboot/modules/resukisu/build-susfs-image.sh [prepare|build|all]   (default all)
#     -> bsp612/out/susfs/{Image,System.map,BUILDINFO,vmlinux.symvers,crc-changed.txt,susfs.config}
#
# The main kernel tree and its outputs are never touched: the work is done in bsp612/kernel-susfs (a reflink copy
# of bsp612/kernel, made once; delete it to start over) with the output in bsp612/out/gki-susfs.
# The release string stays the same because every tracked file the patches touch is marked
# `git update-index --assume-unchanged` in the copy (setlocalversion: git status -uno), as kernel-diag does.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../../.." && pwd)
BSP=$TOP/bsp612; SRC=$BSP/kernel; KS=${KS:-$BSP/kernel-susfs}; GKI=$BSP/out/gki; OD=${OD:-$BSP/out/gki-susfs}; DIST=${DIST:-$BSP/out/susfs}
DIAG=$TOP/drivers612/realboot/kernel-diag
RESUKISU=$TOP/donors/ReSukiSU; KSU_REV=8770c7e324a22895703c4916b8a16520e0b81c79
SUSFS=$TOP/donors/susfs4ksu; SUSFS_URL=https://gitlab.com/simonpunk/susfs4ksu.git; SUSFS_BRANCH=gki-android16-6.12
# b213c54 (2026-09-26, v2.3.0) = the last state whose hooks ReSukiSU 8770c7e3 can satisfy: from acb92d4 on the patch calls
# my_security_* / my_setprocattr / ksu_setup_preinit_file, which this ReSukiSU does not export (link fails).
SUSFS_REV=b213c54126fb243595ce7876e91d84d6e0861fec
CLANG=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
RUSTBIN=${RUSTBIN:-$HOME/.rustup/toolchains/1.82.0-x86_64-unknown-linux-gnu/bin}
export LIBCLANG_PATH=$(dirname "$CLANG")/lib KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost
K=(make -s -C "$KS" ARCH=arm64 LLVM="$CLANG/" RUSTC="$RUSTBIN/rustc" HOSTRUSTC="$RUSTBIN/rustc"
	BINDGEN=${ANDROID_TREE:-$HOME/android}/prebuilts/clang-tools/linux-x86/bin/bindgen O="$OD")
fail() { echo "FAILED: $*" >&2; exit 1; }

prepare() {
	[ -e "$KS/.a52-susfs-applied" ] && { echo "prepare: $KS already prepared ($(cat "$KS/.a52-susfs-applied"))"; return 0; }
	[ ! -e "$KS" ] || fail "$KS exists without the marker: remove it"
	[ -z "$(git -C "$SRC" status --porcelain -uno)" ] || fail "bsp612/kernel has tracked changes"
	[ -d "$RESUKISU/.git" ] || fail "no donors/ReSukiSU (run ./build.sh once)"
	if [ ! -d "$SUSFS/.git" ]; then git clone -q --single-branch --branch "$SUSFS_BRANCH" "$SUSFS_URL" "$SUSFS"; fi
	git -C "$SUSFS" checkout -q "$SUSFS_REV"
	cp -a --reflink=auto "$SRC" "$KS"     # keeps the index: setup.h (COMMAND_LINE_SIZE 4096) stays assume-unchanged
	cd "$KS"
	# 1. SUSFS kernel side: upstream patch, then the two hunks that do not apply on 6.12.81 (include block of exec.c, show_smap)
	patch -s -p1 --no-backup-if-mismatch < "$SUSFS/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" || true
	[ "$(find . -name '*.rej' | sort | tr '\n' ' ')" = "./fs/exec.c.rej ./fs/proc/task_mmu.c.rej " ] || fail "unexpected rejects: $(find . -name '*.rej')"
	rm fs/exec.c.rej fs/proc/task_mmu.c.rej
	patch -s -p1 < "$HERE/susfs/0001-susfs-rejected-hunks-for-6.12.81.patch"
	cp "$SUSFS/kernel_patches/fs/susfs.c" fs/
	cp "$SUSFS/kernel_patches/include/linux/susfs.h" "$SUSFS/kernel_patches/include/linux/susfs_def.h" include/linux/
	# 2. ReSukiSU in the tree (its own clone: the version code needs the git history; the LKM build tree stays clean)
	git clone -q "$RESUKISU" KernelSU; git -C KernelSU checkout -q "$KSU_REV"
	[ "$(git -C KernelSU rev-list --count HEAD)" = 4503 ] || fail "unexpected ReSukiSU history"
	ln -s ../KernelSU/kernel drivers/kernelsu
	printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
	sed -i '0,/^endmenu/{/^endmenu/i source "drivers/kernelsu/Kconfig"
}' drivers/Kconfig
	# 3. a52bc (breadcrumbs + RAM console), as the diag Image
	cp "$DIAG/a52bc.c" "$DIAG/a52bc.h" arch/arm64/kernel/
	patch -s -p1 < "$DIAG/0001-a52bc-hooks.patch"
	# 4. same release string
	git status --porcelain -uno | awk '{print $2}' > .a52-susfs-files
	git update-index --assume-unchanged $(cat .a52-susfs-files)
	[ -z "$(git status --porcelain -uno)" ] || fail "tree still dirty for setlocalversion"
	echo "resukisu=$KSU_REV susfs4ksu=$SUSFS_REV a52bc=$(sha256sum < "$DIAG/a52bc.c" | cut -c1-12)" > .a52-susfs-applied
	echo "prepare: $(wc -l < .a52-susfs-files) tracked files patched in $KS"
}

build() {
	[ -e "$KS/.a52-susfs-applied" ] || fail "run prepare first"
	[ -f "$GKI/vmlinux.symvers" ] && [ -f "$GKI/include/config/kernel.release" ] || fail "no bsp612/out/gki build"
	REL=$(cat "$GKI/include/config/kernel.release")
	[ -z "$(git -C "$KS" status --porcelain -uno)" ] || fail "$KS is dirty for setlocalversion"
	mkdir -p "$OD" "$DIST"
	# config = the GKI .config + the port's 5.4 root options (MonsterROM k4-source/susfs/susfs.config)
	cp "$GKI/.config" "$OD/.config"
	"$KS/scripts/config" --file "$OD/.config" -e KSU -d KSU_DEBUG -e KSU_MULTI_MANAGER_SUPPORT -d KSU_TRACEPOINT_HOOK \
		-d KSU_MANUAL_HOOK -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_MOUNT -e KSU_SUSFS_SUS_KSTAT \
		-e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
		-e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG -e KSU_SUSFS_OPEN_REDIRECT -e KSU_SUSFS_SUS_MAP
	"${K[@]}" olddefconfig >/dev/null
	diff <(grep CONFIG_ "$GKI/.config" | grep -v KSU) <(grep CONFIG_ "$OD/.config" | grep -v KSU) >/dev/null || fail "config differs outside CONFIG_KSU*"
	for o in KSU KSU_MULTI_MANAGER_SUPPORT KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
		KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
		grep -q "^CONFIG_$o=y" "$OD/.config" || fail "CONFIG_$o did not take"
	done
	echo "building Image in $OD (log $OD/susfs-build.log)"
	"${K[@]}" -j"${J:-20}" Image > "$OD/susfs-build.log" 2>&1 || { tail -40 "$OD/susfs-build.log"; fail "make Image"; }
	grep -E '(^|[^a-z_])error:' "$OD/susfs-build.log" && fail "errors in the build log"

	DREL=$(cat "$OD/include/config/kernel.release")
	[ "$DREL" = "$REL" ] || fail "kernel.release $DREL != $REL (dirty tree?)"
	IREL=$(strings "$OD/arch/arm64/boot/Image" | sed -n 's/^Linux version \([^ ]*\) .*/\1/p' | head -1)
	[ "$IREL" = "$REL" ] || fail "Image says $IREL"
	grep -q ' a52bc_stage$' "$OD/System.map" && grep -q ' a52ram_write$' "$OD/System.map" || fail "a52bc not linked"
	grep -q ' susfs_init$' "$OD/System.map" && grep -q ' ksu_handle_susfs_cmd\| kernelsu_init$' "$OD/System.map" || fail "susfs / KernelSU not linked"

	# KMI: every export of the base Image must be there with the same CRC and namespace; new exports are listed
	# MODDIRS: dirs with the modules to check (default: the first stage of the newest OneUI build + the LKM flavours)
	MODDIRS=${MODDIRS:-$(ls -t "$TOP"/drivers612/realboot/out/rbou*/BUILDINFO 2> /dev/null | head -1 | sed 's|/BUILDINFO$|/work/vr/lib/modules|') $HERE/out $HERE/../kernelsu/out}
	python3 -I "$HERE/susfs/crc-compare.py" "$GKI/vmlinux.symvers" "$OD/vmlinux.symvers" "$DIST/crc-changed.txt" $MODDIRS | tee "$DIST/crc-compare.txt"
	cp "$OD/arch/arm64/boot/Image" "$OD/System.map" "$OD/vmlinux.symvers" "$DIST/"
	grep 'KSU' "$OD/.config" > "$DIST/susfs.config"
	cp "$DIAG/a52bc.c" "$DIAG/a52bc.h" "$DIAG/0001-a52bc-hooks.patch" "$DIST/"
	NCRC=$(wc -l < "$OD/vmlinux.symvers"); CH=$(grep -c '^CHANGED\|^MISSING' "$DIST/crc-changed.txt" || true)
	{ echo "release=$REL"; echo "base=$GKI (.config + CONFIG_KSU*; full rebuild from $KS)"
	  echo "variant: $(cat "$KS/.a52-susfs-applied")"
	  echo "ksu: $(grep -E -m2 'version (code|name)|KSU_VERSION' "$OD/susfs-build.log" | tr '\n' ' ')"
	  echo "susfs: $(sed -n 's/^#define SUSFS_VERSION //p' "$KS/include/linux/susfs.h") GKI, built in (CONFIG_KSU=y: no kernelsu.ko, no /ksuinit)"
	  echo "a52bc.c sha256 $(sha256sum < "$DIAG/a52bc.c" | cut -d' ' -f1)"
	  echo "Image sha256 $(sha256sum < "$DIST/Image" | cut -d' ' -f1), image_size $(printf %#x "$(od -An -tu8 -j16 -N8 "$DIST/Image" | tr -d ' ')")"
	  if [ "$CH" = 0 ]; then echo "modversion CRCs: $NCRC, all $(wc -l < "$GKI/vmlinux.symvers") of $GKI/vmlinux identical (+$(grep -c '^NEW' "$DIST/crc-changed.txt" || true) new exports)"
	  else echo "modversion CRCs: $NCRC, $CH CHANGED/MISSING vs $GKI/vmlinux (crc-changed.txt): modules importing them must be rebuilt"; fi
	  echo "modules: $(tail -1 "$DIST/crc-compare.txt") [$MODDIRS]"
	  echo "built $(date '+%F %T')"; } > "$DIST/BUILDINFO"
	cat "$DIST/BUILDINFO"
}

for step in ${@:-all}; do
	case "$step" in
		all) prepare; build ;;
		prepare|build) $step ;;
		*) echo "usage: $0 [prepare|build|all]" >&2; exit 2 ;;
	esac
done
