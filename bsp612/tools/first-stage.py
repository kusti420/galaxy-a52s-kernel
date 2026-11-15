#!/usr/bin/env python3
"""Proposes a first-stage (ramdisk) module list for a52sxq bring-up on the 6.12 BSP:
Qualcomm's own first-stage list for lahaina (modules-lists/modules.list.msm.lahaina) without
the entries this build does not produce and without the SM8350-only parts, plus USB (not in
Qualcomm's first stage), closed over modules.dep and written in load order (dependencies first).
Usage: first-stage.py out/dist   -> out/dist/first-stage.a52sxq.list"""
import os, re, sys
D = sys.argv[1]
R = os.path.join(D, 'lib/modules', os.listdir(os.path.join(D, 'lib/modules'))[0])
dep, path = {}, {}
for l in open(os.path.join(R, 'modules.dep')):
    k, v = l.split(':', 1)
    n = os.path.basename(k); path[n] = k
    dep[n] = [os.path.basename(x) for x in v.split()]
bsp = os.path.dirname(os.path.dirname(os.path.abspath(D)))
qc = [l.strip() for l in open(os.path.join(bsp, 'soc-repo/modules-lists/modules.list.msm.lahaina')) if l.strip().endswith('.ko')]
SM8350_ONLY = {'gcc-sm8350.ko', 'dispcc-sm8350.ko', 'pinctrl-lahaina.ko', 'qnoc-lahaina.ko',
               'phy-qcom-ufs-qmp-v4-lahaina.ko', 'phy-qcom-ufs-qrbtc-sdm845.ko'}
USB = ['dwc3-msm.ko', 'phy-msm-snps-hs.ko', 'phy-msm-ssusb-qmp.ko']
# PMIC GPIOs and the power/volume keys, which Qualcomm loads later (from vendor_dlkm).
EXTRA = ['pinctrl-spmi-gpio.ko', 'qcom-pon.ko', 'pm8941-pwrkey.ko']
seeds, skipped = [], []
for m in qc + USB + EXTRA:
    if m in SM8350_ONLY: continue
    (seeds if m in dep else skipped).append(m)
order, seen = [], set()
def visit(m):
    if m in seen: return
    seen.add(m)
    for d in dep.get(m, []): visit(d)
    order.append(m)
for m in seeds: visit(m)
out = os.path.join(D, 'first-stage.a52sxq.list')
with open(out, 'w') as f:
    for m in order: f.write(path[m] + '\n')
size = sum(os.path.getsize(os.path.join(R, path[m])) for m in order)
print(f"{out}: {len(order)} modules ({len(seeds)} seeds), {size/1e6:.1f} MB stripped; not built, skipped: {' '.join(skipped)}")
