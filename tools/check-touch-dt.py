#!/usr/bin/env python3
"""Offline check of the mainline a52sxq touch description against the phone's downstream tree.

Usage: tools/check-touch-dt.py <sm7325-samsung-a52sxq.dtb> [downstream-dt/a52sxq-r02.dts]
Checks: I2C13 (i2c@a94000), its QUP wrapper and GPI DMA 1 enabled; touchscreen@49 with
compatible st,fts5cu56a; interrupt = TLMM <downstream sec,irq_gpio> level-low; avdd-supply = the
regulator downstream uses for tsp_avdd_ldo, pinned min == max at its downstream voltage.
"""
import re
import sys

import libfdt
from libfdt import QUIET_NOTFOUND, Fdt

dtb = Fdt(open(sys.argv[1], 'rb').read())
src = open(sys.argv[2] if len(sys.argv) > 2 else 'downstream-dt/a52sxq-r02.dts').read()
bad = []


def block(text, start):
    i = text.index(start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                return text[i:j]
    raise ValueError(start)


# downstream facts
ds = block(src, 'tsp_stm: touchscreen@49 {')
irq_gpio = int(re.search(r'sec,irq_gpio = <0x[0-9a-f]+ (0x[0-9a-f]+)', ds).group(1), 16)
avdd_ph = int(re.search(r'tsp_avdd_ldo-supply = <(0x[0-9a-f]+)>', ds).group(1), 16)
avdd = None
for line in open('downstream-dt/regulators-r02.txt'):
    if f'ph={avdd_ph:#x}' in line.split():
        avdd = (line.split()[1], line.split()[2].split(',')[0],
                int(line.split('min=')[1].split()[0]), int(line.split('max=')[1].split()[0]))
if avdd is None:
    sys.exit(f'FAIL downstream tsp_avdd_ldo phandle {avdd_ph:#x} not in regulators-r02.txt')
if avdd[2] != avdd[3]:
    bad.append(f'downstream AVDD range {avdd[2]}-{avdd[3]} is not a single voltage')


def find(path):
    off = 0
    for comp in [c for c in path.split('/') if c]:
        sub = dtb.first_subnode(off, QUIET_NOTFOUND)
        while sub >= 0 and dtb.get_name(sub) != comp:
            sub = dtb.next_subnode(sub, QUIET_NOTFOUND)
        if sub < 0:
            return -1
        off = sub
    return off


def prop(off, name):
    v = dtb.getprop(off, name, QUIET_NOTFOUND)
    return None if isinstance(v, int) else bytes(v)


def cells(b):
    return [int.from_bytes(b[i:i + 4], 'big') for i in range(0, len(b), 4)]


for p in ('/soc@0/dma-controller@a00000', '/soc@0/geniqup@ac0000', '/soc@0/geniqup@ac0000/i2c@a94000'):
    o = find(p)
    if o < 0 or prop(o, 'status') != b'okay\0':
        bad.append(f'{p} not okay')

ts = find('/soc@0/geniqup@ac0000/i2c@a94000/touchscreen@49')
if ts < 0:
    sys.exit('FAIL touchscreen@49 missing\n' + '\n'.join('FAIL ' + b for b in bad))
if prop(ts, 'compatible') != b'st,fts5cu56a\0':
    bad.append(f'compatible {prop(ts, "compatible")}')
if cells(prop(ts, 'reg') or b'') != [0x49]:
    bad.append('reg is not 0x49')

tlmm = find('/soc@0/pinctrl@f100000')
irq = cells(prop(ts, 'interrupts-extended') or b'')
if len(irq) != 3 or irq[0] != dtb.get_phandle(tlmm) or irq[1] != irq_gpio or irq[2] != 8:
    bad.append(f'interrupts-extended {irq}: want <&tlmm {irq_gpio} IRQ_TYPE_LEVEL_LOW>')

sup = cells(prop(ts, 'avdd-supply') or b'')
reg = dtb.node_offset_by_phandle(sup[0], QUIET_NOTFOUND) if sup else -1
name = dtb.get_name(reg) if reg >= 0 else None
# downstream "ldoc7" = PM8350C (regulators-1, pmic-id c) ldo7
want_name = 'ldo' + avdd[0][4:] if avdd[0].startswith('ldo') else None
parent = dtb.parent_offset(reg, QUIET_NOTFOUND) if reg >= 0 else -1
pmic_id = prop(parent, 'qcom,pmic-id') if parent >= 0 else None
if name != want_name or pmic_id != avdd[0][3:4].encode() + b'\0':
    bad.append(f'avdd-supply -> {name} (pmic {pmic_id}), want {avdd[0]} ({avdd[1]})')
else:
    lo = cells(prop(reg, 'regulator-min-microvolt') or b'')
    hi = cells(prop(reg, 'regulator-max-microvolt') or b'')
    if lo != [avdd[2]] or hi != [avdd[3]]:
        bad.append(f'{avdd[1]} pinned {lo}/{hi}, downstream {avdd[2]}/{avdd[3]}')

if prop(ts, 'vdd-supply') is not None:
    bad.append('vdd-supply present (downstream: sec,unuse_dvdd_power, I/O rail always on)')

if bad:
    print('\n'.join('FAIL ' + b for b in bad))
    sys.exit(1)
print(f'ok   touch dtb: FTS5CU56A i2c@a94000 0x49, TLMM {irq_gpio} level-low, AVDD {avdd[1]} '
      f'{avdd[2]} uV = downstream tsp_avdd_ldo, GPI DMA 1 + QUP1 + I2C13 okay')
