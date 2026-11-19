#!/bin/bash
# Regenerates work/ from the phone's 5.4 camera techpack (read-only source) and
# builds camera.ko against the 6.12 BSP. Every change to the donor is made by
# port612.py or by compat/, so the port can be redone from the Samsung source.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PRJ=$(cd "$HERE/../.." && pwd)
SRC=${SRC:-$HOME/git/android/kernel/samsung/sm7325/techpack/camera}
W=$HERE/work
LLVM=$HOME/git/android/prebuilts/clang/host/linux-x86/clang-r547379/bin/
if [ "$1" != "build" ]; then
	rm -rf "$W"; mkdir -p "$W"
	cp -r "$SRC/drivers" "$SRC/include" "$W/"
	cp -r "$HERE/compat" "$W/compat"
	python3 "$HERE/port612.py" "$W/drivers"
	sed -e 's#^cameratree := $(srctree)/techpack/camera/drivers#cameratree := $(src)#' \
	    -e 's#-I$(srctree)/techpack/camera/include/uapi/camera#-I$(src)/../compat -I$(src)/../compat/ioncompat-include -I$(src)/../compat/ioncompat-include/uapi -I$(src)/../include/uapi/camera -I$(src)/../include/uapi -I$(src)/../include -include $(src)/../compat/a52sxq_camera_conf.h -include $(src)/../compat/cam_compat_612.h#' \
	    -e '/BOARD_VENDOR_KERNEL_MODULES/d' -e '/SPECTRA CAMERA IS BUILT AS DLKM/d' \
	    -e '/^ccflags-y += -I$(srctree)$/d' \
	    "$SRC/drivers/Makefile" > "$W/drivers/Kbuild"
	rm -f "$W/drivers/Makefile"
	cat "$HERE/Kbuild.tail" >> "$W/drivers/Kbuild"
fi
SYM="$PRJ/bsp612/soc-repo-staging/build/Module.symvers"
[ -f "$SYM" ] || SYM=$(ls "$PRJ"/bsp612/out/lahaina/*/Module.symvers 2>/dev/null | head -1)
# ion_alloc's modversion CRC must be the one of the ioncompat.ko that is LOADED on the phone = the
# drivers612/secure/ioncompat build (stage secure of the test ramdisks). deps/ioncompat is an older copy
# with another CRC: a camera.ko built against it fails to load ("disagrees about version of symbol
# ion_alloc", rehearsal rh612p2a40 2026-11-18).
IONDEF=$PRJ/drivers612/secure/ioncompat/Module.symvers; [ -f "$IONDEF" ] || IONDEF=$HERE/deps/ioncompat/Module.symvers
KBUILD_BUILD_USER=android-build KBUILD_BUILD_HOST=localhost make -C "$PRJ/bsp612/kernel" ARCH=arm64 \
	LLVM=$LLVM O="$PRJ/bsp612/out/lahaina" M="$W/drivers" \
	KBUILD_EXTRA_SYMBOLS="$SYM ${ION_SYMVERS:-$IONDEF} ${FLED_SYMVERS:-$HERE/deps/sm5714-fled-stub/Module.symvers}" \
	CONFIG_SPECTRA_CAMERA=m CONFIG_SPECTRA_ISP=y CONFIG_SPECTRA_SENSOR=y CONFIG_SPECTRA_ICP=y \
	CONFIG_SPECTRA_JPEG=y CONFIG_SPECTRA_LRME=y \
	CONFIG_CAMERA_FRAME_CNT_DBG=y CONFIG_SAMSUNG_OIS_MCU_STM32=y \
	CONFIG_QCOM_CX_IPEAK= CONFIG_QCOM_BUS_SCALING= CONFIG_MSM_GLOBAL_SYNX= CONFIG_LEDS_QPNP_FLASH_V2= \
	modules -k -j20 > "$HERE/build.log" 2>&1 || true
echo "errors: $(grep -c ' error:' "$HERE/build.log")"
grep -E ' error:|undefined!|ERROR:' "$HERE/build.log" | sed "s#.*/work/drivers/##" | sort | uniq -c | sort -rn | head -${N:-60}
ls -la "$W"/drivers/*.ko 2>/dev/null
