#!/system/bin/sh
# Samsung / TEE service health: init service states (the Knox, TEE, HAL daemons OneUI starts), restart loops,
# Knox/TIMA properties. Read-only.
. "${0%/*}/../dev-lib.sh"
all=$(getprop | grep -E '^\[init\.svc\.[^]]+\]: ' | sed -e 's/^\[init\.svc\.//' -e 's/\]: \[/=/' -e 's/\]$//')
rs=$(printf '%s\n' "$all" | grep -E '=restarting$' | cut -d= -f1 | tr '\n' ' ')
if [ -z "$rs" ]; then C svc.restarting PASS kernel+ROM "0 restarting" "$(printf '%s\n' "$all" | grep -c =running) running, $(printf '%s\n' "$all" | grep -c =stopped) stopped"; else C svc.restarting FAIL kernel+ROM "restarting: $rs"; fi
M svc_running "$(printf '%s\n' "$all" | grep -c =running)"
setl svc.running_set kernel+ROM 60 "$(printf '%s\n' "$all" | grep -E '=running$' | cut -d= -f1 | tr '\n' ' ')"
# the daemons OneUI needs for Knox / TEE / Samsung HALs; state must be the same on both kernels
for s in vaultkeeper vaultkeeper_hal cass proca drk_hal engmode_hal vendor.wvkprov_default vendor.qseecomd qseecom-service \
	vendor.keymaster-4-0 vendor.fkeymaster-default vendor.gatekeeper-1-0 keystore2 gatekeeperd credstore \
	vendor.drm-widevine-hal-1-3 vendor.trustedui-1-0 vendor.fps_hal vendor.face_hal sec-camera-provider-4-0 \
	sec-miscpower-2-0 sec-sysinput-1-3 sec-thermal-1-0 sec-vibrator-aidl vendor.samsung.hardware.hyper-default \
	vendor.samsung.power-default vendor.samsung.hardware.light-default health-hal-2-1-samsung vendor.usb-hal-1-3 \
	nfc_hal_service vendor.sensors-hal-2-0-multihal vendor.audio-hal vendor.ipacm thermal-engine ril-daemon \
	vendor.qti.hardware.display.composer argos-daemon pageboostd iod emservice mppserver snapaidl imsd \
	vendor.bluetooth-1-0-qti vendor.wifi_hal_legacy cnss-daemon vendor.pd_mapper vendor.rmt_storage vendor.tftp_server \
	vendor.adsprpcd vendor.cdsprpcd vendor.sensors loc_launcher gnss_service; do
	st=$(svc "$s"); pid=$(getprop "init.svc_debug_pid.$s")
	case "$st" in
		running) if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then C "svc.$s" FAIL kernel+ROM "running (pid gone)" "init says running, /proc/$pid missing"; else C "svc.$s" PASS kernel+ROM running "boottime $(( $(num "$(getprop ro.boottime.$s)") / 1000000 )) ms"; fi;;
		restarting) C "svc.$s" FAIL kernel+ROM restarting;;
		"") C "svc.$s" SKIP ROM "no such service" "init.svc.$s unset";;
		*) C "svc.$s" PASS kernel+ROM "$st" "not running (oneshot or disabled); compare with the other kernel";;
	esac
done
# Knox / TIMA / verified boot properties (explicit list: no identifiers)
kp=
for p in ro.boot.warranty_bit ro.warranty_bit ro.vendor.boot.warranty_bit ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state \
	ro.boot.veritymode ro.config.knox ro.config.tima ro.config.iccc_version ro.config.kap ro.config.dmverity ro.security.knoxmatrix \
	vendor.security.vaultkeeper.native ro.security.vaultkeeper.feature ro.boot.security_mode ro.security.keystore.keytype \
	ro.security.fips.ux ro.security.mdf.ux ro.knox.enhance.zygote.aslr ro.boot.em.status ro.boot.sec_atd.tty ro.build.selinux; do
	kp="$kp $p=$(getprop $p)"
done
C sec.knox_props PASS kernel+ROM "$kp"
C sec.boot_identity PASS info "bootloader=$(getprop ro.boot.bootloader) build=$(getprop ro.build.display.id)" "kernel $(uname -r)"
C sec.selinux "$([ "$(getenforce)" = Enforcing ] && echo PASS || echo FAIL)" kernel+ROM "$(getenforce)" "policyvers $(rd /sys/fs/selinux/policyvers) deny_unknown $(rd /sys/fs/selinux/deny_unknown) su context $(id -Z 2>/dev/null)"
# TEE nodes the Samsung TAs go through
nodes sec.tee_nodes kernel /dev/qseecom /dev/smcinvoke
for n in /dev/qseecom /dev/smcinvoke /dev/qce /dev/hw_random /dev/dek_evt /dev/dek_req /dev/dek_log /dev/dek_kek /dev/proca_config; do
	if [ -e "$n" ]; then C "sec.node.${n#/dev/}" PASS kernel "present $(lz $n)"; else C "sec.node.${n#/dev/}" FAIL kernel absent; fi
done
# listeners qseecomd registered (rpmb, ssd, sec ui, time...) and TA processes alive
C sec.tee_procs PASS kernel+ROM "$(for p in qseecomd vaultkeeperd wvkprov cass; do echo "$p=$(pidof $p >/dev/null 2>&1 && echo up || echo down)"; done | tr '\n' ' ')"
