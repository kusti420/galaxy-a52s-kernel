#!/usr/bin/env python3
"""Predict /proc/cmdline of a real boot on the Samsung ABL, and what the kernel cuts off.

  cmdline-sim.py --live <live.dtb> --stock-vendor-cmdline <file> --stock-dtb <stock base dtb>
                 --dt-bootargs <file> --vendor-cmdline <file> --config-cmdline <str>
                 --cmdline-size <n> -o <report>

How the string is built (measured on test phone 2, 5.4 LineageOS, testdev-*/live.dtb):
  ABL: /chosen/bootargs = <base dtb bootargs> + " " + <boot cmdline + vendor_boot cmdline>
       + " " + <the ABL's own arguments: androidboot.*, sec_debug.*, msm_drm.*, ...>
       (fdt_appendprop_string, donors/abl-edk2 UpdateDeviceTree.c)
  6.12 kernel (bsp612 drivers/of/fdt.c, CONFIG_CMDLINE_EXTEND): CONFIG_CMDLINE + " " +
       /chosen/bootargs, cut at COMMAND_LINE_SIZE - 1 bytes.
The ABL's own part is taken from the live tree (live bootargs minus the stock dtb bootargs and
the stock vendor cmdline). It depends on the phone and the boot (serial, panel id, revision,
param offsets), so the result is an estimate for that phone. --abl-min <n> assumes the ABL part
is at least <n> bytes (padded with a filler word) to check a worst-case append.
"""
import argparse, subprocess, sys

IMPORTANT = ('androidboot.', 'msm_drm.', 'sec_common_fn.', 'sec-battery.', 'sec_debug.',
             'sm5714_', 'sec_mparam.', 'android_arch_task_struct_size', 'firmware_class.path',
             'console=', 'bootconfig', 'kvm-arm.mode', 'sched_proxy_exec', 'ABL-PAD')

def fdtget(dtb, node, prop):
    return subprocess.run(['fdtget', dtb, node, prop], stdout=subprocess.PIPE, text=True,
                          check=True).stdout.rstrip('\n')

def main():
    ap = argparse.ArgumentParser()
    for k in ('live', 'stock-vendor-cmdline', 'stock-dtb', 'dt-bootargs', 'vendor-cmdline',
              'config-cmdline', 'cmdline-size', 'o'):
        ap.add_argument('--' + k if k != 'o' else '-o', required=True)
    ap.add_argument('--abl-min', type=int, default=0)
    a = ap.parse_args()
    live = fdtget(a.live, '/chosen', 'bootargs')
    stock_dt = fdtget(a.stock_dtb, '/chosen', 'bootargs')
    stock_vc = open(a.stock_vendor_cmdline).read().strip()
    prefix = stock_dt + ' ' + stock_vc
    if not live.startswith(prefix):
        sys.exit("live bootargs do not start with <stock dtb bootargs> <stock vendor cmdline>: "
                 "the ABL model does not fit this dump")
    abl = live[len(prefix):].strip()
    measured = len(abl)
    if len(abl) < a.abl_min:   # worst case: a longer bootloader append, filler at the very end
        abl = abl + ' ABL-PAD-' + 'x' * max(0, a.abl_min - len(abl) - 9)
    dt = open(a.dt_bootargs).read().strip(); vc = open(a.vendor_cmdline).read().strip()
    bootargs = ' '.join(x for x in (dt, vc, abl) if x)
    full = a.config_cmdline + ' ' + bootargs
    size = int(a.cmdline_size)
    kept = full[:size - 1]
    lost = full[size - 1:]
    # a word cut in the middle counts as lost
    if lost and not lost.startswith(' ') and not kept.endswith(' '):
        cut = kept.rfind(' '); lost = kept[cut + 1:] + lost; kept = kept[:cut]
    lost_words = lost.split()
    imp = [w for w in lost_words if w.startswith(IMPORTANT)]
    with open(a.o, 'w') as fh:
        fh.write(f"COMMAND_LINE_SIZE {size}; predicted length {len(full)}; "
                 f"ABL part {len(abl)} chars (measured {measured}); lost {len(lost_words)} words; "
                 f"headroom {size - 1 - len(full)}\n\n")
        fh.write("== predicted /proc/cmdline (kept part)\n" + kept + "\n\n")
        fh.write("== cut off by the kernel\n" + ('\n'.join(lost_words) or '(nothing)') + "\n")
    print(f"cmdline: {len(full)} chars predicted (ABL part {len(abl)}, measured {measured}), "
          f"COMMAND_LINE_SIZE {size}: {len(lost_words)} words lost, {len(imp)} of them important, "
          f"headroom {size - 1 - len(full)}")
    for w in imp[:12]:
        print("  LOST:", w)
    if len(imp) > 12:
        print(f"  ... {len(imp) - 12} more in {a.o}")
    sys.exit(3 if imp else 0)

if __name__ == '__main__':
    main()
