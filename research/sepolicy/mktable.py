#!/usr/bin/env python3
"""Mapping table for research/sepolicy/PATHS.md: every /devices/platform genfscon entry of the ROM
(genfscon-sysfs-lineage-a52sxq.txt) whose device exists in phone 2's 5.4 tree, with its path on
5.4, on 6.12 before the fix (rb10 tree) and now (5.4 layout tree), from the DT simulation of
drivers612/boarddt/tools/sysfscompat.py (platform devices: of_device_make_bus_id under the
populating buses; i2c: alias + dynamic numbering). Device directories created by drivers below
a DT device (input/, wakeup/, power_supply/, subsysN/, MFD cells, SPMI function devices) keep
the 5.4 suffix: their prefix is what the DT decides.

  mktable.py GENFSCON LIVE54.dtb OLD612.dtb NEW612.dtb > table.md
"""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../drivers612/boarddt/tools'))
import sysfscompat as sc

WRAP_RE = re.compile(r'/qcom,qupv3_\d_geni_se@[0-9a-f]+')

def devmap(dtb, kernel, failing=None):
    t = sc.load(dtb)
    dev, i2c = sc.simulate(t, kernel, failing)
    soc, ws = sc.wrappers(t)
    containers = set()   # buses: an entry that only reaches one of these names another board's device
    out = {}   # sysfs path -> (node path, kind)
    for k, v in dev.items():
        if isinstance(k, tuple):
            kind, n = k
            if kind in ('adap', 'spmi'): containers.add(v)
        else:
            kind, n = 'dev', k
            comp = n.strs('compatible')
            if any(x in sc.BUS_COMPAT for x in comp) or n in ws or any('spmi-pmic-arb' in x for x in comp) \
               or any(x in ('qcom,i2c-geni', 'i2c-gpio') for x in comp):
                containers.add(v)
        out[v] = (n.path(), kind)
    return out, containers

def norm(p):
    return WRAP_RE.sub('', p)

# devices of the 5.4 tree whose node is not in the 6.12 tree (or has another name there): what
# 6.12 has instead, checked by hand (research/sepolicy/PATHS.md)
NOTES = [
    (r'/subsys\d+(/(name|restart_level))?$', 'same path: subsys_compat.ko (first stage) registers a parent device named like the 5.4 PIL device under /soc + subsysN with the 5.4 index'),
    (r'(\.qcom,(lpass|turing|mss|venus)|soc:qcom,(kgsl-hyp|ipa_fws|wpss@8a00000))(/subsys\d+)?(/wakeup)?$',
     'parent + subsysN exist (subsys_compat.ko), but no wakeup source on them on 6.12: nothing to label'),
    (r'/devfreq$', 'no such devfreq device on 6.12: CPU/bus DCVS is qcom-dcvs + memlat + bwmon (PATHS.md section 4)'),
    (r'hall_ic', 'hall sensor not ported (6.12 tree: hall_keys gpio-keys, disabled)'),
    (r'soc:hwevent', 'CoreSight hwevent: no node in the 6.12 tree'),
    (r'soc:i2c@17/i2c-19/19-0028', 'i2c-gpio (=m) and sx9360 are not loaded on 6.12; /aliases i2c19 keeps the 5.4 number once they are'),
    (r'msm-ext-disp', 'external display (DP) not in the 6.12 tree (placeholder node only)'),
]

def main():
    gf, live, old, new = sys.argv[1:5]
    m54, cont54 = devmap(live, 54)
    mold, _ = devmap(old, 612)
    mnew, _ = devmap(new, 612, failing=())   # as if a80000 probed (see the note below the table)
    # node identity across trees: node path without the qupv3 wrapper component + kind
    def index(m):
        r = {}
        for p, (n, kind) in m.items(): r[(norm(n), kind)] = p
        return r
    iold, inew = index(mold), index(mnew)
    rows = []; absent = []; other = 0
    entries = set(l.split()[0] for l in open(gf) if l.strip())
    for line in open(gf):
        if not line.strip(): continue
        path, label = line.split()[:2]
        if not path.startswith('/devices/platform/'): continue
        p = path.rstrip('/')
        best = ''
        for sp in m54:
            if sp in cont54: continue
            if (p + '/').startswith(sp + '/') and len(sp) > len(best): best = sp
        if not best or (p in cont54 and p != best):
            other += 1; continue
        node, kind = m54[best]
        suffix = p[len(best):]
        key = (norm(node), kind)
        po, pn = iold.get(key), inew.get(key)
        if pn is None:
            note = next((t for r, t in NOTES if re.search(r, p)), '?')
            absent.append((path, label, node, note)); continue
        o = po + suffix if po else '(absent)'
        n = pn + suffix
        st = 'same as 5.4' if n == p and o == p else ('FIXED' if n == p else 'differs')
        if st == 'differs' and '/spmi0-' in p:
            twin = re.sub(r'/spmi0-', '/0-', path)
            st = ('5.4 SPMI device name (spmi0-NN); the policy\'s 0-NN twin entry matches 6.12' if twin in entries
                  else 'differs: 6.12 SPMI device is 0-NN, the policy has only the 5.4 spmi0-NN spelling')
        if '/a80000.i2c/' in p: st += ' (bus a80000 does not probe on 6.12 yet: GPIO 32/33 reserved)'
        rows.append((path, label, o, n, st, node))
    print('| 5.4 genfscon path | label | 6.12 rb10 (before) | 6.12/6.18 now | |')
    print('|---|---|---|---|---|')
    def short(x): return x.replace('/devices/platform/', '…/')
    for path, label, o, n, st, node in rows:
        oo = '=' if o == path else short(o)
        nn = '=' if n == path else short(n)
        print('| `%s` | %s | %s | %s | %s |' % (short(path), label, oo if oo == '=' else '`%s`' % oo, nn if nn == '=' else '`%s`' % nn, st))
    print()
    print('%d entries map to a device of the phone\'s 5.4 tree: %d FIXED, %d were the same as 5.4 already, %d SPMI spellings (see status); '
          '%d whose DT node is not in the 6.12 tree; %d entries name devices this phone does not have (other boards/SoCs).'
          % (len(rows) + len(absent), sum(r[4].startswith('FIXED') for r in rows), sum(r[4] == 'same as 5.4' for r in rows),
             sum(not r[4].startswith('FIXED') and r[4] != 'same as 5.4' for r in rows), len(absent), other))
    if absent:
        print()
        print('Device of the 5.4 tree with no node of the same path in the 6.12 tree:')
        print()
        print('| 5.4 genfscon path | label | 5.4 DT node | 6.12 |')
        print('|---|---|---|---|')
        for path, label, node, note in absent:
            print('| `%s` | %s | `%s` | %s |' % (short(path), label, node, note))

if __name__ == '__main__':
    main()
