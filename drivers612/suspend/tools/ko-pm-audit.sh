#!/bin/bash
# Offline suspend/resume audit of every module of an Android test run on the 6.12 kernel.
# Reads only .ko files (llvm-nm), writes a TSV to stdout:
#   stage  module  pm_cbs  wake  wsrc  notif  rpm  pm_funcs
# pm_cbs   number of defined functions whose name looks like a system-sleep callback
#          (suspend/resume/freeze/thaw/poweroff/restore/prepare/complete/_pm_)
# wake     imports that arm/declare wake IRQs (irq_set_irq_wake, device_init_wakeup, ...)
# wsrc     imports that hold wakeup sources (__pm_stay_awake, pm_wakeup_ws_event, ...)
# notif    imports of PM-transition hooks (register_pm_notifier, register_syscore_ops,
#          cpu_pm_register_notifier, dev_pm_genpd_add_notifier, register_trace_suspend_resume)
# rpm      imports of runtime PM (__pm_runtime_*)
# pm_funcs up to 6 of the callback names
# Usage: tools/ko-pm-audit.sh [s68]   (kx-<name> dir of drivers612/androidboot/out)
set -eu
TOP=$(cd "$(dirname "$0")/../../.." && pwd)
RUN=${1:-s68}
NM=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-nm
DIST=$TOP/bsp612/out/dist/lib/modules
KREL=$(ls "$DIST" | head -1)
MODS=$TOP/drivers612/androidboot/out/kx-$RUN/ov/a52/mods
[ -d "$MODS" ] || { echo "no $MODS" >&2; exit 1; }
# shipped .ko files are partly stripped of local symbols: audit the unstripped build output of
# the same module when it exists (soc-repo-staging for BSP modules)
STG=$TOP/bsp612/soc-repo-staging
IDX=$(mktemp); trap 'rm -f "$IDX"' EXIT
find "$STG" -name '*.ko' -type f 2>/dev/null > "$IDX"
unstripped() { # path -> best path to audit
	local b; b=$(basename "$1"); b=${b#[0-9][0-9]-}
	if [ "$("$NM" "$1" 2>/dev/null | awk '$2=="t"' | wc -l)" -lt 3 ]; then
		local u; u=$(grep -m1 "/$b\$" "$IDX" || true); [ -n "$u" ] && { echo "$u"; return; }
	fi
	echo "$1"
}
audit() { # stage path
	local st=$1 ko=$2 n syms pm wake ws notif rpm names
	n=$(basename "$ko" .ko); n=${n#[0-9][0-9]-}
	syms=$("$NM" "$(unstripped "$ko")" 2>/dev/null || true)
	names=$(echo "$syms" | awk '$2 ~ /^[tT]$/ {print $3}' |
		grep -E '(suspend|resume|freeze|thaw|poweroff|restore|_pm_prepare|_pm_complete|_prepare_sleep|_pm_ops)' |
		grep -v -E '^(__|\.)' | grep -v -E 'runtime' | sort -u || true)
	pm=$(echo "$names" | grep -c . || true)
	wake=$(echo "$syms" | awk '$1=="U"{print $2}' | grep -c -x -E 'irq_set_irq_wake|device_init_wakeup|device_wakeup_enable|device_set_wakeup_capable|device_set_wakeup_enable|dev_pm_set_wake_irq|dev_pm_set_dedicated_wake_irq|devm_pm_set_wake_irq' || true)
	ws=$(echo "$syms" | awk '$1=="U"{print $2}' | grep -c -x -E '__pm_stay_awake|pm_stay_awake|pm_wakeup_ws_event|pm_wakeup_dev_event|wakeup_source_register|wakeup_source_create|wakeup_source_add|pm_system_wakeup' || true)
	notif=$(echo "$syms" | awk '$1=="U"{print $2}' | grep -x -E 'register_pm_notifier|register_syscore_ops|cpu_pm_register_notifier|dev_pm_genpd_add_notifier|register_trace_suspend_resume|register_trace_android_vh_.*suspend.*|register_trace_android_rvh_.*suspend.*' | tr '\n' ',' | sed 's/,$//' || true)
	rpm=$(echo "$syms" | awk '$1=="U"{print $2}' | grep -c -E '^__pm_runtime_|^pm_runtime_' || true)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$n" "$pm" "$wake" "$ws" "${notif:--}" "$rpm" \
		"$(echo "$names" | head -6 | tr '\n' ' ')"
}
printf 'stage\tmodule\tpm_cbs\twake\twsrc\tnotif\trpm\tpm_funcs\n'
while read -r p; do
	[ -n "$p" ] || continue
	if [ -f "$STG/$p" ]; then audit first "$STG/$p"; else audit first "$DIST/$KREL/$p"; fi
done < "$TOP/bsp612/out/bringup/load.paths"
for st in debug secure display kgsl i2c nfc touch fingerprint powerpd vibrator camera dsp wlanb audio wlan; do
	[ -f "$MODS/$st.list" ] || continue
	while read -r m _; do
		case "$m" in ''|'#'*|'&') continue;; esac
		[ -f "$MODS/$st/$m" ] && audit "$st" "$MODS/$st/$m"
	done < "$MODS/$st.list"
done
