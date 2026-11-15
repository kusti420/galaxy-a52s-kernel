#!/usr/bin/env python3
"""Offline insmod simulation of a REAL boot's module order (6.12 or 6.18).

  loadsim.py --krel <release> --symvers <vmlinux Module.symvers> [--builtin modules.builtin]
             <group>:<dir>:<load list> ...

Groups are loaded in the order given, each in the order of its list (first stage =
vendor_boot /lib/modules/modules.load, then /vendor/lib/modules/6.x by the vendor rc, then
macloader's 5.4-gki/qca_cld3_wlan.ko). The ELF checks are bsp618/android/check-load.py's
(analyse(): vermagic, every undefined symbol exported by vmlinux or an earlier module, modversion
CRCs, no duplicate exports, no clash with a GKI built-in), only the plan differs: no test
modules (hhwdt, testguard), no stages. A module that fails is not loaded, so its dependants fail
too. A name loaded twice counts as "already" (EEXIST). Exit 1 on any failure."""
import argparse, importlib.util, os, sys
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    'checkload', os.path.join(HERE, '../../../bsp618/android/check-load.py'))
cl = importlib.util.module_from_spec(spec); spec.loader.exec_module(cl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--krel', required=True)
    ap.add_argument('--symvers', required=True)
    ap.add_argument('--builtin')
    ap.add_argument('groups', nargs='+')
    a = ap.parse_args()
    vml = {}
    for l in open(a.symvers):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and f[2] == 'vmlinux':
            vml[f[1]] = int(f[0], 16)
    builtin = set()
    if a.builtin:
        builtin = {os.path.basename(l.strip())[:-3].replace('-', '_') for l in open(a.builtin) if l.strip()}
    plan = []
    for g in a.groups:
        name, d, lst = g.split(':', 2)
        plan += [(name, os.path.join(d, m)) for m in cl.read_list(lst)]
    loaded, exporter = {}, {}
    res = {'ok': 0, 'already': 0, 'fail': 0}
    per = {}
    fails = []
    for group, p in plan:
        per.setdefault(group, 0)
        if not os.path.exists(p):
            res['fail'] += 1; fails.append((group, os.path.basename(p), 'file missing')); continue
        m = cl.analyse(p)
        nm = m['name'].replace('-', '_')
        why = []
        if not m['vermagic'].startswith(a.krel + ' '):
            why.append(f"vermagic '{m['vermagic']}'")
        if nm in loaded:
            res['already'] += 1; continue
        if nm in builtin:
            why.append('name clashes with a GKI built-in module')
        for s in sorted(m['und']):
            if s in vml:
                crc = vml[s]
            elif s in exporter:
                crc = exporter[s][1]
            else:
                why.append(f'unknown symbol {s}'); continue
            if s in m['ver'] and crc is not None and m['ver'][s] != crc:
                why.append(f"CRC of {s}: module {m['ver'][s]:#010x}, exporter {crc:#010x}")
        for s in sorted(m['exp']):
            if s in vml:
                why.append(f'exports duplicate symbol {s} (vmlinux)')
            elif s in exporter:
                why.append(f'exports duplicate symbol {s} (owned by {exporter[s][0]})')
        if why:
            res['fail'] += 1; fails.append((group, os.path.basename(p), '; '.join(why[:6])))
            continue
        res['ok'] += 1; per[group] += 1
        loaded[nm] = m['exp']
        for s, c in m['exp'].items():
            exporter.setdefault(s, (nm, c))
    print(f"insmod simulation ({a.krel}, real boot order): {res['ok']} ok "
          f"({', '.join(f'{g} {n}' for g, n in per.items())}), {res['already']} already loaded, {res['fail']} FAIL")
    for f in fails:
        print('  FAIL', *f)
    return 1 if res['fail'] else 0


if __name__ == '__main__':
    sys.exit(main())
